import XCTest
import AVFoundation
import Photos
import UIKit
@testable import VideoShrink

/// The service layer, plus the parts of a run that a fake can drive.
///
/// Earlier passes covered the models, the formatting and the failure vocabulary. What is left is
/// the code that owns the file system and the run's own state machine: what the temporary
/// workspace does with the disk reserve and with a URL it does not own, whether the screen awake
/// hold is ever left on, what the two on-device stores do to what they are handed, and what a run
/// does when it is paused, finished early, retried or reset.
///
/// Everything here is behaviour a user would notice if it silently changed. Where a check can
/// only be made against the machine it runs on, the test says so rather than pretending.
@MainActor final class ServiceCoverageTests: XCTestCase {

    // MARK: - The temporary workspace

    func testAnOutputURLIsANewFileInsideOneWorkspaceTheAppOwns() throws {
        let manager = TemporaryFileManager()
        defer { try? manager.cleanup() }

        let first = try manager.outputURL()
        let second = try manager.outputURL()

        XCTAssertEqual(first.pathExtension, "mov")
        XCTAssertNotEqual(first.lastPathComponent, second.lastPathComponent)
        XCTAssertEqual(first.deletingLastPathComponent(), second.deletingLastPathComponent())
        // The workspace sits inside the process temporary directory, which is the only place this
        // manager is allowed to write.
        XCTAssertTrue(first.path.hasPrefix(FileManager.default.temporaryDirectory.path))
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.deletingLastPathComponent().path,
                                                     isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
    }

    func testAskingForTheWorkspaceAgainKeepsTheOneThatIsThere() throws {
        let manager = TemporaryFileManager()
        defer { try? manager.cleanup() }

        try manager.ensureWorkspace()
        let first = try manager.outputURL()
        // The second call is what the next video, the next run and the next launch each make, so
        // it has to be a no-op rather than a failure or a move.
        try manager.ensureWorkspace()
        let second = try manager.outputURL()

        XCTAssertEqual(first.deletingLastPathComponent(), second.deletingLastPathComponent())
    }

    func testCleanupRemovesTheWorkspaceAndIsSafeToRunAgain() throws {
        let manager = TemporaryFileManager()
        let url = try manager.outputURL()
        try Data("half a copy".utf8).write(to: url)
        let workspace = url.deletingLastPathComponent()

        try manager.cleanup()

        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.path))
        // Nothing left to remove is not a failure: this runs on launch and at the end of every run.
        try manager.cleanup()
    }

    func testRemovingIsConfinedToTheWorkspaceItOwns() throws {
        let manager = TemporaryFileManager()
        defer { try? manager.cleanup() }

        // A file that is not this app's to delete: the shape a source URL would have.
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("service-coverage-\(UUID().uuidString).mov")
        try Data("an original".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }

        do {
            try manager.remove(outside)
            XCTFail("Removing a file the app does not own must be refused")
        } catch {
            XCTAssertEqual(error as? PipelineError, .temporaryFiles)
        }
        // Refused, not done: the file is still exactly where it was.
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))

        // Inside the workspace but not a direct child of it, so not a URL the encoder ever wrote.
        let inside = try manager.outputURL()
        let nested = inside.deletingLastPathComponent()
            .appendingPathComponent("nested", isDirectory: true)
            .appendingPathComponent("copy.mov")
        do {
            try manager.remove(nested)
            XCTFail("Only a direct child of the workspace may be removed")
        } catch {
            XCTAssertEqual(error as? PipelineError, .temporaryFiles)
        }
    }

    func testAnExistingOutputIsRemovedAndOneThatWasNeverWrittenIsNotAnError() throws {
        let manager = TemporaryFileManager()
        defer { try? manager.cleanup() }

        let kept = try manager.outputURL()
        let removed = try manager.outputURL()
        try Data("kept".utf8).write(to: kept)
        try Data("removed".utf8).write(to: removed)

        try manager.remove(removed)

        XCTAssertFalse(FileManager.default.fileExists(atPath: removed.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: kept.path))
        // A video the export never got as far as writing still has a URL the run cleans up, so
        // removing a name that is not there cannot be an error.
        try manager.remove(removed)
    }

    /// The two flows own different directories, so one flow's sweep cannot delete the other's work.
    ///
    /// This is the guard on a defect that a shared workspace produced for a whole round: the user
    /// finishes a one-video export, leaves it on "Save copy to Photos", runs a batch, comes back,
    /// and the copy the screen is still offering to save has been deleted by the batch's own
    /// cleanup. The copy is unverified against a real Photos library here, but which directory a
    /// sweep reaches is a fact about this class and is settled exactly.
    func testASweepOnlyRemovesTheWorkspaceItsOwnManagerOwns() throws {
        let oneVideo = TemporaryFileManager(workspace: .oneVideo)
        let batch = TemporaryFileManager(workspace: .batch)
        defer {
            try? oneVideo.cleanup()
            try? batch.cleanup()
        }

        let keptCopy = try oneVideo.outputURL()
        try Data("a copy waiting to be saved".utf8).write(to: keptCopy)
        let batchScratch = try batch.outputURL()
        try Data("a run's working file".utf8).write(to: batchScratch)

        // The two directories are genuinely different places, not a shared one reached by two names.
        XCTAssertNotEqual(keptCopy.deletingLastPathComponent(), batchScratch.deletingLastPathComponent())

        // What the batch flow does on launch and again at the end of every run.
        try batch.cleanup()

        XCTAssertTrue(FileManager.default.fileExists(atPath: keptCopy.path),
                      "a batch sweep must not remove the one-video flow's directory")
        XCTAssertFalse(FileManager.default.fileExists(atPath: batchScratch.path))

        // And the reverse, so neither flow's cleanup can be the other's, whichever runs first.
        let secondBatchScratch = try batch.outputURL()
        try Data("another run's working file".utf8).write(to: secondBatchScratch)
        try oneVideo.cleanup()
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondBatchScratch.path),
                      "the one-video flow's cleanup must not remove the batch's directory")
    }

    func testAnExportThatFailsMidWriteRemovesItsOwnPartialOutput() async {
        // The encoder writes into the destination itself, so an attempt that fails can leave bytes
        // behind - a stop can interrupt one mid-write. Nothing outside the transcoder is ever
        // handed that URL on a failure path, so it has to take the partial copy with it instead of
        // leaving it in the shared workspace until the run ends.
        let files = ServiceMockFiles()
        let service = VideoTranscodingService(temporary: files)
        // A source with no readable media fails the export whichever way the OS rejects it. The
        // shape of that rejection is not what this test is about, so it is left to the OS, exactly
        // as the verification tests leave theirs; what must hold either way is that the file the
        // attempt started is gone.
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = RetrievedVideo(asset: AVURLAsset(url: missing), identity: .unknown)
        let metadata = VideoMetadata(duration: 120, width: 3840, height: 2160, bytes: 1_000,
                                     fileType: "MOV", audioTrackCount: 1, isPlayable: true,
                                     codec: .hevc, nominalFrameRate: 30)

        do {
            _ = try await service.transcode(source, metadata: metadata, settings: .standard) { _ in }
            XCTFail("An export of a file with no media must never report a written copy")
        } catch {
            XCTAssertFalse(error is CancellationError)
        }
        XCTAssertEqual(files.removed, ["1.mov"],
                       "a failed export has to remove the destination it had already started")
    }

    func testTheDiskReserveRefusesAWriteBeforeTheEncoderDiscoversIt() throws {
        let manager = TemporaryFileManager()
        defer { try? manager.cleanup() }

        // A request no volume could fail on is not refused: the guard is a comparison against the
        // free space, not a blanket refusal.
        try manager.requireCapacity(for: 0)
        try manager.requireCapacity(for: 1)

        // No volume has this much free space, and this check is the only warning the run gets
        // before iOS reports the failure in the middle of an export.
        do {
            try manager.requireCapacity(for: Int64.max)
            XCTFail("A reserve larger than the free space must be refused before the write starts")
        } catch {
            XCTAssertEqual(error as? PipelineError, .insufficientStorage)
        }
    }

    func testTheFreeSpaceAStepNeedsIsTheOneFileItIsAboutToWritePlusTheReserve() {
        // The question every check in the pipeline is really asking. A size that is not known yet
        // asks only for the reserve, because a video must never be refused over a figure the app
        // made up.
        XCTAssertEqual(DiskHeadroom.neededToWrite(nil), DiskHeadroom.reserve)
        XCTAssertEqual(DiskHeadroom.neededToWrite(0), DiskHeadroom.reserve)
        XCTAssertEqual(DiskHeadroom.neededToWrite(-1), DiskHeadroom.reserve)
        XCTAssertEqual(DiskHeadroom.neededToWrite(1_000_000_000),
                       1_000_000_000 + DiskHeadroom.reserve)
        // A number this large cannot be a real requirement: it means "refuse", not a wrapped total.
        XCTAssertEqual(DiskHeadroom.neededToWrite(Int64.max), Int64.max)
    }

    func testAStepNeverDemandsRoomForTheFileItIsCopyingFrom() {
        // The finding this arithmetic exists to answer. An export writes one more file, and the
        // original it is copying from is already on the disk and already reflected in the free
        // space the check reads. Sizing the step as two files - which is what the call sites did -
        // demands room the step will never need, and that is how a phone with space to finish an
        // export gets told there is not enough space to start one.
        let original: Int64 = 3_000_000_000
        // Enough for the one file an export writes plus the reserve, and nowhere near enough for
        // two copies of the original. The reserve is most of the difference, so a figure only just
        // above the original does not separate the two rules.
        let phoneWithRoomToFinish: Int64 = 3_300_000_000

        XCTAssertEqual(DiskHeadroom.neededToWrite(original), DiskHeadroom.bytes(original, copies: 1))
        XCTAssertLessThan(DiskHeadroom.neededToWrite(original), DiskHeadroom.bytes(original, copies: 2))
        // One more copy against the same phone: the first fits, the second refuses it.
        XCTAssertLessThanOrEqual(DiskHeadroom.neededToWrite(original), phoneWithRoomToFinish)
        XCTAssertGreaterThan(DiskHeadroom.bytes(original, copies: 2), phoneWithRoomToFinish)
    }

    func testAFreeSpaceReadingRefusesOnlyWhenItIsSmallerThanTheStepNeeds() throws {
        let tight = TemporaryFileManager(capacity: { _ -> Int64? in 1_000 })
        // Exactly at the line is enough: the comparison refuses only a step that needs more.
        try tight.requireCapacity(for: 1_000)
        do {
            try tight.requireCapacity(for: 1_001)
            XCTFail("A step needing more than the volume reports must be refused")
        } catch {
            XCTAssertEqual(error as? PipelineError, .insufficientStorage)
        }

        let roomy = TemporaryFileManager(capacity: { _ -> Int64? in 5_000 })
        try roomy.requireCapacity(for: 1_001)
    }

    func testAFreeSpaceReadingThisDeviceWillNotGiveUpIsNotEvidenceOfAFullDisk() throws {
        // Nil means unknown, and unknown is not zero: a step is never turned away with a message
        // about storage that the reading cannot back up. The write itself is still the real
        // report, so nothing here can hide a genuinely full disk.
        let silent = TemporaryFileManager(capacity: { _ -> Int64? in nil })
        try silent.requireCapacity(for: Int64.max)

        // The same rule for a reading that cannot be taken at all: on this machine the read is a
        // `resourceValues` call on the temporary directory, which can fail outright.
        let unreadable = TemporaryFileManager(capacity: { _ -> Int64? in throw PipelineError.temporaryFiles })
        try unreadable.requireCapacity(for: Int64.max)
    }

    // MARK: - Keeping the screen awake

    /// The controller exists for one pair of facts: the flag is on exactly while a run holds it,
    /// and a release always puts it back. A controller that only ever set the flag would leave a
    /// user's display on after the run ended.
    func testTheScreenIsHeldWhileWorkRunsAndReleasedAfterwards() {
        let controller = ScreenAwakeController()
        defer { controller.hold(false) }
        let application = UIApplication.shared

        XCTAssertFalse(controller.isHolding)
        // Releasing something that was never held must not arm the timer.
        controller.hold(false)
        XCTAssertFalse(controller.isHolding)
        XCTAssertFalse(application.isIdleTimerDisabled)

        controller.hold(true)
        XCTAssertTrue(controller.isHolding)
        XCTAssertTrue(application.isIdleTimerDisabled)
        // A second hold for the same run says nothing new and must not double-arm anything.
        controller.hold(true)
        XCTAssertTrue(controller.isHolding)

        controller.hold(false)
        XCTAssertFalse(controller.isHolding)
        XCTAssertFalse(application.isIdleTimerDisabled)
    }

    // MARK: - On-device history

    func testWhatTheHistoryStoreRemembersOutlivesTheStoreThatWroteIt() throws {
        let name = "videoshrink.services.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }

        let writer = UserDefaultsShrinkHistoryStore(defaults: defaults)
        writer.record(identifier: "original",
                      measurement: CopyMeasurement(bitsPerSecond: 5_000_000, longEdge: 1920))
        writer.recordCreatedCopy(identifier: "made-copy")

        // Every launch builds a new store over the same defaults, which is the only way the last
        // launch's work is known at all.
        let reader = UserDefaultsShrinkHistoryStore(defaults: defaults)
        XCTAssertEqual(reader.completedIdentifiers(), ["original"])
        XCTAssertEqual(reader.createdCopyIdentifiers(), ["made-copy"])
        XCTAssertEqual(reader.copyMeasurements().count, 1)
        XCTAssertEqual(reader.copyMeasurements().first?.bitsPerSecond, 5_000_000)
        XCTAssertEqual(reader.copyMeasurements().first?.longEdge, 1_920)
    }

    /// The one-video flow's record of a save it never heard back about is kept where the other flow
    /// reads it, and dropped when the app learns the answer either way.
    func testTheHistoryStoreKeepsACopyTheOneVideoFlowNeverHeardBackAbout() throws {
        let name = "videoshrink.services.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }

        let writer = UserDefaultsShrinkHistoryStore(defaults: defaults)
        XCTAssertTrue(writer.unconfirmedSaveIdentifiers().isEmpty)

        // Written before Photos is asked, and read back by the launch that follows a kill.
        writer.noteUnconfirmedSave(identifier: "original")
        let reader = UserDefaultsShrinkHistoryStore(defaults: defaults)
        XCTAssertEqual(reader.unconfirmedSaveIdentifiers(), ["original"])

        // A second one piles up in one session too - a save that throws leaves the flow able to choose
        // another video - and both are held.
        writer.noteUnconfirmedSave(identifier: "another")
        XCTAssertEqual(writer.unconfirmedSaveIdentifiers(), ["original", "another"])

        // An answer clears one of them and leaves the other, and a repeat is not a second entry.
        writer.noteUnconfirmedSave(identifier: "original")
        XCTAssertEqual(writer.unconfirmedSaveIdentifiers().count, 2)
        writer.clearUnconfirmedSave(identifier: "original")
        XCTAssertEqual(writer.unconfirmedSaveIdentifiers(), ["another"])
        writer.clearUnconfirmedSave(identifier: "another")
        XCTAssertTrue(UserDefaultsShrinkHistoryStore(defaults: defaults).unconfirmedSaveIdentifiers().isEmpty)
    }

    func testMeasurementsDropTheOldestSoTheNewestStillRetuneTheBand() throws {
        let name = "videoshrink.services.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = UserDefaultsShrinkHistoryStore(defaults: defaults)
        let limit = UserDefaultsShrinkHistoryStore.measurementLimit
        let written = limit + 5

        for index in 0..<written {
            store.record(identifier: "id-\(index)",
                         measurement: CopyMeasurement(bitsPerSecond: 5_000_000,
                                                      longEdge: 1_000 + index))
        }

        let kept = store.copyMeasurements()
        XCTAssertEqual(kept.count, limit)
        // The newest samples are the ones kept, in the order they were measured, because later
        // estimates read this device's most recent results rather than its first ones.
        XCTAssertEqual(kept.first?.longEdge, 1_000 + 5)
        XCTAssertEqual(kept.last?.longEdge, 1_000 + written - 1)
        XCTAssertFalse(kept.contains { $0.longEdge == 1_000 })
    }

    // MARK: - The stored queue on disk

    func testAQueueOnDiskIsReplacedWholeAndANewStoreReadsIt() throws {
        let directory = try makeQueueDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileBatchQueueStore(directory: directory)
        XCTAssertNil(store.load())

        let record = BatchQueueRecord(
            settings: BatchQueueRecord.Settings(resolution: CopyResolution.hd1080.rawValue,
                                                frameRate: FrameRateOption.original.rawValue),
            items: [serviceQueuedItem("a"), serviceQueuedItem("b")])
        try store.save(record)

        // A relaunch builds a new store over the same directory, which is how a stopped run is
        // picked up at all.
        let relaunched = FileBatchQueueStore(directory: directory)
        XCTAssertEqual(relaunched.load(), record)

        // The next write replaces the record rather than merging with it: an item a later run has
        // dropped must not come back from an older write.
        let replaced = BatchQueueRecord(
            settings: BatchQueueRecord.Settings(resolution: CopyResolution.hd720.rawValue,
                                                frameRate: FrameRateOption.fps24.rawValue),
            items: [serviceQueuedItem("b")])
        try store.save(replaced)
        XCTAssertEqual(relaunched.load(), replaced)
        XCTAssertEqual(relaunched.load()?.items.map(\.identifier), ["b"])
    }

    func testAQueueThatCannotBeWrittenThrowsAndLeavesNothingHalfWritten() throws {
        let directory = try makeQueueDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // Something is already sitting where the queue's own directory has to go, so the store
        // cannot set it up. The run gates every Photos mutation on this call throwing, so
        // reporting success here would let it change Photos with nothing written down.
        let blocked = directory.appendingPathComponent("VideoShrink")
        try Data("not a directory".utf8).write(to: blocked)

        let store = FileBatchQueueStore(directory: directory)
        let record = BatchQueueRecord(
            settings: BatchQueueRecord.Settings(resolution: CopyResolution.hd1080.rawValue,
                                                frameRate: FrameRateOption.original.rawValue),
            items: [serviceQueuedItem("a")])
        do {
            try store.save(record)
            XCTFail("A queue that cannot reach disk must throw rather than report success")
        } catch {
            // Whatever the file system refused with, what matters is that the store reported it
            // rather than returning as though the record were safe.
            XCTAssertFalse(error is CancellationError)
        }
        // Nothing is there to be read back as a run.
        XCTAssertNil(store.load())
    }

    func testTheStoredQueueIsKeptOutOfBackupsAndBehindFileProtection() throws {
        let directory = try makeQueueDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileBatchQueueStore(directory: directory)
        try store.save(BatchQueueRecord(
            settings: BatchQueueRecord.Settings(resolution: CopyResolution.hd1080.rawValue,
                                                frameRate: FrameRateOption.original.rawValue),
            items: [serviceQueuedItem("a")]))

        let file = directory.appendingPathComponent("VideoShrink", isDirectory: true)
            .appendingPathComponent("queue.json")
        // A queue names the user's videos, so it must not be carried off in an iCloud backup.
        let values = try file.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true,
                       "The stored queue names the user's videos, so it must stay out of the backup")

        // The protection class is set at write time. Some runtimes do not report data protection
        // attributes back, so this half is skipped rather than asserted where it cannot be read.
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        let recorded = protectionClass(in: attributes)
        try XCTSkipIf(recorded == nil, "This runtime does not report data protection attributes")
        XCTAssertEqual(recorded, FileProtectionType.completeUntilFirstUserAuthentication.rawValue)
    }

    // MARK: - Starting, pausing and finishing a run

    func testStartingWithNothingSelectedBeginsNothing() async {
        let fixture = ServiceFixture(assets: [serviceAsset("a", bytes: 3_000_000_000)])
        await scan(fixture)
        fixture.batch.beginSelecting()
        XCTAssertFalse(fixture.batch.canStart)

        fixture.batch.start()

        // The screen stays where it was and no video is touched.
        XCTAssertEqual(fixture.batch.phase, .selecting)
        XCTAssertTrue(fixture.batch.items.isEmpty)
        XCTAssertEqual(fixture.photos.retrieveCount, 0)
        XCTAssertEqual(fixture.queue.saveCount, 0)
    }

    func testASecondScanRequestedDuringARunChangesNothing() async {
        let fixture = ServiceFixture(assets: [serviceAsset("a", bytes: 3_000_000_000)])
        fixture.transcoder.hold = true
        await scan(fixture)
        fixture.batch.beginSelecting()
        fixture.batch.selectAll()
        fixture.batch.start()
        await eventually { fixture.transcoder.gate != nil }

        let scansSoFar = fixture.scanner.scanCount
        fixture.batch.scan()

        // A scan replaces the library and empties the run, so one started by a stray tap in the
        // middle of a run must be ignored rather than destroy the work in flight.
        XCTAssertEqual(fixture.batch.phase, .processing)
        XCTAssertEqual(fixture.batch.items.count, 1)
        XCTAssertEqual(fixture.scanner.scanCount, scansSoFar)

        fixture.transcoder.release()
        await eventually { fixture.batch.phase == .finished }
        XCTAssertEqual(fixture.batch.summary.savedCount, 1)
    }

    func testTheRunningVideoIsTheOneTheScreenNames() async {
        let fixture = ServiceFixture(assets: [serviceAsset("a", bytes: 3_000_000_000),
                                             serviceAsset("b", bytes: 3_000_000_000)])
        fixture.transcoder.hold = true
        await scan(fixture)
        fixture.batch.beginSelecting()
        fixture.batch.selectAll()
        fixture.batch.start()
        await eventually { fixture.transcoder.gate != nil }

        XCTAssertEqual(fixture.batch.currentID, "a")
        XCTAssertEqual(fixture.batch.currentAsset?.id, "a")
        XCTAssertEqual(fixture.batch.currentNumber, 1)
        XCTAssertEqual(fixture.batch.currentStage, .transcoding)
        XCTAssertFalse(fixture.batch.currentIsSaving)
        XCTAssertEqual(fixture.batch.remainingCount, 2)
        XCTAssertEqual(fixture.batch.finishedCount, 0)
        XCTAssertTrue(fixture.batch.hasPendingWork)

        fixture.transcoder.hold = false
        fixture.transcoder.release()
        await eventually { fixture.batch.phase == .finished }

        XCTAssertNil(fixture.batch.currentID)
        XCTAssertEqual(fixture.batch.finishedCount, 2)
        XCTAssertEqual(fixture.batch.summary.savedCount, 2)
    }

    func testTheFlowCannotBeLeftWhileWorkRemains() async {
        let fixture = ServiceFixture(assets: [serviceAsset("a", bytes: 3_000_000_000)])
        fixture.transcoder.hold = true
        await scan(fixture)
        fixture.batch.beginSelecting()
        fixture.batch.selectAll()
        fixture.batch.start()
        await eventually { fixture.transcoder.gate != nil }

        XCTAssertTrue(fixture.batch.isRunning)
        XCTAssertFalse(fixture.batch.canLeaveFlow)
        XCTAssertFalse(fixture.batch.canStart)

        fixture.transcoder.release()
        await eventually { fixture.batch.phase == .finished }

        XCTAssertFalse(fixture.batch.isRunning)
        XCTAssertTrue(fixture.batch.canLeaveFlow)
    }

    func testPausingAndResumingReportsTheReasonOnlyWhileItIsPaused() async {
        let fixture = ServiceFixture(assets: [serviceAsset("a", bytes: 3_000_000_000)])
        fixture.transcoder.hold = true
        await scan(fixture)
        fixture.batch.beginSelecting()
        fixture.batch.selectAll()
        fixture.batch.start()
        await eventually { fixture.transcoder.gate != nil }
        XCTAssertNil(fixture.batch.pauseReason)

        fixture.batch.pause()
        fixture.transcoder.hold = false
        fixture.transcoder.release()
        await eventually { fixture.batch.phase == .paused }
        XCTAssertEqual(fixture.batch.pauseReason, .asked)

        fixture.batch.resume()
        // Work is going again, so nothing is left explaining a pause that ended.
        XCTAssertNil(fixture.batch.pauseReason)

        await eventually { fixture.batch.summary.savedCount == 1 }
        XCTAssertEqual(fixture.batch.phase, .finished)
    }

    func testFinishingAPausedRunLandsOnTheSummaryWithTheRestUntouched() async {
        let fixture = ServiceFixture(assets: [serviceAsset("a", bytes: 3_000_000_000),
                                             serviceAsset("b", bytes: 3_000_000_000)])
        fixture.transcoder.hold = true
        await scan(fixture)
        fixture.batch.beginSelecting()
        fixture.batch.selectAll()
        fixture.batch.start()
        await eventually { fixture.transcoder.gate != nil }
        fixture.batch.pause()
        fixture.transcoder.release()
        await eventually { fixture.batch.phase == .paused }

        fixture.batch.finishNow()

        // "Finish with what's done" from a pause has to reach the summary rather than leave the
        // user on a paused screen with a button that did nothing.
        XCTAssertEqual(fixture.batch.phase, .finished)
        XCTAssertEqual(fixture.batch.summary.pendingCount, 2)
        XCTAssertEqual(fixture.batch.summary.savedCount, 0)
        XCTAssertEqual(fixture.photos.saveCount, 0)
        // The unfinished videos are still waiting, so the flow is not free to be left.
        XCTAssertEqual(fixture.batch.remainingCount, 2)
        XCTAssertFalse(fixture.batch.canLeaveFlow)
    }

    func testLeavingTheAppDuringAScanStopsItAndChangesNothing() async {
        let fixture = ServiceFixture(assets: [serviceAsset("a", bytes: 3_000_000_000)])
        fixture.scanner.hold = true
        fixture.batch.scan()
        await eventually { fixture.scanner.gate != nil }

        fixture.batch.enteredBackground()

        // A scan the user walked away from leaves them where a scan leaves them: no library, no
        // message, and the progress line gone.
        await eventually { fixture.batch.phase == .start }
        XCTAssertNil(fixture.batch.scanResult)
        XCTAssertNil(fixture.batch.scanProgress)
        XCTAssertNil(fixture.batch.message)
    }

    // MARK: - What the summary is made of

    func testTheSummaryAndTheSavedBytesComeFromWhatActuallyHappened() async {
        let fixture = ServiceFixture(assets: [serviceAsset("a", bytes: 20_000_000),
                                             serviceAsset("b", bytes: 20_000_000),
                                             serviceAsset("c", bytes: 20_000_000)])
        // The pipeline measures the original through the verifier, so both numbers have to agree
        // or every copy would look bigger than the original it replaced.
        fixture.verifier.inspectBytes = 20_000_000
        fixture.verifier.outputs = [10_000_000, 30_000_000]
        fixture.photos.retrievalFailures = ["c": .retrieval]
        await scan(fixture)
        fixture.batch.beginSelecting()
        fixture.batch.selectAll()
        fixture.batch.start()
        await eventually { fixture.batch.phase == .finished }

        let summary = fixture.batch.summary
        XCTAssertEqual(summary.savedCount, 1)
        XCTAssertEqual(summary.skippedCount, 1)
        XCTAssertEqual(summary.failedCount, 1)
        XCTAssertEqual(summary.pendingCount, 0)
        // Only the video that produced a copy contributes to the totals the screen reports.
        XCTAssertEqual(summary.originalBytes, 20_000_000)
        XCTAssertEqual(summary.copyBytes, 10_000_000)
        XCTAssertEqual(summary.measuredSavings?.bytesSaved, 10_000_000)
        XCTAssertEqual(summary.measuredSavings?.percentage, 50)
        XCTAssertEqual(fixture.batch.readBackReport.confirmed, 1)
        XCTAssertEqual(fixture.batch.readBackReport.unavailable, 0)
        XCTAssertEqual(fixture.batch.readBackReport.total, 1)
    }

    func testAnEstimateIsOfferedForTheLibraryAndForTheSelection() async {
        let fixture = ServiceFixture(assets: [serviceAsset("a", bytes: 3_000_000_000),
                                             serviceAsset("b", bytes: nil)])
        await scan(fixture)

        // The scan screen's estimate covers the videos Photos reported a size for, and says
        // nothing about the one it did not.
        XCTAssertEqual(fixture.batch.scanEstimate?.sizedCount, 1)
        XCTAssertEqual(fixture.batch.scanEstimate?.sizedBytes, 3_000_000_000)

        fixture.batch.beginSelecting()
        // Nothing is ticked yet, so there is no selection to estimate.
        XCTAssertNil(fixture.batch.selectionEstimate)
        XCTAssertNil(fixture.batch.savings(for: fixture.assets[1]))
        fixture.batch.selectAll()

        let hd = fixture.batch.savings(for: fixture.assets[0])
        XCTAssertNotNil(hd)
        // The selection estimate follows the quality the user picked, and a bigger copy means less
        // saved.
        XCTAssertEqual(fixture.batch.selectionEstimate,
                       fixture.batch.estimate(for: fixture.settings.resolution))
        fixture.settings.resolution = .uhd4k
        XCTAssertEqual(fixture.batch.selectionEstimate, fixture.batch.estimate(for: .uhd4k))
        XCTAssertNotEqual(fixture.batch.selectionEstimate, fixture.batch.estimate(for: .hd1080))
        XCTAssertGreaterThan(hd?.conservativeBytes ?? 0,
                             fixture.batch.savings(for: fixture.assets[0])?.conservativeBytes ?? 0)
    }

    func testTheDeletionModeTheRunStartedWithStaysInForceUntilItEnds() async {
        let fixture = ServiceFixture(assets: [serviceAsset("a", bytes: 20_000_000)])
        fixture.verifier.inspectBytes = 20_000_000
        fixture.verifier.outputs = [10_000_000]
        fixture.transcoder.hold = true
        await scan(fixture)
        fixture.batch.beginSelecting()
        fixture.batch.selectAll()
        fixture.batch.start()
        await eventually { fixture.transcoder.gate != nil }
        XCTAssertEqual(fixture.batch.effectiveDeletionMode, .off)

        // Turning deleting on while work is in flight cannot make this run start deleting.
        fixture.settings.deletionMode = .afterRun
        XCTAssertEqual(fixture.batch.effectiveDeletionMode, .off)
        XCTAssertEqual(fixture.queue.stored?.settings.deletion, DeletionMode.off.rawValue)

        fixture.transcoder.hold = false
        fixture.transcoder.release()
        await eventually { fixture.batch.phase == .finished }

        // Nothing was deleted, and the user's newer choice applies from here on.
        XCTAssertEqual(fixture.photos.deleteBatches.count, 0)
        XCTAssertEqual(fixture.batch.deletionReport.handled, 0)
        XCTAssertEqual(fixture.batch.effectiveDeletionMode, .afterRun)
    }

    func testRetryingTheFailedVideosDoesNotRunTheFinishedOnesAgain() async {
        let fixture = ServiceFixture(assets: [serviceAsset("a", bytes: 20_000_000),
                                             serviceAsset("b", bytes: 20_000_000)])
        fixture.verifier.inspectBytes = 20_000_000
        fixture.verifier.outputs = [10_000_000]
        fixture.photos.retrievalFailures = ["b": .retrieval]
        await scan(fixture)
        fixture.batch.beginSelecting()
        fixture.batch.selectAll()
        fixture.batch.start()
        await eventually { fixture.batch.phase == .finished }
        XCTAssertEqual(fixture.batch.summary.savedCount, 1)
        XCTAssertEqual(fixture.batch.summary.failedCount, 1)
        XCTAssertEqual(fixture.photos.saveCount, 1)

        // Whatever stopped the first attempt is over, and the row offers a second try.
        fixture.photos.retrievalFailures = [:]
        fixture.batch.retryFailed()
        await eventually { fixture.batch.summary.savedCount == 2 }

        XCTAssertEqual(fixture.batch.summary.failedCount, 0)
        // Only the video that failed was run again: a copy Photos already holds is never asked for
        // twice, because the second copy cannot be taken back.
        XCTAssertEqual(fixture.photos.saveCount, 2)
        XCTAssertEqual(fixture.batch.items.first?.state,
                       .saved(Savings(originalBytes: 20_000_000, compressedBytes: 10_000_000)))
    }

    func testResettingASettledRunClearsWhatTheSummaryWasBuiltFrom() async {
        let fixture = ServiceFixture(assets: [serviceAsset("a", bytes: 20_000_000)],
                                     stored: serviceStoredRecord("a"))
        XCTAssertTrue(fixture.batch.restoredRun)
        XCTAssertEqual(fixture.batch.deletionOutcomes["a"], .deleted)
        XCTAssertEqual(fixture.batch.readBackOutcomes["a"], .confirmed)
        XCTAssertEqual(fixture.batch.deletionReport.deleted, 1)
        await scan(fixture)

        fixture.batch.reset()

        XCTAssertEqual(fixture.batch.phase, .scanned)
        XCTAssertTrue(fixture.batch.items.isEmpty)
        XCTAssertTrue(fixture.batch.selection.isEmpty)
        XCTAssertFalse(fixture.batch.restoredRun)
        XCTAssertNil(fixture.queue.stored)
        XCTAssertNil(fixture.batch.queueWarning)
        // Nothing from the run is left for the next screen to read as this run's answer.
        XCTAssertEqual(fixture.batch.summary, BatchSummary())
        XCTAssertEqual(fixture.batch.deletionReport, DeletionReport())
        XCTAssertEqual(fixture.batch.readBackReport, ReadBackReport())
        XCTAssertTrue(fixture.batch.deletionOutcomes.isEmpty)
        XCTAssertTrue(fixture.batch.copyEvidence.isEmpty)
        XCTAssertTrue(fixture.batch.revalidationOutcomes.isEmpty)
    }

    // MARK: - The two waits this service makes for PhotoKit

    // The read-back that checks a saved copy and the quick look that opens one both ask PhotoKit
    // for media and wait for one callback. PhotoKit documents that the callback arrives exactly
    // once, and nothing here can prove a device always does. Both waits used to be unbounded, so a
    // handler that never called back held the step for good: the run's "Checking the copy" step had
    // nothing that could end it, and the scrub sheet's spinner had nothing either. Both now run
    // through the scan's own bounded read (`PhotoLibraryScanService.boundedAnswer`), where one
    // lock-guarded claim decides whether the handler, the bound or a stop finishes the wait, so a
    // handler that never arrives and one that arrives twice are both harmless.

    func testTheTwoPhotoKitWaitsThisServiceMakesAreBounded() {
        // Both bounds are the only thing between a PhotoKit read that never answers and a step that
        // never ends, so the numbers themselves are pinned here as the scan's own bound is. The
        // read-back's is the scan's number because it is the same read - a file already on the
        // iPhone, with the network off - and the quick look's is longer because PhotoKit may have
        // to reach iCloud for it.
        XCTAssertEqual(PhotoLibraryService.copyReadBackTimeout, Duration.seconds(10))
        XCTAssertEqual(PhotoLibraryService.scrubRequestTimeout, Duration.seconds(20))
        XCTAssertEqual(PhotoLibraryService.copyReadBackTimeout,
                       PhotoLibraryScanService.onDeviceRequestTimeout)
    }

    func testAQuickLookThatNeverAnswersIsGivenUpAndExplainedInsteadOfSpinning() async {
        let started = Date()
        // The wait the quick look makes, driven with the value it really hands back. Nothing answers
        // here, which is the case this bound exists for.
        let answer: PlayerItemAnswer? = await PhotoLibraryScanService.boundedAnswer(
            timeout: .milliseconds(40),
            start: { _ in
                let nothingToCancel: () -> Void = {}
                return nothingToCancel
            })
        let waited = Date().timeIntervalSince(started)

        XCTAssertNil(answer)
        // It waited for the bound rather than giving up at once...
        XCTAssertGreaterThanOrEqual(waited, 0.02)
        // ...and the bound is what ended the wait.
        XCTAssertLessThan(waited, 5)
        // What the caller is told is the sheet's own failure line rather than a spinner:
        // `previewItem` passes this straight through, and the sheet stops loading and draws it.
        XCTAssertThrowsError(try PhotoLibraryService.resolvePlayerItem(answer)) { error in
            XCTAssertEqual(error as? PipelineError, .retrieval)
        }
    }

    func testAPlayerItemIsHandedBackWhenPhotosAnswersAndItsOwnSentenceWhenItDoesNot() throws {
        let item = AVPlayerItem(url: URL(fileURLWithPath: "/service-preview.mov"))
        let answered = PlayerItemAnswer(item: item, error: nil)
        XCTAssertTrue(try PhotoLibraryService.resolvePlayerItem(answered) === item)

        // A read Photos answered with nothing keeps the sentence it always produced.
        XCTAssertThrowsError(try PhotoLibraryService.resolvePlayerItem(PlayerItemAnswer(item: nil,
                                                                                        error: nil))) { error in
            XCTAssertEqual(error as? PipelineError, .retrieval)
        }
        // ...and an error Photos did report travels as itself, exactly as it did before the bound
        // was added.
        XCTAssertThrowsError(try PhotoLibraryService.resolvePlayerItem(
            PlayerItemAnswer(item: nil, error: PipelineError.insufficientStorage))) { error in
            XCTAssertEqual(error as? PipelineError, .insufficientStorage)
        }
    }

    func testACopyPhotosHandsNothingBackForIsSavedButNeverOfferedForDeletion() async {
        let fixture = ServiceFixture(assets: [serviceAsset("a", bytes: 20_000_000)])
        fixture.verifier.inspectBytes = 20_000_000
        fixture.verifier.outputs = [10_000_000]
        // Nil is both what a bounded-out read-back answers and what Photos answers when it cannot
        // produce the file, and the two must read the same way: a copy that was saved, that this
        // app could not check.
        fixture.photos.readBackURL = nil
        await scan(fixture)
        fixture.batch.beginSelecting()
        fixture.batch.selectAll()
        fixture.batch.start()
        await eventually { fixture.batch.phase == .finished }

        XCTAssertEqual(fixture.batch.summary.savedCount, 1)
        XCTAssertEqual(fixture.batch.summary.failedCount, 0)
        XCTAssertEqual(fixture.batch.readBackOutcomes["a"], .unavailable)
        XCTAssertEqual(fixture.batch.readBackReport.unavailable, 1)
        // And an unconfirmed copy is not evidence enough to delete the original it came from.
        fixture.batch.settings.deletionMode = .afterRun
        XCTAssertTrue(fixture.batch.deletableItemIDs.isEmpty)
    }

    // MARK: - Temporary files a run cannot clear

    func testATemporaryCopyThatCannotBeRemovedIsReportedWhileTheRestCarriesOn() async {
        let fixture = ServiceFixture(assets: [serviceAsset("a", bytes: 20_000_000),
                                             serviceAsset("b", bytes: 20_000_000)])
        fixture.verifier.inspectBytes = 20_000_000
        fixture.verifier.outputs = [10_000_000]
        fixture.files.removeError = .temporaryFiles
        // The second video is held, so the state after the first one finished can be read.
        fixture.transcoder.holdFromCall = 2
        await scan(fixture)
        fixture.batch.beginSelecting()
        fixture.batch.selectAll()
        fixture.batch.start()
        await eventually { fixture.transcoder.gate != nil }

        // The first video is done, its copy could not be removed, and the run said so instead of
        // leaking the file in silence.
        XCTAssertEqual(fixture.batch.summary.savedCount, 1)
        XCTAssertTrue(fixture.files.removed.isEmpty)
        XCTAssertNotNil(fixture.batch.cleanupWarning)

        fixture.transcoder.release()
        await eventually { fixture.batch.phase == .finished }

        // The end of the run sweeps the whole workspace, which does remove what a single file
        // removal could not, so the warning is not left standing.
        XCTAssertEqual(fixture.batch.summary.savedCount, 2)
        XCTAssertNil(fixture.batch.cleanupWarning)
    }

    func testAWorkspaceThatCannotBeCleanedIsReported() async {
        let fixture = ServiceFixture(assets: [serviceAsset("a", bytes: 20_000_000)])
        fixture.verifier.inspectBytes = 20_000_000
        fixture.verifier.outputs = [10_000_000]
        await scan(fixture)
        fixture.batch.beginSelecting()
        fixture.batch.selectAll()
        fixture.files.cleanupError = .temporaryFiles
        fixture.batch.start()
        await eventually { fixture.batch.phase == .finished }

        XCTAssertEqual(fixture.batch.summary.savedCount, 1)
        XCTAssertNotNil(fixture.batch.cleanupWarning)
        // The launch's own cleanup ran; the run's failed one is not counted as a success.
        XCTAssertEqual(fixture.files.cleanups, 1)
    }

    // MARK: - What a retrieval refuses, in its own words

    /// The retrieval step reads a video's traits and refuses on them, exactly as the library scan
    /// does. What it threw was `PipelineError.unsupported` - a sentence listing everything that
    /// might be wrong - even though `AssetRules.unsupportedReason` had just answered the question
    /// with one fact. A video that gains a refusal trait between the scan and the run (edited in
    /// Photos, moved into a shared album) is not re-screened, so it arrives here and was described
    /// by that guess. This pins the mapping the request now uses, which is the part of it a machine
    /// with no Photos library can drive.
    func testARefusedTraitIsDescribedByTheRulesOwnSentence() throws {
        let guess = PipelineError.unsupported.localizedDescription
        let refused: [AssetRules.Traits] = [
            AssetRules.Traits(isVideo: false),
            AssetRules.Traits(hasPairedVideo: true),
            AssetRules.Traits(isTimeLapse: true),
            AssetRules.Traits(isSpatial: true),
            AssetRules.Traits(isHighFrameRate: true),
            AssetRules.Traits(hasAdjustmentData: true),
            AssetRules.Traits(hasFullSizeVideo: true),
            AssetRules.Traits(isCinematic: true),
            AssetRules.Traits(isProRes: true),
            AssetRules.Traits(isHDR: true),
            AssetRules.Traits(isSharedOrRestricted: true)
        ]
        for traits in refused {
            let sentence = try XCTUnwrap(AssetRules.unsupportedReason(traits))
            let refusal = try XCTUnwrap(PhotoLibraryService.unsupportedOriginalRefusal(traits))
            XCTAssertEqual(refusal, .unsupportedOriginal(reason: sentence))
            // Both flows draw this string: the one-video screen shows it as its message, and a batch
            // row draws the same `localizedDescription`.
            XCTAssertEqual(refusal.localizedDescription, sentence)
            XCTAssertNotEqual(refusal.localizedDescription, guess,
                              "A trait the app has just read is not a list of what might be wrong")
        }
        // Nothing refuses an ordinary video, so a retrieval of one is not refused here either.
        XCTAssertNil(PhotoLibraryService.unsupportedOriginalRefusal(AssetRules.Traits()))
        // And the sentence is the rules' own, not a copy of it kept beside this mapping.
        XCTAssertEqual(AssetRules.unsupportedReason(AssetRules.Traits(isHDR: true)),
                       AssetRules.unsupportedFormatReason(isHDR: true, isProRes: false))
    }

    /// The one refusal no trait describes: PhotoKit answered the request for an original with
    /// something that is not a file on this iPhone. This branch threw the same list of formats,
    /// which is untrue in a specific way - the media was never the problem, and every trait rule
    /// had already passed. The reachable half of that branch is its sentence, and the sentence is
    /// what this drives: the request itself needs a real Photos library.
    func testAnOriginalPhotoKitDoesNotHandBackAsAFileSaysSoInsteadOfListingFormats() {
        let refusal = PhotoLibraryService.unreadableOriginalRefusal()
        XCTAssertEqual(refusal.errorDescription, PhotoLibraryService.unreadableOriginalSentence)
        XCTAssertEqual(refusal.localizedDescription, PhotoLibraryService.unreadableOriginalSentence)
        XCTAssertNotEqual(refusal.localizedDescription, PipelineError.unsupported.localizedDescription)
        // It says what was found - not a file - rather than naming formats that were never read.
        XCTAssertTrue(refusal.localizedDescription.contains("file"))
        XCTAssertFalse(refusal.localizedDescription.contains("ProRes"))
    }

    // MARK: - What an export refuses, in its own words

    /// The export step had the same hole the retrieval step above had. `makeSession` threw
    /// `PipelineError.unsupported` - the sentence listing Live Photos, HDR, ProRes and the rest -
    /// when AVFoundation had just refused to build the export at all. No trait in that list has
    /// been looked at on this path and the media may be an ordinary video, so the list is a guess
    /// where the app holds two facts: which quality it asked for, and what came back instead of a
    /// session. Apple's answer cannot be produced on a machine with no media to export, so the
    /// mapping is driven here rather than through a real export - the same split, for the same
    /// reason, as the retrieval refusal above.
    func testAnExportAppleWillNotBuildSaysWhatItFoundInsteadOfListingFormats() {
        let guess = PipelineError.unsupported.localizedDescription
        for resolution in CopyResolution.allCases {
            let noSession = ExportRefusal.noSession(resolution: resolution)
            XCTAssertEqual(noSession.error.errorDescription, noSession.sentence,
                           "the case carries the sentence it was given rather than restating it")
            XCTAssertEqual(noSession.error.localizedDescription, noSession.sentence)
            XCTAssertNotEqual(noSession.sentence, guess,
                              "what was found is not a list of traits nothing has read")
            XCTAssertTrue(noSession.sentence.contains(resolution.title),
                          "the sentence names the quality the run actually asked for")
            XCTAssertFalse(noSession.sentence.contains("ProRes"))
            XCTAssertFalse(noSession.sentence.contains("Live Photo"))

            let container = ExportRefusal.cannotWriteMovieFile(resolution: resolution)
            XCTAssertEqual(container.error.localizedDescription, container.sentence)
            XCTAssertNotEqual(container.sentence, guess)
            XCTAssertTrue(container.sentence.contains(resolution.title))
            // The container is the thing Apple would not write, so the sentence names it: that is
            // the difference between this finding and a preset that has no session at all.
            XCTAssertTrue(container.sentence.contains("QuickTime"))
        }
        // The two findings are not the same fact and must not read as the same sentence.
        XCTAssertNotEqual(ExportRefusal.noSession(resolution: .uhd4k).sentence,
                          ExportRefusal.cannotWriteMovieFile(resolution: .uhd4k).sentence)
        XCTAssertNotEqual(ExportRefusal.noSession(resolution: .hd1080).error,
                          .unsupportedOriginal(reason: "HDR videos aren't supported yet."))
    }

    /// The same finding at the end of a run: the row for that video fails in those words, and the
    /// record left on disk keeps the coarse kind a later launch reads, because a stored queue
    /// carries no sentences.
    func testAVideoAppleWillNotExportFailsInTheFindingsOwnWords() async {
        let fixture = ServiceFixture(assets: [serviceAsset("a", bytes: 20_000_000)])
        let finding = ExportRefusal.noSession(resolution: .uhd4k).error
        fixture.transcoder.error = finding
        await scan(fixture)
        fixture.batch.beginSelecting()
        fixture.batch.selectAll()
        fixture.batch.start()
        await eventually { fixture.batch.phase == .finished }

        XCTAssertEqual(fixture.batch.items.map(\.state), [.failed(finding)])
        XCTAssertNotEqual(finding.localizedDescription, PipelineError.unsupported.localizedDescription)
        XCTAssertEqual(fixture.queue.stored?.items.map(\.state) ?? [], [.failed(code: .unsupported)],
                       "a restored queue can only say this app cannot process that video")
    }

    // MARK: - A copy the one-video flow made

    // MARK: - Watching Photos without asking for it

    /// Launching the app must not put iOS's Photos permission alert on screen.
    ///
    /// This was observed before it was reasoned about. The app-launch-smoke job's first run left
    /// the alert in its log - "BatchShrink would like full access to your Photo Library" - up
    /// before the test had touched anything, and XCUITest's default handler answered it "Don't
    /// Allow", which is what put the run on a recovery screen. The cause is one line: the monitor
    /// reached for `PHPhotoLibrary.shared()` from `BatchViewModel`'s initialiser. That also broke a
    /// promise the app makes on its own first screen, whose footnote reads "Photos access is
    /// requested when you scan".
    ///
    /// The registration is watched through the injected closures rather than through a real
    /// library, because a real one cannot be built in a test and reaching for it is the behaviour
    /// under test.
    func testNothingTouchesPhotosUntilTheAppMayReadTheLibrary() {
        let status = ServiceMonitorStatus(.notDetermined)
        var registrations = 0
        var unregistrations = 0
        let monitor = LibraryChangeMonitor(
            authorizationStatus: { status.value },
            registerObserver: { _ in registrations += 1 },
            unregisterObserver: { _ in unregistrations += 1 }
        )

        monitor.start()

        XCTAssertFalse(monitor.isObservingChanges)
        XCTAssertEqual(registrations, 0,
                       "a launch nobody has asked anything of must not reach for Photos")

        // Returning to the foreground while still unauthorised changes nothing.
        monitor.enteredForeground()
        XCTAssertEqual(registrations, 0)

        // The user allows access - here as a grant in Settings while the app was suspended, which
        // is the moment the monitor re-reads the status and the moment the observer can finally be
        // registered. The first listing after a grant has to be watched like any other.
        status.value = .authorized
        monitor.enteredForeground()

        XCTAssertTrue(monitor.isObservingChanges)
        XCTAssertEqual(registrations, 1)
        // And once only: every foreground report re-checks, and a second registration would double
        // every change report.
        monitor.enteredForeground()
        XCTAssertEqual(registrations, 1)

        monitor.stop()
        XCTAssertFalse(monitor.isObservingChanges)
        XCTAssertEqual(unregistrations, 1)
    }

    /// The ordinary case, so the wait above cannot be satisfied by never registering at all.
    func testAnAppThatMayAlreadyReadTheLibraryWatchesItFromTheStart() {
        var registrations = 0
        let monitor = LibraryChangeMonitor(
            authorizationStatus: { .authorized },
            registerObserver: { _ in registrations += 1 },
            unregisterObserver: { _ in }
        )

        monitor.start()

        XCTAssertTrue(monitor.isObservingChanges)
        XCTAssertEqual(registrations, 1)
    }

    /// And the whole batch flow, built the way the app builds it: nothing is asked for.
    func testBuildingTheBatchFlowAsksPhotosForNothing() {
        let status = ServiceMonitorStatus(.notDetermined)
        var registrations = 0
        let monitor = LibraryChangeMonitor(
            authorizationStatus: { status.value },
            registerObserver: { _ in registrations += 1 },
            unregisterObserver: { _ in }
        )
        let fixture = ServiceFixture(assets: [], monitor: monitor)

        _ = fixture.batch

        XCTAssertEqual(registrations, 0)
        // The introduction is gated on this phase, so a new user still reads it.
        XCTAssertEqual(fixture.batch.phase, .start)
    }

    /// What one confirmed save in the one-video flow leaves behind, and what the batch flow does with
    /// it.
    ///
    /// Two facts go into the shared store, and each has its own history of being missed. The copy's
    /// identifier was dropped first: the flow had no store at all, so only the batch flow ever called
    /// `recordCreatedCopy`, and the next "Select all" could pick up a copy this app had just made and
    /// shrink it again. The original was the second: it was never marked as one this iPhone had
    /// shrunk, so the batch flow would tick *it* and make a second copy of a video that already had a
    /// smaller one - while the batch flow's own saves did mark it, and so did the one-video flow's
    /// branch for a transaction Photos finished without naming the copy. This case drives the whole
    /// save against a real store, then hands the batch flow a library holding the original, the copy
    /// and one other video, and checks what an automatic selection does with each.
    func testACopyTheOneVideoFlowSavesIsRecordedAsThisAppsOwn() async throws {
        let name = "videoshrink.services.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = UserDefaultsShrinkHistoryStore(defaults: defaults)

        let oneVideo = OneVideoServiceFixture(history: store)
        oneVideo.model.chooseVideo()
        await eventually { oneVideo.model.showingPicker }
        oneVideo.model.selected(identifier: "original")
        // `canSave` stays false until the run's own task has finished, which is the state `save()`
        // needs before it will take the tap at all.
        await eventually { oneVideo.model.canSave }
        oneVideo.model.save()
        await eventually { oneVideo.model.stage == .saved }

        // The identifier Photos reported is in the device-local memory, under the copy key: what a
        // later bulk selection reads.
        let copy = try XCTUnwrap(oneVideo.photos.createdIdentifiers.last)
        XCTAssertEqual(store.createdCopyIdentifiers(), [copy])
        // And the *original* is written down as one this iPhone has shrunk, in the set the batch flow
        // reads for exactly that. The copy never enters it: that set means "an original was shrunk",
        // and the copy is not an original - it stays visible and can still be ticked by hand.
        XCTAssertEqual(store.completedIdentifiers(), ["original"],
                       "A copy of this original exists, so no automatic selection may run it again")
        XCTAssertFalse(store.completedIdentifiers().contains(copy),
                       "A copy this app made is not an original that was shrunk")

        // The consequence, through the flow that reads the memory: a batch selection is offered
        // everything except the copy *and* the original it came from. Without the original's mark
        // this was the second copy the whole area exists to prevent - Select all would tick it and
        // shrink an already-shrunk video all over again.
        let batchFixture = ServiceFixture(assets: [serviceAsset("original", bytes: 20_000_000),
                                                   serviceAsset(copy, bytes: 20_000_000),
                                                   serviceAsset("other", bytes: 20_000_000)])
        batchFixture.history.copies = store.createdCopyIdentifiers()
        batchFixture.history.identifiers = store.completedIdentifiers()
        await scan(batchFixture)
        XCTAssertEqual(batchFixture.batch.eligibleAssets.map(\.id), ["original", copy, "other"],
                       "Both stay in the library and can still be ticked by hand")
        XCTAssertEqual(batchFixture.batch.selectableAssets.map(\.id), ["other"],
                       "Neither this app's copy nor the original it came from is picked automatically")
        // And the flow's own promise, which no case held before: the Originals sheet says "This
        // applies to batch runs. The one-video flow never deletes." Nothing on this path has an
        // original to remove. The fake records a deletion when one is *submitted*, so what this
        // observes is the sharper of the two: nothing on this path ever got far enough to ask.
        XCTAssertTrue(oneVideo.photos.deleteBatches.isEmpty,
                      "the one-video flow never submitted a deletion")
    }

    /// A save is the one step whose outcome the app cannot recover from not knowing, and this flow
    /// has no queue to journal it in - so the note goes to the store before Photos is asked, and the
    /// answer takes it away again. Both halves are pinned here: what the store held *at the moment of
    /// the call* is read inside it, not afterwards.
    func testTheOneVideoFlowNotesASaveBeforePhotosIsAskedAndClearsItOnTheAnswer() async throws {
        let name = "videoshrink.services.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = UserDefaultsShrinkHistoryStore(defaults: defaults)

        let oneVideo = OneVideoServiceFixture(history: store)
        var heldDuringTheCall: Set<String>?
        oneVideo.photos.onSave = { heldDuringTheCall = store.unconfirmedSaveIdentifiers() }

        oneVideo.model.chooseVideo()
        await eventually { oneVideo.model.showingPicker }
        oneVideo.model.selected(identifier: "original")
        await eventually { oneVideo.model.canSave }
        oneVideo.model.save()
        await eventually { oneVideo.model.stage == .saved }

        XCTAssertEqual(heldDuringTheCall, ["original"],
                       "the app has to know a copy may exist before Photos is asked for one")
        XCTAssertTrue(store.unconfirmedSaveIdentifiers().isEmpty,
                      "Photos answered with an identifier, so there is nothing left to ask about")
        XCTAssertEqual(store.createdCopyIdentifiers(), ["created-1"])
    }

    /// And when Photos never answers - it throws, or hands back no identifier - the note stays, so the
    /// batch flow's automatic selection still leaves that video alone.
    func testASavePhotosNeverAnswersLeavesTheOneVideoFlowsNoteInPlace() async throws {
        let name = "videoshrink.services.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = UserDefaultsShrinkHistoryStore(defaults: defaults)

        let oneVideo = OneVideoServiceFixture(history: store)
        oneVideo.photos.saveFailure = .save

        oneVideo.model.chooseVideo()
        await eventually { oneVideo.model.showingPicker }
        oneVideo.model.selected(identifier: "original")
        await eventually { oneVideo.model.canSave }
        oneVideo.model.save()
        await eventually { oneVideo.model.stage == .failed }

        XCTAssertEqual(store.unconfirmedSaveIdentifiers(), ["original"])
        XCTAssertTrue(store.createdCopyIdentifiers().isEmpty,
                      "nothing was written down as this app's own copy, because nothing confirmed one")
    }

    /// Photos can finish the transaction and hand back no identifier at all. The copy is real and this
    /// app cannot name it, so the note is not the honest thing to leave: asking the user whether a copy
    /// exists would contradict the sentence the screen is about to show. What the original needs is the
    /// one thing the app can say about it - it has been shrunk, so no automatic selection may run it.
    func testASaveWithNoIdentifierRecordsTheOriginalRatherThanAShrug() async throws {
        let name = "videoshrink.services.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = UserDefaultsShrinkHistoryStore(defaults: defaults)

        let oneVideo = OneVideoServiceFixture(history: store)
        oneVideo.photos.saveWithoutIdentifier = true

        oneVideo.model.chooseVideo()
        await eventually { oneVideo.model.showingPicker }
        oneVideo.model.selected(identifier: "original")
        await eventually { oneVideo.model.canSave }
        oneVideo.model.save()
        await eventually { oneVideo.model.stage == .saved }

        XCTAssertEqual(store.completedIdentifiers(), ["original"])
        XCTAssertTrue(store.createdCopyIdentifiers().isEmpty,
                      "there is no identifier to record for the copy itself")
        XCTAssertTrue(store.unconfirmedSaveIdentifiers().isEmpty,
                      "the transaction finished, so there is nothing left to ask about")
    }

    // MARK: - Helpers

    private func scan(_ fixture: ServiceFixture) async {
        fixture.scanner.result = LibraryScanResult(assets: fixture.assets,
                                                   videoCount: fixture.assets.count,
                                                   unsupportedCount: 0,
                                                   unknownSizeCount: fixture.assets.filter { $0.bytes == nil }.count,
                                                   sizeSource: .reportedByPhotos,
                                                   measuredOnDeviceCount: 0)
        fixture.batch.scan()
        await eventually { fixture.batch.phase == .scanned }
    }

    private func eventually(_ predicate: () -> Bool, file: StaticString = #filePath,
                            line: UInt = #line) async {
        for _ in 0..<500 {
            if predicate() { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("Timed out waiting for the batch", file: file, line: line)
    }

    private func makeQueueDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("service-coverage-queue-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

/// The protection class a write recorded, in whichever shape this runtime reports it.
private func protectionClass(in attributes: [FileAttributeKey: Any]) -> String? {
    if let raw = attributes[.protectionKey] as? String { return raw }
    if let raw = attributes[.protectionKey] as? FileProtectionType { return raw.rawValue }
    return nil
}

private func serviceAsset(_ id: String, bytes: Int64?, duration: Double = 120) -> LibraryAsset {
    LibraryAsset(id: id, creationDate: Date(timeIntervalSince1970: 1_700_000_000),
                 duration: duration, pixelWidth: 3840, pixelHeight: 2160, bytes: bytes,
                 unsupportedReason: nil)
}

private func serviceQueuedItem(_ id: String, bytes: Int64? = 3_000_000_000,
                               state: BatchQueueRecord.State = .pending) -> BatchQueueRecord.Item {
    BatchQueueRecord.Item(identifier: id, creationDate: nil, duration: 120,
                          pixelWidth: 3840, pixelHeight: 2160, bytes: bytes, state: state)
}

/// The receipt a run stores when Photos hands a copy back, as `PhotoLibraryService` builds it.
private func serviceReceipt(for id: String) -> DeletionEvidence {
    DeletionEvidence(copy: AssetSnapshot(identifier: "created-1", duration: 120,
                                         pixelWidth: 1920, pixelHeight: 1080,
                                         creationDate: nil, modificationDate: nil),
                     source: AssetSnapshot(identifier: id, duration: 120,
                                           pixelWidth: 3840, pixelHeight: 2160,
                                           creationDate: nil, modificationDate: nil))
}

/// A stored queue as a run leaves it once Photos has answered: one copy saved and read back, and
/// the original it belongs to already dealt with.
private func serviceStoredRecord(_ id: String) -> BatchQueueRecord {
    var record = BatchQueueRecord(
        settings: BatchQueueRecord.Settings(resolution: CopyResolution.hd1080.rawValue,
                                            frameRate: FrameRateOption.original.rawValue,
                                            deletion: DeletionMode.afterRun.rawValue),
        items: [serviceQueuedItem(id, state: .saved(originalBytes: 20_000_000,
                                                    copyBytes: 10_000_000))])
    record.items[0].readBack = .confirmed
    record.items[0].deletion = .deleted
    record.items[0].copyEvidence = serviceReceipt(for: id)
    return record
}

@MainActor private final class ServiceFixture {
    let assets: [LibraryAsset]
    let photos = ServiceMockPhotos()
    let scanner = ServiceMockScanner()
    let transcoder = ServiceMockTranscoder()
    let verifier = ServiceMockVerifier()
    let files = ServiceMockFiles()
    let history = ServiceMockHistory()
    let queue = ServiceMockQueue()
    let screenAwake = ServiceMockScreenAwake()
    /// The model watches the real Photos library unless a test hands it a monitor that reports
    /// without one, so every fixture here watches a library whose access is known.
    let monitor: LibraryChangeMonitor
    let settings = ShrinkSettings(defaults: UserDefaults(suiteName: "videoshrink.services.\(UUID().uuidString)")
                                  ?? .standard)
    lazy var batch = BatchViewModel(photos: photos, scanner: scanner, transcoder: transcoder,
                                    verifier: verifier, temporary: files, history: history,
                                    queueStore: queue, screenAwake: screenAwake,
                                    libraryChanges: monitor, settings: settings)

    init(assets: [LibraryAsset], stored: BatchQueueRecord? = nil,
         monitor: LibraryChangeMonitor? = nil) {
        self.assets = assets
        self.monitor = monitor ?? LibraryChangeMonitor(authorizationStatus: { .authorized })
        queue.stored = stored
    }
}

/// The one-video model over the same fakes, with the history store a test hands it. It exists so a
/// test can drive a save in the one-video flow and then read what the *other* flow reads.
@MainActor private final class OneVideoServiceFixture {
    let photos = ServiceMockPhotos()
    let transcoder = ServiceMockTranscoder()
    let verifier = ServiceMockVerifier()
    let files = ServiceMockFiles()
    let history: any ShrinkHistoryStoring
    let settings = ShrinkSettings(defaults: UserDefaults(suiteName: "videoshrink.services.\(UUID().uuidString)")
                                  ?? .standard)
    lazy var model = CompressionViewModel(photos: photos, transcoder: transcoder,
                                          verifier: verifier, temporary: files,
                                          history: history, settings: settings)

    init(history: any ShrinkHistoryStoring) {
        self.history = history
    }
}

@MainActor private final class ServiceMockScreenAwake: ScreenAwakeControlling {
    var values: [Bool] = []
    func hold(_ hold: Bool) { values.append(hold) }
}

/// A mutable authorization status, so a test can drive the moment access is granted.
///
/// Deliberately not main-actor isolated: the monitor reads it through a plain escaping closure,
/// which is evaluated outside the actor.
private final class ServiceMonitorStatus {
    var value: PHAuthorizationStatus
    init(_ value: PHAuthorizationStatus) { self.value = value }
}

@MainActor private final class ServiceMockQueue: BatchQueueStoring {
    var stored: BatchQueueRecord?
    var saveCount = 0
    var clearCount = 0
    var saveError: Error?

    func load() -> BatchQueueRecord? { stored }

    func save(_ record: BatchQueueRecord) throws {
        if let saveError { throw saveError }
        saveCount += 1
        stored = record
    }

    func clear() {
        clearCount += 1
        stored = nil
    }
}

@MainActor private final class ServiceMockPhotos: PhotoLibraryServing {
    var retrievalFailures: [String: PipelineError] = [:]
    var retrieveCount = 0
    var saveCount = 0
    /// Every identifier this fake handed back, so a test can read what a save did with it.
    var createdIdentifiers: [String] = []
    /// One entry per Photos transaction, which is one system confirmation.
    var deleteBatches: [[String]] = []
    var deletedIdentifiers: [String] = []
    /// What Photos hands back when the app asks for the copy it just saved.
    var readBackURL: URL? = URL(fileURLWithPath: "/photos/readback.mov")
    /// What the fake throws instead of answering a save, so a case can drive the one state where
    /// nobody knows whether the copy exists.
    var saveFailure: PipelineError?
    /// Finishes the transaction without handing an identifier back, which Photos does when it has no
    /// placeholder to name the new asset with.
    var saveWithoutIdentifier = false
    /// Called at the top of `save`, which is the moment the one-video flow has just written down that
    /// Photos is about to be asked. It exists so a case can read the store *during* the call rather
    /// than after it, which is the only way to tell that write from one made afterwards.
    var onSave: (() -> Void)?

    func requestAccess() async throws -> Bool { false }

    func retrieve(identifier: String, progress: @escaping @MainActor (Double) -> Void) async throws -> RetrievedVideo {
        retrieveCount += 1
        if let failure = retrievalFailures[identifier] { throw failure }
        try Task.checkCancellation()
        return RetrievedVideo(asset: AVURLAsset(url: URL(fileURLWithPath: "/service-\(identifier).mov")),
                              identity: AssetIdentity(originalFilename: "\(identifier).mov"))
    }

    func cancelRetrieval() {}

    func save(videoAt url: URL, identity: AssetIdentity) async throws -> String? {
        saveCount += 1
        onSave?()
        if let saveFailure { throw saveFailure }
        guard !saveWithoutIdentifier else { return nil }
        let identifier = "created-\(saveCount)"
        createdIdentifiers.append(identifier)
        return identifier
    }

    func localFileURL(identifier: String) async -> URL? { readBackURL }

    func playerItem(identifier: String) async throws -> AVPlayerItem {
        AVPlayerItem(url: URL(fileURLWithPath: "/service-preview.mov"))
    }

    func deleteOriginals(identifiers: [String]) async throws -> [String] {
        deleteBatches.append(identifiers)
        deletedIdentifiers.append(contentsOf: identifiers)
        return identifiers
    }

    func deletionEvidence(originalIdentifier: String, copyIdentifier: String) -> DeletionEvidence? {
        DeletionEvidence(copy: AssetSnapshot(identifier: copyIdentifier, duration: 120,
                                             pixelWidth: 1920, pixelHeight: 1080,
                                             creationDate: nil, modificationDate: nil),
                         source: AssetSnapshot(identifier: originalIdentifier, duration: 120,
                                               pixelWidth: 3840, pixelHeight: 2160,
                                               creationDate: nil, modificationDate: nil))
    }

    func revalidateForDeletion(_ evidence: DeletionEvidence) -> CopyRevalidation { .matches }

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

@MainActor private final class ServiceMockScanner: LibraryScanning {
    var result = LibraryScanResult(assets: [], videoCount: 0, unsupportedCount: 0, unknownSizeCount: 0,
                                   sizeSource: .reportedByPhotos, measuredOnDeviceCount: 0)
    var hold = false
    var scanCount = 0
    var gate: CheckedContinuation<Void, Error>?
    private var cancelled = false

    func scan(progress: @escaping @MainActor (LibraryScanProgress) -> Void) async throws -> LibraryScanResult {
        scanCount += 1
        cancelled = false
        progress(LibraryScanProgress(phase: .listing, scanned: 0, total: result.assets.count))
        if hold { try await withCheckedThrowingContinuation { gate = $0 } }
        if cancelled { throw PipelineError.cancelled }
        return result
    }

    func refreshListing() async throws -> LibraryScanResult { result }

    func reconcile(previous: LibraryScanResult?,
                   selection: Set<String>,
                   running: Set<String>) async throws -> LibraryReconciliation {
        LibraryScanResult.reconcile(previous: previous, fresh: result,
                                    selection: selection, running: running)
    }

    func cancel() {
        cancelled = true
        gate?.resume(throwing: PipelineError.cancelled)
        gate = nil
    }
}

@MainActor private final class ServiceMockTranscoder: VideoTranscoding {
    /// What AVFoundation answers when the run asks it for an export it will not build.
    var error: Error?
    var hold = false
    /// Holds the given transcode and every call after it, so a test can read the run's state once
    /// an earlier video has finished.
    var holdFromCall: Int?
    var cancelCalled = false
    var gate: CheckedContinuation<Void, Never>?
    var receivedSettings: [TranscodeSettings] = []
    var written = URL(fileURLWithPath: "/service-root/output.mov")
    private var calls = 0

    func transcode(_ source: RetrievedVideo, metadata: VideoMetadata, settings: TranscodeSettings,
                   progress: @escaping @MainActor (Double) -> Void) async throws -> URL {
        calls += 1
        receivedSettings.append(settings)
        if hold || (holdFromCall.map { calls >= $0 } ?? false) {
            await withCheckedContinuation { gate = $0 }
        }
        if let error { throw error }
        try Task.checkCancellation()
        return written
    }

    func cancel() { cancelCalled = true }
    func release() { gate?.resume(); gate = nil }
}

// The batch model waits for this fake on the main actor; production uses an actor.
private final class ServiceMockVerifier: VideoVerifying {
    var inspectBytes: Int64 = 1_000
    var outputs: [Int64] = [600]
    private var verifications = 0

    func inspect(_ url: URL) async throws -> VideoMetadata {
        VideoMetadata(duration: 120, width: 3840, height: 2160, bytes: inspectBytes,
                      fileType: "MOV", audioTrackCount: 1, isPlayable: true, codec: .hevc,
                      nominalFrameRate: 30)
    }

    func verify(_ url: URL, source: VideoMetadata, expecting codec: VideoCodec?) async throws -> VideoMetadata {
        let bytes = outputs[min(verifications, outputs.count - 1)]
        verifications += 1
        return VideoMetadata(duration: source.duration, width: 1920, height: 1080, bytes: bytes,
                             fileType: "MOV", audioTrackCount: 1, isPlayable: true,
                             codec: codec ?? .hevc, nominalFrameRate: 30)
    }

    /// Read-back compares the copy Photos handed back with what the run measured, so this fake
    /// hands back exactly the properties the run expected.
    func verifyImportedCopy(_ url: URL, matching expected: VideoMetadata) async throws -> VideoMetadata {
        expected
    }
}

@MainActor private final class ServiceMockFiles: TemporaryFileManaging {
    var capacityError: PipelineError?
    var removeError: PipelineError?
    var cleanupError: PipelineError?
    var cleanups = 0
    var removed: [String] = []
    private var counter = 0

    func ensureWorkspace() throws {}

    func outputURL() throws -> URL {
        counter += 1
        return URL(fileURLWithPath: "/service-root/\(counter).mov")
    }

    func remove(_ url: URL) throws {
        if let removeError { throw removeError }
        removed.append(url.lastPathComponent)
    }

    func requireCapacity(for bytes: Int64) throws { if let capacityError { throw capacityError } }

    func cleanup() throws {
        if let cleanupError { throw cleanupError }
        cleanups += 1
    }
}

@MainActor private final class ServiceMockHistory: ShrinkHistoryStoring {
    var identifiers: Set<String> = []
    var copies: Set<String> = []
    var measurements: [CopyMeasurement] = []
    var records: [String] = []

    func completedIdentifiers() -> Set<String> { identifiers }
    func createdCopyIdentifiers() -> Set<String> { copies }
    func copyMeasurements() -> [CopyMeasurement] { measurements }

    func record(identifier: String, measurement: CopyMeasurement?) {
        records.append(identifier)
        identifiers.insert(identifier)
        if let measurement, measurement.isValid { measurements.append(measurement) }
    }

    func recordCreatedCopy(identifier: String) { copies.insert(identifier) }
}
