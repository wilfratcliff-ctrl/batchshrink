import Photos
import AVFoundation
import CoreMedia

/// Builds the library summary the batch screen works from.
///
/// The scan never downloads an original. Listing uses library metadata, and the bounded
/// on-device pass asks PhotoKit with network access switched off, so a video that lives only
/// in iCloud answers nothing instead of being fetched. The refresh used to reconcile a library
/// that changed outside the app is the listing half alone, so it can never fetch anything
/// either.
@MainActor final class PhotoLibraryScanService: LibraryScanning {
    /// `PHAssetResource.dataSize` is public API from iOS 27. A build toolchain may predate
    /// that SDK, so the documented property is probed at runtime instead of linked.
    private static let dataSizeSelector = NSSelectorFromString("dataSize")

    /// Bounds the on-device pass so a large library cannot turn a scan into an unbounded wait.
    /// Newest videos, which the summary lists first, are read first.
    ///
    /// The bound matters because this pass is the one place a scan asks PhotoKit for media rather
    /// than for metadata: one request per video. It is the same bound the size pass has always
    /// used, and it now covers both questions that one request can answer, so a scan spends at
    /// most 400 requests on it whatever the library holds. A video past the bound is left exactly
    /// as the listing described it, and is refused later in a run for the same reason it would
    /// have been refused here.
    static let onDeviceProbeLimit = 400

    /// How many videos the listing pass reads between two progress updates. The yield beside
    /// each one is what keeps the main actor free for the interface while a large library is
    /// being read, and the readings are what make the count the user watches move.
    static let listingProgressStride = 32

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
        // One bounded pass over the originals already on this iPhone answers the two questions no
        // PhotoKit listing carries: an original's size on a system that reports none, and an
        // original's codec and colour tags on every system. A video whose original is in iCloud
        // cannot answer either, so it is left exactly as the listing described it rather than being
        // downloaded or guessed at. The phase reported is the one that says what this pass is
        // mainly doing: measuring sizes where Photos reports none, reading formats where it does.
        let outcome = try await classifyOnDevice(
            listing.assets,
            phase: supportsReportedSize ? .inspectingFormats : .measuring,
            progress: progress,
            probe: { await self.findings(for: $0) })
        var sizeSource: LibrarySizeSource = supportsReportedSize ? .reportedByPhotos : .unavailable
        if outcome.measured > 0 { sizeSource = .measuredOnDevice }

        return LibraryScanResult(assets: outcome.assets,
                                 videoCount: listing.videoCount,
                                 unsupportedCount: listing.unsupported + outcome.refused.count,
                                 unknownSizeCount: outcome.assets.filter { $0.bytes == nil }.count,
                                 sizeSource: sizeSource,
                                 measuredOnDeviceCount: outcome.measured,
                                 refusedAssets: outcome.refused)
    }

    /// Re-reads library metadata for a library that changed outside the app.
    ///
    /// This is deliberately not a scan. It never measures a size on device, so it can never ask
    /// PhotoKit to fetch an original, and it never reports a measurement it did not take. It cannot
    /// read a codec or a colour tag either, for the same reason, so it reports no format refusal of
    /// its own: `LibraryScanResult.reconcile` carries the ones a scan already read. Sizes Photos
    /// itself reports come along for free.
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
        let listing = try await walkListing(liveCount: { fetch.count },
                                           assetAt: { fetch.object(at: $0) },
                                           describe: { self.describe($0) },
                                           scanOwned: scanOwned,
                                           progress: progress)
        return (assets: listing.assets, videoCount: listing.videoCount, unsupported: listing.skipped)
    }

    /// The listing walk itself.
    ///
    /// PhotoKit is narrowed to three closures so the loop's behaviour around a library that moves
    /// while it is being read can be driven without a Photos library, which is the only way this
    /// project can test it at all.
    ///
    /// The count is read again at every step rather than once at the start, because a Photos
    /// fetch result can follow the library instead of freezing it. When it does, a video deleted
    /// mid-pass shortens the listing, and asking such a listing for an index it no longer has
    /// goes past its end rather than returning nothing: reading the count first is what lets a
    /// shortened listing end instead, and it is what lets a video added mid-pass be picked up
    /// instead of being silently missed. Where the count cannot change, every reading returns the
    /// same number and the pass walks exactly what it walked before.
    ///
    /// `videoCount` is the number of videos the pass read, counting each one once, so it always
    /// equals the eligible videos plus the unsupported ones. That keeps the summary's totals
    /// adding up even when the library moved under the pass.
    func walkListing<Asset>(
        liveCount: () -> Int,
        assetAt: (Int) -> Asset,
        describe: (Asset) -> LibraryAsset,
        scanOwned: Bool,
        progress: @escaping @MainActor (LibraryScanProgress) -> Void
    ) async throws -> (assets: [LibraryAsset], skipped: Int, videoCount: Int) {
        let opened = max(liveCount(), 0)
        progress(LibraryScanProgress(phase: .listing, scanned: 0, total: opened))
        var assets: [LibraryAsset] = []
        assets.reserveCapacity(opened)
        // The identifiers the pass has already read, so a listing that shifted under it cannot
        // name one video twice. A video added at the top of a newest-first listing pushes every
        // video below it along, and the pass - which is walking positions, not videos - arrives
        // at a video it has already described. Offering that video twice would offer it twice in
        // a run, which is one more copy than the user asked for.
        var seen = Set<String>()
        var skipped = 0
        var read = 0
        while read < liveCount() {
            try checkCancellation(scanOwned: scanOwned)
            let asset = describe(assetAt(read))
            read += 1
            if seen.insert(asset.id).inserted {
                if asset.isEligible { assets.append(asset) } else { skipped += 1 }
            }
            if read % PhotoLibraryScanService.listingProgressStride == 0 {
                progress(LibraryScanProgress(phase: .listing, scanned: read,
                                             total: max(liveCount(), read)))
                await Task.yield()
            }
        }
        try checkCancellation(scanOwned: scanOwned)
        // Reported once more whatever the stride landed on, so a pass that finished between two
        // updates still ends on a count the user can read.
        progress(LibraryScanProgress(phase: .listing, scanned: read, total: max(liveCount(), read)))
        return (assets: assets, skipped: skipped, videoCount: assets.count + skipped)
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

    /// What one on-device read found. Either fact can be absent: a video that could not be read
    /// at all - because its original is in iCloud, which this pass never downloads, or because its
    /// header could not be opened - reports neither, and is left exactly as the listing described
    /// it.
    struct OnDeviceFinding: Equatable, Sendable {
        /// The original's size, when this read could take it. Applied only to a video Photos
        /// reported no size for, because a size Photos reported is not this app's to replace.
        var bytes: Int64? = nil
        /// The refusal the media itself earned, in `AssetRules`' own words. Nil unless the codec
        /// or colour tags were actually read and name a format this app refuses.
        var refusal: String? = nil
    }

    /// The bounded on-device pass: what a scan can learn from originals already on this iPhone,
    /// and the only part of a scan that asks PhotoKit for media rather than for metadata.
    ///
    /// PhotoKit and AVFoundation are narrowed to one closure so the loop's behaviour can be driven
    /// without a Photos library, exactly as the listing walk is. `probe` is what reads a video; the
    /// real one asks PhotoKit for the local original with network access switched off.
    ///
    /// Three rules hold here, and they are the whole reason this pass may refuse anything at all:
    ///
    /// - it never refuses a video it could not read. A finding of nil, or a finding that names no
    ///   refusal, leaves the video in the list to be refused later in a run exactly as before;
    /// - it only ever adds a reason `AssetRules` wrote, so a video refused here reads like one
    ///   refused anywhere else;
    /// - it is capped at `onDeviceProbeLimit` videos, newest first, and checks the stop switch
    ///   before each one, so a large library cannot make a scan unbounded and a stopped scan stops
    ///   within one video.
    func classifyOnDevice(
        _ assets: [LibraryAsset],
        phase: LibraryScanProgress.Phase,
        progress: @escaping @MainActor (LibraryScanProgress) -> Void,
        probe: (String) async -> OnDeviceFinding?
    ) async throws -> (assets: [LibraryAsset], refused: [LibraryAsset], measured: Int) {
        let candidates = Array(assets.prefix(Self.onDeviceProbeLimit))
        guard !candidates.isEmpty else { return (assets, [], 0) }
        var measured: [String: Int64] = [:]
        var refusals: [String: String] = [:]
        progress(LibraryScanProgress(phase: phase, scanned: 0, total: candidates.count))
        for (index, candidate) in candidates.enumerated() {
            try checkCancellation(scanOwned: true)
            if let finding = await probe(candidate.id) {
                if candidate.bytes == nil, let bytes = finding.bytes { measured[candidate.id] = bytes }
                if let refusal = finding.refusal { refusals[candidate.id] = refusal }
            }
            progress(LibraryScanProgress(phase: phase, scanned: index + 1, total: candidates.count))
            await Task.yield()
        }
        // A refused video comes out of the list, because everything the list offers can be run and
        // this one cannot. It is returned separately so the library screen can name it, and so the
        // summary can count it as unsupported rather than losing it.
        var refused: [LibraryAsset] = []
        let updated = assets.compactMap { asset -> LibraryAsset? in
            if let reason = refusals[asset.id] {
                refused.append(asset.refusing(reason))
                return nil
            }
            return measured[asset.id].map { asset.withBytes($0) } ?? asset
        }
        return (updated, refused, measured.count)
    }

    /// Reads what one original already on this iPhone can answer, without downloading or decoding
    /// it.
    ///
    /// One PhotoKit request serves both questions, and it is the request this pass has always
    /// made: the original, fetched with network access switched off, so only a file already on the
    /// iPhone can answer. A video whose original is in iCloud hands back nothing, which is why it
    /// stays unknown instead of being fetched or guessed at.
    ///
    /// The size is a `stat` on the file PhotoKit handed over. The format comes out of the video
    /// track's format descriptions, which live in the file's header: reading them seeks and reads
    /// a few kilobytes, and decodes nothing.
    private func findings(for identifier: String) async -> OnDeviceFinding? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject
        else { return nil }
        let options = PHVideoRequestOptions()
        options.version = .original
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = false
        // A `.highQualityFormat` video request calls its handler exactly once.
        let requested = await withCheckedContinuation { (continuation: CheckedContinuation<AVURLAsset?, Never>) in
            // PhotoKit is documented to call this once; the flag makes a double callback harmless
            // rather than a crash, because resuming a continuation twice traps.
            var finished = false
            manager.requestAVAsset(forVideo: asset, options: options) { handed, _, _ in
                guard !finished else { return }
                finished = true
                guard let urlAsset = handed as? AVURLAsset, urlAsset.url.isFileURL else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: urlAsset)
            }
        }
        guard let urlAsset = requested else { return nil }
        var finding = OnDeviceFinding()
        finding.bytes = Self.fileSize(of: urlAsset.url)
        finding.refusal = await Self.refusalReadingFormats(of: urlAsset)
        return finding
    }

    /// The original's byte size, read from the file PhotoKit handed over. Nil when the size could
    /// not be read, which leaves the video with no size rather than with a made-up one.
    private static func fileSize(of url: URL) -> Int64? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize, size > 0 else { return nil }
        return Int64(size)
    }

    /// The refusal this video's own codec and colour tags earn, or nil when it is ordinary or its
    /// format could not be read at all.
    ///
    /// Both facts are read from the video track's format descriptions, and both go through the
    /// same two owners the rest of the app uses: `VideoVerificationService` decides what a format
    /// description means, and `AssetRules` writes the sentence. That is what makes a video refused
    /// while the library was being listed read exactly like one refused later in a run, with one
    /// place still deciding either.
    ///
    /// Nothing is refused on a guess. A track that cannot be loaded, a format list that is empty,
    /// and a transfer function this app cannot name all come back nil, which leaves the video
    /// eligible and lets the run refuse it on the media itself if that is what it deserves.
    private static func refusalReadingFormats(of asset: AVURLAsset) async -> String? {
        guard let tracks = try? await asset.loadTracks(withMediaType: .video),
              let track = tracks.first,
              let formats = try? await track.load(.formatDescriptions),
              !formats.isEmpty else { return nil }
        let transfer = VideoVerificationService.transferFunction(of: formats)
        let isProRes = formats.contains {
            VideoVerificationService.isProRes(subtype: CMFormatDescriptionGetMediaSubType($0))
        }
        return AssetRules.unsupportedFormatReason(isHDR: transfer.isHDR, isProRes: isProRes)
    }

    /// `Task.isCancelled` stops whichever operation this is. The flag belongs to the scan: a
    /// refresh that read it would stop for a cancel that was never meant for it, and stop for
    /// every later refresh too, because only a new scan clears the flag.
    private func checkCancellation(scanOwned: Bool) throws {
        if Task.isCancelled { throw PipelineError.cancelled }
        if scanOwned, scanCancelled { throw PipelineError.cancelled }
    }
}
