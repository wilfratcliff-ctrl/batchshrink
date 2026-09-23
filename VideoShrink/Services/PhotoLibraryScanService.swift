import Photos
import AVFoundation

/// Builds the library summary the batch screen works from.
///
/// The scan never downloads an original. Listing uses library metadata, and the optional
/// on-device size pass asks PhotoKit with network access switched off, so a video that
/// lives only in iCloud reports no size instead of being fetched.
@MainActor final class PhotoLibraryScanService: LibraryScanning {
    /// `PHAssetResource.dataSize` is public API from iOS 27. A build toolchain may predate
    /// that SDK, so the documented property is probed at runtime instead of linked.
    private static let dataSizeSelector = NSSelectorFromString("dataSize")

    /// Bounds the on-device pass so a large library cannot turn a scan into an unbounded
    /// wait. Newest videos, which the summary lists first, are measured first.
    static let onDeviceSizeLimit = 400

    private let manager = PHImageManager.default()
    private var cancelled = false
    private var supportsReportedSize = false

    func cancel() { cancelled = true }

    func scan(progress: @escaping @MainActor (LibraryScanProgress) -> Void) async throws -> LibraryScanResult {
        cancelled = false
        supportsReportedSize = false
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { throw PipelineError.permissionDenied }

        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let fetch = PHAsset.fetchAssets(with: .video, options: options)
        let total = fetch.count
        progress(LibraryScanProgress(phase: .listing, scanned: 0, total: total))

        var eligible: [LibraryAsset] = []
        eligible.reserveCapacity(total)
        var unsupported = 0
        for index in 0..<total {
            try checkCancellation()
            let asset = describe(fetch.object(at: index))
            if asset.isEligible { eligible.append(asset) } else { unsupported += 1 }
            if index % 32 == 31 || index == total - 1 {
                progress(LibraryScanProgress(phase: .listing, scanned: index + 1, total: total))
                await Task.yield()
            }
        }
        try checkCancellation()

        var measured = 0
        var sizeSource: LibrarySizeSource = supportsReportedSize ? .reportedByPhotos : .unavailable
        if !supportsReportedSize {
            let outcome = try await measureOnDeviceSizes(eligible, progress: progress)
            eligible = outcome.assets
            measured = outcome.measured
            if measured > 0 { sizeSource = .measuredOnDevice }
        }

        return LibraryScanResult(assets: eligible,
                                 videoCount: total,
                                 unsupportedCount: unsupported,
                                 unknownSizeCount: eligible.filter { $0.bytes == nil }.count,
                                 sizeSource: sizeSource,
                                 measuredOnDeviceCount: measured)
    }

    private func describe(_ asset: PHAsset) -> LibraryAsset {
        let resources = PHAssetResource.assetResources(for: asset)
        let traits = AssetRules.Traits(
            isVideo: asset.mediaType == .video,
            isHighFrameRate: asset.mediaSubtypes.contains(.videoHighFrameRate),
            isTimeLapse: asset.mediaSubtypes.contains(.videoTimelapse),
            isSpatial: asset.mediaSubtypes.contains(.spatialMedia),
            hasAdjustmentData: resources.contains { $0.type == .adjustmentData },
            hasFullSizeVideo: resources.contains { $0.type == .fullSizeVideo },
            hasPairedVideo: resources.contains { $0.type == .pairedVideo })
        let videoResource = resources.first { $0.type == .video }
        let size = videoResource.flatMap { self.reportedSize($0) }
        return LibraryAsset(id: asset.localIdentifier,
                            creationDate: asset.creationDate,
                            duration: asset.duration,
                            pixelWidth: asset.pixelWidth,
                            pixelHeight: asset.pixelHeight,
                            bytes: size,
                            unsupportedReason: AssetRules.unsupportedReason(traits))
    }

    /// Reads the documented `dataSize` property when the running OS has it. Returns nil on
    /// older systems, when Photos has no size for the resource, and for a zero value.
    private func reportedSize(_ resource: PHAssetResource) -> Int64? {
        guard resource.responds(to: Self.dataSizeSelector) else { return nil }
        supportsReportedSize = true
        guard let value = resource.perform(Self.dataSizeSelector)?.takeUnretainedValue() as? NSNumber
        else { return nil }
        let size = value.int64Value
        return size > 0 ? size : nil
    }

    /// Last-resort size pass for systems that report no size at all. Every request is made
    /// with network access disabled, so only originals already on this iPhone can answer.
    private func measureOnDeviceSizes(
        _ assets: [LibraryAsset],
        progress: @escaping @MainActor (LibraryScanProgress) -> Void
    ) async throws -> (assets: [LibraryAsset], measured: Int) {
        let candidates = assets.filter { $0.bytes == nil }.prefix(Self.onDeviceSizeLimit)
        guard !candidates.isEmpty else { return (assets, 0) }
        var measured: [String: Int64] = [:]
        progress(LibraryScanProgress(phase: .measuring, scanned: 0, total: candidates.count))
        for (index, candidate) in candidates.enumerated() {
            try checkCancellation()
            if let bytes = await onDeviceBytes(identifier: candidate.id) { measured[candidate.id] = bytes }
            progress(LibraryScanProgress(phase: .measuring, scanned: index + 1, total: candidates.count))
            await Task.yield()
        }
        let updated = assets.map { asset in
            measured[asset.id].map { asset.withBytes($0) } ?? asset
        }
        return (updated, measured.count)
    }

    private func onDeviceBytes(identifier: String) async -> Int64? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject
        else { return nil }
        let options = PHVideoRequestOptions()
        options.version = .original
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = false
        // A `.highQualityFormat` video request calls its handler exactly once.
        return await withCheckedContinuation { (continuation: CheckedContinuation<Int64?, Never>) in
            // PhotoKit is documented to call this once; the flag makes a double callback harmless
            // rather than a crash, because resuming a continuation twice traps.
            var finished = false
            manager.requestAVAsset(forVideo: asset, options: options) { requested, _, _ in
                guard !finished else { return }
                finished = true
                guard let urlAsset = requested as? AVURLAsset, urlAsset.url.isFileURL else {
                    continuation.resume(returning: nil)
                    return
                }
                let values = try? urlAsset.url.resourceValues(forKeys: [.fileSizeKey])
                let size = values?.fileSize ?? 0
                continuation.resume(returning: size > 0 ? Int64(size) : nil)
            }
        }
    }

    private func checkCancellation() throws {
        if cancelled || Task.isCancelled { throw PipelineError.cancelled }
    }
}
