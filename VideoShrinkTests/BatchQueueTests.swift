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
        // The record of a save in flight is kept, which is the evidence a later launch needs, and
        // it names the copy Photos created along with the sizes this run measured for it.
        XCTAssertEqual(fixture.store.stored?.items.first?.state, BatchQueueRecord.State.saving)
        XCTAssertNotNil(fixture.store.stored?.items.first?.copyEvidence?.verifiedCopyIdentifier)
        XCTAssertEqual(fixture.store.stored?.items.first?.attemptedSave?.copyBytes, 600)

        // A relaunch reads that record, finds that copy in Photos and settles the item as the save
        // it turned out to be, so the video is never handed to the encoder again.
        let relaunched = fixture.makeBatch()
        XCTAssertEqual(relaunched.midSaveFindings["a"], MidSaveFinding.copyInPhotos)
        XCTAssertEqual(relaunched.items.first?.state,
                       BatchItemState.saved(Savings(originalBytes: 1_000, compressedBytes: 600)))
        XCTAssertEqual(relaunched.summary.needsCheckCount, 0)
        XCTAssertFalse(relaunched.hasPendingWork)
        relaunched.resume()
        XCTAssertEqual(fixture.photos.saveCount, 1)
    }

    // MARK: - Exactly-once save reconciliation

    func testAMidSaveRecordWhoseCopyIsStillInPhotosSettlesAsTheSaveItWas() async {
        let fixture = QueueFixture(assets: [])
        fixture.store.stored = midSaveRecord("a")
        fixture.photos.revalidation = .matches

        let relaunched = fixture.makeBatch()

        // Photos still has the copy the stopped run created, so the question is answered: this
        // video was saved, and it is never handed to the encoder again.
        XCTAssertEqual(relaunched.midSaveFindings["a"], MidSaveFinding.copyInPhotos)
        XCTAssertEqual(relaunched.items.first?.state,
                       BatchItemState.saved(Savings(originalBytes: 1_000, compressedBytes: 600)))
        XCTAssertEqual(relaunched.summary.savedCount, 1)
        XCTAssertEqual(relaunched.summary.needsCheckCount, 0)
        XCTAssertFalse(relaunched.hasPendingWork)
        XCTAssertEqual(fixture.photos.saveCount, 0)
        // The copy was found, not read back. Nothing may claim the check that justifies a delete,
        // so the original stays even though the fresh look at both assets agreed.
        XCTAssertNil(relaunched.readBackOutcomes["a"])
        relaunched.settings.deletionMode = .afterRun
        XCTAssertTrue(relaunched.deletableItemIDs.isEmpty)
        relaunched.deleteOriginalsNow()
        await eventually { !relaunched.deletionInProgress }
        XCTAssertTrue(fixture.photos.deleteBatches.isEmpty)
        XCTAssertTrue(fixture.photos.deletedIdentifiers.isEmpty)
        // And no route through the model runs it again, because a second copy is the one outcome
        // this whole area exists to prevent.
        relaunched.resume()
        relaunched.requeueUncertain()
        relaunched.retryFailed()
        XCTAssertEqual(fixture.photos.saveCount, 0)
        XCTAssertEqual(relaunched.items.first?.state,
                       BatchItemState.saved(Savings(originalBytes: 1_000, compressedBytes: 600)))
    }

    func testASettledMidSaveItemIsNotOfferedByASelectAllAgain() async {
        let fixture = QueueFixture(assets: [queueAsset("a")])
        fixture.store.stored = midSaveRecord("a")
        fixture.photos.revalidation = .matches

        let relaunched = fixture.makeBatch()
        XCTAssertEqual(relaunched.items.first?.state,
                       BatchItemState.saved(Savings(originalBytes: 1_000, compressedBytes: 600)))

        // The run that made that copy may never have reached the point where it writes either of
        // these down, so the restore does. It matters: an original nothing has recorded is offered
        // by Select all, and running it again would make a second copy.
        XCTAssertTrue(relaunched.completedIdentifiers.contains("a"))
        XCTAssertTrue(relaunched.createdCopyIdentifiers.contains("copy-of-a"))

        await scan(fixture, relaunched)
        relaunched.beginSelecting()
        relaunched.selectAll()
        XCTAssertTrue(relaunched.selectableAssets.isEmpty)
        XCTAssertTrue(relaunched.selection.isEmpty)
    }

    func testAMidSaveRecordPhotosHasNoCopyOfWaitsAgain() {
        let fixture = QueueFixture(assets: [])
        fixture.store.stored = midSaveRecord("a")
        fixture.photos.revalidation = .copyMissing

        let relaunched = fixture.makeBatch()

        // Photos has no copy of this video, so nothing was saved and the video may wait again.
        XCTAssertEqual(relaunched.midSaveFindings["a"], MidSaveFinding.noCopyInPhotos)
        XCTAssertEqual(relaunched.items.first?.state, BatchItemState.pending)
        XCTAssertTrue(relaunched.hasPendingWork)
        XCTAssertEqual(relaunched.summary.pendingCount, 1)
        XCTAssertEqual(relaunched.summary.needsCheckCount, 0)
        XCTAssertEqual(relaunched.phase, .paused)
        // Nothing was saved by the launch itself, and there is nothing to delete: no copy exists.
        XCTAssertEqual(fixture.photos.saveCount, 0)
        XCTAssertTrue(relaunched.deletableItemIDs.isEmpty)
        // The answer reaches disk, so the next launch is not asked the same question again.
        XCTAssertEqual(fixture.store.stored?.items.first?.state, BatchQueueRecord.State.pending)
    }

    func testAMidSaveRecordThatCannotBeLookedUpStaysAQuestion() {
        let fixture = QueueFixture(assets: [])
        fixture.store.stored = midSaveRecord("a")
        fixture.photos.revalidation = .unavailable

        let relaunched = fixture.makeBatch()

        // Photos could not answer, so the question stays the user's, with nothing invented.
        XCTAssertEqual(relaunched.midSaveFindings["a"],
                       MidSaveFinding.unresolved(question: MidSaveFinding.unknownQuestion))
        XCTAssertEqual(relaunched.items.first?.state, BatchItemState.needsCheck)
        XCTAssertEqual(relaunched.summary.needsCheckCount, 1)
        XCTAssertNil(relaunched.readBackOutcomes["a"])
        XCTAssertTrue(relaunched.deletableItemIDs.isEmpty)
        XCTAssertEqual(fixture.photos.saveCount, 0)

        // The user says they looked in Photos, and here their word is the only evidence there is,
        // so the video goes back to waiting. Still nothing runs until they ask for it.
        relaunched.requeueUncertain()
        XCTAssertEqual(relaunched.items.first?.state, BatchItemState.pending)
        XCTAssertEqual(fixture.photos.saveCount, 0)
        XCTAssertEqual(fixture.store.stored?.items.first?.state, BatchQueueRecord.State.pending)
    }

    func testAMidSaveRecordWithNoCopyIdentifierIsStillAQuestion() {
        let fixture = QueueFixture(assets: [])
        // The stopped run never got as far as writing the copy down, so this launch has no
        // identity to look up and no amount of looking can answer it.
        fixture.store.stored = midSaveRecord("a", recordedCopy: false)
        fixture.photos.revalidation = .matches

        let relaunched = fixture.makeBatch()

        XCTAssertEqual(relaunched.midSaveFindings["a"],
                       MidSaveFinding.unresolved(question: MidSaveFinding.unknownQuestion))
        XCTAssertEqual(relaunched.items.first?.state, BatchItemState.needsCheck)
        // What Photos would have said cannot stand in for a receipt that names the copy.
        XCTAssertTrue(relaunched.deletableItemIDs.isEmpty)
        XCTAssertEqual(fixture.photos.saveCount, 0)
    }

    func testAMidSaveRecordThatClaimsAReadBackStillKeepsTheOriginal() async {
        let fixture = QueueFixture(assets: [])
        // A record as an earlier launch could have left it: a mid-save item whose stored read-back
        // describes an earlier attempt of the same video, beside a receipt for this copy.
        fixture.store.stored = midSaveRecord("a", readBack: .confirmed)
        fixture.photos.revalidation = .matches

        let relaunched = fixture.makeBatch()
        relaunched.settings.deletionMode = .afterRun

        // The read-back belonged to a different copy, so it is dropped rather than inherited.
        XCTAssertNil(relaunched.readBackOutcomes["a"])
        XCTAssertEqual(relaunched.items.first?.state,
                       BatchItemState.saved(Savings(originalBytes: 1_000, compressedBytes: 600)))
        XCTAssertTrue(relaunched.deletableItemIDs.isEmpty)

        relaunched.deleteOriginalsNow()
        await eventually { !relaunched.deletionInProgress }
        XCTAssertTrue(fixture.photos.deleteBatches.isEmpty)
        XCTAssertTrue(fixture.photos.deletedIdentifiers.isEmpty)
    }

    func testTheMidSaveRuleNeverInventsAnAnswer() {
        let receipt = copyReceipt(for: "a")
        // Anything showing the recorded copy is in the library means a copy exists.
        for look in [CopyRevalidation.matches, .copyChanged, .sourceMissing, .sourceChanged] {
            XCTAssertEqual(BatchQueueReconciliation.midSaveFinding(receipt: receipt, lookup: look,
                                                                  wholeLibraryVisible: true),
                           MidSaveFinding.copyInPhotos)
        }
        XCTAssertTrue(MidSaveFinding.copyInPhotos.forbidsAnotherSave)
        // A missing copy is only an answer with the whole library in view: under limited access an
        // asset can be invisible rather than gone, and that reading could make a second copy.
        XCTAssertEqual(BatchQueueReconciliation.midSaveFinding(receipt: receipt, lookup: .copyMissing,
                                                              wholeLibraryVisible: true),
                       MidSaveFinding.noCopyInPhotos)
        XCTAssertEqual(BatchQueueReconciliation.midSaveFinding(receipt: receipt, lookup: .copyMissing,
                                                              wholeLibraryVisible: false),
                       MidSaveFinding.unresolved(question: MidSaveFinding.limitedAccessQuestion))
        XCTAssertFalse(MidSaveFinding.noCopyInPhotos.forbidsAnotherSave)
        // Nothing else answers anything.
        for look in [CopyRevalidation.accessDenied, .unavailable] {
            XCTAssertEqual(BatchQueueReconciliation.midSaveFinding(receipt: receipt, lookup: look,
                                                                  wholeLibraryVisible: true),
                           MidSaveFinding.unresolved(question: MidSaveFinding.unknownQuestion))
        }
        XCTAssertEqual(BatchQueueReconciliation.midSaveFinding(receipt: receipt, lookup: nil,
                                                              wholeLibraryVisible: true),
                       MidSaveFinding.unresolved(question: MidSaveFinding.unknownQuestion))
        XCTAssertEqual(BatchQueueReconciliation.midSaveFinding(receipt: nil, lookup: .matches,
                                                              wholeLibraryVisible: true),
                       MidSaveFinding.unresolved(question: MidSaveFinding.unknownQuestion))
        // A receipt from an older algorithm names nothing that can be looked up, and the service
        // reports it exactly as it reports a missing copy, so it can never be read as "no copy".
        let older = DeletionEvidence(version: DeletionEvidence.currentVersion - 1,
                                     copy: receipt.copy, source: receipt.source)
        XCTAssertEqual(BatchQueueReconciliation.midSaveFinding(receipt: older, lookup: .copyMissing,
                                                              wholeLibraryVisible: true),
                       MidSaveFinding.unresolved(question: MidSaveFinding.unknownQuestion))
    }

    func testAQueueFromBeforeTheMeasuredSizesWereWrittenStillDecodes() throws {
        // The file shape a shipped build leaves for an item it was mid-save on: the `.saving`
        // state, no measured sizes and no copy identity, through the project's own encoder.
        let legacy = LegacyMidSaveQueue(
            settings: .init(resolution: "hd1080", frameRate: "original", deletion: "afterRun"),
            items: [LegacyMidSaveQueue.Item(identifier: "a", creationDate: nil, duration: 120,
                                            pixelWidth: 3840, pixelHeight: 2160, bytes: 1_000,
                                            state: .saving, readBack: nil, deletion: nil,
                                            copyEvidence: nil)])
        let data = try JSONEncoder().encode(legacy)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("attemptedSave"),
                       "The fixture must not carry the field this change adds")

        // It still decodes, so an in-progress run on a user's phone is not thrown away.
        let record = try JSONDecoder().decode(BatchQueueRecord.self, from: data)
        XCTAssertEqual(record.version, BatchQueueRecord.currentVersion)
        XCTAssertEqual(record.items.count, 1)
        XCTAssertEqual(record.items[0].state, .saving)
        XCTAssertNil(record.items[0].attemptedSave)
        // With nothing measured and no copy named there is no answer to be had, so the restore
        // keeps the question rather than settling on a save it cannot describe.
        XCTAssertEqual(BatchQueueReconciliation.midSaveFinding(receipt: record.items[0].copyEvidence,
                                                              lookup: nil,
                                                              wholeLibraryVisible: true),
                       MidSaveFinding.unresolved(question: MidSaveFinding.unknownQuestion))
    }

    func testTheMeasuredSizesRoundTripWithTheQueue() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("queue-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileBatchQueueStore(directory: directory)

        let record = midSaveRecord("a")
        try store.save(record)

        let loaded = try XCTUnwrap(store.load())
        XCTAssertEqual(loaded, record)
        XCTAssertEqual(loaded.items[0].attemptedSave,
                       AttemptedSave(Savings(originalBytes: 1_000, compressedBytes: 600)))
        XCTAssertEqual(loaded.items[0].attemptedSave?.savings,
                       Savings(originalBytes: 1_000, compressedBytes: 600))
    }

    // MARK: - Durable evidence before Photos mutations, continued

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

/// A stored queue as a run leaves it when the app stops in the middle of a save: the `.saving`
/// state, the sizes the run had measured for that copy, and the copy's identity once Photos has
/// handed it over. Each of the three is optional in the record, so a test can leave out exactly
/// the evidence it wants to be missing.
private func midSaveRecord(_ id: String,
                           savings: Savings? = Savings(originalBytes: 1_000, compressedBytes: 600),
                           recordedCopy: Bool = true,
                           readBack: CopyReadBack? = nil) -> BatchQueueRecord {
    var item = BatchQueueRecord.Item(identifier: id, creationDate: nil, duration: 120,
                                     pixelWidth: 3840, pixelHeight: 2160, bytes: 3_000_000_000,
                                     state: .saving)
    item.readBack = readBack
    item.copyEvidence = recordedCopy ? copyReceipt(for: id) : nil
    item.attemptedSave = savings.map { AttemptedSave($0) }
    return BatchQueueRecord(
        settings: BatchQueueRecord.Settings(resolution: CopyResolution.hd1080.rawValue,
                                            frameRate: FrameRateOption.original.rawValue,
                                            deletion: DeletionMode.afterRun.rawValue),
        items: [item])
}

/// The queue file shape from before the run's measured sizes were written: the same fields, the
/// project's own encoder, and no `attemptedSave` key. Encoding this produces a file exactly like
/// one a shipped build left on a phone that stopped mid-save.
private struct LegacyMidSaveQueue: Encodable {
    struct Settings: Encodable {
        var resolution: String
        var frameRate: String
        var deletion: String?
    }

    struct Item: Encodable {
        var identifier: String
        var creationDate: Date?
        var duration: Double
        var pixelWidth: Int
        var pixelHeight: Int
        var bytes: Int64?
        var state: BatchQueueRecord.State
        var readBack: CopyReadBack?
        var deletion: DeletionOutcome?
        var copyEvidence: DeletionEvidence?
    }

    var version = 1
    var settings: Settings
    var items: [Item]
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
