import Photos
import AVFoundation
import CoreMedia
import Foundation

/// The one call the batch flow makes before a run starts: read the formats of the videos the user
/// actually chose, with the network switched off, and name the ones the media itself refuses.
///
/// It is declared here rather than beside `LibraryScanning` because the machinery that reads a
/// format lives in this file, and because the batch flow can reach it through the scanner it
/// already holds. A scanner that cannot read a format simply does not conform, and a flow holding
/// one starts its run the way it always did rather than pretending a video was checked.
@MainActor protocol OriginalFormatProbing {
    /// The videos among `assets` whose own format this app refuses, each already carrying
    /// `AssetRules`' sentence as its `unsupportedReason`.
    ///
    /// A video whose original is not on this iPhone - because it is still in iCloud, or because
    /// its header could not be opened - cannot be read, so it is absent from the answer and stays
    /// eligible. Nothing here downloads an original and nothing here is guessed: "not read" is
    /// never the same answer as "unsupported".
    func refusedByFormat(
        among assets: [LibraryAsset],
        progress: @escaping @MainActor (LibraryScanProgress) -> Void
    ) async throws -> [LibraryAsset]
}

/// Builds the library summary the batch screen works from.
///
/// The scan never downloads an original. Listing uses library metadata, and the bounded
/// on-device pass asks PhotoKit with network access switched off, so a video that lives only
/// in iCloud answers nothing instead of being fetched. The refresh used to reconcile a library
/// that changed outside the app is the listing half alone, so it can never fetch anything
/// either.
@MainActor final class PhotoLibraryScanService: LibraryScanning, OriginalFormatProbing {
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
    ///
    /// It bounds a *scan*, which reads a library nobody chose. The chosen-video read of
    /// `refusedByFormat(among:progress:)` is not bounded by it: a selection is the user's own
    /// answer to which videos matter, so all of it is read.
    static let onDeviceProbeLimit = 400

    /// How many videos the listing pass reads between two progress updates. The yield beside
    /// each one is what keeps the main actor free for the interface while a large library is
    /// being read, and the readings are what make the count the user watches move.
    static let listingProgressStride = 32

    /// How long one on-device read may wait for PhotoKit to answer before this pass gives up on
    /// that video.
    ///
    /// The read is a header read of a file that is already on this iPhone, which takes
    /// milliseconds, so a bound this loose is not a slow path: it is what turns a read that never
    /// answers into a bounded one. A video the pass gives up on is left unread - no size and no
    /// format - rather than refused, so this can never refuse a video the pass could not read.
    /// Only a device can say whether the number is ever reached in practice; the case for that is
    /// in `docs/PHYSICAL_DEVICE_TEST_PLAN.md`.
    static let onDeviceRequestTimeout: Duration = .seconds(10)

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
        return try await readOnDevice(
            assets,
            phase: phase,
            progress: progress,
            probe: probe,
            bound: Self.onDeviceProbeLimit,
            scanOwned: true)
    }

    /// The loop both callers of this pass share, with the one thing they disagree about made
    /// explicit: how many videos may be read.
    ///
    /// `bound` is the scan's own limit while a library is being read, because a library is not the
    /// user's choice and can be enormous. The chosen-video read passes the size of the selection
    /// instead, because a selection is the user's own answer to "which videos?" and the whole point
    /// of that pass is that none of them is left to be refused half-way through a run.
    ///
    /// `scanOwned` says whose stop switch this pass reads, for the same reason `walkListing` needs
    /// it: only a scan has one. The flag belongs to the scan and only a new scan clears it, so a
    /// chosen-video read that read it would stop for a cancel that was meant for a scan the user
    /// stopped earlier - and would stop for every later one too. It stops on its task's
    /// cancellation alone.
    private func readOnDevice(
        _ assets: [LibraryAsset],
        phase: LibraryScanProgress.Phase,
        progress: @escaping @MainActor (LibraryScanProgress) -> Void,
        probe: (String) async -> OnDeviceFinding?,
        bound: Int,
        scanOwned: Bool
    ) async throws -> (assets: [LibraryAsset], refused: [LibraryAsset], measured: Int) {
        let candidates = Array(assets.prefix(bound))
        guard !candidates.isEmpty else { return (assets, [], 0) }
        var measured: [String: Int64] = [:]
        var refusals: [String: String] = [:]
        progress(LibraryScanProgress(phase: phase, scanned: 0, total: candidates.count))
        for (index, candidate) in candidates.enumerated() {
            try checkCancellation(scanOwned: scanOwned)
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

    /// The videos among `assets` that the media itself refuses, read before a run starts.
    ///
    /// This is the scan's own on-device pass, asked a narrower question: the videos the user
    /// actually picked instead of the newest few hundred in the library. It runs the scan's own
    /// loop (`readOnDevice`, the body of `classifyOnDevice`), the same one PhotoKit request per
    /// video with the network switched off, and the same two owners of the answer, so a video
    /// refused here is refused in `AssetRules`' own words and reads exactly like one the scan
    /// refused while the library was being listed. There is nothing else to keep in step, because
    /// there is no second copy of the reading or of the sentence.
    ///
    /// A selection is tens of videos, not thousands, so the bound a scan keeps for a whole library
    /// has no place here: every chosen video is read, however deep in the library it sits. (A user
    /// who selects more than a scan would read is still answered in full - that is the point of
    /// asking about a selection rather than about a library.) It reports the refusals alone - the
    /// sizes the same pass can measure have no part in answering "can BatchShrink run this video?"
    /// - and a video it could not read is left out entirely rather than reported, which leaves it
    /// eligible for the run to refuse later, on the media itself, if that is what it deserves.
    func refusedByFormat(
        among assets: [LibraryAsset],
        progress: @escaping @MainActor (LibraryScanProgress) -> Void
    ) async throws -> [LibraryAsset] {
        return try await refusedByFormat(
            among: assets,
            progress: progress,
            probe: { await self.findings(for: $0) })
    }

    /// The same read with its one PhotoKit request narrowed to a closure, so everything above that
    /// request - how many videos are read, whose stop switch applies, and what a refusal says - can
    /// be driven without a Photos library, exactly as the scan's own pass is driven.
    ///
    /// The real caller of this file's protocol method passes `findings(for:)`; a test passes what
    /// it wants the media to have said, including nothing at all.
    func refusedByFormat(
        among assets: [LibraryAsset],
        progress: @escaping @MainActor (LibraryScanProgress) -> Void,
        probe: (String) async -> OnDeviceFinding?
    ) async throws -> [LibraryAsset] {
        let outcome = try await readOnDevice(
            assets,
            phase: .inspectingFormats,
            progress: progress,
            probe: probe,
            bound: assets.count,
            scanOwned: false)
        return outcome.refused
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
    ///
    /// The wait for PhotoKit is bounded by `onDeviceRequestTimeout` and is given up the moment
    /// the pass is stopped, because a read that never answers would otherwise leave the pass
    /// suspended with nothing to press: see `boundedAnswer(timeout:start:)`.
    private func findings(for identifier: String) async -> OnDeviceFinding? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject
        else { return nil }
        let options = PHVideoRequestOptions()
        options.version = .original
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = false
        let manager = self.manager
        let requested: AVURLAsset? = await Self.boundedAnswer(timeout: Self.onDeviceRequestTimeout) { answer in
            let request = manager.requestAVAsset(forVideo: asset, options: options) { handed, _, _ in
                // Only a file already on this iPhone may answer. A streaming asset is not this
                // pass's business, and following one would fetch bytes this pass never fetches.
                guard let urlAsset = handed as? AVURLAsset, urlAsset.url.isFileURL else {
                    answer(nil)
                    return
                }
                answer(urlAsset)
            }
            return { manager.cancelImageRequest(request) }
        }
        guard let urlAsset = requested else { return nil }
        var finding = OnDeviceFinding()
        finding.bytes = Self.fileSize(of: urlAsset.url)
        finding.refusal = await Self.refusalReadingFormats(of: urlAsset)
        return finding
    }

    /// Waits for one PhotoKit read under a bound, and answers with what it handed back.
    ///
    /// The read is asked for once. `start` is given the single callback it may finish through and
    /// returns the way to cancel the request it just made, which is used when the wait is given
    /// up rather than left running.
    ///
    /// Three things can end a read: the handler PhotoKit calls, the bound on how long this pass
    /// will wait, and the stop that cancels the pass. They arrive on different threads and in any
    /// order, and a checked continuation may only be resumed once, so a single claim decides
    /// which of them wins and the others do nothing at all. A handler that arrives after the
    /// bound is therefore exactly as harmless as one that never arrives, and a stop cannot race
    /// the handler either.
    ///
    /// Nil is the answer for a read that did not finish, which is the same answer a video whose
    /// original is only in iCloud gets: nothing measured, nothing refused.
    ///
    /// `timeout` is a parameter and this is internal rather than private so that all three
    /// endings can be driven without a Photos library. The real caller passes
    /// `onDeviceRequestTimeout`.
    static func boundedAnswer<T: AnyObject>(
        timeout: Duration,
        start: (@escaping @Sendable (T?) -> Void) -> () -> Void
    ) async -> T? {
        let read = BoundedRead<T>()
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
                // A stop that arrived before the request was made has already given this read up,
                // and `attach` has resumed the continuation itself.
                guard read.attach(continuation) else { return }
                let cancelRequest = start { answer in read.answer(answer) }
                read.hold(cancelRequest: cancelRequest)
                Task {
                    try? await Task.sleep(for: timeout)
                    read.giveUp()
                }
            }
        }, onCancel: {
            read.giveUp()
        }, isolation: #isolation)
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

/// The one thing that may finish a bounded read, and the only place that touches its
/// continuation.
///
/// A checked continuation has to be resumed exactly once. The handler PhotoKit calls, the bound
/// on the wait, and the stop that cancels the pass can arrive in any order and on different
/// threads - the handler may be called from any queue - so one claim decides which of them wins
/// and the others return without touching the continuation. The lock is what makes that true
/// across those threads; it is held for no longer than a few assignments, and nothing inside it
/// calls back into PhotoKit.
private final class BoundedRead<T: AnyObject>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T?, Never>?
    private var cancelRequest: (() -> Void)?
    private var finished = false

    /// Hands in the continuation and says whether the read should start.
    ///
    /// False means this read was already given up - a stop that arrived before the request was
    /// even made - and in that case the continuation has already been resumed here and the caller
    /// must do nothing else with it.
    func attach(_ continuation: CheckedContinuation<T?, Never>) -> Bool {
        lock.lock()
        if finished {
            lock.unlock()
            continuation.resume(returning: nil)
            return false
        }
        self.continuation = continuation
        lock.unlock()
        return true
    }

    /// Keeps the way to cancel the request, and uses it at once when the read is already over.
    func hold(cancelRequest: @escaping () -> Void) {
        lock.lock()
        if finished {
            lock.unlock()
            cancelRequest()
            return
        }
        self.cancelRequest = cancelRequest
        lock.unlock()
    }

    /// PhotoKit answered.
    func answer(_ value: T?) {
        finish(value, cancellingRequest: false)
    }

    /// The bound was reached, or the pass was stopped.
    ///
    /// The request is cancelled here rather than left for PhotoKit to finish work that nothing is
    /// waiting for any more.
    func giveUp() {
        finish(nil, cancellingRequest: true)
    }

    private func finish(_ value: T?, cancellingRequest: Bool) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let continuation = self.continuation
        let cancelRequest = cancellingRequest ? self.cancelRequest : nil
        self.continuation = nil
        self.cancelRequest = nil
        lock.unlock()
        cancelRequest?()
        continuation?.resume(returning: value)
    }
}
