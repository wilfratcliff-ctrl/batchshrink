import Photos
import AVFoundation

/// Builds the library summary the batch screen works from.
///
/// The scan never downloads an original. Listing uses library metadata, and the optional
/// on-device size pass asks PhotoKit with network access switched off, so a video that
/// lives only in iCloud reports no size instead of being fetched. The refresh used to
/// reconcile a library that changed outside the app is the listing half alone, so it can
/// never fetch anything either.
@MainActor final class PhotoLibraryScanService: LibraryScanning {
    /// `PHAssetResource.dataSize` is public API from iOS 27. A build toolchain may predate
    /// that SDK, so the documented property is probed at runtime instead of linked.
    private static let dataSizeSelector = NSSelectorFromString("dataSize")

    /// Bounds the on-device pass so a large library cannot turn a scan into an unbounded
    /// wait. Newest videos, which the summary lists first, are measured first.
    static let onDeviceSizeLimit = 400

    private let manager = PHImageManager.default()
    /// The stop button on the scanning screen, and the scan's alone.
    ///
    /// `cancel()` is the scan's stop switch, and `BatchViewModel.cancelScan()` cancels the
    /// scan's task in the same breath. A refresh runs on a task of its own and stops with that
    /// task's cancellation, so it never sets or clears this flag. One flag shared by both meant
    /// a refresh that began between the user's tap and the scan loop's next
    /// `checkCancellation()` could clear the cancel and revive a scan the user had stopped.
    private var scanCancelled = false
    private var supportsReportedSize = false

    func cancel() { scanCancelled = true }

    func scan(progress: @escaping @MainActor (LibraryScanProgress) -> Void) async throws -> LibraryScanResult {
        // A new scan is the one thing that clears an earlier cancel.
        scanCancelled = false
        supportsReportedSize = false
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { throw PipelineError.permissionDenied }

        let listing = try await listEligible(progress: progress, scanOwned: true)
        var eligible = listing.assets
        var measured = 0
        var sizeSource: LibrarySizeSource = supportsReportedSize ? .reportedByPhotos : .unavailable
        if !supportsReportedSize {
            let outcome = try await measureOnDeviceSizes(eligible, progress: progress)
            eligible = outcome.assets
            measured = outcome.measured
            if measured > 0 { sizeSource = .measuredOnDevice }
        }

        return LibraryScanResult(assets: eligible,
                                 videoCount: listing.videoCount,
                                 unsupportedCount: listing.unsupported,
                                 unknownSizeCount: eligible.filter { $0.bytes == nil }.count,
                                 sizeSource: sizeSource,
                                 measuredOnDeviceCount: measured)
    }

    /// Re-reads library metadata for a library that changed outside the app.
    ///
    /// This is deliberately not a scan. It never measures a size on device, so it can never ask
    /// PhotoKit to fetch an original, and it never reports a measurement it did not take. Sizes
    /// Photos itself reports come along for free.
    func refreshListing() async throws -> LibraryScanResult {
        // Deliberately leaves `scanCancelled` exactly as it was found. A refresh must never
        // clear a cancel that belongs to a scan; the refresh's own cancellation is its task's,
        // which `Task.isCancelled` reports.
        supportsReportedSize = false
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { throw PipelineError.permissionDenied }
        let listing = try await listEligible(progress: { _ in }, scanOwned: false)
        return LibraryScanResult(assets: listing.assets,
                                 videoCount: listing.videoCount,
                                 unsupportedCount: listing.unsupported,
                                 unknownSizeCount: listing.assets.filter { $0.bytes == nil }.count,
                                 sizeSource: supportsReportedSize ? .reportedByPhotos : .unavailable,
                                 measuredOnDeviceCount: 0)
    }

    /// A refreshed listing folded into the library the app already has in hand.
    ///
    /// `running` comes from `LibraryScanResult.runningIdentifiers(in:)`; the videos it names
    /// keep their identity even if Photos no longer lists them.
    func reconcile(previous: LibraryScanResult?,
                   selection: Set<String>,
                   running: Set<String>) async throws -> LibraryReconciliation {
        let fresh = try await refreshListing()
        return LibraryScanResult.reconcile(previous: previous, fresh: fresh,
                                           selection: selection, running: running)
    }

    /// The metadata half of a scan: what Photos has, what each video looks like, and which ones
    /// the pipeline cannot process. Nothing here measures a size or requests media, so nothing
    /// here can download an original.
    ///
    /// `scanOwned` says whose stop switch this pass reads. Only the scan has one, so a refresh
    /// passes `false` and stops on its task's cancellation alone.
    private func listEligible(
        progress: @escaping @MainActor (LibraryScanProgress) -> Void,
        scanOwned: Bool
    ) async throws -> (assets: [LibraryAsset], videoCount: Int, unsupported: Int) {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let fetch = PHAsset.fetchAssets(with: .video, options: options)
        let total = fetch.count
        progress(LibraryScanProgress(phase: .listing, scanned: 0, total: total))

        var eligible: [LibraryAsset] = []
        eligible.reserveCapacity(total)
        var unsupported = 0
        for index in 0..<total {
            try checkCancellation(scanOwned: scanOwned)
            let asset = describe(fetch.object(at: index))
            if asset.isEligible { eligible.append(asset) } else { unsupported += 1 }
            if index % 32 == 31 || index == total - 1 {
                progress(LibraryScanProgress(phase: .listing, scanned: index + 1, total: total))
                await Task.yield()
            }
        }
        try checkCancellation(scanOwned: scanOwned)
        return (eligible, total, unsupported)
    }

    private func describe(_ asset: PHAsset) -> LibraryAsset {
        let resources = PHAssetResource.assetResources(for: asset)
        // Cinematic videos carry a documented Photos subtype. HDR and ProRes have no PhotoKit
        // counterpart at all: `PHAssetMediaSubtype` has no ProRes member, and the current
        // `PHAsset` has no media characteristic property, so a metadata-only listing cannot
        // decide either one. They stay false here rather than being guessed, and have to be
        // decided from the media itself, where the codec and the colour tags are readable.
        let traits = AssetRules.Traits(
            isVideo: asset.mediaType == .video,
            isHighFrameRate: asset.mediaSubtypes.contains(.videoHighFrameRate),
            isTimeLapse: asset.mediaSubtypes.contains(.videoTimelapse),
            isSpatial: asset.mediaSubtypes.contains(.spatialMedia),
            hasAdjustmentData: resources.contains { $0.type == .adjustmentData },
            hasFullSizeVideo: resources.contains { $0.type == .fullSizeVideo },
            hasPairedVideo: resources.contains { $0.type == .pairedVideo },
            isCinematic: asset.mediaSubtypes.contains(.videoCinematic),
            isSharedOrRestricted: isSharedOrRestricted(asset))
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

    /// True for an item Photos says did not come from the user's own library, or will not let
    /// this app delete. A shared album, a synced file or a restricted asset is one a copy
    /// cannot replace, so it is refused while the library is being listed instead of failing
    /// part-way through a run. Both checks read library metadata only.
    private func isSharedOrRestricted(_ asset: PHAsset) -> Bool {
        let source = asset.sourceType
        if source.contains(.typeCloudShared) || source.contains(.typeiTunesSynced) { return true }
        return !asset.canPerform(.delete)
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
            try checkCancellation(scanOwned: true)
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

    /// `Task.isCancelled` stops whichever operation this is. The flag belongs to the scan: a
    /// refresh that read it would stop for a cancel that was never meant for it, and stop for
    /// every later refresh too, because only a new scan clears the flag.
    private func checkCancellation(scanOwned: Bool) throws {
        if Task.isCancelled { throw PipelineError.cancelled }
        if scanOwned, scanCancelled { throw PipelineError.cancelled }
    }
}
