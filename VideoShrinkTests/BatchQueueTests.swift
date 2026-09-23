import XCTest
import AVFoundation
@testable import VideoShrink

@MainActor final class BatchQueueTests: XCTestCase {

    func testRunningItemsWaitAgainAndMidSaveItemsAreFlagged() {
        let record = BatchQueueRecord(
            settings: .init(resolution: "hd1080", frameRate: "original"),
            items: [item("a", .pending), item("b", .running), item("c", .saving),
                    item("d", .saved(originalBytes: 1_000, copyBytes: 600)),
                    item("e", .skipped(reason: "Not smaller")),
                    item("f", .failed(code: .storage)), item("g", .needsCheck)])
        let reconciled = BatchQueueReconciliation.reconcile(record)
        XCTAssertEqual(reconciled.items.map(\.state),
                       [.pending, .pending, .needsCheck,
                        .saved(originalBytes: 1_000, copyBytes: 600),
                        .skipped(reason: "Not smaller"), .failed(code: .storage), .needsCheck])
    }

    func testLiveStatesRoundTripThroughTheStoredForm() {
        let cases: [(BatchItemState, BatchQueueRecord.State)] = [
            (.pending, .pending),
            (.retrieving(0.4), .running),
            (.preparing, .running),
            (.transcoding(0.9), .running),
            (.verifying, .running),
            (.saving, .saving),
            (.saved(Savings(originalBytes: 1_000, compressedBytes: 600)),
             .saved(originalBytes: 1_000, copyBytes: 600)),
            (.skipped("Not smaller"), .skipped(reason: "Not smaller")),
            (.failed(.insufficientStorage), .failed(code: .storage)),
            (.failed(.verification), .failed(code: .verification)),
            (.needsCheck, .needsCheck)
        ]
        for (live, stored) in cases {
            XCTAssertEqual(BatchQueueReconciliation.persisted(live), stored)
            XCTAssertEqual(BatchQueueReconciliation.live(stored), BatchQueueReconciliation.live(stored))
        }
        // The two coarse states both come back as something the run will not touch on its own.
        XCTAssertEqual(BatchQueueReconciliation.live(.running), .pending)
        XCTAssertEqual(BatchQueueReconciliation.live(.saving), .needsCheck)
        XCTAssertEqual(BatchQueueReconciliation.live(.needsCheck), .needsCheck)
    }

    func testFailureCodesStayUsefulAfterARestart() {
        XCTAssertEqual(BatchFailureCode(.permissionDenied), .permission)
        XCTAssertEqual(BatchFailureCode(.assetUnavailable), .unavailable)
        XCTAssertEqual(BatchFailureCode(.unsupported), .unsupported)
        XCTAssertEqual(BatchFailureCode(.retrieval), .retrieval)
        XCTAssertEqual(BatchFailureCode(.temporaryFiles), .storage)
        XCTAssertEqual(BatchFailureCode(.orientationMismatch), .verification)
        XCTAssertEqual(BatchFailureCode(.save), .save)
        XCTAssertEqual(BatchFailureCode(.export), .export)
        // Every restored code maps back to a real, readable error.
        for code in [BatchFailureCode.permission, .unavailable, .unsupported, .retrieval,
                     .storage, .verification, .export, .save] {
            XCTAssertFalse(code.error.localizedDescription.isEmpty)
        }
    }

    func testTheFileStoreRoundTripsAndClearsByWritingAnEmptyQueue() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("queue-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileBatchQueueStore(directory: directory)

        XCTAssertNil(store.load())
        let record = BatchQueueRecord(settings: .init(resolution: "hd720", frameRate: "fps24"),
                                      items: [item("a", .pending), item("b", .saving)])
        try store.save(record)
        XCTAssertEqual(store.load(), record)

        store.clear()
        XCTAssertNil(store.load())
    }

    func testAQueueFromANewerVersionIsIgnored() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("queue-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileBatchQueueStore(directory: directory)
        var record = BatchQueueRecord(settings: .init(resolution: "hd1080", frameRate: "original"),
                                      items: [item("a", .pending)])
        record.version = BatchQueueRecord.currentVersion + 1
        try store.save(record)
        XCTAssertNil(store.load())
    }

    func testAnEmptyStoredQueueReadsAsNoQueue() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("queue-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileBatchQueueStore(directory: directory)
        try store.save(BatchQueueRecord(settings: .init(resolution: "hd1080", frameRate: "original"),
                                        items: []))
        XCTAssertNil(store.load())
    }

    // MARK: - Durable evidence before Photos mutations

    func testAQueueThatCannotBeWrittenStopsBeforeASaveIsSubmitted() async {
        let fixture = QueueFixture(assets: [queueAsset("a")])
        let batch = fixture.makeBatch()
        await scan(fixture, batch)
        batch.beginSelecting()
        batch.selectAll()
        // Everything up to the save is recorded; the checkpoint that would describe the copy is not.
        fixture.store.failWrites = { record in record.items.contains { $0.state == .saving } }

        batch.start()
        await eventually { batch.phase != .processing }

        // Photos was never asked for a copy, so no copy can exist that the queue does not describe.
        XCTAssertEqual(fixture.photos.saveCount, 0)
        XCTAssertEqual(batch.summary.savedCount, 0)
        XCTAssertEqual(batch.phase, .paused)
        XCTAssertNotNil(batch.queueWarning)
        // The video goes back to waiting: running it again cannot make a second copy.
        XCTAssertEqual(batch.items.first?.state, BatchItemState.pending)

        // A relaunch finds work it can safely run, and nothing ambiguous to look at in Photos.
        let relaunched = fixture.makeBatch()
        XCTAssertEqual(relaunched.phase, .paused)
        XCTAssertTrue(relaunched.hasPendingWork)
        XCTAssertEqual(relaunched.items.first?.state, BatchItemState.pending)
        XCTAssertTrue(relaunched.deletableItemIDs.isEmpty)
        XCTAssertEqual(fixture.photos.saveCount, 0)
    }

    func testACopyPhotosSavedIsNotSavedAgainWhenItsRecordCannotBeWritten() async {
        let fixture = QueueFixture(assets: [queueAsset("a")])
        let batch = fixture.makeBatch()
        await scan(fixture, batch)
        batch.beginSelecting()
        batch.selectAll()
        // The save succeeds; writing down that it did is what fails.
        fixture.store.failWrites = { record in record.items.contains { $0.hasSavedState } }

        batch.start()
        await eventually { batch.phase != .processing }

        XCTAssertEqual(fixture.photos.saveCount, 1)
        XCTAssertEqual(batch.phase, .paused)
        XCTAssertNotNil(batch.queueWarning)
        XCTAssertEqual(batch.summary.savedCount, 1)
        // The record of a save in flight is kept, which is the evidence a later launch needs.
        XCTAssertEqual(fixture.store.stored?.items.first?.state, BatchQueueRecord.State.saving)

        // A relaunch offers a look in Photos rather than a second copy.
        let relaunched = fixture.makeBatch()
        XCTAssertEqual(relaunched.items.first?.state, BatchItemState.needsCheck)
        XCTAssertEqual(relaunched.summary.needsCheckCount, 1)
        XCTAssertFalse(relaunched.hasPendingWork)
        relaunched.resume()
        XCTAssertEqual(fixture.photos.saveCount, 1)
    }

    func testAQueueThatCannotBeWrittenStopsBeforePhotosIsAskedToDelete() async throws {
        let fixture = QueueFixture(assets: [])
        fixture.store.stored = deletionCandidateRecord("a")
        let batch = fixture.makeBatch()
        batch.settings.deletionMode = .afterRun
        // Writing down which original is about to be deleted is what fails.
        fixture.store.failWrites = { record in record.items.contains { $0.deletion == .deleting } }

        batch.deleteOriginalsNow()
        await eventually { !batch.deletionInProgress }

        // Photos was never asked, so nothing can have been deleted behind the app's back.
        XCTAssertTrue(fixture.photos.deleteBatches.isEmpty)
        XCTAssertTrue(fixture.photos.deletedIdentifiers.isEmpty)
        XCTAssertNotNil(batch.queueWarning)
        XCTAssertEqual(batch.deletionReport.handled, 0)
        // Nothing was written down as a delete, and the original is still offered.
        XCTAssertNil(fixture.store.stored?.items.first?.deletion)
        XCTAssertEqual(batch.deletableItemIDs, ["a"])

        // A relaunch offers the same original again instead of a delete it cannot describe.
        let relaunched = fixture.makeBatch()
        XCTAssertNil(relaunched.deletionOutcomes["a"])
        XCTAssertEqual(relaunched.deletableItemIDs, ["a"])
    }

    func testADeletePhotosAcceptedIsNotRepeatedWhenItsOutcomeCannotBeWritten() async throws {
        let fixture = QueueFixture(assets: [])
        fixture.store.stored = deletionCandidateRecord("a")
        let batch = fixture.makeBatch()
        batch.settings.deletionMode = .afterRun
        // The intent reaches disk; Photos answers; writing the answer down is what fails.
        fixture.store.failWrites = { record in record.items.contains { $0.hasSettledDeletion } }

        batch.deleteOriginalsNow()
        await eventually { !batch.deletionInProgress }

        // Photos did delete it, and that cannot be taken back.
        XCTAssertEqual(fixture.photos.deletedIdentifiers, ["a"])
        // So the record of a delete in flight is kept, which is the only honest reading of a crash
        // in this window, and the run says the original is uncertain rather than deleted.
        XCTAssertEqual(fixture.store.stored?.items.first?.deletion, DeletionOutcome.deleting)
        XCTAssertEqual(batch.deletionReport.uncertain, 1)
        XCTAssertTrue(batch.deletableItemIDs.isEmpty)
        XCTAssertNotNil(batch.queueWarning)

        // A relaunch comes back uncertain, and never offers that original again.
        let relaunched = fixture.makeBatch()
        XCTAssertEqual(relaunched.deletionOutcomes["a"], DeletionOutcome.uncertain)
        XCTAssertTrue(relaunched.deletableItemIDs.isEmpty)
        relaunched.deleteOriginalsNow()
        await eventually { !relaunched.deletionInProgress }
        XCTAssertEqual(fixture.photos.deleteBatches.count, 1)
    }

    func testClearingTheQueueIsCheckedRatherThanAssumed() {
        let fixture = QueueFixture(assets: [])
        fixture.store.stored = deletionCandidateRecord("a")
        let batch = fixture.makeBatch()

        batch.reset()

        XCTAssertNil(fixture.store.stored)
        XCTAssertGreaterThan(fixture.store.clearCount, 0)
        XCTAssertNil(batch.queueWarning)
    }

    func testAQueueThatCannotBeClearedSaysSo() {
        let fixture = QueueFixture(assets: [])
        fixture.store.stored = deletionCandidateRecord("a")
        let batch = fixture.makeBatch()
        // Clearing writes an empty queue; this device leaves the old record where it was.
        fixture.store.clearKeepsRecord = true

        batch.reset()

        // The record is still on disk, so the user is told rather than left believing it is gone.
        XCTAssertNotNil(fixture.store.stored)
        XCTAssertNotNil(batch.queueWarning)
    }

    private func item(_ id: String, _ state: BatchQueueRecord.State) -> BatchQueueRecord.Item {
        BatchQueueRecord.Item(identifier: id, creationDate: nil, duration: 120,
                              pixelWidth: 3840, pixelHeight: 2160, bytes: 3_000_000_000, state: state)
    }

    // MARK: - Helpers

    private func scan(_ fixture: QueueFixture, _ batch: BatchViewModel) async {
        fixture.scanner.result = LibraryScanResult(assets: fixture.assets,
                                                   videoCount: fixture.assets.count,
                                                   unsupportedCount: 0,
                                                   unknownSizeCount: 0,
                                                   sizeSource: .reportedByPhotos,
                                                   measuredOnDeviceCount: 0)
        batch.scan()
        await eventually { batch.phase == .scanned }
    }

    private func eventually(_ predicate: () -> Bool, file: StaticString = #filePath,
                            line: UInt = #line) async {
        for _ in 0..<500 {
            if predicate() { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("Timed out waiting for the batch", file: file, line: line)
    }
}

private func queueAsset(_ id: String, bytes: Int64? = 1_000) -> LibraryAsset {
    LibraryAsset(id: id, creationDate: Date(timeIntervalSince1970: 1_700_000_000), duration: 120,
                 pixelWidth: 3840, pixelHeight: 2160, bytes: bytes, unsupportedReason: nil)
}

private extension BatchQueueRecord.Item {
    /// A copy in the state the queue writes while Photos is being asked for it.
    var hasSavedState: Bool {
        if case .saved = state { return true }
        return false
    }

    /// A delete Photos has answered, one way or the other.
    var hasSettledDeletion: Bool {
        guard let deletion else { return false }
        switch deletion {
        case .deleted, .skipped: return true
        case .deleting, .failed, .uncertain: return false
        }
    }
}

/// The receipt a run stores when Photos hands a copy back, as `PhotoLibraryService` would build it.
private func copyReceipt(for id: String) -> DeletionEvidence {
    DeletionEvidence(copy: AssetSnapshot(identifier: "copy-of-\(id)", duration: 120,
                                         pixelWidth: 1920, pixelHeight: 1080,
                                         creationDate: nil, modificationDate: nil),
                     source: AssetSnapshot(identifier: id, duration: 120,
                                           pixelWidth: 3840, pixelHeight: 2160,
                                           creationDate: nil, modificationDate: nil))
}

/// A stored queue holding one copy Photos handed back, which is the state a delete is decided from.
private func deletionCandidateRecord(_ id: String) -> BatchQueueRecord {
    var record = BatchQueueRecord(
        settings: BatchQueueRecord.Settings(resolution: CopyResolution.hd1080.rawValue,
                                            frameRate: FrameRateOption.original.rawValue,
                                            deletion: DeletionMode.afterRun.rawValue),
        items: [BatchQueueRecord.Item(identifier: id, creationDate: nil, duration: 120,
                                      pixelWidth: 3840, pixelHeight: 2160, bytes: 3_000_000_000,
                                      state: .saved(originalBytes: 1_000, copyBytes: 600))])
    record.items[0].readBack = .confirmed
    record.items[0].copyEvidence = copyReceipt(for: id)
    return record
}

/// A queue store that can fail one chosen write, so a test can break exactly one checkpoint.
@MainActor private final class QueueMockStore: BatchQueueStoring {
    var stored: BatchQueueRecord?
    var saveCount = 0
    var clearCount = 0
    /// Fails the write when the record matches. Everything else is written normally.
    var failWrites: ((BatchQueueRecord) -> Bool)?
    /// Leaves the record where it is, the way a clear that cannot write an empty queue behaves.
    var clearKeepsRecord = false

    func load() -> BatchQueueRecord? { stored }

    func save(_ record: BatchQueueRecord) throws {
        if failWrites?(record) == true { throw PipelineError.temporaryFiles }
        saveCount += 1
        stored = record
    }

    func clear() {
        clearCount += 1
        if !clearKeepsRecord { stored = nil }
    }
}

@MainActor private final class QueueMockPhotos: PhotoLibraryServing {
    var retrieveCount = 0
    var saveCount = 0
    /// One entry per Photos transaction, which is one system confirmation.
    var deleteBatches: [[String]] = []
    var deletedIdentifiers: [String] = []
    /// What Photos says when the copy and its original are looked up again before a delete. A
    /// test turns this to a rejecting case to drive an original being kept.
    var revalidation: CopyRevalidation = .matches

    func requestAccess() async throws -> Bool { false }

    func retrieve(identifier: String, progress: @escaping @MainActor (Double) -> Void) async throws -> RetrievedVideo {
        retrieveCount += 1
        progress(0.5)
        return RetrievedVideo(asset: AVURLAsset(url: URL(fileURLWithPath: "/queue-\(identifier).mov")),
                              identity: AssetIdentity(originalFilename: "\(identifier).mov"))
    }

    func cancelRetrieval() {}

    func save(videoAt url: URL, identity: AssetIdentity) async throws -> String? {
        saveCount += 1
        return "created-\(saveCount)"
    }

    func localFileURL(identifier: String) async -> URL? {
        URL(fileURLWithPath: "/photos/\(identifier).mov")
    }

    func playerItem(identifier: String) async throws -> AVPlayerItem {
        AVPlayerItem(url: URL(fileURLWithPath: "/queue-preview.mov"))
    }

    func deleteOriginals(identifiers: [String]) async throws -> [String] {
        deleteBatches.append(identifiers)
        deletedIdentifiers.append(contentsOf: identifiers)
        return identifiers
    }

    // MARK: Deletion revalidation

    func deletionEvidence(originalIdentifier: String, copyIdentifier: String) -> DeletionEvidence? {
        DeletionEvidence(copy: AssetSnapshot(identifier: copyIdentifier, duration: 120,
                                             pixelWidth: 1920, pixelHeight: 1080,
                                             creationDate: nil, modificationDate: nil),
                         source: AssetSnapshot(identifier: originalIdentifier, duration: 120,
                                               pixelWidth: 3840, pixelHeight: 2160,
                                               creationDate: nil, modificationDate: nil))
    }

    func revalidateForDeletion(_ evidence: DeletionEvidence) -> CopyRevalidation { revalidation }

    func deleteOriginals(afterRevalidating evidence: [String: DeletionEvidence]) async throws -> DeletionResult {
        let outcomes = evidence.mapValues { revalidateForDeletion($0) }
        let checked = DeletionPolicy.split(evidence, outcomes: outcomes)
        guard !checked.approved.isEmpty else {
            return DeletionResult(deleted: [], rejected: checked.rejected)
        }
        let deleted = try await deleteOriginals(identifiers: checked.approved)
        return DeletionResult(deleted: deleted, rejected: checked.rejected)
    }
}

@MainActor private final class QueueMockScanner: LibraryScanning {
    var result = LibraryScanResult(assets: [], videoCount: 0, unsupportedCount: 0, unknownSizeCount: 0,
                                   sizeSource: .reportedByPhotos, measuredOnDeviceCount: 0)

    func scan(progress: @escaping @MainActor (LibraryScanProgress) -> Void) async throws -> LibraryScanResult {
        progress(LibraryScanProgress(phase: .listing, scanned: 0, total: result.assets.count))
        return result
    }

    func cancel() {}

    func refreshListing() async throws -> LibraryScanResult { result }

    func reconcile(previous: LibraryScanResult?,
                   selection: Set<String>,
                   running: Set<String>) async throws -> LibraryReconciliation {
        LibraryScanResult.reconcile(previous: previous, fresh: result,
                                    selection: selection, running: running)
    }
}

@MainActor private final class QueueMockTranscoder: VideoTranscoding {
    var written = URL(fileURLWithPath: "/queue-root/output.mov")

    func transcode(_ source: RetrievedVideo, metadata: VideoMetadata, settings: TranscodeSettings,
                   progress: @escaping @MainActor (Double) -> Void) async throws -> URL {
        progress(1)
        return written
    }

    func cancel() {}
}

// The batch model waits for this fake on the main actor; production uses an actor.
private final class QueueMockVerifier: VideoVerifying {
    func inspect(_ url: URL) async throws -> VideoMetadata {
        VideoMetadata(duration: 120, width: 3840, height: 2160, bytes: 1_000,
                      fileType: "MOV", audioTrackCount: 1, isPlayable: true, codec: .hevc,
                      nominalFrameRate: 30)
    }

    func verify(_ url: URL, source: VideoMetadata, expecting codec: VideoCodec?) async throws -> VideoMetadata {
        VideoMetadata(duration: source.duration, width: 1920, height: 1080, bytes: 600,
                      fileType: "MOV", audioTrackCount: 1, isPlayable: true,
                      codec: codec ?? .hevc, nominalFrameRate: 30)
    }

    /// Read-back compares the copy Photos handed back with what the run measured, so this fake
    /// hands back exactly the properties the run expected.
    func verifyImportedCopy(_ url: URL, matching expected: VideoMetadata) async throws -> VideoMetadata {
        expected
    }
}

@MainActor private final class QueueMockFiles: TemporaryFileManaging {
    func ensureWorkspace() throws {}
    func outputURL() throws -> URL { URL(fileURLWithPath: "/queue-root/out.mov") }
    func remove(_ url: URL) throws {}
    func requireCapacity(for bytes: Int64) throws {}
    func cleanup() throws {}
}

@MainActor private final class QueueMockHistory: ShrinkHistoryStoring {
    var identifiers: Set<String> = []
    var createdCopies: Set<String> = []

    func completedIdentifiers() -> Set<String> { identifiers }
    func copyMeasurements() -> [CopyMeasurement] { [] }
    func record(identifier: String, measurement: CopyMeasurement?) { identifiers.insert(identifier) }
    func createdCopyIdentifiers() -> Set<String> { createdCopies }
    func recordCreatedCopy(identifier: String) { createdCopies.insert(identifier) }
}

@MainActor private final class QueueMockScreenAwake: ScreenAwakeControlling {
    func hold(_ hold: Bool) {}
}

/// Everything the batch model needs, plus a second model over the same store: a relaunch.
@MainActor private final class QueueFixture {
    let assets: [LibraryAsset]
    let photos = QueueMockPhotos()
    let scanner = QueueMockScanner()
    let transcoder = QueueMockTranscoder()
    let verifier = QueueMockVerifier()
    let files = QueueMockFiles()
    let history = QueueMockHistory()
    let store = QueueMockStore()
    let screenAwake = QueueMockScreenAwake()
    let settings = ShrinkSettings(defaults: UserDefaults(suiteName: "videoshrink.queue-tests.\(UUID().uuidString)")
                                  ?? .standard)

    init(assets: [LibraryAsset]) { self.assets = assets }

    func makeBatch() -> BatchViewModel {
        BatchViewModel(photos: photos, scanner: scanner, transcoder: transcoder, verifier: verifier,
                       temporary: files, history: history, queueStore: store,
                       screenAwake: screenAwake, settings: settings)
    }
}
