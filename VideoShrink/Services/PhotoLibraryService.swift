import Photos
import AVFoundation
import CoreLocation

@MainActor final class PhotoLibraryService: PhotoLibraryServing {
    private let manager = PHImageManager.default()
    private var pending: CheckedContinuation<RetrievedVideo, Error>?
    private var requestID: PHImageRequestID?
    private var token: UUID?

    func requestAccess() async throws -> Bool {
        var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if status == .notDetermined {
            status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        }
        try Task.checkCancellation()
        guard status == .authorized || status == .limited else { throw PipelineError.permissionDenied }
        return status == .limited
    }

    func retrieve(identifier: String, progress: @escaping @MainActor (Double) -> Void) async throws -> RetrievedVideo {
        try Task.checkCancellation()
        guard let photo = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject
        else { throw PipelineError.assetUnavailable }
        let resources = PHAssetResource.assetResources(for: photo)
        // The same rules the library scan uses, so anything the scan offers can be processed.
        let traits = AssetRules.Traits(
            isVideo: photo.mediaType == .video,
            isHighFrameRate: photo.mediaSubtypes.contains(.videoHighFrameRate),
            isTimeLapse: photo.mediaSubtypes.contains(.videoTimelapse),
            isSpatial: photo.mediaSubtypes.contains(.spatialMedia),
            hasAdjustmentData: resources.contains { $0.type == .adjustmentData },
            hasFullSizeVideo: resources.contains { $0.type == .fullSizeVideo },
            hasPairedVideo: resources.contains { $0.type == .pairedVideo })
        guard AssetRules.unsupportedReason(traits) == nil else { throw PipelineError.unsupported }
        let options = PHVideoRequestOptions()
        options.version = .original
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        let operation = UUID()
        token = operation
        options.progressHandler = { [weak self] fraction, _, _, _ in
            Task { @MainActor in
                guard let self, self.token == operation else { return }
                progress(fraction)
            }
        }
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                pending = continuation
                requestID = manager.requestAVAsset(forVideo: photo, options: options) { [weak self] asset, _, info in
                    let wasCancelled = (info?[PHImageCancelledKey] as? Bool) == true
                    let requestError = info?[PHImageErrorKey] as? Error
                    Task { @MainActor in
                        guard let self, self.token == operation else { return }
                        if wasCancelled {
                            self.finish(.failure(PipelineError.cancelled))
                        } else if let requestError {
                            self.finish(.failure(PipelineError.normalize(requestError, fallback: .retrieval)))
                        } else if let fileAsset = asset as? AVURLAsset, fileAsset.url.isFileURL {
                            self.finish(.success(RetrievedVideo(
                                asset: fileAsset,
                                identity: Self.identity(for: photo, resources: resources))))
                        } else if asset == nil {
                            self.finish(.failure(PipelineError.retrieval))
                        } else {
                            self.finish(.failure(PipelineError.unsupported))
                        }
                    }
                }
            }
        }, onCancel: {
            Task { @MainActor [weak self] in
                guard self?.token == operation else { return }
                self?.cancelRetrieval()
            }
        })
    }

    private func finish(_ result: Result<RetrievedVideo, Error>) {
        let continuation = pending
        pending = nil
        requestID = nil
        token = nil
        continuation?.resume(with: result)
    }

    func cancelRetrieval() {
        let oldID = requestID
        finish(.failure(PipelineError.cancelled))
        if let oldID { manager.cancelImageRequest(oldID) }
    }

    func save(videoAt url: URL, identity: AssetIdentity) async throws -> String? {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { throw PipelineError.permissionDenied }
        // An accepted Photos change transaction cannot be cancelled. Keep the file until completion.
        let created = CreatedAssetBox()
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            let options = PHAssetResourceCreationOptions()
            options.shouldMoveFile = false
            // The copy keeps the original's filename, so it is recognisable in Photos and in Finder.
            if let name = identity.originalFilename, !name.isEmpty {
                options.originalFilename = name
            }
            request.addResource(with: .video, fileURL: url, options: options)
            request.creationDate = identity.creationDate
            if let coordinate = identity.coordinate, coordinate.isValid {
                request.location = CLLocation(latitude: coordinate.latitude,
                                              longitude: coordinate.longitude)
            }
            request.isFavorite = identity.isFavorite
            if identity.isHidden { request.isHidden = true }
            created.identifier = request.placeholderForCreatedAsset?.localIdentifier
        }
        return created.identifier
    }

    /// Deletes originals through the supported Photos change request. Photos moves them to
    /// Recently Deleted and keeps them for 30 days, which is also when the space comes back.
    ///
    /// Everything in one call is one transaction, and Photos asks the user to confirm a
    /// transaction once. Batching is therefore the only lever there is over how often the system
    /// prompt appears.
    func deleteOriginals(identifiers: [String]) async throws -> [String] {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { throw PipelineError.permissionDenied }
        let assets = identifiers.compactMap { identifier in
            PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject
        }
        guard !assets.isEmpty else { throw PipelineError.assetUnavailable }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets(assets as NSArray)
        }
        return assets.map(\.localIdentifier)
    }

    /// The parts of an original that should travel with its copy.
    private static func identity(for photo: PHAsset, resources: [PHAssetResource]) -> AssetIdentity {
        let coordinate = photo.location.map {
            AssetIdentity.Coordinate(latitude: $0.coordinate.latitude,
                                     longitude: $0.coordinate.longitude)
        }
        return AssetIdentity(creationDate: photo.creationDate,
                             originalFilename: resources.first { $0.type == .video }?.originalFilename,
                             coordinate: coordinate,
                             isFavorite: photo.isFavorite,
                             isHidden: photo.isHidden)
    }

    /// Hands back a file for an asset this app created moments ago. Network access stays off: the
    /// copy was written on this iPhone, so if Photos cannot produce it locally the caller is told
    /// nothing rather than given something to download.
    func localFileURL(identifier: String) async -> URL? {
        guard let photo = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject
        else { return nil }
        let options = PHVideoRequestOptions()
        options.version = .original
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = false
        return await withCheckedContinuation { (continuation: CheckedContinuation<URL?, Never>) in
            var finished = false
            manager.requestAVAsset(forVideo: photo, options: options) { requested, _, _ in
                guard !finished else { return }
                finished = true
                guard let urlAsset = requested as? AVURLAsset, urlAsset.url.isFileURL else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: urlAsset.url)
            }
        }
    }

    /// Hands back a player item for the original. PhotoKit decides whether that streams from iCloud
    /// or comes from the phone, and this never asks for the export-grade original, so a quick look
    /// does not pull down a full-quality copy just to show a few seconds.
    func playerItem(identifier: String) async throws -> AVPlayerItem {
        guard let photo = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject
        else { throw PipelineError.assetUnavailable }
        let options = PHVideoRequestOptions()
        options.version = .current
        options.deliveryMode = .automatic
        options.isNetworkAccessAllowed = true
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<AVPlayerItem, Error>) in
            var finished = false
            manager.requestPlayerItem(forVideo: photo, options: options) { item, info in
                guard !finished else { return }
                finished = true
                if let item {
                    continuation.resume(returning: item)
                } else {
                    let error = info?[PHImageErrorKey] as? Error
                    continuation.resume(throwing: PipelineError.normalize(error ?? PipelineError.retrieval,
                                                                         fallback: .retrieval))
                }
            }
        }
    }
}

/// The change block may run off the main actor, so the identifier comes back in a box.
private final class CreatedAssetBox: @unchecked Sendable {
    var identifier: String?
}
