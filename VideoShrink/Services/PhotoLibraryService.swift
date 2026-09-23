import Photos
import AVFoundation
import CoreLocation

/// What a revalidated deletion transaction did. The three methods that produce it are declared on
/// `PhotoLibraryServing`, because the check has to live on the producing side: a caller cannot be
/// trusted to remember to re-check, and the returned values are plain so the decision itself stays
/// in `DeletionPolicy`.
struct DeletionResult: Equatable, Sendable {
    /// The originals Photos found and removed. Anything else was already gone.
    var deleted: [String] = []
    /// Originals that were left alone, with the reason the fresh look gave.
    var rejected: [String: CopyRevalidation] = [:]
}

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
        // Cinematic and shared-or-restricted items are the two extra traits the scan can decide
        // from library metadata alone; HDR and ProRes cannot be decided here and keep their
        // defaults, exactly as they do in the scan.
        let source = photo.sourceType
        let traits = AssetRules.Traits(
            isVideo: photo.mediaType == .video,
            isHighFrameRate: photo.mediaSubtypes.contains(.videoHighFrameRate),
            isTimeLapse: photo.mediaSubtypes.contains(.videoTimelapse),
            isSpatial: photo.mediaSubtypes.contains(.spatialMedia),
            hasAdjustmentData: resources.contains { $0.type == .adjustmentData },
            hasFullSizeVideo: resources.contains { $0.type == .fullSizeVideo },
            hasPairedVideo: resources.contains { $0.type == .pairedVideo },
            isCinematic: photo.mediaSubtypes.contains(.videoCinematic),
            isSharedOrRestricted: source.contains(.typeCloudShared)
                || source.contains(.typeiTunesSynced)
                || !photo.canPerform(.delete))
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

    /// The receipt to store next to a saved copy: which asset Photos created, and what both assets
    /// looked like at the moment it was checked.
    ///
    /// Returns nil unless both can be looked up now, so a receipt is never written from an
    /// assumption. The caller stores it with the queue; it is the only thing that can later
    /// justify a delete, and only when a fresh look agrees with it.
    func deletionEvidence(originalIdentifier: String, copyIdentifier: String) -> DeletionEvidence? {
        guard let copy = snapshot(identifier: copyIdentifier),
              let source = snapshot(identifier: originalIdentifier) else { return nil }
        return DeletionEvidence(copy: copy, source: source)
    }

    /// Looks the copy and the original up again, right before a delete would be submitted, and
    /// says whether the stored receipt still holds.
    ///
    /// Nothing here trusts the receipt on its own. Access is re-checked first, so revoked or
    /// narrowed access keeps every original. Under limited access, an asset outside the allowed
    /// set is simply not fetched, which reads as missing here and keeps the original too.
    func revalidateForDeletion(_ evidence: DeletionEvidence) -> CopyRevalidation {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { return .accessDenied }
        guard evidence.verifiedCopyIdentifier != nil else { return .copyMissing }
        guard let copy = snapshot(identifier: evidence.copy.identifier) else { return .copyMissing }
        guard copy.stillMatches(evidence.copy) else { return .copyChanged }
        guard let source = snapshot(identifier: evidence.source.identifier) else { return .sourceMissing }
        guard source.stillMatches(evidence.source) else { return .sourceChanged }
        return .matches
    }

    /// Deletes only the originals whose copy and original both still look exactly as recorded.
    ///
    /// This is the path that makes "checked when it entered the group" insufficient: a copy that
    /// was edited or removed while the group waited is caught here, moments before Photos is
    /// asked. A candidate with no receipt is rejected without looking at Photos at all.
    func deleteOriginals(afterRevalidating evidence: [String: DeletionEvidence]) async throws -> DeletionResult {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { throw PipelineError.permissionDenied }
        var outcomes: [String: CopyRevalidation] = [:]
        for (identifier, receipt) in evidence {
            outcomes[identifier] = revalidateForDeletion(receipt)
        }
        let checked = DeletionPolicy.split(evidence, outcomes: outcomes)
        guard !checked.approved.isEmpty else {
            return DeletionResult(deleted: [], rejected: checked.rejected)
        }
        let deleted = try await deleteOriginals(identifiers: checked.approved)
        return DeletionResult(deleted: deleted, rejected: checked.rejected)
    }

    /// What Photos reports for one asset right now, using only documented `PHAsset` properties.
    /// Nil means the asset is not in the library as far as this app can see.
    func snapshot(identifier: String) -> AssetSnapshot? {
        guard !identifier.isEmpty,
              let photo = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject
        else { return nil }
        return AssetSnapshot(identifier: photo.localIdentifier,
                             duration: photo.duration,
                             pixelWidth: photo.pixelWidth,
                             pixelHeight: photo.pixelHeight,
                             creationDate: photo.creationDate,
                             modificationDate: photo.modificationDate,
                             bytes: onDeviceBytes(of: photo))
    }

    /// `PHAssetResource.dataSize` is public API from iOS 27, exactly as the library scan probes it.
    /// Nil means the running system has no such property or Photos reported nothing, and a size
    /// that cannot be read is not treated as evidence that the asset changed.
    private func onDeviceBytes(of photo: PHAsset) -> Int64? {
        for resource in PHAssetResource.assetResources(for: photo) where resource.type == .video {
            guard resource.responds(to: Self.dataSizeSelector) else { return nil }
            guard let value = resource.perform(Self.dataSizeSelector)?.takeUnretainedValue() as? NSNumber
            else { continue }
            let size = value.int64Value
            if size > 0 { return size }
        }
        return nil
    }

    private static let dataSizeSelector = NSSelectorFromString("dataSize")

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
