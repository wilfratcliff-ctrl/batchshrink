import Foundation
import Combine
import OSLog
import AVFoundation
import Photos

enum BatchPhase: Equatable {
    case start, scanning, scanned, selecting, processing, paused, finished, failed
}

/// Photos access the flow cannot read past, with the reason, because the two reasons are not the
/// same thing to the user.
///
/// A refusal is the user's own answer to the system prompt and Settings can undo it; the flow comes
/// back by itself when it is undone. A restriction comes from Screen Time or a device management
/// profile, this app cannot lift it, and Photos is not on this app's Settings page while it is on -
/// so a restriction must never be answered with a route to a switch that is not there.
enum PhotosAccessBlock: Equatable, Sendable {
    case refused
    case restricted
}

/// What a run learned when it asked whether it may read Photos, at the one moment it cannot go on
/// without knowing.
///
/// The three answers are kept apart because two of them are not answers about access at all. A run
/// that was stopped while the question was being asked has to come to rest where every other stop
/// rests, not on a screen saying Photos is unavailable; and "nobody has granted this" is not one
/// video failing, which is what the waiting videos used to be told one at a time.
private enum RunAccess: Equatable, Sendable {
    /// The run may read the library and can begin.
    case granted
    /// The run was stopped before it read anything - the user's own tap, or the app leaving the
    /// foreground - so it rests where every other stop rests.
    case stopped
    /// Nobody has granted this app Photos access. Nothing was read or written, so no video has
    /// failed: the flow has to ask, or say that access is refused.
    case missing
}

/// Drives the batch flow: scan the library, choose videos and quality, process them one at a
/// time and report what actually happened.
///
/// The queue lives in memory for the run. Leaving the app pauses it and keeps finished work;
/// it does not pretend to resume after the process is terminated, and it never changes or
/// deletes an original.
@MainActor final class BatchViewModel: ObservableObject {
    @Published private(set) var phase: BatchPhase = .start
    @Published private(set) var scanProgress: LibraryScanProgress?
    @Published private(set) var scanResult: LibraryScanResult?
    @Published private(set) var items: [BatchItem] = []
    @Published private(set) var currentID: String?
    @Published private(set) var currentStage: PipelineStage?
    @Published private(set) var currentProgress: Double?
    @Published private(set) var message: String?
    @Published private(set) var cleanupWarning: String?
    @Published private(set) var queueWarning: String?
    @Published private(set) var restoredRun = false
    @Published private(set) var pauseReason: BatchPauseReason?
    @Published private(set) var readBackOutcomes: [String: CopyReadBack] = [:]
    /// The receipt each saved copy earned when Photos handed it back. It is written only from a
    /// real read-back, and it is the only thing that can later justify deleting an original.
    @Published private(set) var copyEvidence: [String: DeletionEvidence] = [:]
    /// The fresh look taken at those receipts and the originals beside them. It is filled by one
    /// pass over the candidates, never by reading Photos from inside a view update.
    @Published private(set) var revalidationOutcomes: [String: CopyRevalidation] = [:]
    /// What a restored run worked out about each video that was mid-save when the app stopped:
    /// whether Photos holds the copy, whether it holds none, or whether the question is still the
    /// user's. It is a finding and never an instruction: nothing here creates or removes anything,
    /// and finding a copy is not evidence enough to delete an original.
    @Published private(set) var midSaveFindings: [String: MidSaveFinding] = [:]
    @Published private(set) var deletionOutcomes: [String: DeletionOutcome] = [:]
    @Published private(set) var deletionInProgress = false
    @Published private(set) var limitedAccess = false
    @Published private(set) var estimator = ProcessingEstimator()
    @Published private(set) var measurements: [CopyMeasurement] = []
    /// Originals this iPhone already shrank, which is what the "previously shrunk" marking reads.
    @Published private(set) var completedIdentifiers: Set<String> = []
    /// Copies this app created in Photos. They are new assets with identifiers of their own, so
    /// without this a bulk selection would pick one up and shrink it again. Deliberately not part
    /// of `completedIdentifiers`: that set marks originals that were already shrunk, and a copy is
    /// not one. This is only ever a filter over automatic selection, never over the library list.
    @Published private(set) var createdCopyIdentifiers: Set<String> = []
    @Published private(set) var isStopping = false
    @Published var selection: Set<String> = []
    /// Videos whose Photos metadata changed in the last reconciliation, so a picture drawn from
    /// the older version is out of date. Kept here for the thumbnail cache to invalidate against;
    /// nothing in this file redraws or caches an image.
    @Published private(set) var changedThumbnailIdentifiers: [String] = []
    /// Bumped whenever the thumbnail cache is dropped, so a view can re-key the picture it draws.
    @Published private(set) var thumbnailRevision = 0
    /// The chosen-video format read a run now begins with, while it is running.
    ///
    /// It is set only between the user's tap on Shrink and the first export, and the screen reads
    /// it to say what the wait is for. Nil at every other moment, including a scan's own passes,
    /// which report through `scanProgress` instead.
    @Published private(set) var preflight: LibraryScanProgress?
    /// The videos this run began without, because the media itself refused them, each carrying
    /// `AssetRules`' sentence. Named on the screens the run passes through, so the drop from "I
    /// picked twenty" to "eighteen to go" is explained rather than left to be worked out.
    @Published private(set) var preflightRefusals: [LibraryAsset] = []
    /// True when the pre-flight took every chosen video out, so no run started at all. The
    /// selection screen is where that user lands, and it is the one screen that has to say so.
    @Published private(set) var preflightLeftNothingToRun = false
    /// What the chosen-video read has to say for itself when it stopped without running: today,
    /// only the app going to the background under it. Nil whenever no such stop has happened.
    @Published private(set) var preflightNotice: String?
    /// Why the flow is resting on the recovery screen, when Photos access is the reason.
    ///
    /// It is the one thing that tells a refusal from a restriction, it is what the recovery screen
    /// draws its route back from, and it is what the way back in watches for: access allowed in
    /// Settings finishes the pass the user asked for instead of leaving a sentence that is no
    /// longer true.
    @Published private(set) var accessBlock: PhotosAccessBlock?

    let settings: ShrinkSettings

    private let photos: any PhotoLibraryServing
    private let scanner: any LibraryScanning
    /// The scanner, when it can read a video's own format. The pre-flight runs through this and
    /// does nothing without it, which is what keeps a scanner that cannot read a format (a test
    /// double, say) from having to pretend it can.
    private let formatProbe: (any OriginalFormatProbing)?
    private let transcoder: any VideoTranscoding
    private let verifier: any VideoVerifying
    private let temporary: any TemporaryFileManaging
    private let history: any ShrinkHistoryStoring
    private let queueStore: any BatchQueueStoring
    private let screenAwake: any ScreenAwakeControlling
    private let log = Logger(subsystem: "VideoShrink", category: "Batch")
    /// Watches Photos for edits made outside the app and for the app coming back to the front,
    /// where access can have changed while it was suspended. Photos reports on its own queue and
    /// the monitor comes back to the main actor before it says anything.
    private let libraryChanges: LibraryChangeMonitor
    /// The refresh in flight, so a newer report replaces an older listing instead of racing it.
    private var libraryRefresh: Task<Void, Never>?
    /// Photos' own authorization status, read for the one question the monitor's answer cannot
    /// answer: whether access is missing because the user refused it or because something outside
    /// the app restricts it. Those two need different words and different routes back.
    private let authorizationStatus: () -> PHAuthorizationStatus
    /// Set when Photos reported a change while a scan was reading the library.
    ///
    /// That pass began before the change, so its listing cannot be trusted to describe one
    /// moment of the library. The report is kept rather than dropped for arriving at an
    /// inconvenient moment, and the reconciliation it asks for runs as soon as the scan has
    /// landed.
    private var libraryChangeDuringScan = false
    private var runTask: Task<Void, Never>?
    private var stopRequested = false
    private var finishRequested = false
    /// Set when the app left the foreground while the chosen-video read was running, so the pass
    /// that read was part of can say why it stopped rather than leaving the selection screen
    /// looking exactly as it did before the user tapped Shrink.
    private var preflightLeftApp = false
    private var activeStartedAt: Date?
    /// Snapshot taken when a run starts, so changing quality never affects work in flight.
    private var activeSettings = TranscodeSettings.standard
    /// The deletion mode the run was started with, so changing the setting mid-run cannot
    /// start deleting anything by surprise.
    private var activeDeletionMode = DeletionMode.off
    private var deletionTask: Task<Void, Never>?
    /// Originals waiting for the next Photos transaction. Batching is the only lever over how
    /// often iOS shows its delete confirmation.
    private var deletionBatch: [String] = []
    private var activeScreenAwake = false
    /// Set once a checkpoint the run cannot continue past failed to reach disk. It is cleared when
    /// a fresh attempt begins, so a stopped run keeps explaining itself instead of looking healthy.
    private var checkpointFailure = false
    /// The sizes the run measured for the copy it is handing to Photos, by original. They go to
    /// disk with the `.saving` state, and a later launch reads them back for the items that are
    /// still a question: they are what turns "a copy is in Photos" into the save it turned out to
    /// be rather than an unanswerable claim.
    private var attemptedSaves: [String: Savings] = [:]
    /// How many times in a row one video's retrieval has been answered with a cancellation while
    /// the run was not stopping, by original.
    ///
    /// Every stop of the user's own sets its flag before it cancels any work, so a `.cancelled`
    /// failure arriving with no stop asked for can only be PhotoKit answering the app's own
    /// retrieval that way. That answer can repeat, and without a bound the run loop would pick the
    /// same video back up immediately every time and spin on it. The count is cleared the moment an
    /// attempt gets past retrieval, so only consecutive cancellations of one retrieval accumulate,
    /// and it is cleared with the rest of the per-item bookkeeping when a fresh run begins.
    private var cancelledAttempts: [String: Int] = [:]
    /// How many consecutive retrieval cancellations one video is allowed before it fails. Two
    /// retries is three attempts in all.
    private static let cancelledRetryLimit = 2
    static let deletionBatchSize = 5

    init(photos: any PhotoLibraryServing,
         scanner: any LibraryScanning,
         transcoder: any VideoTranscoding,
         verifier: any VideoVerifying,
         temporary: any TemporaryFileManaging,
         history: any ShrinkHistoryStoring,
         queueStore: any BatchQueueStoring,
         screenAwake: any ScreenAwakeControlling,
         // Only passed to watch something other than the real Photos library, which is how a test
         // drives a library change without one. Omitted everywhere in the app.
         libraryChanges: LibraryChangeMonitor? = nil,
         settings: ShrinkSettings,
         // Omitted everywhere in the app: the scanner that can read a video's own format is the
         // one passed above, and this is only here for a test that wants to watch the pre-flight
         // without a Photos library.
         formatProbe: (any OriginalFormatProbing)? = nil,
         // Omitted everywhere in the app: the status the app reads is Photos' own. It is named here
         // so a test can drive a device whose Photos access is restricted, which is a state a
         // simulator cannot be put in and which the monitor's own answer cannot tell apart from a
         // refusal.
         authorizationStatus: @escaping () -> PHAuthorizationStatus = {
             PHPhotoLibrary.authorizationStatus(for: .readWrite)
         }) {
        self.photos = photos
        self.scanner = scanner
        // The one thing in the app that can read a video's own format is the scanner. A local
        // name, so nothing below can reach for the optional parameter by mistake.
        let probe = formatProbe ?? (scanner as? any OriginalFormatProbing)
        self.formatProbe = probe
        self.transcoder = transcoder
        self.verifier = verifier
        self.temporary = temporary
        self.history = history
        self.queueStore = queueStore
        self.screenAwake = screenAwake
        self.authorizationStatus = authorizationStatus
        // A local name, so the rest of the initialiser cannot accidentally reach for the optional
        // parameter: `libraryChanges` inside `init` means the argument, not the stored property.
        let monitor = libraryChanges ?? LibraryChangeMonitor()
        self.libraryChanges = monitor
        self.settings = settings
        completedIdentifiers = history.completedIdentifiers()
        createdCopyIdentifiers = history.createdCopyIdentifiers()
        measurements = history.copyMeasurements()
        cleanWorkspace()
        restoreQueue()
        // The library can change under the app, and access can change while it is suspended. The
        // monitor reports both and decides nothing itself; what they mean is decided here.
        monitor.onChange = { [weak self] reason in
            guard let self else { return }
            self.libraryChanged(reason)
        }
        monitor.start()
    }

    // MARK: - Derived state

    var eligibleAssets: [LibraryAsset] { scanResult?.assets ?? [] }
    /// Videos the scan read and refused on its own, with the reason it read from the media.
    ///
    /// They are deliberately not in `eligibleAssets`, because nothing here can be chosen and run.
    /// The selection screen draws them after the rows that can be, so a user learns which video was
    /// refused and why, rather than only how many were.
    var refusedAssets: [LibraryAsset] { scanResult?.refusedAssets ?? [] }
    var selectedAssets: [LibraryAsset] { eligibleAssets.filter { selection.contains($0.id) } }
    /// Videos the bulk shortcuts may pick: everything eligible that this iPhone has not already
    /// shrunk, that the app did not create itself, and whose original is still in Photos.
    ///
    /// This is the seam for automatic selection only. A copy the app made is a new Photos asset
    /// with an identifier of its own, so to the library it looks like any other video; leaving it
    /// out here is what stops Select all from shrinking it again to no purpose. It is never taken
    /// out of `eligibleAssets`, so it stays on screen and can still be ticked by hand, which is
    /// how a copy is deliberately run through again. Deleting an original takes it out of later
    /// selections too, by the same rule.
    var selectableAssets: [LibraryAsset] {
        eligibleAssets.filter { asset in
            !completedIdentifiers.contains(asset.id)
                && !createdCopyIdentifiers.contains(asset.id)
                && deletionOutcomes[asset.id] != DeletionOutcome.deleted
        }
    }
    var selectableCount: Int { selectableAssets.count }
    var isRunning: Bool { runTask != nil }
    var remainingCount: Int { items.filter { !$0.state.isFinished }.count }
    var finishedCount: Int { items.filter { $0.state.isFinished }.count }
    var hasPendingWork: Bool { items.contains { $0.state == .pending } }
    var canStart: Bool { !selection.isEmpty && runTask == nil }
    var canLeaveFlow: Bool { runTask == nil && remainingCount == 0 }
    var currentAsset: LibraryAsset? { items.first { $0.id == currentID }?.asset }
    var currentNumber: Int? { items.firstIndex { $0.id == currentID }.map { $0 + 1 } }
    var currentIsSaving: Bool { items.first { $0.id == currentID }?.state.isSaving == true }
    var isLowPowerMode: Bool { DeviceConditions.isLowPowerMode() }

    /// What the run has done with originals so far.
    var deletionReport: DeletionReport {
        var report = DeletionReport()
        for outcome in deletionOutcomes.values {
            switch outcome {
            case .deleted: report.deleted += 1
            case .skipped: report.skipped += 1
            case .failed: report.failed += 1
            case .deleting, .uncertain: report.uncertain += 1
            }
        }
        return report
    }

    /// The mode that applies right now: the run's own choice while it is going, the user's
    /// current choice once it has stopped.
    var effectiveDeletionMode: DeletionMode {
        runTask == nil ? settings.deletionMode : activeDeletionMode
    }

    /// The gate for one item, exposed so the interface can show exactly what it decided.
    func deletionDecision(for item: BatchItem) -> DeletionDecision {
        var saving: Savings?
        if case .saved(let value) = item.state { saving = value }
        let outcome = deletionOutcomes[item.id]
        let alreadyDeleted = outcome == DeletionOutcome.deleted || outcome == DeletionOutcome.uncertain
        return DeletionPolicy.decision(mode: effectiveDeletionMode,
                                       saving: saving,
                                       readBack: readBackOutcomes[item.id],
                                       evidence: copyEvidence[item.id],
                                       revalidation: revalidationOutcomes[item.id],
                                       alreadyDeleted: alreadyDeleted)
    }

    /// Takes one fresh look at the copies and originals a delete could remove, and stores the
    /// answers `deletionDecision(for:)` reads.
    ///
    /// This is deliberately not part of `deletionDecision(for:)`: that runs while the finished
    /// screen builds itself, so a Photos fetch there would run on every update. It is called once
    /// per moment the interface offers the candidates: when a copy is read back, when a run
    /// finishes, and when a stored queue is picked up again.
    private func refreshDeletionLook(for identifiers: [String]? = nil) {
        for id in identifiers ?? items.map(\.id) {
            guard let receipt = copyEvidence[id] else {
                revalidationOutcomes[id] = nil
                continue
            }
            revalidationOutcomes[id] = photos.revalidateForDeletion(receipt)
        }
    }

    /// Why an original was kept, in the words the policy itself would use for the same reason.
    private static func deletionSkipReason(_ outcome: CopyRevalidation) -> String {
        switch outcome {
        case .matches: return "The copy and the original still looked the same."
        case .accessDenied: return "Photos access was withdrawn, so the original stays."
        case .copyMissing: return "The copy is no longer in Photos, so the original stays."
        case .copyChanged: return "The copy changed after it was checked, so the original stays."
        case .sourceMissing: return "Photos can no longer find the original."
        case .sourceChanged: return "The original changed after the copy was made, so it stays."
        case .unavailable: return "The copy couldn't be looked up again, so the original stays."
        }
    }

    /// A player item for a quick look at one original, before it is chosen or deleted.
    func previewItem(for identifier: String) async throws -> AVPlayerItem {
        try await photos.playerItem(identifier: identifier)
    }

    /// Originals the app could justify deleting right now. Never used on its own.
    var deletableItemIDs: [String] {
        return items.filter { deletionDecision(for: $0) == .delete }.map(\.id)
    }

    /// How many of this run's copies Photos could hand back for a check.
    var readBackReport: ReadBackReport {
        var report = ReadBackReport()
        for item in items {
            guard case .saved = item.state else { continue }
            switch readBackOutcomes[item.asset.id] {
            case .confirmed: report.confirmed += 1
            case .unavailable: report.unavailable += 1
            case nil: break
            }
        }
        return report
    }
    var scanEstimate: SavingsEstimate? {
        scanResult?.estimate(settings: settings.transcode, measured: measurements)
    }

    var selectionEstimate: SavingsEstimate? {
        estimate(for: settings.resolution)
    }

    /// Estimated result of the current selection at any resolution, for the quality chooser.
    func estimate(for resolution: CopyResolution) -> SavingsEstimate? {
        let chosen = selectedAssets
        guard !chosen.isEmpty else { return nil }
        let candidate = TranscodeSettings(resolution: resolution, frameRate: settings.frameRate)
        return SavingsEstimate.make(assets: chosen, settings: candidate, measured: measurements)
    }

    func savings(for asset: LibraryAsset) -> AssetSavings? {
        asset.savings(settings: settings.transcode, measured: measurements)
    }

    var summary: BatchSummary {
        var summary = BatchSummary()
        for item in items {
            switch item.state {
            case .saved(let saving):
                summary.savedCount += 1
                summary.originalBytes += saving.originalBytes
                summary.copyBytes += saving.compressedBytes
            case .skipped:
                summary.skippedCount += 1
            case .failed:
                summary.failedCount += 1
            case .needsCheck:
                summary.needsCheckCount += 1
            default:
                summary.pendingCount += 1
            }
        }
        return summary
    }

    var remainingEstimate: ClosedRange<Double>? {
        guard phase == .processing || phase == .paused else { return nil }
        let pending = items.filter { !$0.state.isFinished && $0.id != currentID }
        let elapsed = activeStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        return estimator.remainingSeconds(pendingContentSeconds: pending.map(\.asset.duration),
                                          activeContentSeconds: currentAsset?.duration,
                                          activeElapsedSeconds: elapsed)
    }

    // MARK: - Scanning

    func scan() {
        guard runTask == nil else { return }
        guard [.start, .scanned, .selecting, .finished, .failed].contains(phase) else { return }
        // A scan reads the library from scratch, so a listing a change already started is
        // superseded rather than left to land on top of its answer.
        libraryRefresh?.cancel()
        // The pass below reads Photos from scratch, so it supersedes any change an earlier report
        // was going to reconcile: what it finds is at least as new as what that report described.
        libraryChangeDuringScan = false
        // A pass that reads the library from scratch is the beginning of a run of its own, so
        // nothing this one goes on to do was read back from a stored queue.
        restoredRun = false
        // The library is about to be read from scratch, so whatever a run's pre-flight had to say
        // about the videos it left out is superseded by what this pass finds.
        preflightRefusals = []
        preflightLeftNothingToRun = false
        preflightNotice = nil
        preflightLeftApp = false
        // A fresh pass supersedes whatever the last failure had to say about Photos access.
        accessBlock = nil
        phase = .scanning
        message = nil
        scanProgress = LibraryScanProgress(phase: .listing, scanned: 0, total: 0)
        completedIdentifiers = history.completedIdentifiers()
        createdCopyIdentifiers = history.createdCopyIdentifiers()
        measurements = history.copyMeasurements()
        runTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.runTask = nil
                self.scanProgress = nil
            }
            do {
                self.limitedAccess = try await self.photos.requestAccess()
                let result = try await self.scanner.scan { [weak self] update in
                    self?.scanProgress = update
                }
                self.scanResult = result
                self.items = []
                self.selection.removeAll()
                // The library was just read from scratch, so no picture is out of date yet.
                self.changedThumbnailIdentifiers = []
                self.phase = .scanned
                self.log.info("Library scan finished")
                // A change Photos reported while this pass was reading is not lost: the listing
                // the pass produced began before it, so it is reconciled now.
                self.reconcileAfterScan()
            } catch {
                let normalized = PipelineError.normalize(error, fallback: .libraryScan)
                if normalized == .cancelled {
                    // Only the phase this pass took over is restored. A cancel that arrived with
                    // something else already decided - access withdrawn, say - must not overwrite
                    // that decision when it lands.
                    if self.phase == .scanning {
                        self.phase = self.scanResult == nil ? .start : .scanned
                    }
                    self.reconcileAfterScan()
                } else {
                    self.phase = .failed
                    // A Photos failure says which of the two it is: the user's own refusal, which
                    // Settings can undo, or a restriction this app cannot lift. Remembering which
                    // one lets the way back in finish the pass the user asked for, and keeps a
                    // restriction from being answered with a route to a switch that is not there.
                    if normalized == .permissionDenied {
                        let restricted = self.isRestrictedByTheSystem
                        self.accessBlock = restricted ? .restricted : .refused
                        self.message = PipelineError.accessSentence(restricted: restricted)
                    } else {
                        self.accessBlock = nil
                        self.message = normalized.localizedDescription
                    }
                    self.log.error("Library scan failed")
                }
            }
        }
    }

    func cancelScan() {
        guard phase == .scanning else { return }
        // Only a scan has a stop switch of its own. During the pre-flight the scan service is not
        // running anything, and asking it to stop would set a flag belonging to a pass this app
        // never started; the pre-flight stops on its task's cancellation alone.
        if preflight == nil { scanner.cancel() }
        runTask?.cancel()
    }

    // MARK: - Library changes

    /// One report from the monitor: Photos changed outside the app, or the app came back to the
    /// front, where access can have changed while it was suspended.
    ///
    /// The report is read against the three states `LibraryAccess` names rather than against
    /// "can read or not", because two of those states cannot read and only one of them is access
    /// lost. A fresh install reaches its first foreground with `.notDetermined` - nobody has
    /// refused anything, the app itself is what asks for Photos on the first scan - and reading
    /// that as a refusal is what put a recovery screen and its scan button in front of a new user
    /// before the app had asked for anything at all.
    ///
    /// `.denied` covers two different things for the same reason. A refusal is the user's own
    /// answer, undone in Settings, and the flow stops for it wherever it is. A restriction comes
    /// from outside the app and cannot be undone there at all, so it stops a flow that has a
    /// library or a run in hand - and leaves a fresh install alone, because nothing has been lost
    /// and there is nothing to re-list: the introduction still shows, and the first look through
    /// the library says what is wrong when the user asks for it.
    private func libraryChanged(_ reason: LibraryChangeReason) {
        limitedAccess = libraryChanges.isLimited
        // Written as a switch over every state so a state added later has to be given an answer
        // here rather than falling into whichever branch `canRead` happens to put it in.
        switch libraryChanges.access {
        case .notDetermined:
            // Never asked is not lost. There is nothing to re-list either, so this report ends
            // here and the start screen or the onboarding stays exactly as it was.
            return
        case .denied:
            // Refused or restricted: either way this app cannot read the library, so a flow that
            // has one in hand stops and says so.
            let restricted = isRestrictedByTheSystem
            if restricted && scanResult == nil && items.isEmpty {
                // Nothing in hand and nothing the user can do about it. Calling this "access lost"
                // would replace a new user's introduction with a recovery screen they have no way
                // out of, so the flow is left where it is.
                return
            }
            libraryAccessLost(reason: restricted ? .restricted : .refused)
            return
        case .full, .limited:
            break
        }
        log.info("Photos reported a change (\(String(describing: reason), privacy: .public))")
        // Access is readable again. If that is the very thing the flow is waiting on - the user
        // refused the prompt, allowed access in Settings and came back - the pass they asked for is
        // finished here rather than left to a failure screen whose sentence is no longer true and a
        // tap that cannot change it. Nothing else takes this path, so an ordinary Photos change
        // still only refreshes the listing.
        if accessBlock != nil {
            log.info("Photos access is back; looking at the library again")
            scan()
            return
        }
        refreshLibrary()
    }

    /// Folds a fresh look at Photos into the library the app already has in hand.
    ///
    /// The listing and the selection are the only things this touches. A video a run is working
    /// on keeps exactly the entry it started with, which is what `running` is for, so nothing
    /// here can point a job at a different video.
    ///
    /// A refresh is the metadata-only half of a scan: it never measures a size on device, so
    /// noticing an edit cannot turn into a scan of its own.
    private func refreshLibrary() {
        // A scan already in flight is producing a complete listing of its own - but that pass
        // began before this report, so the report is kept rather than dropped, and its
        // reconciliation runs as soon as the scan has landed.
        guard phase != .scanning else {
            libraryChangeDuringScan = true
            return
        }
        // With no library in hand there is nothing to keep honest, and the next scan reads
        // Photos from scratch.
        guard scanResult != nil || !items.isEmpty else { return }
        // A newer report replaces an older listing rather than racing it.
        libraryRefresh?.cancel()
        libraryRefresh = Task { [weak self] in
            guard let self else { return }
            // Read as late as they can be, because the listing is the part that takes time.
            let previous = self.scanResult
            let selection = self.selection
            let running = LibraryScanResult.runningIdentifiers(in: self.items)
            do {
                let reconciled = try await self.scanner.reconcile(previous: previous,
                                                                  selection: selection,
                                                                  running: running)
                guard !Task.isCancelled else { return }
                self.apply(reconciled)
            } catch {
                // A change this app could not read changes nothing. The listing in hand is still
                // its best answer, and the next report tries again.
                if PipelineError.normalize(error, fallback: .libraryScan) != .cancelled {
                    self.log.error("Reconciling the library failed")
                }
            }
        }
    }

    /// Runs the reconciliation a change reported during a scan asked for, now that nothing is
    /// reading the library.
    ///
    /// A change that arrived while a scan was in flight is the one thing a refresh cannot answer
    /// immediately, so it waits here instead of being thrown away. It costs one metadata-only
    /// listing - the same work a Photos change costs at any other moment - and only when a change
    /// actually landed during a pass. With no library in hand the report is simply dropped: there
    /// is nothing for a change to keep honest, and the next scan reads Photos from scratch.
    private func reconcileAfterScan() {
        guard libraryChangeDuringScan else { return }
        libraryChangeDuringScan = false
        guard scanResult != nil else { return }
        refreshLibrary()
    }

    /// Takes the answer to one refresh. Nothing here touches `items`.
    private func apply(_ reconciliation: LibraryReconciliation) {
        scanResult = reconciliation.result
        selection = reconciliation.selection
        changedThumbnailIdentifiers = reconciliation.changedIdentifiers
        // A picture drawn from the older listing is out of date, and a thumbnail is only ever
        // fetched once per identifier, so the cache has to be dropped before the view redraws.
        if !changedThumbnailIdentifiers.isEmpty {
            ThumbnailService.shared.invalidate(identifiers: changedThumbnailIdentifiers)
            thumbnailRevision += 1
        }
        if reconciliation.changedSomething {
            log.info("Photos no longer matches the library in hand")
        }
    }

    /// True while Photos is blocked by Screen Time or a device management profile rather than by
    /// the user's own answer to the system prompt.
    private var isRestrictedByTheSystem: Bool { authorizationStatus() == .restricted }

    /// Photos access is gone.
    ///
    /// The companion of `scan()`'s own Photos failure: the flow says so rather than holding a
    /// library it can no longer read, and it is taken from the phases a scan itself may start in,
    /// plus the pause a run picked up from disk comes back on.
    ///
    /// A scan that is reading the library when access goes is stopped rather than left to run:
    /// what it would produce is a library this app may no longer read, and the flow says so
    /// instead. The scan's own cancel path leaves a phase it no longer owns alone, so this
    /// decision survives the cancellation landing.
    ///
    /// A run that is in flight is deliberately left alone - `runTask != nil` is the test, so an
    /// access report never tears down work that is actually going. Every other resting place,
    /// including the pause a restored run comes back on, is answered with the access sentence
    /// instead of being left where it is: without access there is nothing to continue, and each
    /// waiting video would fail with `assetUnavailable`'s sentence about a video sitting outside
    /// the allowed set, which is not what happened to it. The run's own record is not torn down
    /// here: `items` is untouched and the queue on disk still describes it.
    private func libraryAccessLost(reason: PhotosAccessBlock) {
        if phase == .scanning {
            scanner.cancel()
            runTask?.cancel()
        } else {
            guard runTask == nil,
                  [BatchPhase.start, .scanned, .selecting, .finished, .failed, .paused].contains(phase)
            else { return }
        }
        restOnLostAccess(reason)
        log.error("Photos access was withdrawn")
    }

    /// Says access is gone, in the words that match the reason, and rests the flow on the screen
    /// whose whole job is the route back.
    ///
    /// `reason` is kept rather than folded away, because the recovery screen reads it: a refusal
    /// gets the route to Settings, and a restriction gets the truth that this app cannot lift it.
    /// Two callers reach this - a report that access changed while the flow was resting, and a run
    /// whose own first step could not read - and both have to leave the same state, so the sentence
    /// is written once.
    private func restOnLostAccess(_ reason: PhotosAccessBlock) {
        phase = .failed
        accessBlock = reason
        message = PipelineError.accessSentence(restricted: reason == .restricted)
    }

    // MARK: - Choosing

    func beginSelecting() {
        guard phase == .scanned || phase == .finished || phase == .selecting else { return }
        // A restored run has results but no library scan to choose from yet.
        guard scanResult != nil else {
            phase = .start
            return
        }
        if phase != .selecting { selection.removeAll() }
        phase = .selecting
    }

    func toggle(_ id: String) {
        guard phase == .selecting else { return }
        // A video the scan read and refused can never enter the selection. The refused rows carry
        // no button, and this is the backstop that keeps the rule true whatever calls it.
        if selection.contains(id) {
            selection.remove(id)
        } else if !refusedAssets.contains(where: { $0.id == id }) {
            selection.insert(id)
        }
    }

    func clearSelection() { selection.removeAll() }

    func selectAll() {
        guard phase == .selecting else { return }
        selection = Set(selectableAssets.map(\.id))
    }

    /// Selects only the videos that look like they will shrink even at the top of the band.
    func selectLikelyToShrink() {
        guard phase == .selecting else { return }
        selection = Set(selectableAssets.filter { savings(for: $0)?.likelyShrinks == true }.map(\.id))
    }

    func backToSummary() {
        guard phase == .selecting else { return }
        selection.removeAll()
        phase = .scanned
    }

    // MARK: - Running

    func start() {
        guard canStart else { return }
        let chosen = selectedAssets
        guard !chosen.isEmpty else { return }
        // These items come from the selection on screen, not from a stored queue, so the claim
        // that this run was picked up from disk ends with the run before it.
        restoredRun = false
        // A fresh start clears what the last one had to say about the videos it could not run.
        preflightRefusals = []
        preflightLeftNothingToRun = false
        preflightNotice = nil
        preflightLeftApp = false
        guard formatProbe != nil else {
            // Nothing here can read a video's own format, so the run starts exactly as it always
            // did. The real app always has the service that can.
            beginRun(with: chosen)
            return
        }
        // A selection is tens of videos, not thousands, so the videos the user actually chose can
        // be read exactly - cap or no cap - before the first export begins. This is the one thing
        // that keeps the worst of the old experience out of a run: a video that turns out to be
        // HDR or ProRes is refused here, in a moment, while the user is still watching, instead of
        // halfway through. The read is the scan's own, with the network switched off, so a video
        // whose original is in iCloud stays unknown and is refused later exactly as it was before.
        message = nil
        phase = .scanning
        preflight = LibraryScanProgress(phase: .inspectingFormats, scanned: 0, total: chosen.count)
        runTask = Task { [weak self] in
            guard let self else { return }
            var refused: [LibraryAsset]?
            do {
                refused = try await self.formatProbe?.refusedByFormat(among: chosen) { [weak self] update in
                    self?.preflight = update
                }
            } catch {
                // A read that failed changes nothing: every chosen video stays eligible and the
                // run starts. A read the user stopped is different - nothing was refused and
                // nothing has begun - and that is settled below by the task's own cancellation.
                if PipelineError.normalize(error, fallback: .libraryScan) != .cancelled { refused = [] }
            }
            self.preflight = nil
            guard !Task.isCancelled, let refused else {
                // The Stop button, the app leaving the foreground, or access going while the read
                // was in flight: nothing was refused and nothing started, so the flow goes back to
                // the choice being made. The Stop button is the user's own tap and needs no
                // explaining; the app going to the background is not, so that one says why the
                // check stopped instead of leaving a selection screen that looks untouched.
                if self.phase == .scanning { self.phase = .selecting }
                if self.phase == .selecting, self.preflightLeftApp {
                    self.preflightNotice = "You left BatchShrink while it was checking the videos you picked, so the run stopped before it began. Nothing was changed; tap Shrink to start again."
                }
                self.preflightLeftApp = false
                self.runTask = nil
                self.reconcileAfterScan()
                return
            }
            let eligible = self.settlePreflight(refused, chosen: chosen)
            guard !eligible.isEmpty else {
                // Every chosen video turned out to be one this app cannot shrink. Nothing is
                // exported, and the selection screen names them with the reason.
                self.preflightLeftNothingToRun = true
                if self.phase == .scanning { self.phase = .selecting }
                self.runTask = nil
                self.reconcileAfterScan()
                return
            }
            self.beginRun(with: eligible)
            // A change Photos reported while this read was going is not lost, exactly as it is not
            // lost by a scan: the listing the read began from may be older than the change.
            self.reconcileAfterScan()
        }
    }

    /// Takes the pre-flight's answer.
    ///
    /// The videos it could not refuse are the run. The ones it refused come out of the selection
    /// and out of the library's own list, into the refusals the screens name, so the listing says
    /// the same thing the run does: a video this app has read and refused is not one that can be
    /// chosen. The reason is always `AssetRules`' sentence, read from the media, so a video refused
    /// here reads exactly like one the scan refused while it was listing the library.
    private func settlePreflight(_ refused: [LibraryAsset], chosen: [LibraryAsset]) -> [LibraryAsset] {
        guard !refused.isEmpty else { return chosen }
        let refusedIDs = Set(refused.map(\.id))
        preflightRefusals = refused
        selection.subtract(refusedIDs)
        if let result = scanResult {
            let remaining = result.assets.filter { !refusedIDs.contains($0.id) }
            scanResult = LibraryScanResult(assets: remaining,
                                           videoCount: result.videoCount,
                                           unsupportedCount: result.unsupportedCount + refused.count,
                                           unknownSizeCount: remaining.filter { $0.bytes == nil }.count,
                                           sizeSource: result.sizeSource,
                                           measuredOnDeviceCount: result.measuredOnDeviceCount,
                                           refusedAssets: result.refusedAssets + refused)
        }
        return chosen.filter { !refusedIDs.contains($0.id) }
    }

    /// Begins the run itself with the videos the pre-flight left eligible.
    ///
    /// These are the steps a start has always taken, in the same order, so nothing about a run
    /// changed except the list it was handed.
    private func beginRun(with chosen: [LibraryAsset]) {
        items = chosen.map { BatchItem(asset: $0, state: .pending) }
        // A fresh run starts with no history of cancellations against any video.
        cancelledAttempts = [:]
        activeSettings = settings.transcode
        activeDeletionMode = settings.deletionMode
        estimator = ProcessingEstimator()
        stopRequested = false
        finishRequested = false
        isStopping = false
        message = nil
        phase = .processing
        activeScreenAwake = settings.keepScreenAwake
        screenAwake.hold(activeScreenAwake)
        persistQueue()
        run()
    }

    func pause() {
        pause(reason: .asked)
    }

    private func pause(reason: BatchPauseReason) {
        guard phase == .processing, !stopRequested else { return }
        stopRequested = true
        finishRequested = false
        isStopping = true
        pauseReason = reason
        stopActiveWork()
        screenAwake.hold(false)
        persistQueue()
    }

    /// Leaves the unprocessed videos alone and shows what this run produced.
    func finishNow() {
        guard phase == .processing || phase == .paused else { return }
        stopRequested = true
        finishRequested = true
        isStopping = true
        stopActiveWork()
        persistQueue()
        if runTask == nil { phase = .finished }
    }

    func resume() {
        guard runTask == nil, phase == .paused || phase == .processing else { return }
        guard hasPendingWork else {
            phase = .finished
            return
        }
        stopRequested = false
        finishRequested = false
        isStopping = false
        pauseReason = nil
        message = nil
        phase = .processing
        persistQueue()
        run()
    }

    func retryFailed() {
        guard runTask == nil else { return }
        let failed = items.indices.filter { items[$0].state.isFailed }
        guard !failed.isEmpty else { return }
        // The user asked for these videos to be tried again, so each starts with a clean slate.
        cancelledAttempts = [:]
        for index in failed { items[index].state = .pending }
        activeSettings = settings.transcode
        activeDeletionMode = settings.deletionMode
        stopRequested = false
        finishRequested = false
        isStopping = false
        phase = .processing
        persistQueue()
        run()
    }

    func reset() {
        guard runTask == nil else { return }
        screenAwake.hold(false)
        items = []
        restoredRun = false
        preflightRefusals = []
        preflightLeftNothingToRun = false
        preflightNotice = nil
        preflightLeftApp = false
        pauseReason = nil
        accessBlock = nil
        readBackOutcomes = [:]
        copyEvidence = [:]
        revalidationOutcomes = [:]
        midSaveFindings = [:]
        deletionOutcomes = [:]
        activeDeletionMode = settings.deletionMode
        checkpointFailure = false
        attemptedSaves = [:]
        cancelledAttempts = [:]
        queueWarning = nil
        clearStoredQueue()
        selection.removeAll()
        estimator = ProcessingEstimator()
        stopRequested = false
        finishRequested = false
        isStopping = false
        message = nil
        phase = scanResult == nil ? .start : .scanned
    }

    /// Requeues the videos the app is not sure about. Only for use after the user has looked
    /// in Photos, because running one again can create a second copy.
    ///
    /// The tap is the user saying they looked. The app looks again too, at that moment and not only
    /// at launch, exactly as the delete path does: a video whose copy it can see is never put back
    /// in the waiting list, because running that video again would make the second copy this whole
    /// area exists to prevent. The user's word covers what the app cannot see; it does not override
    /// what the app can.
    func requeueUncertain() {
        guard runTask == nil else { return }
        let flagged = items.filter { $0.state == .needsCheck }.map(\.id)
        guard !flagged.isEmpty else { return }
        refreshDeletionLook(for: flagged)
        resolveMidSaveItems()
        let uncertain = items.indices.filter { index in
            items[index].state == .needsCheck
                && midSaveFindings[items[index].id]?.forbidsAnotherSave != true
        }
        // A video whose copy the app can see keeps the flag it had instead of going back in the
        // queue. That flag is what the paused and finished screens already point the user at, and
        // nothing here may quietly run it again.
        guard !uncertain.isEmpty else { return }
        for index in uncertain { items[index].state = .pending }
        persistQueue()
        phase = .paused
    }

    func enteredBackground() {
        switch phase {
        case .scanning:
            // Both stops go back to where the flow was, and only one of them needs saying. A
            // chosen-video read is the moment between the user's tap and any work at all, so
            // returning to the unchanged selection screen in silence reads as a tap that did
            // nothing - the pass that stopped says why it stopped. A library scan stopped the same
            // way stays silent: it was a look, the user asked for nothing to be made, and the
            // screen it returns to offers to look again.
            if preflight != nil { preflightLeftApp = true }
            cancelScan()
        case .processing: pause(reason: .leftApp)
        default: break
        }
    }

    // MARK: - Run loop

    private func run() {
        // A fresh attempt starts from a clean notice. If this attempt cannot write its
        // checkpoints either, it stops and says so again.
        checkpointFailure = false
        runTask = Task { [weak self] in
            guard let self else { return }
            // A run reads an original before it writes anything, and it cannot read one without
            // Photos access. This is therefore the first moment a run needs some, and the last
            // moment at which asking can still turn it into work rather than into one failure per
            // waiting video. See `accessForRun()`.
            switch await self.accessForRun() {
            case .granted, .stopped:
                // A stop while the question was being asked is not an answer about access. It
                // rests where every other stop rests: through the loop's own tail.
                await self.runLoop()
            case .missing:
                self.restForAccessTheRunCannotRead()
            }
        }
    }

    /// Whether this run may read Photos, asked once before the first video rather than left for
    /// every video to find out for itself.
    ///
    /// `PhotoLibraryService.requestAccess()` is the app's one route to the system prompt, and it
    /// asks only when nobody has been asked, so this is a plain read for a run that follows a scan
    /// and a real question for one that does not. The case it exists for is a run picked up from a
    /// stored queue on an iPhone that has never granted Photos access - a migration that carries
    /// the queue and not the grant. Without this, Continue went straight to the waiting videos and
    /// every one of them failed with `assetUnavailable`'s sentence about a video sitting outside
    /// the set access allows, which is not what happened to any of them, and no screen offered a
    /// way to change it.
    ///
    /// The app's own scan asks at its first read, so this is the same rule at the other entrance:
    /// the flow asks for Photos access the first time it needs to read, whichever screen that is.
    /// A run that already has access never sees a prompt, and one that has been refused is not
    /// asked again - the system answers immediately, which is what makes the refusal below land
    /// where it lands.
    private func accessForRun() async -> RunAccess {
        // A run that has already been stopped asks for nothing.
        if stopRequested || Task.isCancelled {
            stopRequested = true
            return .stopped
        }
        do {
            limitedAccess = try await photos.requestAccess()
            return .granted
        } catch {
            // A stop is not an answer about access: the user asked the run to stop, or the app went
            // to the background, and the run has to come to rest where every other stop rests.
            if stopRequested || Task.isCancelled
                || PipelineError.normalize(error, fallback: .permissionDenied) == .cancelled {
                stopRequested = true
                return .stopped
            }
            return .missing
        }
    }

    /// Rests a run that never read anything on the screen, and in the words, every other
    /// lost-access path uses.
    ///
    /// Nothing about the run is torn down. No video was tried, so none is failed; the waiting
    /// videos are still waiting, and the queue on disk is the record it already was. The reason is
    /// kept, so the recovery screen offers the route that actually exists - Settings for a
    /// refusal, the plain truth for a restriction - and access allowed in Settings finishes the
    /// pass the user asked for.
    private func restForAccessTheRunCannotRead() {
        isStopping = false
        runTask = nil
        screenAwake.hold(false)
        restOnLostAccess(isRestrictedByTheSystem ? .restricted : .refused)
        log.error("A run could not read Photos: no access was granted")
    }

    private func runLoop() async {
        while !stopRequested, let next = items.first(where: { $0.state == .pending })?.id {
            // Encoding for an hour heats a phone, and iOS will shut work down if it gets too hot.
            if DeviceConditions.pacing() == .tooWarm {
                log.info("Stopping the batch: the device is too warm")
                pause(reason: .tooWarm)
                break
            }
            await process(id: next)
        }
        // A finished run flushes whatever is left in the delete batch. A pause leaves it, because
        // Photos needs the app in front to show its confirmation.
        // One fresh look at every candidate, so the screen that offers them reads a stored answer
        // instead of asking Photos again for each row it draws.
        refreshDeletionLook()
        if finishRequested || !stopRequested { await flushDeletions() }
        cleanWorkspace()
        currentID = nil
        currentStage = nil
        currentProgress = nil
        activeStartedAt = nil
        isStopping = false
        runTask = nil
        screenAwake.hold(false)
        phase = stopRequested && !finishRequested ? .paused : .finished
        persistQueue()
        log.info("Batch run ended")
    }

    private func process(id: String) async {
        guard let asset = items.first(where: { $0.id == id })?.asset else { return }
        // A fresh attempt makes a new copy, so any receipt from an earlier attempt no longer
        // describes what this one is about to create. It has to be earned again, and the read-back
        // goes with it: a check of an earlier copy is not a check of this one, and the deletion
        // gate must never be able to read one as the other.
        copyEvidence[id] = nil
        revalidationOutcomes[id] = nil
        readBackOutcomes[id] = nil
        // A fresh attempt makes a new copy, so the sizes measured for the last one describe a
        // different file. They stay in the record only for an item whose copy is still a question,
        // which is what `attemptedSaves` is for; an attempt that reaches this step writes its own.
        attemptedSaves[id] = nil
        // Work only starts while the queue can be written. Shrinking a video for an hour and then
        // finding out the app cannot record the copy is work thrown away, and copying without a
        // record is worse than not copying at all.
        guard persistQueue() else {
            stopForUnwrittenCheckpoint("BatchShrink couldn't write its place on this iPhone, so it stopped before shrinking this video. Nothing in Photos was changed.")
            return
        }
        currentID = id
        currentProgress = nil
        currentStage = .retrieving
        activeStartedAt = Date()
        setState(.retrieving(nil), for: id)
        var destination: URL?
        var workingIdentity = AssetIdentity.unknown
        // Set only while the run's own floor check is in hand: the one space demand made before
        // anything about this video has been measured, and therefore the same figure for every
        // video in the run. A refusal of it is the device's answer about the run, not about this
        // video, so it stops the run once instead of failing each remaining item in turn.
        var refusingFloor = false
        // Set the moment Photos is handed the copy, so a failure arriving after that is read as the
        // question it is: Photos may already hold the copy, whatever it answered. It is per attempt
        // on purpose - the sizes `attemptedSaves` keeps describe the copy this attempt makes, and an
        // entry left by an earlier one says nothing about a step that has not been reached yet.
        var handedToPhotos = false
        do {
            try temporary.ensureWorkspace()
            refusingFloor = true
            try temporary.requireCapacity(for: DiskHeadroom.neededToWrite(nil))
            refusingFloor = false
            let retrieved = try await photos.retrieve(identifier: id) { [weak self] value in
                guard let self, self.currentID == id else { return }
                self.currentProgress = value
                self.setState(.retrieving(value), for: id)
            }
            // This attempt got past the retrieval, so whatever run of cancellations came before it
            // is over. Only consecutive cancellations of the same retrieval may accumulate.
            cancelledAttempts[id] = nil
            workingIdentity = retrieved.identity
            try checkStop()
            setState(.preparing, for: id)
            currentStage = .preparing
            currentProgress = nil
            let original = try await verifier.inspect(retrieved.asset.url)
            try checkStop()
            // One file is about to be written, not two: the original is already on the disk and
            // was just measured, so its bytes are already spent. Demanding a second copy of it
            // turned away phones that had room to finish the export.
            try temporary.requireCapacity(for: DiskHeadroom.neededToWrite(original.bytes))
            setState(.transcoding(nil), for: id)
            currentStage = .transcoding
            let started = Date()
            let written = try await transcoder.transcode(retrieved, metadata: original,
                                                        settings: activeSettings) { [weak self] value in
                guard let self, self.currentID == id else { return }
                self.currentProgress = value
                self.setState(.transcoding(value), for: id)
            }
            destination = written
            try checkStop()
            setState(.verifying, for: id)
            currentStage = .verifying
            currentProgress = nil
            let output = try await verifier.verify(written, source: original, expecting: activeSettings.codec)
            let processingSeconds = Date().timeIntervalSince(started)
            estimator.record(processingSeconds: processingSeconds, contentSeconds: original.duration)
            try checkStop()
            let saving = Savings(originalBytes: original.bytes, compressedBytes: output.bytes)
            if saving.isSmaller {
                try temporary.requireCapacity(for: DiskHeadroom.neededToWrite(output.bytes))
                // The sizes this run measured go down with the intent, so a launch that finds the
                // copy in Photos afterwards can say what was saved instead of asking the user to
                // work it out.
                attemptedSaves[id] = saving
                // The intent is on disk before Photos is asked to keep anything. A copy Photos has
                // accepted cannot be taken back, so the queue must already describe it when the
                // app stops for good.
                try requireJournaledCheckpoint(setState(.saving, for: id), step: "saving a copy")
                currentStage = .saving
                handedToPhotos = true
                let created = try await photos.save(videoAt: written, identity: workingIdentity)
                // Photos already holds this copy, so its identifier is remembered straight away:
                // the copy is in the library whatever happens to the rest of this step, and the
                // next bulk selection must leave it alone rather than shrink it a second time.
                rememberCreatedCopy(created)
                record(output: output, for: id)
                // Which asset Photos created is written down here, at the moment its identifier is
                // known, rather than only after the read-back below. A crash in that window would
                // otherwise leave a restored run with no way at all to find out whether this save
                // landed. What is written is the copy's identity: it is not a verification, and a
                // delete still needs a read-back this app performed.
                if let created,
                   let receipt = photos.deletionEvidence(originalIdentifier: id,
                                                         copyIdentifier: created) {
                    copyEvidence[id] = receipt
                    persistQueue()
                }
                // Photos now holds a copy, so the run must not go back on that. When the record of
                // it cannot be written, the `.saving` entry already on disk is what stops a later
                // launch from making a second copy, and the run stops here rather than reach a
                // deletion it could not describe.
                guard setState(.saved(saving), for: id) else {
                    stopForUnwrittenCheckpoint("BatchShrink saved a copy but couldn't write that down, so it stopped. Check Photos before running that video again.")
                    throw PipelineError.cancelled
                }
                await confirmReadBack(for: id, createdIdentifier: created, expected: output)
                // The save is settled, so the sizes measured for it are no longer the only record
                // of what happened: the item's own state carries them from here.
                attemptedSaves[id] = nil
                if activeDeletionMode == .afterEachCopy {
                    await queueDeletion(for: id)
                }
            } else {
                setState(.skipped("This copy wasn’t smaller than the original, so it wasn’t saved."), for: id)
            }
        } catch {
            let normalized = PipelineError.normalize(error, fallback: .export)
            if refusingFloor, normalized == .insufficientStorage {
                // The run asked for the same working reserve for every video in it, and this is
                // that check refusing. The video goes back to waiting - nothing was retrieved,
                // written or asked of Photos - and the run stops once, with the paused screen
                // naming the figure the check asked for. Failing each remaining video instead
                // would repeat one sentence per item and end on "No copies were saved."
                setState(.pending, for: id)
                pause(reason: .storage)
            } else if handedToPhotos {
                // Photos was asked to keep a copy and answered something this run cannot place.
                // A copy may already be in the library, so this is not a clean failure and not an
                // item the run may pick up again by itself: it keeps the `.saving` evidence as the
                // question the read-back path already knows how to settle. See
                // `noteUnsettledSave` for why it is not persisted as `.failed`.
                noteUnsettledSave(for: id)
            } else if stopRequested || normalized == .cancelled {
                // A copy Photos already kept is never put back in the waiting list: running that
                // video again would make a second copy. Anything else is safe to run again.
                if !hasSavedCopy(id) {
                    if stopRequested {
                        // The run is stopping because the user asked it to, so nothing about this
                        // answer is a fault: the video waits for the resume that picks it up.
                        setState(.pending, for: id)
                    } else if (cancelledAttempts[id] ?? 0) < Self.cancelledRetryLimit {
                        // PhotoKit cancelled a retrieval this run never asked to stop. Retrying it
                        // straight away is safe and usually enough, so the video waits again - but
                        // only while the retries last, or a persistent cause would spin the run on
                        // this one video forever.
                        cancelledAttempts[id] = (cancelledAttempts[id] ?? 0) + 1
                        setState(.pending, for: id)
                    } else {
                        // The cap is reached and this video has failed. It fails in the retrieval's
                        // own words rather than the export's: outside a stop the only step that can
                        // be cancelled is the retrieval, and `.cancelled` persists as `.export`,
                        // which would tell the user about an export that never ran.
                        cancelledAttempts[id] = nil
                        setState(.failed(.retrieval), for: id)
                        log.error("Batch item failed")
                    }
                }
            } else {
                setState(.failed(normalized), for: id)
                log.error("Batch item failed")
            }
        }
        if let destination { removeTemporary(destination) }
        currentID = nil
        currentStage = nil
        currentProgress = nil
        activeStartedAt = nil
    }

    private func stopActiveWork() {
        // An accepted Photos save cannot be cancelled; let it settle.
        guard items.first(where: { $0.id == currentID })?.state.isSaving != true else { return }
        // Cancelling the task the run is driven by is what makes a stop reach work that is in
        // flight. The session `transcoder.cancel()` reaches is only the one running at this
        // instant: the transcoder tries a second plan after a failed attempt, that attempt builds
        // a session of its own, and nothing can cancel a session that does not exist yet. The plan
        // loop reads this task before it starts another, exactly as the one-video flow's own
        // cancel does, so a retry cannot outlive the stop that caused it.
        runTask?.cancel()
        photos.cancelRetrieval()
        transcoder.cancel()
    }

    private func checkStop() throws {
        if stopRequested || Task.isCancelled { throw PipelineError.cancelled }
    }

    /// Whether this video already has a copy Photos accepted, which must never be saved twice.
    private func hasSavedCopy(_ id: String) -> Bool {
        guard let item = items.first(where: { $0.id == id }) else { return false }
        if case .saved = item.state { return true }
        return false
    }

    /// Records that Photos answered a save in a way this run cannot place, without throwing away
    /// the evidence that a copy may exist.
    ///
    /// The item becomes `.needsCheck`, which is the state a queue that stopped mid-save is
    /// reconciled into: Photos may hold the copy, the sizes the run measured for it stay in the
    /// record beside it, and nothing runs this video again until the user has looked in Photos.
    /// It is deliberately not `.failed`: `retryFailed()` runs failed items again on one tap, and a
    /// second copy is the outcome this whole area exists to prevent. The wording is
    /// `PipelineError.save`'s, because that is what happened - Photos did not confirm the save.
    ///
    /// A record that cannot be written here is not the dangerous kind: the `.saving` entry already
    /// on disk is the same evidence, and a queue read back from it is reconciled into this very
    /// state. Nothing was added to or removed from Photos by the write either way.
    private func noteUnsettledSave(for id: String) {
        guard !hasSavedCopy(id) else { return }
        midSaveFindings[id] = .unresolved(question: PipelineError.save.localizedDescription)
        setState(.needsCheck, for: id)
        log.error("Photos did not confirm a save; the copy is a question now")
    }

    /// Stops the run before the next Photos step when the checkpoint that would describe it is
    /// not on disk. A run is only allowed to continue while the app can write down what it does.
    ///
    /// A run that is already stopped, and a deletion the user asked for on a finished screen, are
    /// left alone: the warning is the part that matters there.
    private func stopForUnwrittenCheckpoint(_ detail: String) {
        queueWarning = detail
        checkpointFailure = true
        log.error("A required queue checkpoint could not be written")
        guard runTask != nil, !stopRequested else { return }
        stopRequested = true
        finishRequested = false
        isStopping = true
        stopActiveWork()
        screenAwake.hold(false)
    }

    /// Refuses a Photos step whose checkpoint did not reach disk.
    private func requireJournaledCheckpoint(_ journaled: Bool, step: String) throws {
        guard !journaled else { return }
        stopForUnwrittenCheckpoint("BatchShrink couldn't write its place on this iPhone, so it stopped before \(step). Nothing was added to or removed from Photos by that step.")
        throw PipelineError.cancelled
    }

    /// Records a state change and says whether the queue on disk now describes it.
    ///
    /// Progress callbacks repeat the same stored step, so only real transitions are written. A
    /// repeated step reports whether the last write is still standing, because between two Photos
    /// mutations the only thing that matters is whether the evidence reached disk.
    @discardableResult
    private func setState(_ state: BatchItemState, for id: String) -> Bool {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return false }
        let changed = BatchQueueReconciliation.persisted(items[index].state)
            != BatchQueueReconciliation.persisted(state)
        items[index].state = state
        if changed { return persistQueue() }
        return !checkpointFailure
    }

    /// Asks Photos for the copy it just accepted and compares it with the copy this run measured
    /// and approved before saving. A copy that cannot be read back is not a failed save, because
    /// Photos already confirmed the write. It only means the copy could not be checked yet, and
    /// the summary says exactly that.
    ///
    /// Only a copy Photos really hands back earns a receipt, and a receipt is the only thing that
    /// can later justify deleting the original.
    private func confirmReadBack(for id: String, createdIdentifier: String?,
                                 expected: VideoMetadata) async {
        var outcome: CopyReadBack = .unavailable
        if let createdIdentifier {
            for attempt in 0..<3 {
                if let url = await photos.localFileURL(identifier: createdIdentifier),
                   (try? await verifier.verifyImportedCopy(url, matching: expected)) != nil {
                    outcome = .confirmed
                    if let receipt = photos.deletionEvidence(originalIdentifier: id,
                                                             copyIdentifier: createdIdentifier) {
                        copyEvidence[id] = receipt
                    }
                    break
                }
                if attempt < 2 { try? await Task.sleep(for: .milliseconds(400)) }
            }
        }
        readBackOutcomes[id] = outcome
        // The copy this run just made is a candidate now, so it gets its fresh look here rather
        // than when the screen is drawn.
        refreshDeletionLook(for: [id])
        persistQueue()
    }

    /// Runs the gate for one original and adds it to the next Photos transaction.
    private func queueDeletion(for id: String) async {
        guard let item = items.first(where: { $0.id == id }) else { return }
        switch deletionDecision(for: item) {
        case .skip(let reason):
            // With deleting turned off there is nothing worth recording.
            if effectiveDeletionMode.deletesOriginals {
                deletionOutcomes[id] = .skipped(reason)
                persistQueue()
            }
        case .delete:
            deletionBatch.append(id)
            if deletionBatch.count >= Self.deletionBatchSize { await flushDeletions() }
        }
    }

    /// Sends the waiting originals to Photos in one transaction, which means one confirmation.
    ///
    /// Intent is written down before the call and the answer is written down after it, so a stop
    /// in the middle comes back as uncertain instead of being repeated.
    private func flushDeletions() async {
        let candidates = deletionBatch
        deletionBatch.removeAll()
        guard !candidates.isEmpty else { return }
        let previous = candidates.map { ($0, deletionOutcomes[$0]) }
        // The receipts come from what the run recorded when Photos handed each copy back. A
        // candidate with no receipt is simply absent from this dictionary, so the service is never
        // asked about it and it is never deleted. The stored fresh look is applied once more here,
        // so a copy that changed while the group waited is settled as kept with its reason rather
        // than riding on the answer it entered the group with.
        let receipts = candidates.reduce(into: [String: DeletionEvidence]()) { found, id in
            found[id] = copyEvidence[id]
        }
        let looks = candidates.reduce(into: [String: CopyRevalidation]()) { found, id in
            found[id] = revalidationOutcomes[id]
        }
        let offered = DeletionPolicy.split(receipts, outcomes: looks)
        for (id, outcome) in offered.rejected {
            deletionOutcomes[id] = .skipped(Self.deletionSkipReason(outcome))
        }
        guard !offered.approved.isEmpty else {
            // Nothing here may be handed to Photos. What each look said is still worth writing
            // down, because that is this run's answer for those originals.
            guard persistQueue() else {
                for (id, outcome) in previous { deletionOutcomes[id] = outcome }
                stopForUnwrittenCheckpoint("BatchShrink couldn't write down what happened to these originals, so it stopped. Nothing was deleted from Photos.")
                return
            }
            return
        }
        let batch = offered.approved
        let submitted = batch.reduce(into: [String: DeletionEvidence]()) { found, id in
            found[id] = receipts[id]
        }
        for id in batch { deletionOutcomes[id] = .deleting }
        guard persistQueue() else {
            // Photos was never asked, so the intent goes back to what it was and these originals
            // stay available for an attempt that can be written down.
            for (id, outcome) in previous { deletionOutcomes[id] = outcome }
            stopForUnwrittenCheckpoint("BatchShrink couldn't write down which originals it was about to delete, so it stopped before asking Photos. Nothing was deleted.")
            return
        }
        do {
            let result = try await photos.deleteOriginals(afterRevalidating: submitted)
            let deleted = Set(result.deleted)
            for id in batch {
                if deleted.contains(id) {
                    deletionOutcomes[id] = .deleted
                } else if let outcome = result.rejected[id] {
                    deletionOutcomes[id] = .skipped(Self.deletionSkipReason(outcome))
                } else {
                    deletionOutcomes[id] = .skipped("Photos couldn’t find this original any more.")
                }
            }
            log.info("Deleted \(deleted.count, privacy: .public) originals in one transaction")
        } catch {
            let code = BatchFailureCode(PipelineError.normalize(error, fallback: .save))
            for id in batch { deletionOutcomes[id] = .failed(code) }
            log.error("Deleting originals failed")
        }
        // Photos has answered. What it did has to reach disk as well: when it cannot, the only
        // honest reading is that a delete was in flight, so each original is kept uncertain and a
        // later launch checks Photos instead of deleting anything again.
        guard persistQueue() else {
            for id in batch { deletionOutcomes[id] = .uncertain }
            stopForUnwrittenCheckpoint("BatchShrink couldn't write down what happened to these originals, so it stopped. Check Recently Deleted in Photos before running those videos again.")
            return
        }
    }

    /// Deletes the originals a stopped run can justify. Only ever called after the user has read
    /// what it means and confirmed; nothing here runs on its own.
    func deleteOriginalsNow() {
        guard runTask == nil, !deletionInProgress else { return }
        // The offer was drawn from a look taken earlier, and a copy can have changed since. The
        // candidates the screen offered are looked at again here, at the moment of the tap, and
        // the list is built from that fresh answer, so it can only be smaller than the offer. A
        // copy with no current look is left out and its original stays.
        let offered = deletableItemIDs
        refreshDeletionLook(for: offered)
        let ids = items.filter { deletionDecision(for: $0) == .delete }.map(\.id)
        // Anything the fresh look just refused has to say so. Returning quietly would leave
        // someone who tapped Delete looking at a button that appeared to do nothing at all.
        for id in offered where !ids.contains(id) {
            switch revalidationOutcomes[id] {
            case .some(.matches), .none:
                // The look agreed, so it was something else: no confirmed read-back, a copy that
                // is not smaller, or a mode that is off. None of those has a revalidation reason.
                deletionOutcomes[id] = .skipped("The original can't be deleted right now, so it stays.")
            case .some(let look):
                deletionOutcomes[id] = .skipped(Self.deletionSkipReason(look))
            }
        }
        guard !ids.isEmpty else { return }
        deletionInProgress = true
        deletionTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.deletionTask = nil
                self.deletionInProgress = false
            }
            self.deletionBatch = ids
            await self.flushDeletions()
            self.log.info("Deleting originals finished")
        }
    }

    /// Writes the queue and says whether the record reached disk.
    ///
    /// Every Photos mutation is gated on this answer. A queue the app cannot write is a queue that
    /// cannot describe what it asked Photos to do, so a caller must stop rather than take the next
    /// step without it.
    @discardableResult
    private func persistQueue() -> Bool {
        guard !items.isEmpty else { return clearStoredQueue() }
        let record = BatchQueueRecord(
            settings: BatchQueueRecord.Settings(resolution: activeSettings.resolution.rawValue,
                                                frameRate: activeSettings.frameRate.rawValue,
                                                deletion: activeDeletionMode.rawValue),
            items: items.map { item in
                BatchQueueRecord.Item(identifier: item.asset.id,
                                      creationDate: item.asset.creationDate,
                                      duration: item.asset.duration,
                                      pixelWidth: item.asset.pixelWidth,
                                      pixelHeight: item.asset.pixelHeight,
                                     bytes: item.asset.bytes,
                                      state: BatchQueueReconciliation.persisted(item.state),
                                      readBack: readBackOutcomes[item.asset.id],
                                      deletion: deletionOutcomes[item.asset.id],
                                      copyEvidence: copyEvidence[item.asset.id],
                                      attemptedSave: attemptedSaves[item.asset.id].map { AttemptedSave($0) })
            },
            // The videos this run began without, so a run that is picked up again can still
            // account for them wherever it ends. The record holds the identity the screens draw
            // and `AssetRules`' own stable kind, never the sentence itself.
            refusals: preflightRefusals.compactMap { BatchQueueRecord.Refusal(asset: $0) })
        do {
            try queueStore.save(record)
            // A notice is only dropped once the run has a written record to put in its place.
            if !checkpointFailure { queueWarning = nil }
            return true
        } catch {
            queueWarning = "BatchShrink couldn't write its place on this iPhone. It stops before changing anything else in Photos."
            log.error("Storing the queue failed")
            return false
        }
    }

    /// Removes the stored queue and says whether the record is really gone.
    ///
    /// Clearing writes an empty queue rather than deleting a file, and the store reports nothing
    /// when that fails, so the queue is read back. A record left behind would let a later launch
    /// act on work this run has already finished, which is why the user is told about it.
    @discardableResult
    private func clearStoredQueue() -> Bool {
        queueStore.clear()
        guard queueStore.load() != nil else { return true }
        queueWarning = "BatchShrink couldn't clear the queue it had saved. The next launch may offer this run again, so check Photos before letting it run."
        log.error("Clearing the stored queue left a record behind")
        return false
    }

    private func restoreQueue() {
        guard let record = queueStore.load() else { return }
        let reconciled = BatchQueueReconciliation.reconcile(record)
        guard !reconciled.items.isEmpty else {
            clearStoredQueue()
            return
        }
        if let resolution = CopyResolution(rawValue: reconciled.settings.resolution) {
            settings.resolution = resolution
        }
        if let frameRate = FrameRateOption(rawValue: reconciled.settings.frameRate) {
            settings.frameRate = frameRate
        }
        if let deletion = reconciled.settings.deletion.flatMap(DeletionMode.init(rawValue:)) {
            activeDeletionMode = deletion
        }
        activeSettings = settings.transcode
        items = reconciled.items.map { item in
            BatchItem(asset: item.asset, state: BatchQueueReconciliation.live(item.state))
        }
        // The videos this run began without, so every screen that names them keeps naming them -
        // the finished one most of all, because it is the screen that has to account for the
        // difference between what the user picked and what this run actually took. The record
        // carries the identity alone, and the reason comes back from `AssetRules` through it. A
        // queue written before this was kept carries no list, which is exactly what a run that
        // refused nothing looked like.
        preflightRefusals = reconciled.refusals?.map(\.asset) ?? []
        readBackOutcomes = Dictionary(uniqueKeysWithValues: reconciled.items.compactMap { item in
            item.readBack.map { (item.identifier, $0) }
        })
        copyEvidence = Dictionary(uniqueKeysWithValues: reconciled.items.compactMap { item in
            item.copyEvidence.map { (item.identifier, $0) }
        })
        deletionOutcomes = Dictionary(uniqueKeysWithValues: reconciled.items.compactMap { item in
            item.deletion.map { (item.identifier, $0) }
        })
        // What the stopped run had measured for the copy it was handing over, kept for the items
        // that are still a question. An item that settled carries its own sizes.
        var restoredAttempts: [String: Savings] = [:]
        for item in reconciled.items where BatchQueueReconciliation.live(item.state) == .needsCheck {
            if let attempt = item.attemptedSave { restoredAttempts[item.identifier] = attempt.savings }
        }
        attemptedSaves = restoredAttempts
        restoredRun = true
        // A restored run still has to take its own fresh look before it offers anything, because
        // a receipt written earlier says what the assets looked like then, not now.
        refreshDeletionLook()
        // Then the one question the stored record cannot answer on its own: whether Photos took
        // the copy an interrupted save was handing over.
        resolveMidSaveItems()
        // Read after that question is settled: a video Photos has no copy of is waiting again, and
        // the run should come back as one that can be continued rather than one that is finished.
        phase = hasPendingWork ? .paused : .finished
        log.info("Restored a stored queue")
    }

    /// Answers "did Photos take that copy?" for the videos a restored run is unsure about, as far
    /// as the stored record and Photos can answer it, and lets the two answers that can be acted
    /// on change what the item is.
    ///
    /// Nothing here creates or removes anything: it looks, and writes down what it saw. A video
    /// whose copy it can see settles as the save that copy turned out to be and is never handed to
    /// the encoder again, because a second copy of a video that was already copied is the outcome
    /// this whole area exists to prevent. A video Photos has no copy of goes back to waiting, which
    /// cannot duplicate anything. Anything else stays a question for the user. No finding here can
    /// authorise a delete: only a read-back this app performed can do that, and this is not one.
    private func resolveMidSaveItems() {
        var settled = false
        for index in items.indices where items[index].state == .needsCheck {
            let id = items[index].id
            let finding = BatchQueueReconciliation.midSaveFinding(
                receipt: copyEvidence[id],
                lookup: revalidationOutcomes[id],
                wholeLibraryVisible: !libraryChanges.isLimited)
            midSaveFindings[id] = finding
            switch finding {
            case .copyInPhotos:
                // The copy exists whatever else is known about it, so it is recorded as this
                // app's own output and left out of every automatic selection.
                rememberCreatedCopy(copyEvidence[id]?.verifiedCopyIdentifier)
                // The record also has to carry what the run measured for that copy. Without those
                // numbers there is nothing to claim, so the item keeps its question, and the
                // requeue path below refuses it either way.
                guard let saving = attemptedSaves[id], saving.isSmaller else { break }
                // A read-back found in a mid-save record describes an earlier attempt rather than
                // this copy, so it is dropped instead of inherited. That is what keeps the
                // deletion gate shut for a video whose copy was never checked, while the copy
                // itself is still written down properly below.
                readBackOutcomes[id] = nil
                items[index].state = .saved(saving)
                recordFoundCopy(for: id, savings: saving)
                attemptedSaves[id] = nil
                settled = true
                log.info("A restored mid-save item was settled from Photos")
            case .noCopyInPhotos:
                items[index].state = .pending
                attemptedSaves[id] = nil
                settled = true
            case .unresolved:
                break
            }
        }
        // What a launch settled on has to reach disk, or the next one is asked the same question.
        if settled { persistQueue() }
    }

    /// Writes down that this iPhone made a copy of an original, from what the queue kept.
    ///
    /// A run that stopped mid-save may never have reached the point where it records this, and a
    /// restore that has just found the copy is the only other place that can. It matters beyond
    /// tidiness: an original nothing has recorded is offered by Select all, and running it again
    /// would make a second copy.
    private func recordFoundCopy(for id: String, savings: Savings) {
        let copy = copyEvidence[id]?.copy
        let longEdge = copy.map { max($0.pixelWidth, $0.pixelHeight) } ?? 0
        let duration = items.first { $0.id == id }?.asset.duration ?? 0
        var measurement: CopyMeasurement?
        if longEdge > 0, duration > 0 {
            measurement = CopyMeasurement(bitsPerSecond: Double(savings.compressedBytes) * 8 / duration,
                                          longEdge: longEdge)
        }
        history.record(identifier: id, measurement: measurement)
        completedIdentifiers.insert(id)
        measurements = history.copyMeasurements()
    }

    private func record(output: VideoMetadata, for id: String) {
        let measurement = CopyMeasurement(bitsPerSecond: output.duration > 0
                                          ? Double(output.bytes) * 8 / output.duration : 0,
                                          longEdge: output.longEdge)
        history.record(identifier: id, measurement: measurement)
        completedIdentifiers.insert(id)
        measurements = history.copyMeasurements()
    }

    /// Writes down the copy Photos just handed back, so a later bulk selection leaves it alone.
    /// The copy goes into its own set, never into `completedIdentifiers`: that set means "this
    /// original was shrunk" and drives the marking in the library, while a copy is this app's own
    /// output. Merging them would mislabel the copy, and keeping them apart is what lets a copy
    /// stay visible and still be chosen by hand.
    private func rememberCreatedCopy(_ identifier: String?) {
        guard let identifier else { return }
        history.recordCreatedCopy(identifier: identifier)
        createdCopyIdentifiers.insert(identifier)
    }

    private func removeTemporary(_ url: URL) {
        do { try temporary.remove(url) }
        catch {
            cleanupWarning = "Temporary cleanup could not finish. Restart BatchShrink to retry."
            log.error("Temporary file removal failed")
        }
    }

    private func cleanWorkspace() {
        do { try temporary.cleanup(); cleanupWarning = nil }
        catch {
            cleanupWarning = "Temporary cleanup could not finish. Restart BatchShrink to retry."
            log.error("Temporary cleanup failed")
        }
    }
}
