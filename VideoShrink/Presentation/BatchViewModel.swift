import Foundation
import Combine
import OSLog
import AVFoundation

enum BatchPhase: Equatable {
    case start, scanning, scanned, selecting, processing, paused, finished, failed
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

    let settings: ShrinkSettings

    private let photos: any PhotoLibraryServing
    private let scanner: any LibraryScanning
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
         settings: ShrinkSettings) {
        self.photos = photos
        self.scanner = scanner
        self.transcoder = transcoder
        self.verifier = verifier
        self.temporary = temporary
        self.history = history
        self.queueStore = queueStore
        self.screenAwake = screenAwake
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
                    self.message = normalized.localizedDescription
                    self.log.error("Library scan failed")
                }
            }
        }
    }

    func cancelScan() {
        guard phase == .scanning else { return }
        scanner.cancel()
        runTask?.cancel()
    }

    // MARK: - Library changes

    /// One report from the monitor: Photos changed outside the app, or the app came back to the
    /// front, where access can have changed while it was suspended.
    private func libraryChanged(_ reason: LibraryChangeReason) {
        limitedAccess = libraryChanges.isLimited
        guard libraryChanges.canReadLibrary else {
            libraryAccessLost()
            return
        }
        log.info("Photos reported a change (\(String(describing: reason), privacy: .public))")
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

    /// Photos access is gone.
    ///
    /// This is the path `scan()` takes when Photos refuses it: the flow says so rather than
    /// holding a library it can no longer read, and it is taken only from the phases a scan
    /// itself may start in. A run in flight, or one paused with work left, keeps the screen and
    /// its own record of what happened to each video.
    ///
    /// A scan that is reading the library when access goes is stopped rather than left to run:
    /// what it would produce is a library this app may no longer read, and the flow says so
    /// instead. The scan's own cancel path leaves a phase it no longer owns alone, so this
    /// decision survives the cancellation landing.
    private func libraryAccessLost() {
        if phase == .scanning {
            scanner.cancel()
            runTask?.cancel()
        } else {
            guard runTask == nil,
                  [BatchPhase.start, .scanned, .selecting, .finished, .failed].contains(phase) else { return }
        }
        phase = .failed
        message = PipelineError.permissionDenied.localizedDescription
        log.error("Photos access was withdrawn")
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
        items = chosen.map { BatchItem(asset: $0, state: .pending) }
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
        pauseReason = nil
        readBackOutcomes = [:]
        copyEvidence = [:]
        revalidationOutcomes = [:]
        midSaveFindings = [:]
        deletionOutcomes = [:]
        activeDeletionMode = settings.deletionMode
        checkpointFailure = false
        attemptedSaves = [:]
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
        case .scanning: cancelScan()
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
            await self?.runLoop()
        }
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
        do {
            try temporary.ensureWorkspace()
            try temporary.requireCapacity(for: DiskHeadroom.reserve)
            let retrieved = try await photos.retrieve(identifier: id) { [weak self] value in
                guard let self, self.currentID == id else { return }
                self.currentProgress = value
                self.setState(.retrieving(value), for: id)
            }
            workingIdentity = retrieved.identity
            try checkStop()
            setState(.preparing, for: id)
            currentStage = .preparing
            currentProgress = nil
            let original = try await verifier.inspect(retrieved.asset.url)
            try checkStop()
            try temporary.requireCapacity(for: DiskHeadroom.bytes(original.bytes, copies: 2))
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
                try temporary.requireCapacity(for: DiskHeadroom.bytes(output.bytes, copies: 1))
                // The sizes this run measured go down with the intent, so a launch that finds the
                // copy in Photos afterwards can say what was saved instead of asking the user to
                // work it out.
                attemptedSaves[id] = saving
                // The intent is on disk before Photos is asked to keep anything. A copy Photos has
                // accepted cannot be taken back, so the queue must already describe it when the
                // app stops for good.
                try requireJournaledCheckpoint(setState(.saving, for: id), step: "saving a copy")
                currentStage = .saving
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
            if stopRequested || normalized == .cancelled {
                // A copy Photos already kept is never put back in the waiting list: running that
                // video again would make a second copy. Anything else is safe to run again.
                if !hasSavedCopy(id) { setState(.pending, for: id) }
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
            })
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
