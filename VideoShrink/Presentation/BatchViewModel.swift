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
    @Published private(set) var deletionOutcomes: [String: DeletionOutcome] = [:]
    @Published private(set) var deletionInProgress = false
    @Published private(set) var limitedAccess = false
    @Published private(set) var estimator = ProcessingEstimator()
    @Published private(set) var measurements: [CopyMeasurement] = []
    @Published private(set) var completedIdentifiers: Set<String> = []
    @Published private(set) var isStopping = false
    @Published var selection: Set<String> = []

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
    static let deletionBatchSize = 5

    init(photos: any PhotoLibraryServing,
         scanner: any LibraryScanning,
         transcoder: any VideoTranscoding,
         verifier: any VideoVerifying,
         temporary: any TemporaryFileManaging,
         history: any ShrinkHistoryStoring,
         queueStore: any BatchQueueStoring,
         screenAwake: any ScreenAwakeControlling,
         settings: ShrinkSettings) {
        self.photos = photos
        self.scanner = scanner
        self.transcoder = transcoder
        self.verifier = verifier
        self.temporary = temporary
        self.history = history
        self.queueStore = queueStore
        self.screenAwake = screenAwake
        self.settings = settings
        completedIdentifiers = history.completedIdentifiers()
        measurements = history.copyMeasurements()
        cleanWorkspace()
        restoreQueue()
    }

    // MARK: - Derived state

    var eligibleAssets: [LibraryAsset] { scanResult?.assets ?? [] }
    var selectedAssets: [LibraryAsset] { eligibleAssets.filter { selection.contains($0.id) } }
    /// Videos the bulk shortcuts may pick: everything eligible that this iPhone has not
    /// already shrunk. Individual rows stay available for a deliberate second run.
    /// Everything eligible that this iPhone has not already shrunk and whose original is still in
    /// Photos. Deleting an original takes it out of later selections.
    var selectableAssets: [LibraryAsset] {
        eligibleAssets.filter { asset in
            !completedIdentifiers.contains(asset.id) && deletionOutcomes[asset.id] != DeletionOutcome.deleted
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
        phase = .scanning
        message = nil
        scanProgress = LibraryScanProgress(phase: .listing, scanned: 0, total: 0)
        completedIdentifiers = history.completedIdentifiers()
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
                self.phase = .scanned
                self.log.info("Library scan finished")
            } catch {
                let normalized = PipelineError.normalize(error, fallback: .libraryScan)
                if normalized == .cancelled {
                    self.phase = self.scanResult == nil ? .start : .scanned
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
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
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
        deletionOutcomes = [:]
        activeDeletionMode = settings.deletionMode
        checkpointFailure = false
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
    func requeueUncertain() {
        guard runTask == nil else { return }
        let uncertain = items.indices.filter { items[$0].state == .needsCheck }
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
        // describes what this one is about to create. It has to be earned again.
        copyEvidence[id] = nil
        revalidationOutcomes[id] = nil
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
                // The intent is on disk before Photos is asked to keep anything. A copy Photos has
                // accepted cannot be taken back, so the queue must already describe it when the
                // app stops for good.
                try requireJournaledCheckpoint(setState(.saving, for: id), step: "saving a copy")
                currentStage = .saving
                let created = try await photos.save(videoAt: written, identity: workingIdentity)
                record(output: output, for: id)
                // Photos now holds a copy, so the run must not go back on that. When the record of
                // it cannot be written, the `.saving` entry already on disk is what stops a later
                // launch from making a second copy, and the run stops here rather than reach a
                // deletion it could not describe.
                guard setState(.saved(saving), for: id) else {
                    stopForUnwrittenCheckpoint("BatchShrink saved a copy but couldn't write that down, so it stopped. Check Photos before running that video again.")
                    throw PipelineError.cancelled
                }
                await confirmReadBack(for: id, createdIdentifier: created, expected: output)
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
        let ids = items.filter { deletionDecision(for: $0) == .delete }.map(\.id)
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
                                      copyEvidence: copyEvidence[item.asset.id])
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
        restoredRun = true
        phase = hasPendingWork ? .paused : .finished
        // A restored run still has to take its own fresh look before it offers anything, because
        // a receipt written earlier says what the assets looked like then, not now.
        refreshDeletionLook()
        log.info("Restored a stored queue")
    }

    private func record(output: VideoMetadata, for id: String) {
        let measurement = CopyMeasurement(bitsPerSecond: output.duration > 0
                                          ? Double(output.bytes) * 8 / output.duration : 0,
                                          longEdge: output.longEdge)
        history.record(identifier: id, measurement: measurement)
        completedIdentifiers.insert(id)
        measurements = history.copyMeasurements()
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
