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

    init(assets: [LibraryAsset], stored: BatchQueueRecord? = nil) {
        self.assets = assets
        self.monitor = LibraryChangeMonitor(authorizationStatus: { .authorized })
        queue.stored = stored
    }
}

@MainActor private final class ServiceMockScreenAwake: ScreenAwakeControlling {
    var values: [Bool] = []
    func hold(_ hold: Bool) { values.append(hold) }
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
    /// One entry per Photos transaction, which is one system confirmation.
    var deleteBatches: [[String]] = []
    var deletedIdentifiers: [String] = []
    /// What Photos hands back when the app asks for the copy it just saved.
    var readBackURL: URL? = URL(fileURLWithPath: "/photos/readback.mov")

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
        return "created-\(saveCount)"
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
