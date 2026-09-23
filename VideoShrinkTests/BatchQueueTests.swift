import XCTest
import AVFoundation
import Photos
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
        // The pairs that survive a round trip, checked in both directions. This used to compare
        // `live(stored)` with itself, which is true whatever the code does: `live` is pure, so the
        // assertion held even if every line of the mapping were wrong, in the file that guards the
        // queue's state machine.
        let lossless: [BatchQueueRecord.State] = [
            .pending,
            .saved(originalBytes: 1_000, copyBytes: 600),
            .skipped(reason: "Not smaller"),
            .failed(code: .storage),
            .failed(code: .verification),
            .needsCheck
        ]
        for (live, stored) in cases where lossless.contains(stored) {
            XCTAssertEqual(BatchQueueReconciliation.persisted(live), stored)
            XCTAssertEqual(BatchQueueReconciliation.live(stored), live,
                           "reading \(stored) back did not give the state it was written from")
        }
        // And the deliberately coarse ones: everything in flight is one stored state, so a restored
        // queue waits on it again rather than resuming the step it had reached.
        for (live, stored) in cases where stored == .running {
            XCTAssertEqual(BatchQueueReconciliation.persisted(live), stored)
            XCTAssertEqual(BatchQueueReconciliation.live(stored), .pending)
        }
        // The one in-flight state that is not answered that way: Photos may have taken the copy a save
        // was handing over, so it comes back as a question instead of as work.
        XCTAssertEqual(BatchQueueReconciliation.persisted(.saving), .saving)
        XCTAssertEqual(BatchQueueReconciliation.live(.saving), .needsCheck)
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
        // An export Apple would not build is a video this app cannot process, and that is what a
        // restored queue can honestly say about it: the finding itself - no session at that
        // quality, or a session that cannot write the container - is not storable.
        XCTAssertEqual(BatchFailureCode(.exportUnavailable(reason: "There's no 4K export for this video on this iPhone.")),
                       .unsupported)
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

    func testAQueueWrittenAfterAPhotosSaveErrorIsStillAQuestion() {
        // The queue a save Photos did not confirm leaves behind: written as `.needsCheck` rather
        // than left as the `.saving` checkpoint, with the sizes the run measured and no receipt,
        // because the failed save never handed an asset identifier back. A launch reads it as the
        // same question a mid-save stop leaves, and nothing it can do runs the video again.
        let fixture = QueueFixture(assets: [])
        fixture.store.stored = midSaveRecord("a", recordedCopy: false, state: .needsCheck)
        fixture.photos.revalidation = .matches

        let relaunched = fixture.makeBatch()

        XCTAssertEqual(relaunched.midSaveFindings["a"],
                       MidSaveFinding.unresolved(question: MidSaveFinding.unknownQuestion))
        XCTAssertEqual(relaunched.items.first?.state, BatchItemState.needsCheck)
        XCTAssertEqual(relaunched.summary.needsCheckCount, 1)
        XCTAssertEqual(relaunched.summary.failedCount, 0)
        XCTAssertFalse(relaunched.hasPendingWork,
                       "a copy that may already exist is never waiting to be run again")
        // Neither route the screens offer for failures and for pending work can pick it up on its
        // own. Only the user's own "I checked Photos" does.
        relaunched.retryFailed()
        relaunched.resume()
        XCTAssertEqual(fixture.photos.saveCount, 0)
        XCTAssertEqual(fixture.photos.retrieveCount, 0)
        XCTAssertEqual(relaunched.items.first?.state, BatchItemState.needsCheck)
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
        // And only the unresolved case is still the user's to answer. The other two are conclusions
        // this app reached: one says the video may wait again, the other says it has a copy nothing
        // may save. Only a question keeps a video out of a bulk selection, so only a question counts
        // as one - and calling a conclusion a question would put "the app cannot tell" on screen
        // about something the app has just established.
        XCTAssertFalse(MidSaveFinding.copyInPhotos.isOpenQuestion)
        XCTAssertFalse(MidSaveFinding.noCopyInPhotos.isOpenQuestion)
        XCTAssertTrue(MidSaveFinding.unresolved(question: MidSaveFinding.unknownQuestion).isOpenQuestion)
        XCTAssertTrue(MidSaveFinding.unresolved(question: MidSaveFinding.limitedAccessQuestion).isOpenQuestion)
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

    // MARK: - The videos the run began without

    func testARestoredRunStillNamesTheVideosThePreflightTookOut() async throws {
        // A run that began without a video, paused, and was left for the app to be closed on: one
        // item still waiting, with the refusal the chosen-video read took out beside it.
        let fixture = QueueFixture(assets: [])
        let hdr = queueAsset("hdr").refusing(preflightHDRReason)
        var stored = BatchQueueRecord(
            settings: BatchQueueRecord.Settings(resolution: CopyResolution.hd1080.rawValue,
                                                frameRate: FrameRateOption.original.rawValue),
            items: [item("ordinary", .pending)])
        let refusal = try XCTUnwrap(BatchQueueRecord.Refusal(asset: hdr))
        stored.refusals = [refusal]
        // Put away the way a phone holds it, through the project's own encoder and decoder, so the
        // restore below reads a record that has been to a file and back rather than this value.
        fixture.store.stored = try JSONDecoder().decode(BatchQueueRecord.self,
                                                        from: JSONEncoder().encode(stored))

        // The relaunch. The queue comes back as the run it was, and the video that was taken out
        // before the first export is named again - which is what the paused and finished screens
        // draw, and what makes the count under them add up.
        let batch = fixture.makeBatch()
        XCTAssertEqual(batch.phase, .paused)
        XCTAssertEqual(batch.items.map(\.id), ["ordinary"])
        XCTAssertEqual(batch.preflightRefusals.map(\.id), ["hdr"])
        XCTAssertEqual(batch.preflightRefusals.first?.unsupportedReason, preflightHDRReason)

        // Finishing the run writes the refusal down again, because the run is not finished with
        // saying what it began without.
        batch.resume()
        await eventually { !batch.isRunning }
        XCTAssertEqual(batch.phase, .finished)
        XCTAssertEqual(batch.preflightRefusals.map(\.id), ["hdr"])
        XCTAssertEqual(fixture.store.stored?.refusals?.map(\.identifier), ["hdr"])

        // And the screen the user reads at the end is the one that has to account for the drop,
        // even when it is a second relaunch that draws it.
        let relaunched = fixture.makeBatch()
        XCTAssertEqual(relaunched.phase, .finished)
        XCTAssertEqual(relaunched.preflightRefusals.map(\.id), ["hdr"])
        XCTAssertEqual(relaunched.preflightRefusals.first?.unsupportedReason, preflightHDRReason)
    }

    func testTheRefusalTravelsAsItsKindAndNotItsSentence() throws {
        let reason = try XCTUnwrap(AssetRules.unsupportedFormatReason(isHDR: false, isProRes: true))
        let proRes = queueAsset("prores").refusing(reason)
        var record = BatchQueueRecord(
            settings: BatchQueueRecord.Settings(resolution: CopyResolution.hd1080.rawValue,
                                                frameRate: FrameRateOption.original.rawValue),
            items: [item("ordinary", .pending)])
        let refusal = try XCTUnwrap(BatchQueueRecord.Refusal(asset: proRes))
        record.refusals = [refusal]

        // What reaches a file: the video's own identity and the stable kind of its refusal.
        let data = try JSONEncoder().encode(record)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("proRes"))
        XCTAssertFalse(text.contains(reason),
                       "The queue must not pin the wording one build happened to use")

        // What comes back: the same video, and the reason read from `AssetRules` rather than from
        // the file. This is the whole trade - one owner of the words, and a code that survives it.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("queue-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileBatchQueueStore(directory: directory)
        try store.save(record)

        let loaded = try XCTUnwrap(store.load())
        XCTAssertEqual(loaded.refusals?.map(\.kind), [.proRes])
        XCTAssertEqual(loaded.refusals?.map(\.asset), [proRes])
        XCTAssertEqual(loaded.refusals?.first?.asset.unsupportedReason, reason)

        // A video refused for something that is not this file's two kinds is not written down at
        // all, rather than being written down in words of this file's own.
        var traits = AssetRules.Traits()
        traits.isSpatial = true
        let spatial = try XCTUnwrap(AssetRules.unsupportedReason(traits))
        XCTAssertNil(BatchQueueRecord.Refusal(asset: queueAsset("spatial").refusing(spatial)))
    }

    func testAQueueFromBeforeTheRefusalsWereKeptStillDecodes() throws {
        // The file shape a shipped build leaves: every field the record writes today, the measured
        // sizes included, and no `refusals` key at all. Encoded through the project's own encoder,
        // which is what makes this a queue a user's phone could actually be holding.
        let legacy = LegacyQueueBeforeRefusals(
            settings: .init(resolution: "hd1080", frameRate: "original", deletion: "afterRun"),
            items: [LegacyQueueBeforeRefusals.Item(identifier: "a", creationDate: nil, duration: 120,
                                                   pixelWidth: 3840, pixelHeight: 2160,
                                                   bytes: 3_000_000_000, state: .pending,
                                                   readBack: nil, deletion: nil, copyEvidence: nil,
                                                   attemptedSave: nil)])
        let data = try JSONEncoder().encode(legacy)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("refusals"),
                       "The fixture must not carry the field this change adds")

        // It still decodes, so a run in progress on a user's phone is not thrown away.
        let record = try JSONDecoder().decode(BatchQueueRecord.self, from: data)
        XCTAssertEqual(record.version, BatchQueueRecord.currentVersion)
        XCTAssertEqual(record.items.map(\.identifier), ["a"])
        XCTAssertEqual(record.items[0].state, .pending)
        // The list such a record never held reads as a run that refused nothing, which is exactly
        // what those screens said before this was kept.
        XCTAssertNil(record.refusals)
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

    // MARK: - What a run may claim about where it came from

    func testANewRunDoesNotClaimToHaveBeenPickedUpFromDisk() async {
        // A stored queue from an earlier launch, which is the one thing the flag stands for.
        let fixture = QueueFixture(assets: [queueAsset("a")])
        fixture.store.stored = BatchQueueRecord(
            settings: BatchQueueRecord.Settings(resolution: CopyResolution.hd1080.rawValue,
                                                frameRate: FrameRateOption.original.rawValue),
            items: [item("a", .saved(originalBytes: 1_000, copyBytes: 600))])
        let batch = fixture.makeBatch()
        XCTAssertTrue(batch.restoredRun)
        XCTAssertEqual(batch.phase, .finished)

        // The user leaves that run behind and starts a new batch from a fresh scan of the library.
        await scan(fixture, batch)
        XCTAssertFalse(batch.restoredRun)
        batch.beginSelecting()
        batch.selectAll()
        batch.start()
        await eventually { batch.phase != .processing }

        // None of this run was read back from disk, so nothing about it may say that it was: the
        // paused screen draws "Picked up where you left off." from this flag alone.
        XCTAssertEqual(batch.summary.savedCount, 1)
        XCTAssertFalse(batch.restoredRun)
    }

    // MARK: - A run that comes back from disk with its access withdrawn

    func testARestoredRunWhoseAccessIsWithdrawnIsToldAccessIsGone() {
        // A run that stopped mid-way with a video still waiting, picked up from disk on the next
        // launch: it rests on the paused screen with work left to do.
        let fixture = QueueFixture(assets: [queueAsset("a"), queueAsset("b")])
        fixture.store.stored = BatchQueueRecord(
            settings: BatchQueueRecord.Settings(resolution: CopyResolution.hd1080.rawValue,
                                                frameRate: FrameRateOption.original.rawValue),
            items: [item("a", .saved(originalBytes: 1_000, copyBytes: 600)),
                    item("b", .pending)])
        let status = QueueAccessBox(.authorized)
        let monitor = LibraryChangeMonitor(authorizationStatus: { status.value })
        let relaunched = fixture.makeBatch(monitor: monitor, authorizationStatus: { status.value })
        XCTAssertTrue(relaunched.restoredRun)
        XCTAssertEqual(relaunched.phase, .paused)
        XCTAssertTrue(relaunched.hasPendingWork)

        // Photos access is withdrawn while the app is away, and the app comes back to the front.
        status.value = .denied
        monitor.enteredForeground()

        // The honest answer is that access is gone, said once, in the sentence that names the route
        // back. It is deliberately not `assetUnavailable`'s sentence about a video sitting outside
        // the allowed set, which is what each waiting video would have failed with had the run gone
        // on to try them one by one.
        XCTAssertEqual(relaunched.phase, .failed)
        XCTAssertEqual(relaunched.accessBlock, .refused)
        XCTAssertEqual(relaunched.message, PipelineError.refusedAccess)
        XCTAssertNotEqual(relaunched.message, PipelineError.assetUnavailable.localizedDescription)
        // Nothing about the run was rewritten or torn down on the way: its record keeps the video
        // it saved and the one still waiting, and no Photos work was attempted for either.
        XCTAssertEqual(relaunched.items.map(\.state),
                       [.saved(Savings(originalBytes: 1_000, compressedBytes: 600)), .pending])
        XCTAssertEqual(fixture.photos.retrieveCount, 0)
    }

    func testAnAccessReportDoesNotTearDownARunThatIsStillWorking() async {
        // The exception this round must not weaken: an access report never tears down work that is
        // actually in flight, however it is answered for the flow's resting places.
        let fixture = QueueFixture(assets: [queueAsset("a"), queueAsset("b")])
        let status = QueueAccessBox(.authorized)
        let monitor = LibraryChangeMonitor(authorizationStatus: { status.value })
        let batch = fixture.makeBatch(monitor: monitor, authorizationStatus: { status.value })
        await scan(fixture, batch)
        batch.beginSelecting()
        batch.selectAll()
        fixture.transcoder.hold = true
        batch.start()
        await eventually { fixture.transcoder.gate != nil }
        XCTAssertEqual(batch.phase, .processing)

        // Photos access is withdrawn while the run is working on a video.
        status.value = .denied
        monitor.enteredForeground()

        // The run keeps the screen and its own record of what happened to each video.
        XCTAssertEqual(batch.phase, .processing)
        XCTAssertNil(batch.accessBlock)
        XCTAssertNil(batch.message)

        // And it finishes the work it was given rather than being stopped by the report.
        fixture.transcoder.hold = false
        fixture.transcoder.release()
        await eventually { batch.phase == .finished }
        XCTAssertEqual(batch.summary.savedCount, 2)
    }

    // MARK: - A run on an iPhone that has never been asked for Photos

    /// A queue carried over by a device migration brings the run and, on an iPhone whose Photos
    /// grant was never made, not the access. Continue used to reach the waiting videos with nobody
    /// ever asked, and every one of them then failed with `assetUnavailable`'s sentence about a
    /// video sitting outside the set access allows - a sentence about a refusal that never
    /// happened, offering no way forward.
    ///
    /// The honest fix is to ask, at the one moment the answer can still be used and a screen can
    /// still act on it. The app's own scan asks at its first read, and a run is a read like any
    /// other, so this is the same rule at the other entrance: the prompt appears, and the run goes
    /// on with whatever the user answers.
    func testARestoredRunOnAniPhoneThatNeverAskedForPhotosAsksRatherThanFailingEveryVideo() async {
        let fixture = QueueFixture(assets: [queueAsset("a")])
        fixture.store.stored = BatchQueueRecord(
            settings: BatchQueueRecord.Settings(resolution: CopyResolution.hd1080.rawValue,
                                                frameRate: FrameRateOption.original.rawValue),
            items: [item("a", .pending)])
        // Nobody has answered a prompt on this iPhone: the queue is here, the grant is not.
        let status = QueueAccessBox(.notDetermined)
        let monitor = LibraryChangeMonitor(authorizationStatus: { status.value })
        let batch = fixture.makeBatch(monitor: monitor, authorizationStatus: { status.value })
        XCTAssertTrue(batch.restoredRun)
        XCTAssertEqual(batch.phase, .paused)
        XCTAssertEqual(fixture.photos.accessRequests, 0)

        // The user taps Continue. The run asks before it reads anything, and the answer it gets is
        // what it goes on with.
        batch.resume()
        await eventually { batch.phase == .finished }

        XCTAssertEqual(fixture.photos.accessRequests, 1,
                       "a run that has never been granted access asks for it, once")
        XCTAssertEqual(batch.summary.savedCount, 1)
        XCTAssertNil(batch.message)
        XCTAssertNil(batch.accessBlock)
    }

    /// The other answer to that prompt. A refusal is not a failed video and not a torn-down run:
    /// nothing was read, written or asked of Photos, so the waiting videos stay waiting, the record
    /// on disk still describes them, and the flow rests on the sentence that names the way back.
    func testARefusedPromptLeavesTheRestoredRunIntactRatherThanFailingEveryVideo() async {
        let fixture = QueueFixture(assets: [queueAsset("a"), queueAsset("b")])
        fixture.store.stored = BatchQueueRecord(
            settings: BatchQueueRecord.Settings(resolution: CopyResolution.hd1080.rawValue,
                                                frameRate: FrameRateOption.original.rawValue),
            items: [item("a", .pending), item("b", .pending)])
        fixture.photos.accessError = .permissionDenied
        let status = QueueAccessBox(.notDetermined)
        let monitor = LibraryChangeMonitor(authorizationStatus: { status.value })
        let batch = fixture.makeBatch(monitor: monitor, authorizationStatus: { status.value })
        XCTAssertEqual(batch.phase, .paused)

        batch.resume()
        await eventually { batch.phase == .failed }

        XCTAssertEqual(fixture.photos.accessRequests, 1)
        XCTAssertEqual(batch.accessBlock, .refused)
        XCTAssertEqual(batch.message, PipelineError.refusedAccess)
        XCTAssertNotEqual(batch.message, PipelineError.assetUnavailable.localizedDescription,
                          "nobody refused this app access to one particular video")
        // Nothing was tried, so nothing failed: the run is still the run it came back as, and the
        // queue on disk still describes the videos that are waiting.
        XCTAssertEqual(fixture.photos.retrieveCount, 0)
        XCTAssertEqual(batch.items.map(\.state), [.pending, .pending])
        XCTAssertFalse(batch.isRunning)
        XCTAssertTrue(batch.restoredRun)
        XCTAssertNotNil(fixture.store.stored, "the queue on disk still describes this run")
        XCTAssertEqual(fixture.store.stored?.items.map(\.state) ?? [], [.pending, .pending])
    }

    /// A restriction is not a refusal, and this entrance reads the same distinction the rest of
    /// the flow does: a device held back by Screen Time or a management profile gets the truth
    /// and no route to a Photos switch that is not on this app's Settings page.
    func testARestoredRunOnARestrictedIPhoneSaysSoRatherThanSendingItToSettings() async {
        let fixture = QueueFixture(assets: [queueAsset("a")])
        fixture.store.stored = BatchQueueRecord(
            settings: BatchQueueRecord.Settings(resolution: CopyResolution.hd1080.rawValue,
                                                frameRate: FrameRateOption.original.rawValue),
            items: [item("a", .pending)])
        fixture.photos.accessError = .permissionDenied
        let monitor = LibraryChangeMonitor(authorizationStatus: { .restricted })
        let batch = fixture.makeBatch(monitor: monitor, authorizationStatus: { .restricted })

        batch.resume()
        await eventually { batch.phase == .failed }

        XCTAssertEqual(batch.accessBlock, .restricted)
        XCTAssertEqual(batch.message, PipelineError.restrictedAccess)
        XCTAssertFalse((batch.message ?? "").lowercased().contains("settings"),
                       "a restricted device has no Photos switch to send anyone to")
        XCTAssertEqual(fixture.photos.retrieveCount, 0)
    }

    private func item(_ id: String, _ state: BatchQueueRecord.State) -> BatchQueueRecord.Item {
        BatchQueueRecord.Item(identifier: id, creationDate: nil, duration: 120,
                              pixelWidth: 3840, pixelHeight: 2160, bytes: 3_000_000_000, state: state)
    }

    // MARK: - A question a run leaves behind

    /// The two questions the app asks, in the words it asks them in.
    ///
    /// Every other case about these compares a constant with itself - `midSaveFindings` holds the same
    /// value the case asserts - so either sentence could be reversed, and "Look in Photos" could become
    /// its opposite, with all 407 cases still green. These are the only sentences that tell a user what
    /// to do about a copy the app cannot account for, so the instruction is asserted as content.
    func testTheQuestionsTheAppAsksCarryTheInstructionTheyExistFor() {
        XCTAssertTrue(MidSaveFinding.unknownQuestion.contains("Look in Photos"))
        XCTAssertTrue(MidSaveFinding.unknownQuestion.contains("if there are two copies, that copy was made"))
        XCTAssertTrue(MidSaveFinding.limitedAccessQuestion.contains("access covers only some of your library"))
        XCTAssertTrue(MidSaveFinding.limitedAccessQuestion.contains("Look in Photos"))
        // The two are different questions: one is about the copy, the other about what the app is
        // allowed to see, and a user who is told the wrong one looks for the wrong thing.
        XCTAssertNotEqual(MidSaveFinding.unknownQuestion, MidSaveFinding.limitedAccessQuestion)
    }

    /// The file keeps a question with no run beside it, and reads it back as a question rather than
    /// as no queue - which is the whole reason the field exists.
    func testTheFileStoreKeepsAQueueOfQuestionsRatherThanReadingItAsNoQueue() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("queue-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileBatchQueueStore(directory: directory)

        let record = BatchQueueRecord(
            settings: .init(resolution: "hd1080", frameRate: "original"),
            items: [],
            questions: [.init(identifier: "a", kind: .unknown),
                        .init(identifier: "b", kind: .limitedAccess)])
        XCTAssertFalse(record.isEmpty)
        try store.save(record)

        XCTAssertEqual(store.load(), record)
        XCTAssertFalse(store.hasUnreadableRecord())

        // And the app's own "no run" is still no run, not a queue of nothing.
        store.clear()
        XCTAssertNil(store.load())
        XCTAssertFalse(store.hasUnreadableRecord())
        XCTAssertTrue(BatchQueueRecord(settings: .init(resolution: "hd1080", frameRate: "original"),
                                       items: []).isEmpty)
    }

    func testAQueueFileThisBuildCannotReadIsToldApartFromNoQueueAtAll() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("queue-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileBatchQueueStore(directory: directory)

        // Nothing there is no queue.
        XCTAssertNil(store.load())
        XCTAssertFalse(store.hasUnreadableRecord())

        // A queue from a build this one does not read, with something in it, is the record being set
        // aside: there is nothing to restore, and no way to say what it held.
        var newer = BatchQueueRecord(settings: .init(resolution: "hd1080", frameRate: "original"),
                                     items: [item("a", .pending)])
        newer.version = BatchQueueRecord.currentVersion + 1
        try store.save(newer)
        XCTAssertNil(store.load())
        XCTAssertTrue(store.hasUnreadableRecord())
    }

    /// A file that is present and is not a queue at all - a write that never finished - is the same
    /// answer, and the launch is where the user is told.
    func testALaunchWithAQueueItCannotReadSaysSoRatherThanLookingLikeAFreshInstall() async {
        let fixture = QueueFixture(assets: [queueAsset("a")])
        fixture.store.unreadable = true

        let batch = fixture.makeBatch()

        // Not `queueWarning`: that one is headed as a write that failed, and a record another build
        // wrote perfectly is not that statement.
        XCTAssertNil(batch.queueWarning)
        XCTAssertNotNil(batch.queueReadWarning)
        XCTAssertTrue(batch.items.isEmpty)
        XCTAssertEqual(batch.phase, .start)

        // Nothing is claimed about what the record held, and the one thing the user can act on is
        // named: what to look at before running the same videos again.
        XCTAssertTrue(batch.queueReadWarning?.contains("Photos") == true)

        // A run writes a record of its own, and that is the moment the old one stops being anything
        // the user has to act on.
        await scan(fixture, batch)
        batch.beginSelecting()
        batch.selectAll()
        batch.start()
        await eventually { batch.phase != .processing }
        XCTAssertEqual(batch.summary.savedCount, 1)
        XCTAssertNil(batch.queueReadWarning)
    }

    /// A launch that finds a question reads it as one: the video is named on the screen where videos
    /// are chosen, and no automatic selection picks it.
    func testALaunchWithASavedQuestionLeavesThatVideoOutOfSelectAll() async {
        let fixture = QueueFixture(assets: [queueAsset("a"), queueAsset("b")])
        // The quality the record names is the *ended run's* choice, and the user may have changed
        // theirs since: giving the flow a different one is what makes the assertion below about the
        // record rather than about the app's own default happening to be the same resolution.
        fixture.settings.resolution = .uhd4k
        fixture.store.stored = BatchQueueRecord(
            settings: .init(resolution: CopyResolution.hd720.rawValue, frameRate: "original"),
            items: [],
            questions: [.init(identifier: "a", kind: .limitedAccess)])

        let relaunched = fixture.makeBatch()

        // A question describes no run, so nothing is offered to continue and no run's screen is
        // drawn. What it does is travel to the library the launch scans.
        XCTAssertTrue(relaunched.items.isEmpty)
        XCTAssertEqual(relaunched.phase, .start)
        XCTAssertEqual(relaunched.midSaveFindings["a"],
                       MidSaveFinding.unresolved(question: MidSaveFinding.limitedAccessQuestion))
        XCTAssertEqual(relaunched.unaccountedIdentifiers, ["a"])

        await scan(fixture, relaunched)
        relaunched.beginSelecting()
        relaunched.selectAll()
        // Nothing about a record that describes no run is imposed on this flow, not even the quality
        // the run it came from was using.
        XCTAssertEqual(relaunched.settings.resolution, .uhd4k)
        XCTAssertEqual(relaunched.selection, ["b"])
        XCTAssertEqual(relaunched.unaccountedAssets.map(\.id), ["a"])
        XCTAssertEqual(relaunched.midSaveQuestion(for: "a"), MidSaveFinding.limitedAccessQuestion)
    }

    /// The route RR2 named: a run started after the question, and a relaunch after *that*, which is
    /// the moment the question used to be lost and the video became one Select all would copy again.
    func testAVideoAnEarlierRunCouldNotAccountForSurvivesTheNextRunAndItsRelaunch() async {
        let fixture = QueueFixture(assets: [queueAsset("a"), queueAsset("b")])
        fixture.store.stored = midSaveRecord("a")
        fixture.photos.revalidation = .unavailable
        let batch = fixture.makeBatch()
        XCTAssertEqual(batch.items.first?.state, BatchItemState.needsCheck)

        // The user leaves that run behind, scans again and runs another video. The question about
        // "a" is not this run's business, and the record this run writes is the only place left to
        // keep it.
        await scan(fixture, batch)
        batch.beginSelecting()
        batch.selectAll()
        XCTAssertEqual(batch.selection, ["b"])
        batch.start()
        await eventually { batch.phase != .processing }
        XCTAssertEqual(batch.summary.savedCount, 1)
        XCTAssertEqual(fixture.store.stored?.questions?.map(\.identifier), ["a"])
        XCTAssertEqual(fixture.store.stored?.items.map(\.identifier), ["b"])

        // And a launch after that still leaves "a" out of every automatic selection.
        let relaunched = fixture.makeBatch()
        XCTAssertEqual(relaunched.midSaveFindings["a"],
                       MidSaveFinding.unresolved(question: MidSaveFinding.unknownQuestion))
        await scan(fixture, relaunched)
        relaunched.beginSelecting()
        relaunched.selectAll()
        // Nothing may be ticked: "b" was saved by the run above - this fixture's history is shared,
        // so "b" is one of this iPhone's shrunk videos now - and "a" is the question. Asserted on the
        // sets rather than on the selection alone, so the two reasons cannot hide behind each other.
        XCTAssertEqual(relaunched.completedIdentifiers.contains("b"), true)
        XCTAssertEqual(relaunched.unaccountedIdentifiers, ["a"])
        XCTAssertFalse(relaunched.selectableAssets.contains { $0.id == "a" },
                       "a video whose copy may already exist is never picked by an automatic selection")
        XCTAssertTrue(relaunched.selection.isEmpty)
    }

    /// Ending a run with a question keeps that question on disk, and ending one with nothing
    /// outstanding still clears the record.
    func testEndingARunKeepsItsQuestionButClearsEverythingElse() async {
        let fixture = QueueFixture(assets: [queueAsset("a")])
        fixture.store.stored = midSaveRecord("a")
        fixture.photos.revalidation = .unavailable
        let batch = fixture.makeBatch()
        XCTAssertEqual(batch.items.first?.state, BatchItemState.needsCheck)

        batch.reset()

        XCTAssertTrue(batch.items.isEmpty)
        XCTAssertEqual(batch.phase, .start)
        XCTAssertEqual(fixture.store.stored?.items.isEmpty, true)
        XCTAssertEqual(fixture.store.stored?.questions?.map(\.identifier), ["a"])
        XCTAssertEqual(fixture.store.stored?.questions?.first?.kind, .unknown)
        XCTAssertNil(fixture.store.stored?.pause)

        // A run with nothing outstanding clears the record instead: the user asked for it to be over.
        let other = QueueFixture(assets: [queueAsset("a")])
        let saved = other.makeBatch()
        await scan(other, saved)
        saved.beginSelecting()
        saved.selectAll()
        saved.start()
        await eventually { saved.phase != .processing }
        XCTAssertEqual(saved.summary.savedCount, 1)
        saved.reset()
        XCTAssertNil(other.store.stored)
    }

    /// A video the user ticks by hand and runs is a question answered - the same answer the
    /// "I checked Photos" tap gives - so the record stops carrying it.
    func testAVideoTickedByHandAndRunIsNoLongerAQuestion() async {
        let fixture = QueueFixture(assets: [queueAsset("a")])
        fixture.store.stored = midSaveRecord("a")
        fixture.photos.revalidation = .unavailable
        let batch = fixture.makeBatch()
        XCTAssertEqual(batch.unaccountedIdentifiers, ["a"])

        await scan(fixture, batch)
        batch.beginSelecting()
        batch.toggle("a")
        XCTAssertEqual(batch.selection, ["a"])
        batch.start()
        await eventually { batch.phase != .processing }

        XCTAssertNil(batch.midSaveFindings["a"])
        XCTAssertTrue(batch.unaccountedIdentifiers.isEmpty)
        XCTAssertEqual(batch.summary.savedCount, 1)
        XCTAssertEqual(fixture.photos.saveCount, 1)
        XCTAssertEqual(fixture.store.stored?.questions?.isEmpty, true)
    }

    // MARK: - A copy the one-video flow never heard back about

    /// Only the one-video flow can leave one of these: it has no queue of its own, so the copy it was
    /// handing to Photos when the app stopped was written down in the history store instead. The
    /// batch flow has to carry it as the same question it carries any other, or an automatic
    /// selection would tick both that copy's original and the copy itself.
    func testACopyTheOtherFlowNeverHeardAboutKeepsItsVideoOutOfSelectAll() async {
        let fixture = QueueFixture(assets: [queueAsset("a"), queueAsset("b")])
        fixture.history.unconfirmedSaves = ["a"]

        let batch = fixture.makeBatch()

        XCTAssertEqual(batch.midSaveFindings["a"],
                       MidSaveFinding.unresolved(question: MidSaveFinding.unknownQuestion))

        await scan(fixture, batch)
        batch.beginSelecting()
        batch.selectAll()

        XCTAssertEqual(batch.selection, ["b"])
        XCTAssertEqual(batch.unaccountedAssets.map(\.id), ["a"])
        XCTAssertEqual(batch.midSaveQuestion(for: "a"), MidSaveFinding.unknownQuestion)
    }

    func testTickingThatVideoByHandAnswersTheOtherFlowsQuestion() async {
        let fixture = QueueFixture(assets: [queueAsset("a")])
        fixture.history.unconfirmedSaves = ["a"]
        let batch = fixture.makeBatch()

        await scan(fixture, batch)
        batch.beginSelecting()
        batch.toggle("a")
        batch.start()
        await eventually { batch.phase != .processing }

        XCTAssertTrue(batch.unaccountedIdentifiers.isEmpty)
        // And the store is told, or the next launch would ask again about a video the user has just
        // run: the entry is read at every launch, not once.
        XCTAssertTrue(fixture.history.unconfirmedSaves.isEmpty)
    }

    func testAFreshLookThatSettlesTheQuestionDropsTheOtherFlowsEntry() {
        let fixture = QueueFixture(assets: [])
        fixture.store.stored = midSaveRecord("a")
        fixture.history.unconfirmedSaves = ["a"]
        fixture.photos.revalidation = .matches

        let relaunched = fixture.makeBatch()

        // The queue named this video precisely and a fresh look found its copy, so the app has an
        // answer. The other flow's entry was the same question, so it goes with it.
        XCTAssertEqual(relaunched.midSaveFindings["a"], MidSaveFinding.copyInPhotos)
        XCTAssertTrue(fixture.history.unconfirmedSaves.isEmpty)
    }

    func testTheCheckedPhotosTapAlsoDropsTheOtherFlowsEntry() {
        let fixture = QueueFixture(assets: [])
        fixture.store.stored = midSaveRecord("a")
        fixture.history.unconfirmedSaves = ["a"]
        fixture.photos.revalidation = .unavailable

        let relaunched = fixture.makeBatch()
        XCTAssertEqual(relaunched.midSaveFindings["a"],
                       MidSaveFinding.unresolved(question: MidSaveFinding.unknownQuestion))

        relaunched.requeueUncertain()

        XCTAssertEqual(relaunched.items.first?.state, BatchItemState.pending)
        XCTAssertTrue(fixture.history.unconfirmedSaves.isEmpty)
    }

    /// Both stores can have something to say about one video. The queue's question is the more
    /// specific one, so adopting the other flow's entry first must not write over it.
    func testAQuestionTheQueueNamesMorePreciselyWinsOverTheOtherFlowsEntry() {
        let fixture = QueueFixture(assets: [])
        fixture.store.stored = BatchQueueRecord(
            settings: .init(resolution: "hd1080", frameRate: "original"),
            items: [],
            questions: [.init(identifier: "a", kind: .limitedAccess)])
        fixture.history.unconfirmedSaves = ["a"]

        let relaunched = fixture.makeBatch()

        XCTAssertEqual(relaunched.midSaveFindings["a"],
                       MidSaveFinding.unresolved(question: MidSaveFinding.limitedAccessQuestion))
    }

    /// A launch is not the only way the two flows hand work to each other.
    ///
    /// The batch flow can be at rest and the one-video flow used and come back to it without the app
    /// ever restarting, so the store is read again wherever the batch refreshes what it knows from it -
    /// which is the scan. Without that, a save the other flow made while this model was alive never
    /// reaches the selection screen that has to leave the video out of Select all.
    func testASaveTheOtherFlowMakesWhileTheBatchIsOpenReachesTheNextScan() async {
        let fixture = QueueFixture(assets: [queueAsset("a"), queueAsset("b")])
        let batch = fixture.makeBatch()
        XCTAssertTrue(batch.midSaveFindings.isEmpty, "nothing has been saved yet")

        // The other flow, in the same session: it asks Photos for a copy and never learns the answer.
        fixture.history.unconfirmedSaves = ["a"]
        await scan(fixture, batch)
        batch.beginSelecting()
        batch.selectAll()

        XCTAssertEqual(batch.midSaveFindings["a"],
                       MidSaveFinding.unresolved(question: MidSaveFinding.unknownQuestion))
        XCTAssertEqual(batch.selection, ["b"])
        XCTAssertEqual(batch.unaccountedAssets.map(\.id), ["a"])
    }

    /// And a re-read must not downgrade a question the queue can name more precisely than the store.
    func testAScanDoesNotWriteOverAQuestionTheQueueNamesMorePrecisely() async {
        let fixture = QueueFixture(assets: [queueAsset("a")])
        fixture.store.stored = BatchQueueRecord(
            settings: .init(resolution: "hd1080", frameRate: "original"),
            items: [],
            questions: [.init(identifier: "a", kind: .limitedAccess)])
        let batch = fixture.makeBatch()
        XCTAssertEqual(batch.midSaveFindings["a"],
                       MidSaveFinding.unresolved(question: MidSaveFinding.limitedAccessQuestion))

        // The store has an entry for the same video, which says only "some question" - the generic
        // sentence. The scan reads it and must leave the queue's sentence standing.
        fixture.history.unconfirmedSaves = ["a"]
        await scan(fixture, batch)

        XCTAssertEqual(batch.midSaveFindings["a"],
                       MidSaveFinding.unresolved(question: MidSaveFinding.limitedAccessQuestion))
    }

    // MARK: - Why a restored run stopped

    func testARestoredRunRemembersWhyItStopped() async {
        let fixture = QueueFixture(assets: [queueAsset("a")])
        var record = BatchQueueRecord(
            settings: .init(resolution: "hd1080", frameRate: "original"),
            items: [item("a", .pending)])
        record.pause = .tooWarm
        fixture.store.stored = record

        let relaunched = fixture.makeBatch()

        XCTAssertEqual(relaunched.phase, .paused)
        XCTAssertEqual(relaunched.pauseReason, .tooWarm)
        // The sentence is `BatchPauseReason`'s own, so the restored screen says what the stopped one
        // said rather than a second wording of the same fact.
        XCTAssertEqual(relaunched.pauseReason?.explanation, BatchPauseReason.tooWarm.explanation)

        // Continuing clears it, exactly as continuing a run stopped in this session does.
        relaunched.resume()
        await eventually { relaunched.phase != .processing }
        XCTAssertNil(relaunched.pauseReason)
        XCTAssertNil(fixture.store.stored?.pause)
    }

    func testEveryReasonARunCanStopForHasAKindTheFileCanKeep() {
        for reason in BatchPauseReason.allCases {
            let kind = BatchQueueRecord.PauseKind(reason)
            XCTAssertEqual(kind.reason, reason)
            // And one that is not stopped deliberately still says what stopped it.
            if reason != .asked {
                XCTAssertNotNil(kind.reason.explanation)
            }
        }
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
                           readBack: CopyReadBack? = nil,
                           state: BatchQueueRecord.State = .saving) -> BatchQueueRecord {
    var item = BatchQueueRecord.Item(identifier: id, creationDate: nil, duration: 120,
                                     pixelWidth: 3840, pixelHeight: 2160, bytes: 3_000_000_000,
                                     state: state)
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

/// The queue file shape from before the run's refusals were kept: every field the record writes
/// today, the measured sizes included, and no `refusals` key. Encoding this produces a file exactly
/// like one a shipped build left on a phone, which is what makes the test beside it a statement
/// about a user's queue rather than about this file.
private struct LegacyQueueBeforeRefusals: Encodable {
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
        var attemptedSave: AttemptedSave?
    }

    var version = 1
    var settings: Settings
    var items: [Item]
}

/// The sentence `AssetRules` writes for an HDR video, read from the rule rather than written down a
/// second time. A test that needs to be sure of the sentence it holds unwraps it for itself.
private var preflightHDRReason: String {
    AssetRules.unsupportedFormatReason(isHDR: true, isProRes: false) ?? ""
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
    /// Reports a saved queue this build cannot read, the way a store with a file it cannot decode
    /// does. Set by a test that wants the launch's own answer to that rather than a real bad file.
    var unreadable = false

    func load() -> BatchQueueRecord? { stored }

    func hasUnreadableRecord() -> Bool { unreadable }

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
    /// How many times the flow has asked for Photos access, so a test can tell an app that asks
    /// from one that assumes.
    var accessRequests = 0
    /// What the prompt answers. Nil is a grant - what the real service reports when access is
    /// already there - and an error is what it throws when access is refused.
    var accessError: PipelineError?
    /// One entry per Photos transaction, which is one system confirmation.
    var deleteBatches: [[String]] = []
    var deletedIdentifiers: [String] = []
    /// What Photos says when the copy and its original are looked up again before a delete. A
    /// test turns this to a rejecting case to drive an original being kept.
    var revalidation: CopyRevalidation = .matches

    func requestAccess() async throws -> Bool {
        accessRequests += 1
        if let accessError { throw accessError }
        return false
    }

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
    /// What AVFoundation answers when the run asks it for an export it will not build.
    var error: Error?
    /// Holds a transcode, so a test can look at a run while one video is really in flight.
    var hold = false
    var gate: CheckedContinuation<Void, Never>?

    func transcode(_ source: RetrievedVideo, metadata: VideoMetadata, settings: TranscodeSettings,
                   progress: @escaping @MainActor (Double) -> Void) async throws -> URL {
        progress(1)
        if let error { throw error }
        if hold { await withCheckedContinuation { gate = $0 } }
        return written
    }

    func release() { gate?.resume(); gate = nil }
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
    /// The one-video flow's record of a copy it asked Photos for and never heard back about.
    var unconfirmedSaves: Set<String> = []

    func completedIdentifiers() -> Set<String> { identifiers }
    func copyMeasurements() -> [CopyMeasurement] { [] }
    func record(identifier: String, measurement: CopyMeasurement?) { identifiers.insert(identifier) }
    func createdCopyIdentifiers() -> Set<String> { createdCopies }
    func recordCreatedCopy(identifier: String) { createdCopies.insert(identifier) }
    func unconfirmedSaveIdentifiers() -> Set<String> { unconfirmedSaves }
    func noteUnconfirmedSave(identifier: String) { unconfirmedSaves.insert(identifier) }
    func clearUnconfirmedSave(identifier: String) { unconfirmedSaves.remove(identifier) }
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

    /// The model. It watches the real Photos library unless a test hands it a monitor it can drive,
    /// and reads the running system's authorization status unless the test names one too - which is
    /// the only way a test can put the flow somewhere access really has been withdrawn.
    func makeBatch(monitor: LibraryChangeMonitor? = nil,
                   authorizationStatus: (() -> PHAuthorizationStatus)? = nil) -> BatchViewModel {
        let status: () -> PHAuthorizationStatus
        if let authorizationStatus {
            status = authorizationStatus
        } else {
            status = { PHPhotoLibrary.authorizationStatus(for: .readWrite) }
        }
        return BatchViewModel(photos: photos, scanner: scanner, transcoder: transcoder,
                              verifier: verifier, temporary: files, history: history,
                              queueStore: store, screenAwake: screenAwake,
                              libraryChanges: monitor,
                              settings: settings,
                              authorizationStatus: status)
    }
}

/// Photos access a test can move, so the report the monitor makes can be driven without a library.
private final class QueueAccessBox {
    var value: PHAuthorizationStatus
    init(_ value: PHAuthorizationStatus) { self.value = value }
}
