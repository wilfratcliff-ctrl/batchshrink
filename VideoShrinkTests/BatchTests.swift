import XCTest
import AVFoundation
import Photos
@testable import VideoShrink

@MainActor final class BatchTests: XCTestCase {

    // MARK: - Quality options

    func testPlanningBandFollowsTheChosenResolution() {
        let hd = CopySizeModel.make(for: .hd1080, frameRate: .original, measured: [])
        XCTAssertEqual(hd.lowBitsPerSecond, 4_000_000, accuracy: 1)
        XCTAssertEqual(hd.highBitsPerSecond, 8_000_000, accuracy: 1)
        XCTAssertEqual(hd.basis, .planning(resolution: .hd1080))
        XCTAssertEqual(CopySizeModel.make(for: .uhd4k, frameRate: .original, measured: []).lowBitsPerSecond,
                       12_000_000, accuracy: 1)
        XCTAssertEqual(CopySizeModel.make(for: .hd720, frameRate: .original, measured: []).highBitsPerSecond,
                       5_000_000, accuracy: 1)
    }

    func testFewerFramesLowerTheEstimate() {
        let original = CopySizeModel.make(for: .hd1080, frameRate: .original, measured: [])
        let thirty = CopySizeModel.make(for: .hd1080, frameRate: .fps30, measured: [])
        let twentyFour = CopySizeModel.make(for: .hd1080, frameRate: .fps24, measured: [])
        XCTAssertEqual(thirty.highBitsPerSecond, original.highBitsPerSecond, accuracy: 1)
        XCTAssertEqual(twentyFour.highBitsPerSecond, original.highBitsPerSecond * 0.8, accuracy: 1)
    }

    func testMeasuredCopiesOnlyRefineTheSizeTheyWereMadeAt() {
        let measurements = [CopyMeasurement(bitsPerSecond: 5_000_000, longEdge: 1920),
                            CopyMeasurement(bitsPerSecond: 5_400_000, longEdge: 1920),
                            CopyMeasurement(bitsPerSecond: 5_200_000, longEdge: 1920)]
        let hd = CopySizeModel.make(for: .hd1080, frameRate: .original, measured: measurements)
        XCTAssertEqual(hd.basis, .measured(samples: 3))
        XCTAssertEqual(hd.lowBitsPerSecond, 4_500_000, accuracy: 1)
        XCTAssertEqual(hd.highBitsPerSecond, 5_940_000, accuracy: 1)
        XCTAssertEqual(CopySizeModel.make(for: .uhd4k, frameRate: .original, measured: measurements).basis,
                       .planning(resolution: .uhd4k))
        // Two samples are not enough to retune the band.
        XCTAssertEqual(CopySizeModel.make(for: .hd1080, frameRate: .original,
                                          measured: [CopyMeasurement(bitsPerSecond: 5_000_000, longEdge: 1920)]).basis,
                       .planning(resolution: .hd1080))
    }

    func testResolutionIsNeverRaisedAndNeverExceedsTheSource() {
        let fourK = TranscodeSettings(resolution: .uhd4k, frameRate: .original)
        XCTAssertEqual(fourK.renderLongEdge(sourceLongEdge: 3840), 3840)
        XCTAssertEqual(fourK.renderLongEdge(sourceLongEdge: 1920), 1920)
        XCTAssertEqual(fourK.effectiveResolution(sourceLongEdge: 1920), .hd1080)
        XCTAssertEqual(fourK.effectiveResolution(sourceLongEdge: 3840), .uhd4k)

        let hd = TranscodeSettings(resolution: .hd1080, frameRate: .original)
        XCTAssertEqual(hd.effectiveResolution(sourceLongEdge: 1280), .hd720)
        XCTAssertEqual(hd.effectiveResolution(sourceLongEdge: 3840), .hd1080)
    }

    func testACompositionIsOnlyUsedWhenThePresetCannotDoIt() {
        let hd = TranscodeSettings(resolution: .hd1080, frameRate: .original)
        // 4K down to 1080p: the preset alone does it.
        XCTAssertFalse(hd.needsComposition(sourceLongEdge: 3840, sourceFrameRate: 30))
        // A 720p source would be upscaled by the preset, so a composition fixes the size.
        XCTAssertTrue(hd.needsComposition(sourceLongEdge: 1280, sourceFrameRate: 30))
        // A lower frame rate needs a composition too.
        let twentyFour = TranscodeSettings(resolution: .hd1080, frameRate: .fps24)
        XCTAssertTrue(twentyFour.needsComposition(sourceLongEdge: 3840, sourceFrameRate: 30))
        XCTAssertFalse(twentyFour.needsComposition(sourceLongEdge: 3840, sourceFrameRate: 24))
    }

    func testFrameRateIsNeverRaised() {
        let thirty = TranscodeSettings(resolution: .hd1080, frameRate: .fps30)
        XCTAssertNil(thirty.targetFrameRate(sourceFrameRate: 24))
        XCTAssertEqual(thirty.targetFrameRate(sourceFrameRate: 60), 30)
        XCTAssertNil(TranscodeSettings(resolution: .hd1080, frameRate: .original)
            .targetFrameRate(sourceFrameRate: 60))
    }

    func testSavingsFollowTheChosenResolution() throws {
        // Ten minutes of 4K at roughly 40 Mbps.
        let clip = asset("a", bytes: 3_000_000_000)
        let fourK = try XCTUnwrap(clip.savings(settings: TranscodeSettings(resolution: .uhd4k,
                                                                          frameRate: .original), measured: []))
        let hd = try XCTUnwrap(clip.savings(settings: TranscodeSettings(resolution: .hd1080,
                                                                       frameRate: .original), measured: []))
        XCTAssertGreaterThan(hd.conservativeBytes, fourK.conservativeBytes)
        XCTAssertGreaterThan(hd.optimisticBytes, fourK.optimisticBytes)
    }

    func testASmallFileForItsLengthIsFlaggedAsUnlikelyToShrink() throws {
        // Two minutes at roughly 1 Mbps: already smaller than anything the bands predict.
        let saving = try XCTUnwrap(asset("a", bytes: 15_000_000, duration: 120)
            .savings(settings: TranscodeSettings(), measured: []))
        XCTAssertFalse(saving.likelyShrinks)
        XCTAssertEqual(saving.conservativeBytes, 0)
    }

    func testScanEstimateCountsOnlyVideosWithAReportedSize() {
        let result = LibraryScanResult(assets: [asset("a", bytes: 3_000_000_000), asset("b", bytes: nil)],
                                       videoCount: 4, unsupportedCount: 2, unknownSizeCount: 1,
                                       sizeSource: .reportedByPhotos, measuredOnDeviceCount: 0)
        let estimate = result.estimate(settings: TranscodeSettings(), measured: [])
        XCTAssertEqual(estimate.sizedCount, 1)
        XCTAssertEqual(estimate.sizedBytes, 3_000_000_000)
        XCTAssertGreaterThan(estimate.conservativeBytes, 0)
        XCTAssertEqual(estimate.basis, .planning(resolution: .hd1080))
        XCTAssertLessThan(estimate.estimatedCopyBytes, estimate.sizedBytes)
    }

    func testImpossibleDurationsCannotProduceAnEstimate() {
        XCTAssertNil(CopySizeModel.make(for: .hd1080, frameRate: .original, measured: [])
            .savings(sourceBytes: 1_000_000, duration: 0))
        XCTAssertNil(CopySizeModel.make(for: .hd1080, frameRate: .original, measured: [])
            .copyBytes(forDuration: .nan))
        XCTAssertNil(CopySizeModel.make(for: .hd1080, frameRate: .original, measured: [])
            .savings(sourceBytes: 0, duration: 120))
    }

    // MARK: - Time estimate

    func testEstimatorStaysSilentUntilAVideoHasFinished() {
        var estimator = ProcessingEstimator()
        XCTAssertFalse(estimator.hasEstimate)
        XCTAssertNil(estimator.remainingSeconds(pendingContentSeconds: [60], activeContentSeconds: nil,
                                                activeElapsedSeconds: 0))
    }

    func testEstimatorScalesWithTheContentStillToGo() throws {
        var estimator = ProcessingEstimator()
        estimator.record(processingSeconds: 30, contentSeconds: 60)
        let estimate = try XCTUnwrap(estimator.remainingSeconds(pendingContentSeconds: [120, 120],
                                                               activeContentSeconds: nil,
                                                               activeElapsedSeconds: 0))
        XCTAssertTrue(estimate.contains(120))
    }

    func testShortestBandComesFromASingleSample() throws {
        var estimator = ProcessingEstimator()
        estimator.record(processingSeconds: 20, contentSeconds: 40)
        let estimate = try XCTUnwrap(estimator.remainingSeconds(pendingContentSeconds: [40],
                                                               activeContentSeconds: nil,
                                                               activeElapsedSeconds: 0))
        XCTAssertEqual(estimate.lowerBound, 12, accuracy: 0.5)
        XCTAssertEqual(estimate.upperBound, 36, accuracy: 0.5)
    }

    func testObservedSpreadWidensTheBandWithMoreSamples() throws {
        var estimator = ProcessingEstimator()
        estimator.record(processingSeconds: 30, contentSeconds: 60)
        estimator.record(processingSeconds: 60, contentSeconds: 60)
        let estimate = try XCTUnwrap(estimator.remainingSeconds(pendingContentSeconds: [60],
                                                               activeContentSeconds: nil,
                                                               activeElapsedSeconds: 0))
        XCTAssertTrue(estimate.contains(52.5))
        XCTAssertLessThan(estimate.lowerBound, 52.5)
        XCTAssertGreaterThan(estimate.upperBound, 52.5)
    }

    func testElapsedTimeOnTheActiveVideoIsSubtracted() throws {
        var estimator = ProcessingEstimator()
        estimator.record(processingSeconds: 60, contentSeconds: 60)
        let estimate = try XCTUnwrap(estimator.remainingSeconds(pendingContentSeconds: [],
                                                               activeContentSeconds: 60,
                                                               activeElapsedSeconds: 45))
        XCTAssertTrue(estimate.contains(15))
    }

    // MARK: - Eligibility rules

    func testAssetRulesRejectSpecialFormats() {
        XCTAssertNil(AssetRules.unsupportedReason(AssetRules.Traits()))
        XCTAssertNotNil(AssetRules.unsupportedReason(AssetRules.Traits(isVideo: false)))
        XCTAssertNotNil(AssetRules.unsupportedReason(AssetRules.Traits(isHighFrameRate: true)))
        XCTAssertNotNil(AssetRules.unsupportedReason(AssetRules.Traits(isTimeLapse: true)))
        XCTAssertNotNil(AssetRules.unsupportedReason(AssetRules.Traits(isSpatial: true)))
        XCTAssertNotNil(AssetRules.unsupportedReason(AssetRules.Traits(hasAdjustmentData: true)))
        XCTAssertNotNil(AssetRules.unsupportedReason(AssetRules.Traits(hasFullSizeVideo: true)))
        XCTAssertNotNil(AssetRules.unsupportedReason(AssetRules.Traits(hasPairedVideo: true)))
    }

    func testOnlyEligibleVideosWithSizesGetAPerRowEstimate() {
        let settings = TranscodeSettings()
        XCTAssertNotNil(asset("sized", bytes: 3_000_000_000).savings(settings: settings, measured: []))
        XCTAssertNil(asset("unsized", bytes: nil).savings(settings: settings, measured: []))
        XCTAssertNil(asset("unsupported", bytes: 3_000_000_000, unsupported: "Edited videos aren’t supported yet.")
            .savings(settings: settings, measured: []))
    }

    // MARK: - Running a batch

    func testBatchSavesSmallerCopiesAndSkipsOnesThatGrew() async {
        let fixture = BatchFixture(assets: [asset("a", bytes: 1_000), asset("b", bytes: 1_000)])
        fixture.verifier.outputs = [600, 2_000]
        await scan(fixture)
        fixture.batch.beginSelecting()
        fixture.batch.selectAll()
        fixture.batch.start()
        await eventually { fixture.batch.phase == .finished }

        XCTAssertEqual(fixture.photos.saveCount, 1)
        XCTAssertEqual(fixture.batch.summary.savedCount, 1)
        XCTAssertEqual(fixture.batch.summary.skippedCount, 1)
        XCTAssertEqual(fixture.batch.summary.pendingCount, 0)
        // Each finished video had its temporary copy removed, saved or not.
        XCTAssertEqual(fixture.files.removed.count, 2)
        // History records only the copy Photos actually confirmed, with its measured size.
        XCTAssertEqual(fixture.history.records, ["a"])
        XCTAssertEqual(fixture.history.identifiers, ["a"])
        XCTAssertEqual(fixture.history.measurements.count, 1)
    }

    func testTheRunUsesTheQualityThatWasChosen() async {
        let fixture = BatchFixture(assets: [asset("a", bytes: 1_000)])
        fixture.settings.resolution = .hd720
        fixture.settings.frameRate = .fps24
        await scan(fixture)
        fixture.batch.beginSelecting()
        fixture.batch.selectAll()
        fixture.batch.start()
        await eventually { fixture.batch.phase == .finished }

        XCTAssertEqual(fixture.transcoder.receivedSettings.first?.resolution, .hd720)
        XCTAssertEqual(fixture.transcoder.receivedSettings.first?.frameRate, .fps24)
        XCTAssertEqual(fixture.verifier.receivedCodecs.first, .h264)
    }

    func testChangingQualityMidRunLeavesWorkInFlightAlone() async {
        let fixture = BatchFixture(assets: [asset("a", bytes: 1_000), asset("b", bytes: 1_000)])
        fixture.transcoder.hold = true
        await scan(fixture)
        fixture.batch.beginSelecting()
        fixture.batch.selectAll()
        fixture.batch.start()
        await eventually { fixture.transcoder.gate != nil }

        fixture.settings.resolution = .uhd4k
        fixture.transcoder.hold = false
        fixture.transcoder.release()
        await eventually { fixture.batch.phase == .finished }

        XCTAssertEqual(fixture.transcoder.receivedSettings.map(\.resolution), [.hd1080, .hd1080])
    }

    func testBatchContinuesAfterOneVideoFails() async {
        let fixture = BatchFixture(assets: [asset("a", bytes: 1_000), asset("b", bytes: 1_000),
                                            asset("c", bytes: 1_000)])
        fixture.photos.retrievalFailures = ["b": .retrieval]
        await scan(fixture)
        fixture.batch.beginSelecting()
        fixture.batch.selectAll()
        fixture.batch.start()
        await eventually { fixture.batch.phase == .finished }

        XCTAssertEqual(fixture.batch.summary.savedCount, 2)
        XCTAssertEqual(fixture.batch.summary.failedCount, 1)
        XCTAssertEqual(fixture.photos.saveCount, 2)
        XCTAssertEqual(fixture.history.records.count, 2)
    }

    func testAFailedSaveLeavesTheVideoUnmarked() async {
        let fixture = BatchFixture(assets: [asset("a", bytes: 1_000)])
        fixture.photos.saveError = .save
        await scan(fixture)
        fixture.batch.beginSelecting()
        fixture.batch.selectAll()
        fixture.batch.start()
        await eventually { fixture.batch.phase == .finished }

        XCTAssertEqual(fixture.batch.summary.failedCount, 1)
        XCTAssertEqual(fixture.batch.summary.savedCount, 0)
        XCTAssertTrue(fixture.history.records.isEmpty)
        XCTAssertTrue(fixture.history.identifiers.isEmpty)
    }

    func testPausingKeepsUnfinishedWorkAndResumingFinishesIt() async {
        let fixture = BatchFixture(assets: [asset("a", bytes: 1_000), asset("b", bytes: 1_000)])
        fixture.transcoder.hold = true
        await scan(fixture)
        fixture.batch.beginSelecting()
        fixture.batch.selectAll()
        fixture.batch.start()
        await eventually { fixture.transcoder.gate != nil }
        fixture.batch.pause()
        fixture.transcoder.release()
        await eventually { fixture.batch.phase == .paused }

        XCTAssertEqual(fixture.batch.remainingCount, 2)
        XCTAssertEqual(fixture.batch.summary.savedCount, 0)
        XCTAssertTrue(fixture.transcoder.cancelCalled)

        fixture.transcoder.hold = false
        fixture.batch.resume()
        await eventually { fixture.batch.phase == .finished }
        XCTAssertEqual(fixture.photos.saveCount, 2)
        XCTAssertEqual(fixture.batch.summary.savedCount, 2)
    }

    func testFinishingEarlyLeavesTheRestUntouched() async {
        let fixture = BatchFixture(assets: [asset("a", bytes: 1_000), asset("b", bytes: 1_000)])
        fixture.transcoder.hold = true
        await scan(fixture)
        fixture.batch.beginSelecting()
        fixture.batch.selectAll()
        fixture.batch.start()
        await eventually { fixture.transcoder.gate != nil }
        fixture.batch.finishNow()
        fixture.transcoder.release()
        await eventually { fixture.batch.phase == .finished }

        XCTAssertEqual(fixture.batch.summary.pendingCount, 2)
        XCTAssertEqual(fixture.photos.saveCount, 0)
        XCTAssertGreaterThan(fixture.batch.remainingCount, 0)
    }

    func testEnteringTheBackgroundPausesANetworkBoundRun() async {
        let fixture = BatchFixture(assets: [asset("a", bytes: 1_000), asset("b", bytes: 1_000)])
        fixture.transcoder.hold = true
        await scan(fixture)
        fixture.batch.beginSelecting()
        fixture.batch.selectAll()
        fixture.batch.start()
        await eventually { fixture.transcoder.gate != nil }
        fixture.batch.enteredBackground()
        fixture.transcoder.release()
        await eventually { fixture.batch.phase == .paused }
        XCTAssertEqual(fixture.photos.saveCount, 0)
    }

    func testLowStorageStopsTheFirstVideoWithoutSaving() async {
        let fixture = BatchFixture(assets: [asset("a", bytes: 1_000)])
        fixture.files.capacityError = .insufficientStorage
        await scan(fixture)
        fixture.batch.beginSelecting()
        fixture.batch.selectAll()
        fixture.batch.start()
        await eventually { fixture.batch.phase == .finished }

        XCTAssertEqual(fixture.batch.summary.failedCount, 1)
        XCTAssertEqual(fixture.photos.retrieveCount, 0)
        XCTAssertEqual(fixture.photos.saveCount, 0)
    }

    // MARK: - Scanning and selection

    func testCancellingAScanReturnsToWhereItStarted() async {
        let fixture = BatchFixture(assets: [])
        fixture.scanner.hold = true
        fixture.batch.scan()
        await eventually { fixture.scanner.gate != nil }
        fixture.batch.cancelScan()
        await eventually { fixture.batch.phase == .start }
        XCTAssertNil(fixture.batch.scanProgress)
    }

    func testAFailedScanOffersRecoveryWithoutChangingAnything() async {
        let fixture = BatchFixture(assets: [])
        fixture.scanner.error = .libraryScan
        fixture.batch.scan()
        await eventually { fixture.batch.phase == .failed }
        XCTAssertEqual(fixture.batch.message, PipelineError.libraryScan.localizedDescription)
        XCTAssertNil(fixture.batch.scanResult)
    }

    func testSelectingEverythingSkipsNothingTheScanOffered() async {
        // "a" is ten minutes of 4K, so it looks like it will shrink. "b" has no reported size.
        let fixture = BatchFixture(assets: [asset("a", bytes: 3_000_000_000), asset("b", bytes: nil)])
        await scan(fixture)
        fixture.batch.beginSelecting()
        fixture.batch.selectAll()
        XCTAssertEqual(fixture.batch.selection, ["a", "b"])
        fixture.batch.clearSelection()
        XCTAssertTrue(fixture.batch.selection.isEmpty)
        fixture.batch.selectLikelyToShrink()
        XCTAssertEqual(fixture.batch.selection, ["a"])
    }

    func testBulkShortcutsLeaveOutVideosThisIPhoneAlreadyShrunk() async {
        let fixture = BatchFixture(assets: [asset("a", bytes: 3_000_000_000), asset("b", bytes: 3_000_000_000)])
        fixture.history.identifiers = ["a"]
        await scan(fixture)
        fixture.batch.beginSelecting()
        fixture.batch.selectAll()
        XCTAssertEqual(fixture.batch.selection, ["b"])
        XCTAssertEqual(fixture.batch.selectableCount, 1)
        fixture.batch.toggle("a")
        XCTAssertEqual(fixture.batch.selection, ["a", "b"])
    }

    // MARK: - Copies this app made

    func testAnAppCreatedCopyStaysOutOfABulkSelectionAndCanStillBeChosenByHand() async {
        // "copy" is what this app made on an earlier run: a new Photos asset with an identifier of
        // its own, so the library lists it like any other video.
        let fixture = BatchFixture(assets: [asset("a", bytes: 3_000_000_000),
                                            asset("copy", bytes: 3_000_000_000)])
        fixture.history.copies = ["copy"]
        await scan(fixture)

        // It is never taken out of the library the screen lists.
        XCTAssertEqual(fixture.batch.eligibleAssets.map(\.id), ["a", "copy"])

        fixture.batch.beginSelecting()
        fixture.batch.selectAll()
        XCTAssertEqual(fixture.batch.selection, ["a"])
        XCTAssertEqual(fixture.batch.selectableCount, 1)
        fixture.batch.clearSelection()
        fixture.batch.selectLikelyToShrink()
        XCTAssertEqual(fixture.batch.selection, ["a"])

        // Ticking it by hand is how a copy is deliberately run through again.
        fixture.batch.toggle("copy")
        XCTAssertEqual(fixture.batch.selection, ["a", "copy"])
        XCTAssertTrue(fixture.batch.canStart)
    }

    func testACopyCanBeRunThroughAgainWhenItIsTickedByHand() async {
        let fixture = BatchFixture(assets: [asset("copy", bytes: 3_000_000_000)])
        fixture.history.copies = ["copy"]
        await scan(fixture)

        fixture.batch.beginSelecting()
        fixture.batch.selectAll()
        XCTAssertTrue(fixture.batch.selection.isEmpty)

        fixture.batch.toggle("copy")
        XCTAssertEqual(fixture.batch.selection, ["copy"])
        fixture.batch.start()
        await eventually { fixture.batch.phase == .finished }

        XCTAssertEqual(fixture.photos.saveCount, 1)
        XCTAssertEqual(fixture.batch.summary.savedCount, 1)
    }

    func testTheCopyARunCreatesIsRememberedAndLeftOutOfTheNextBulkSelect() async {
        let fixture = BatchFixture(assets: [asset("a", bytes: 3_000_000_000)])
        await scan(fixture)
        fixture.batch.beginSelecting()
        fixture.batch.selectAll()
        fixture.batch.start()
        await eventually { fixture.batch.phase == .finished }

        // Photos handed back "created-1", and that is what the app writes down as its own copy.
        XCTAssertEqual(fixture.photos.saveCount, 1)
        XCTAssertEqual(fixture.history.copies, ["created-1"])
        XCTAssertEqual(fixture.batch.createdCopyIdentifiers, ["created-1"])
        // It is not an original that was shrunk, so it never joins the other list.
        XCTAssertFalse(fixture.history.identifiers.contains("created-1"))

        // A relaunch over the library, which now lists the original, its copy and a fresh video.
        let relaunched = BatchFixture(assets: [asset("a", bytes: 3_000_000_000),
                                               asset("created-1", bytes: 3_000_000_000),
                                               asset("b", bytes: 3_000_000_000)])
        relaunched.history.identifiers = fixture.history.identifiers
        relaunched.history.copies = fixture.history.copies
        await scan(relaunched)
        relaunched.batch.beginSelecting()
        relaunched.batch.selectAll()

        // The copy is left out. The fresh video is still selected.
        XCTAssertEqual(relaunched.batch.selection, ["b"])
    }

    func testTheChooserEstimatesEachResolutionForTheSelection() async {
        let fixture = BatchFixture(assets: [asset("a", bytes: 3_000_000_000)])
        await scan(fixture)
        fixture.batch.beginSelecting()
        fixture.batch.selectAll()
        let hd = fixture.batch.estimate(for: .hd1080)
        let fourK = fixture.batch.estimate(for: .uhd4k)
        XCTAssertNotNil(hd)
        XCTAssertNotNil(fourK)
        XCTAssertGreaterThan(hd?.conservativeBytes ?? 0, fourK?.conservativeBytes ?? 0)
    }

    // MARK: - On-device history

    // MARK: - Restoring a stored queue

    func testTheCopyCarriesTheOriginalsIdentity() async {
        let fixture = BatchFixture(assets: [asset("a", bytes: 1_000)])
        await scan(fixture)
        fixture.batch.beginSelecting()
        fixture.batch.selectAll()
        fixture.batch.start()
        await eventually { fixture.batch.phase == .finished }

        XCTAssertEqual(fixture.photos.receivedIdentities.first?.originalFilename, "a.mov")
    }

    // MARK: - Deleting originals

    func testAPreviewAsksForAPlayerItemForThatVideo() async throws {
        let fixture = BatchFixture(assets: [asset("a", bytes: 1_000)])
        _ = try await fixture.batch.previewItem(for: "a")
        XCTAssertEqual(fixture.photos.previewedIdentifiers, ["a"])
    }

    func testAFailedPreviewExplainsItselfInsteadOfCrashing() async {
        let fixture = BatchFixture(assets: [asset("a", bytes: 1_000)])
        fixture.photos.previewError = .retrieval
        do {
            _ = try await fixture.batch.previewItem(for: "a")
            XCTFail("A preview that fails must throw so the sheet can say so")
        } catch {
            XCTAssertEqual(error as? PipelineError, .retrieval)
        }
    }

    func testDeletingIsOffUntilItIsTurnedOn() async {
        let fixture = BatchFixture(assets: [asset("a", bytes: 1_000)])
        await scan(fixture)
        fixture.batch.beginSelecting()
        fixture.batch.selectAll()
        fixture.batch.start()
        await eventually { fixture.batch.phase == .finished }

        XCTAssertEqual(fixture.batch.deletionOutcomes.count, 0)
        XCTAssertTrue(fixture.photos.deletedIdentifiers.isEmpty)
        XCTAssertTrue(fixture.batch.deletableItemIDs.isEmpty)
    }

    func testAnOriginalIsDeletedOnlyAfterTheCopyIsReadBack() async {
        let fixture = BatchFixture(assets: [asset("a", bytes: 1_000)])
        fixture.settings.deletionMode = .afterEachCopy
        await scan(fixture)
        fixture.batch.beginSelecting()
        fixture.batch.selectAll()
        fixture.batch.start()
        await eventually { fixture.batch.phase == .finished }

        XCTAssertEqual(fixture.photos.deletedIdentifiers, ["a"])
        XCTAssertEqual(fixture.batch.deletionOutcomes["a"], .deleted)
        XCTAssertEqual(fixture.batch.deletionReport.deleted, 1)
        XCTAssertEqual(fixture.queue.stored?.items.first?.deletion, .deleted)
    }

    func testAnOriginalStaysWhenItsCopyCannotBeReadBack() async {
        let fixture = BatchFixture(assets: [asset("a", bytes: 1_000)])
        fixture.settings.deletionMode = .afterEachCopy
        fixture.photos.readBackURL = nil
        await scan(fixture)
        fixture.batch.beginSelecting()
        fixture.batch.selectAll()
        fixture.batch.start()
        await eventually { fixture.batch.phase == .finished }

        XCTAssertTrue(fixture.photos.deletedIdentifiers.isEmpty)
        XCTAssertEqual(fixture.batch.deletionReport.skipped, 1)
        XCTAssertTrue(fixture.batch.deletableItemIDs.isEmpty)
    }

    func testAnOriginalStaysWhenTheCopyIsNotSmaller() async {
        let fixture = BatchFixture(assets: [asset("a", bytes: 1_000)])
        fixture.settings.deletionMode = .afterEachCopy
        fixture.verifier.outputs = [5_000]
        await scan(fixture)
        fixture.batch.beginSelecting()
        fixture.batch.selectAll()
        fixture.batch.start()
        await eventually { fixture.batch.phase == .finished }

        XCTAssertTrue(fixture.photos.deletedIdentifiers.isEmpty)
        XCTAssertEqual(fixture.batch.summary.skippedCount, 1)
    }

    func testAfterRunModeWaitsForTheUserToConfirm() async {
        let fixture = BatchFixture(assets: [asset("a", bytes: 1_000), asset("b", bytes: 1_000)])
        fixture.settings.deletionMode = .afterRun
        await scan(fixture)
        fixture.batch.beginSelecting()
        fixture.batch.selectAll()
        fixture.batch.start()
        await eventually { fixture.batch.phase == .finished }

        XCTAssertTrue(fixture.photos.deletedIdentifiers.isEmpty)
        XCTAssertEqual(Set(fixture.batch.deletableItemIDs), ["a", "b"])

        fixture.batch.deleteOriginalsNow()
        await eventually { !fixture.batch.deletionInProgress }
        XCTAssertEqual(Set(fixture.photos.deletedIdentifiers), ["a", "b"])
        XCTAssertEqual(fixture.batch.deletionReport.deleted, 2)
    }

    func testDeletingAtTheEndIsOnePhotosTransaction() async {
        let fixture = BatchFixture(assets: [asset("a", bytes: 1_000), asset("b", bytes: 1_000),
                                            asset("c", bytes: 1_000)])
        fixture.settings.deletionMode = .afterRun
        await scan(fixture)
        fixture.batch.beginSelecting()
        fixture.batch.selectAll()
        fixture.batch.start()
        await eventually { fixture.batch.phase == .finished }

        fixture.batch.deleteOriginalsNow()
        await eventually { !fixture.batch.deletionInProgress }
        // One transaction means one system confirmation, however many originals are in it.
        XCTAssertEqual(fixture.photos.deleteBatches.count, 1)
        XCTAssertEqual(Set(fixture.photos.deleteBatches[0]), ["a", "b", "c"])
        XCTAssertEqual(fixture.batch.deletionReport.deleted, 3)
    }

    func testDeletingAsItGoesBatchesInsteadOfPromptingEachTime() async {
        let fixture = BatchFixture(assets: (0..<7).map { asset("v\($0)", bytes: 1_000) })
        fixture.settings.deletionMode = .afterEachCopy
        await scan(fixture)
        fixture.batch.beginSelecting()
        fixture.batch.selectAll()
        fixture.batch.start()
        await eventually { fixture.batch.phase == .finished }

        // Seven videos, batches of five: five on the way through, the remainder when the run ends.
        XCTAssertEqual(fixture.photos.deleteBatches.map(\.count), [5, 2])
        XCTAssertEqual(fixture.batch.deletionReport.deleted, 7)
    }

    func testAnOriginalPhotosCannotFindIsKeptAndSaidSo() async {
        let fixture = BatchFixture(assets: [asset("a", bytes: 1_000), asset("b", bytes: 1_000)])
        fixture.settings.deletionMode = .afterRun
        fixture.photos.missingFromLibrary = ["b"]
        await scan(fixture)
        fixture.batch.beginSelecting()
        fixture.batch.selectAll()
        fixture.batch.start()
        await eventually { fixture.batch.phase == .finished }

        fixture.batch.deleteOriginalsNow()
        await eventually { !fixture.batch.deletionInProgress }
        XCTAssertEqual(fixture.batch.deletionReport.deleted, 1)
        XCTAssertEqual(fixture.batch.deletionReport.skipped, 1)
    }

    func testTheScreenIsHeldAwakeOnlyWhenAskedAndOnlyWhileWorking() async {
        let fixture = BatchFixture(assets: [asset("a", bytes: 1_000)])
        fixture.settings.keepScreenAwake = true
        await scan(fixture)
        fixture.batch.beginSelecting()
        fixture.batch.selectAll()
        fixture.batch.start()
        XCTAssertEqual(fixture.screenAwake.values.last, true)

        await eventually { fixture.batch.phase == .finished }
        XCTAssertEqual(fixture.screenAwake.values.last, false)
    }

    func testTheScreenIsLeftAloneWhenTheSettingIsOff() async {
        let fixture = BatchFixture(assets: [asset("a", bytes: 1_000)])
        await scan(fixture)
        fixture.batch.beginSelecting()
        fixture.batch.selectAll()
        fixture.batch.start()
        await eventually { fixture.batch.phase == .finished }
        XCTAssertTrue(fixture.screenAwake.values.allSatisfy { $0 == false })
    }

    func testADeleteThatWasInFlightComesBackUncertain() {
        let fixture = BatchFixture(assets: [])
        var record = queuedRecord([queuedItem("a", .saved(originalBytes: 1_000, copyBytes: 600))])
        record.items[0].readBack = .confirmed
        record.items[0].deletion = .deleting
        record.settings.deletion = DeletionMode.afterRun.rawValue
        fixture.queue.stored = record

        XCTAssertEqual(fixture.batch.deletionOutcomes["a"], .uncertain)
        // It is not offered again: Photos may already have removed it.
        XCTAssertTrue(fixture.batch.deletableItemIDs.isEmpty)
    }

    func testAFailedDeleteIsReportedAndCanBeTriedAgain() async {
        let fixture = BatchFixture(assets: [asset("a", bytes: 1_000)])
        fixture.settings.deletionMode = .afterRun
        fixture.photos.deleteError = .assetUnavailable
        await scan(fixture)
        fixture.batch.beginSelecting()
        fixture.batch.selectAll()
        fixture.batch.start()
        await eventually { fixture.batch.phase == .finished }

        fixture.batch.deleteOriginalsNow()
        await eventually { !fixture.batch.deletionInProgress }
        XCTAssertEqual(fixture.batch.deletionReport.failed, 1)
        XCTAssertEqual(Set(fixture.batch.deletableItemIDs), ["a"])

        fixture.photos.deleteError = nil
        fixture.batch.deleteOriginalsNow()
        await eventually { !fixture.batch.deletionInProgress }
        XCTAssertEqual(fixture.photos.deletedIdentifiers, ["a"])
    }

    func testACopyIsReadBackFromPhotosAfterSaving() async {
        let fixture = BatchFixture(assets: [asset("a", bytes: 1_000)])
        await scan(fixture)
        fixture.batch.beginSelecting()
        fixture.batch.selectAll()
        fixture.batch.start()
        await eventually { fixture.batch.phase == .finished }

        XCTAssertEqual(fixture.batch.readBackOutcomes["a"], .confirmed)
        XCTAssertEqual(fixture.batch.readBackReport.confirmed, 1)
        XCTAssertEqual(fixture.batch.readBackReport.unavailable, 0)
        XCTAssertEqual(fixture.queue.stored?.items.first?.readBack, .confirmed)
    }

    func testACopyPhotosCannotHandBackIsReportedRatherThanFailed() async {
        let fixture = BatchFixture(assets: [asset("a", bytes: 1_000)])
        fixture.photos.readBackURL = nil
        await scan(fixture)
        fixture.batch.beginSelecting()
        fixture.batch.selectAll()
        fixture.batch.start()
        await eventually { fixture.batch.phase == .finished }

        // The save still counts: Photos confirmed it, the copy just could not be checked yet.
        XCTAssertEqual(fixture.batch.summary.savedCount, 1)
        XCTAssertEqual(fixture.batch.summary.failedCount, 0)
        XCTAssertEqual(fixture.batch.readBackOutcomes["a"], .unavailable)
        XCTAssertEqual(fixture.batch.readBackReport.unavailable, 1)
    }

    func testReadBackOutcomesSurviveARestore() {
        let fixture = BatchFixture(assets: [])
        var record = queuedRecord([queuedItem("a", .saved(originalBytes: 1_000, copyBytes: 600)),
                                   queuedItem("b", .saved(originalBytes: 2_000, copyBytes: 900))])
        record.items[1].readBack = .unavailable
        record.items[0].readBack = .confirmed
        fixture.queue.stored = record
        XCTAssertEqual(fixture.batch.readBackReport.confirmed, 1)
        XCTAssertEqual(fixture.batch.readBackReport.unavailable, 1)
    }

    func testAStoredQueueIsPickedUpAsPaused() {
        let fixture = BatchFixture(assets: [])
        fixture.queue.stored = queuedRecord([queuedItem("a", .pending), queuedItem("b", .pending)])
        XCTAssertEqual(fixture.batch.phase, .paused)
        XCTAssertEqual(fixture.batch.remainingCount, 2)
        XCTAssertTrue(fixture.batch.restoredRun)
    }

    func testAMidSaveItemIsFlaggedRatherThanRunAgain() async {
        let fixture = BatchFixture(assets: [])
        fixture.queue.stored = queuedRecord([queuedItem("a", .saving)])
        XCTAssertEqual(fixture.batch.phase, .finished)
        XCTAssertEqual(fixture.batch.summary.needsCheckCount, 1)
        XCTAssertFalse(fixture.batch.hasPendingWork)
        XCTAssertEqual(fixture.photos.retrieveCount, 0)

        // Only an explicit "I checked Photos" puts it back in the queue.
        fixture.batch.requeueUncertain()
        XCTAssertEqual(fixture.batch.phase, .paused)
        XCTAssertTrue(fixture.batch.hasPendingWork)
        fixture.batch.resume()
        await eventually { fixture.batch.phase == .finished }
        XCTAssertEqual(fixture.photos.saveCount, 1)
        XCTAssertEqual(fixture.history.records, ["a"])
    }

    func testFinishedWorkIsNeverRunAgainAfterARestore() async {
        let fixture = BatchFixture(assets: [])
        fixture.queue.stored = queuedRecord([queuedItem("a", .saved(originalBytes: 1_000, copyBytes: 600)),
                                             queuedItem("b", .pending)])
        XCTAssertEqual(fixture.batch.phase, .paused)
        XCTAssertEqual(fixture.batch.summary.savedCount, 1)
        XCTAssertEqual(fixture.batch.remainingCount, 1)

        fixture.batch.resume()
        await eventually { fixture.batch.phase == .finished }
        // Only the waiting video was fetched.
        XCTAssertEqual(fixture.photos.retrieveCount, 1)
    }

    func testTheQueueIsWrittenWhileWorkRunsAndClearedAtTheEnd() async {
        let fixture = BatchFixture(assets: [asset("a", bytes: 1_000)])
        await scan(fixture)
        fixture.batch.beginSelecting()
        fixture.batch.selectAll()
        fixture.batch.start()
        await eventually { fixture.batch.phase == .finished }

        XCTAssertEqual(fixture.queue.stored?.items.count, 1)
        XCTAssertEqual(fixture.queue.stored?.items.first?.state,
                       .saved(originalBytes: 1_000, copyBytes: 600))
        fixture.batch.reset()
        XCTAssertNil(fixture.queue.stored)
        XCTAssertGreaterThan(fixture.queue.clearCount, 0)
    }

    func testAQueueThatCannotBeWrittenIsReported() async {
        let fixture = BatchFixture(assets: [asset("a", bytes: 1_000)])
        await scan(fixture)
        fixture.queue.saveError = PipelineError.temporaryFiles
        fixture.batch.beginSelecting()
        fixture.batch.selectAll()
        fixture.batch.start()
        await eventually { fixture.batch.phase != .processing }

        // The run stops at the first checkpoint it cannot write, before Photos is asked for
        // anything at all, and says so instead of carrying on without a record.
        XCTAssertNotNil(fixture.batch.queueWarning)
        XCTAssertEqual(fixture.batch.phase, .paused)
        XCTAssertEqual(fixture.photos.saveCount, 0)
        XCTAssertEqual(fixture.batch.summary.pendingCount, 1)
        // Nothing on disk describes a save, because no copy was ever asked for.
        let storedStates = fixture.queue.stored?.items.map(\.state) ?? []
        XCTAssertFalse(storedStates.contains { state in
            if case .saving = state { return true }
            if case .saved = state { return true }
            return false
        })
    }

    func testACopyEditedInPhotosAfterTheRunKeepsItsOriginal() async {
        let fixture = BatchFixture(assets: [asset("a", bytes: 1_000)])
        fixture.settings.deletionMode = .afterRun
        await scan(fixture)
        fixture.batch.beginSelecting()
        fixture.batch.selectAll()
        fixture.batch.start()
        await eventually { fixture.batch.phase == .finished }

        // The run checked the copy as it saved it, so the original is offered.
        XCTAssertEqual(fixture.batch.deletableItemIDs, ["a"])

        // Someone edits the copy in Photos before the user confirms. The look taken when the copy
        // was saved is stale, so Photos is asked again as the delete is submitted and the original
        // stays, which is the whole point of holding a receipt rather than a confirmation.
        fixture.photos.revalidation = .copyChanged
        fixture.batch.deleteOriginalsNow()
        await eventually { !fixture.batch.deletionInProgress }

        XCTAssertTrue(fixture.photos.deletedIdentifiers.isEmpty)
        XCTAssertTrue(fixture.photos.deleteBatches.isEmpty)
        XCTAssertEqual(fixture.batch.deletionOutcomes["a"],
                       .skipped("The copy changed after it was checked, so the original stays."))
        XCTAssertEqual(fixture.batch.deletionReport.skipped, 1)
        XCTAssertEqual(fixture.batch.deletionReport.deleted, 0)
    }

    // MARK: - On-device history

    func testHistoryStoreKeepsItsOwnListAndCapsWhatItRemembers() throws {
        let name = "videoshrink.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = UserDefaultsShrinkHistoryStore(defaults: defaults)

        XCTAssertTrue(store.completedIdentifiers().isEmpty)
        XCTAssertTrue(store.copyMeasurements().isEmpty)

        store.record(identifier: "one", measurement: CopyMeasurement(bitsPerSecond: 5_000_000, longEdge: 1920))
        store.record(identifier: "two", measurement: nil)
        XCTAssertEqual(store.completedIdentifiers(), ["one", "two"])
        XCTAssertEqual(store.copyMeasurements().count, 1)

        store.record(identifier: "one", measurement: CopyMeasurement(bitsPerSecond: 6_000_000, longEdge: 1280))
        XCTAssertEqual(store.completedIdentifiers(), ["one", "two"])
        XCTAssertEqual(store.copyMeasurements().count, 2)
        XCTAssertEqual(store.copyMeasurements().last?.longEdge, 1280)

        // A measurement that cannot be trusted is never stored.
        store.record(identifier: "three", measurement: CopyMeasurement(bitsPerSecond: 0, longEdge: 1920))
        XCTAssertEqual(store.copyMeasurements().count, 2)

        for index in 0..<120 {
            store.record(identifier: "id-\(index)",
                         measurement: CopyMeasurement(bitsPerSecond: 5_000_000, longEdge: 1920))
        }
        XCTAssertEqual(store.copyMeasurements().count, UserDefaultsShrinkHistoryStore.measurementLimit)
        XCTAssertEqual(store.completedIdentifiers().count, 123)

        // The copies this app made are their own list, so a copy is never marked as an original
        // that was shrunk. They are bounded by the same limit as the shrunk originals.
        XCTAssertTrue(store.createdCopyIdentifiers().isEmpty)
        store.recordCreatedCopy(identifier: "copy-one")
        store.recordCreatedCopy(identifier: "copy-two")
        XCTAssertEqual(store.createdCopyIdentifiers(), ["copy-one", "copy-two"])
        XCTAssertFalse(store.completedIdentifiers().contains("copy-one"))
        store.recordCreatedCopy(identifier: "copy-one")
        XCTAssertEqual(store.createdCopyIdentifiers(), ["copy-one", "copy-two"])

        for index in 0..<(UserDefaultsShrinkHistoryStore.identifierLimit + 3) {
            store.recordCreatedCopy(identifier: "bulk-\(index)")
        }
        let capped = store.createdCopyIdentifiers()
        XCTAssertEqual(capped.count, UserDefaultsShrinkHistoryStore.identifierLimit)
        XCTAssertFalse(capped.contains("bulk-0"))
        XCTAssertTrue(capped.contains("bulk-\(UserDefaultsShrinkHistoryStore.identifierLimit + 2)"))
        // Writing copies never disturbs the originals this iPhone already shrank.
        XCTAssertEqual(store.completedIdentifiers().count, 123)
    }

    // MARK: - Library freshness

    func testARefreshDropsVideosPhotosNoLongerListsAndTheSelectionThatPointedAtThem() {
        let previous = listing([asset("a", bytes: 10), asset("b", bytes: 20)])
        let fresh = listing([asset("a", bytes: 10)])
        let reconciliation = LibraryScanResult.reconcile(previous: previous, fresh: fresh,
                                                         selection: ["a", "b"], running: [])

        XCTAssertEqual(reconciliation.result.assets.map(\.id), ["a"])
        XCTAssertEqual(reconciliation.selection, ["a"])
        XCTAssertEqual(reconciliation.removedIdentifiers, ["b"])
        XCTAssertTrue(reconciliation.changedIdentifiers.isEmpty)
        XCTAssertTrue(reconciliation.vanishedRunningIdentifiers.isEmpty)
        XCTAssertTrue(reconciliation.changedSomething)
    }

    func testARefreshKeepsTheIdentityOfAVideoTheRunIsStillWorkingOn() {
        let previous = listing([asset("a", bytes: 10), asset("b", bytes: 20)])
        let fresh = listing([asset("a", bytes: 10)])
        let reconciliation = LibraryScanResult.reconcile(previous: previous, fresh: fresh,
                                                         selection: ["a", "b"], running: ["b"])

        // The running original is gone from Photos, but the entry the run started with stays.
        XCTAssertEqual(reconciliation.result.assets.map(\.id), ["a", "b"])
        XCTAssertEqual(reconciliation.result.assets.last?.bytes, 20)
        XCTAssertEqual(reconciliation.selection, ["a", "b"])
        XCTAssertEqual(reconciliation.vanishedRunningIdentifiers, ["b"])
        XCTAssertTrue(reconciliation.removedIdentifiers.isEmpty)
    }

    func testARefreshTakesTheNewMetadataForAVideoThatChangedInPhotos() {
        let previous = listing([asset("a", bytes: 10, duration: 120)])
        let fresh = listing([asset("a", bytes: 10, duration: 90)])
        let reconciliation = LibraryScanResult.reconcile(previous: previous, fresh: fresh,
                                                         selection: ["a"], running: [])

        XCTAssertEqual(reconciliation.changedIdentifiers, ["a"])
        XCTAssertEqual(reconciliation.result.assets.first?.duration, 90)
        XCTAssertTrue(reconciliation.changedSomething)
    }

    func testARefreshKeepsASizeTheDeviceAlreadyMeasured() {
        // A refresh cannot measure, so the size this device already took is still the answer.
        let previous = listing([asset("a", bytes: 10), asset("b", bytes: 20)],
                               sizeSource: .measuredOnDevice, measured: 2)
        let fresh = listing([asset("a", bytes: nil), asset("b", bytes: nil)], sizeSource: .unavailable)
        let reconciliation = LibraryScanResult.reconcile(previous: previous, fresh: fresh,
                                                         selection: ["a"], running: [])

        XCTAssertEqual(reconciliation.result.assets.first?.bytes, 10)
        XCTAssertEqual(reconciliation.result.assets.last?.bytes, 20)
        XCTAssertEqual(reconciliation.result.sizeSource, .measuredOnDevice)
        XCTAssertEqual(reconciliation.result.measuredOnDeviceCount, 2)
        XCTAssertTrue(reconciliation.changedIdentifiers.isEmpty)
    }

    func testARefreshWithoutAnEarlierLibraryJustTakesTheNewListing() {
        let fresh = listing([asset("a", bytes: 10), asset("b", bytes: 20)])
        let reconciliation = LibraryScanResult.reconcile(previous: nil, fresh: fresh,
                                                         selection: ["a", "gone"], running: [])

        XCTAssertEqual(reconciliation.result.assets, fresh.assets)
        XCTAssertEqual(reconciliation.selection, ["a"])
        XCTAssertTrue(reconciliation.removedIdentifiers.isEmpty)
        XCTAssertTrue(reconciliation.vanishedRunningIdentifiers.isEmpty)
    }

    func testRunningIdentifiersAreTheOnesTheRunHasNotFinished() {
        let items = [BatchItem(asset: asset("a", bytes: 10), state: .pending),
                     BatchItem(asset: asset("b", bytes: 10), state: .saving),
                     BatchItem(asset: asset("c", bytes: 10),
                               state: .saved(Savings(originalBytes: 10, compressedBytes: 5))),
                     BatchItem(asset: asset("d", bytes: 10), state: .failed(.save)),
                     BatchItem(asset: asset("e", bytes: 10), state: .needsCheck)]
        XCTAssertEqual(LibraryScanResult.runningIdentifiers(in: items), ["a", "b"])
    }

    // MARK: - Library change wiring

    func testAChangePhotosReportsReachesTheScannerThroughItsOwnProtocol() async {
        let monitor = LibraryChangeMonitor(authorizationStatus: { .authorized })
        let fixture = BatchFixture(assets: [asset("a", bytes: 3_000_000_000),
                                            asset("b", bytes: 3_000_000_000)], monitor: monitor)
        await scan(fixture)
        fixture.batch.beginSelecting()
        fixture.batch.selectAll()
        XCTAssertEqual(fixture.batch.selection, ["a", "b"])

        // Photos stops listing "b". The monitor reports that, the model asks the scanner for a
        // refresh through `LibraryScanning`, and the listing and the selection both lose what is
        // gone.
        fixture.scanner.refreshResult = listing([asset("a", bytes: 3_000_000_000)])
        monitor.enteredForeground()
        await eventually { fixture.scanner.reconcileCount == 1 }
        await eventually { fixture.batch.scanResult?.assets.map(\.id) == ["a"] }

        XCTAssertEqual(fixture.batch.selection, ["a"])
        XCTAssertEqual(fixture.scanner.reconciledSelection, ["a", "b"])
        XCTAssertTrue(fixture.scanner.reconciledRunning.isEmpty)
        // A refresh re-lists; it never scans, so the library keeps the size source it had.
        XCTAssertEqual(fixture.batch.scanResult?.sizeSource, .reportedByPhotos)
    }

    func testARefreshDuringARunKeepsTheJobAndTheIdentityItStartedWith() async {
        let monitor = LibraryChangeMonitor(authorizationStatus: { .authorized })
        let fixture = BatchFixture(assets: [asset("a", bytes: 3_000_000_000),
                                            asset("b", bytes: 3_000_000_000)], monitor: monitor)
        await scan(fixture)
        fixture.batch.beginSelecting()
        fixture.batch.selectAll()
        fixture.transcoder.hold = true
        fixture.batch.start()
        await eventually { fixture.transcoder.gate != nil }

        // Photos stops listing the video the run is working on.
        fixture.scanner.refreshResult = listing([asset("b", bytes: 3_000_000_000)])
        monitor.enteredForeground()
        await eventually { fixture.scanner.reconcileCount == 1 }

        XCTAssertEqual(fixture.scanner.reconciledRunning, ["a"])
        // The running job is named to the scanner as one that must keep its identity, so the
        // refreshed listing carries it even though Photos no longer lists it.
        XCTAssertEqual(Set(fixture.batch.scanResult?.assets.map(\.id) ?? []), ["a", "b"])
        // ...and the job itself is untouched, still working on the video it started with.
        XCTAssertEqual(fixture.batch.items.map(\.id), ["a", "b"])
        XCTAssertEqual(fixture.batch.currentID, "a")

        fixture.transcoder.release()
        await eventually { fixture.batch.phase == .finished }
        XCTAssertEqual(fixture.batch.summary.savedCount, 2)
    }

    func testPhotosAccessIsClassifiedInThisAppsOwnTerms() {
        XCTAssertEqual(LibraryAccess(.authorized), .full)
        XCTAssertTrue(LibraryAccess(.authorized).canRead)
        XCTAssertFalse(LibraryAccess(.authorized).isLimited)
        XCTAssertEqual(LibraryAccess(.limited), .limited)
        XCTAssertTrue(LibraryAccess(.limited).canRead)
        XCTAssertTrue(LibraryAccess(.limited).isLimited)
        XCTAssertEqual(LibraryAccess(.denied), .denied)
        XCTAssertFalse(LibraryAccess(.denied).canRead)
        XCTAssertEqual(LibraryAccess(.restricted), .denied)
        XCTAssertFalse(LibraryAccess(.restricted).canRead)
        XCTAssertEqual(LibraryAccess(.notDetermined), .notDetermined)
        XCTAssertFalse(LibraryAccess(.notDetermined).canRead)
    }

    func testComingBackToTheFrontOffersAFreshLook() {
        let monitor = LibraryChangeMonitor(authorizationStatus: { .authorized })
        var reasons: [LibraryChangeReason] = []
        monitor.onChange = { reasons.append($0) }
        XCTAssertEqual(monitor.revision, 0)
        XCTAssertEqual(monitor.access, .full)

        monitor.enteredForeground()

        XCTAssertEqual(monitor.revision, 1)
        XCTAssertEqual(reasons, [.enteredForeground])
    }

    func testComingBackToTheFrontPicksUpNarrowedOrRevokedAccess() {
        let status = AccessBox(.authorized)
        let monitor = LibraryChangeMonitor(authorizationStatus: { status.value })
        var reasons: [LibraryChangeReason] = []
        monitor.onChange = { reasons.append($0) }

        status.value = .limited
        monitor.enteredForeground()
        XCTAssertEqual(monitor.access, .limited)
        XCTAssertTrue(monitor.isLimited)
        XCTAssertTrue(monitor.canReadLibrary)

        status.value = .denied
        monitor.enteredForeground()
        XCTAssertEqual(monitor.access, .denied)
        XCTAssertFalse(monitor.canReadLibrary)
        XCTAssertEqual(reasons, [.accessChanged, .accessChanged])
        XCTAssertEqual(monitor.revision, 2)
    }

    // MARK: - Helpers

    private func scan(_ fixture: BatchFixture) async {
        fixture.scanner.result = LibraryScanResult(assets: fixture.assets,
                                                   videoCount: fixture.assets.count,
                                                   unsupportedCount: 0,
                                                   unknownSizeCount: fixture.assets.filter { $0.bytes == nil }.count,
                                                   sizeSource: .reportedByPhotos,
                                                   measuredOnDeviceCount: 0)
        fixture.batch.scan()
        await eventually { fixture.batch.phase == .scanned }
    }

    private func eventually(_ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<500 {
            if predicate() { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("Timed out waiting for the batch", file: file, line: line)
    }
}

private func asset(_ id: String, bytes: Int64?, duration: Double = 120,
                   unsupported: String? = nil) -> LibraryAsset {
    LibraryAsset(id: id, creationDate: Date(timeIntervalSince1970: 1_700_000_000), duration: duration,
                 pixelWidth: 3840, pixelHeight: 2160, bytes: bytes, unsupportedReason: unsupported)
}

private func listing(_ assets: [LibraryAsset],
                     videoCount: Int? = nil,
                     sizeSource: LibrarySizeSource = .reportedByPhotos,
                     measured: Int = 0) -> LibraryScanResult {
    LibraryScanResult(assets: assets,
                      videoCount: videoCount ?? assets.count,
                      unsupportedCount: 0,
                      unknownSizeCount: assets.filter { $0.bytes == nil }.count,
                      sizeSource: sizeSource,
                      measuredOnDeviceCount: measured)
}

/// A Photos authorization status a test can change between reads.
private final class AccessBox {
    var value: PHAuthorizationStatus
    init(_ value: PHAuthorizationStatus) { self.value = value }
}

private func queuedItem(_ id: String, _ state: BatchQueueRecord.State) -> BatchQueueRecord.Item {
    BatchQueueRecord.Item(identifier: id, creationDate: nil, duration: 120,
                          pixelWidth: 3840, pixelHeight: 2160, bytes: 3_000_000_000, state: state)
}

private func queuedRecord(_ items: [BatchQueueRecord.Item]) -> BatchQueueRecord {
    BatchQueueRecord(settings: BatchQueueRecord.Settings(resolution: CopyResolution.hd1080.rawValue,
                                                         frameRate: FrameRateOption.original.rawValue),
                     items: items)
}

@MainActor private final class BatchFixture {
    let assets: [LibraryAsset]
    let photos = BatchMockPhotos()
    let scanner = BatchMockScanner()
    let transcoder = BatchMockTranscoder()
    let verifier = BatchMockVerifier()
    let files = BatchMockFiles()
    let history = BatchMockHistory()
    let queue = BatchMockQueue()
    let screenAwake = BatchMockScreenAwake()
    /// The model watches the real Photos library unless a test hands it a monitor that reports a
    /// change without one.
    let monitor: LibraryChangeMonitor
    let settings = ShrinkSettings(defaults: UserDefaults(suiteName: "videoshrink.tests.\(UUID().uuidString)")
                                  ?? .standard)
    lazy var batch = BatchViewModel(photos: photos, scanner: scanner, transcoder: transcoder,
                                    verifier: verifier, temporary: files, history: history,
                                    queueStore: queue, screenAwake: screenAwake,
                                    libraryChanges: monitor, settings: settings)

    init(assets: [LibraryAsset], monitor: LibraryChangeMonitor? = nil) {
        self.assets = assets
        self.monitor = monitor ?? LibraryChangeMonitor(authorizationStatus: { .authorized })
    }
}

@MainActor private final class BatchMockScreenAwake: ScreenAwakeControlling {
    var values: [Bool] = []
    func hold(_ hold: Bool) { values.append(hold) }
}

@MainActor private final class BatchMockQueue: BatchQueueStoring {
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

@MainActor private final class BatchMockPhotos: PhotoLibraryServing {
    var retrievalFailures: [String: PipelineError] = [:]
    var saveError: PipelineError?
    var deleteError: PipelineError?
    var retrieveCount = 0
    var saveCount = 0
    var deletedIdentifiers: [String] = []
    var previewError: PipelineError?
    var previewedIdentifiers: [String] = []
    var stubItem = AVPlayerItem(url: URL(fileURLWithPath: "/mock-preview.mov"))
    /// One entry per Photos transaction, which is one system confirmation.
    var deleteBatches: [[String]] = []
    /// Identifiers Photos could not find, for checking partial batches.
    var missingFromLibrary: Set<String> = []
    var receivedIdentities: [AssetIdentity] = []
    /// What Photos hands back when the app asks for the copy it just saved.
    var readBackURL: URL? = URL(fileURLWithPath: "/photos/readback.mov")

    func requestAccess() async throws -> Bool { false }

    func retrieve(identifier: String, progress: @escaping @MainActor (Double) -> Void) async throws -> RetrievedVideo {
        retrieveCount += 1
        if let failure = retrievalFailures[identifier] { throw failure }
        try Task.checkCancellation()
        return RetrievedVideo(asset: AVURLAsset(url: URL(fileURLWithPath: "/mock-\(identifier).mov")),
                              identity: AssetIdentity(originalFilename: "\(identifier).mov"))
    }

    func cancelRetrieval() {}

    func save(videoAt url: URL, identity: AssetIdentity) async throws -> String? {
        if let saveError { throw saveError }
        saveCount += 1
        receivedIdentities.append(identity)
        return "created-\(saveCount)"
    }

    func localFileURL(identifier: String) async -> URL? { readBackURL }

    func playerItem(identifier: String) async throws -> AVPlayerItem {
        previewedIdentifiers.append(identifier)
        if let previewError { throw previewError }
        return stubItem
    }

    func deleteOriginals(identifiers: [String]) async throws -> [String] {
        if let deleteError { throw deleteError }
        deleteBatches.append(identifiers)
        deletedIdentifiers.append(contentsOf: identifiers)
        return identifiers.filter { !missingFromLibrary.contains($0) }
    }

    // MARK: - Deletion revalidation

    /// What Photos says when the app looks the copy and its original up again before a delete.
    /// A test turns this to a rejecting case to drive an original being kept.
    var revalidation: CopyRevalidation = .matches

    /// The receipt Photos hands back for a copy it just created, built the way the service builds
    /// it: the copy that was made, and the original as it looked at that moment.
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

@MainActor private final class BatchMockScanner: LibraryScanning {
    var result = LibraryScanResult(assets: [], videoCount: 0, unsupportedCount: 0, unknownSizeCount: 0,
                                   sizeSource: .reportedByPhotos, measuredOnDeviceCount: 0)
    var error: PipelineError?
    var hold = false
    var gate: CheckedContinuation<Void, Error>?
    /// The listing a refresh reports: the library as Photos now has it. A test sets this to drive
    /// a change, and leaving it nil makes the refresh repeat the last scan.
    var refreshResult: LibraryScanResult?
    var refreshError: PipelineError?
    /// How the view model asked for a refresh, and how often.
    var reconcileCount = 0
    var reconciledSelection: Set<String> = []
    var reconciledRunning: Set<String> = []
    private var cancelled = false

    func scan(progress: @escaping @MainActor (LibraryScanProgress) -> Void) async throws -> LibraryScanResult {
        cancelled = false
        progress(LibraryScanProgress(phase: .listing, scanned: 0, total: result.assets.count))
        if hold { try await withCheckedThrowingContinuation { gate = $0 } }
        if cancelled { throw PipelineError.cancelled }
        if let error { throw error }
        return result
    }

    /// The half a scan does not need: the same listing with no on-device size pass. Folding it in
    /// goes through the production rule, so a test drives the path a real Photos change takes.
    func refreshListing() async throws -> LibraryScanResult {
        if let refreshError { throw refreshError }
        return refreshResult ?? result
    }

    func reconcile(previous: LibraryScanResult?,
                   selection: Set<String>,
                   running: Set<String>) async throws -> LibraryReconciliation {
        reconcileCount += 1
        reconciledSelection = selection
        reconciledRunning = running
        let fresh = try await refreshListing()
        return LibraryScanResult.reconcile(previous: previous, fresh: fresh,
                                           selection: selection, running: running)
    }

    func cancel() {
        cancelled = true
        gate?.resume(throwing: PipelineError.cancelled)
        gate = nil
    }
}

@MainActor private final class BatchMockTranscoder: VideoTranscoding {
    var error: PipelineError?
    var hold = false
    var cancelCalled = false
    var gate: CheckedContinuation<Void, Never>?
    var receivedSettings: [TranscodeSettings] = []
    var written = URL(fileURLWithPath: "/mock-root/output.mov")

    func transcode(_ source: RetrievedVideo, metadata: VideoMetadata, settings: TranscodeSettings,
                   progress: @escaping @MainActor (Double) -> Void) async throws -> URL {
        receivedSettings.append(settings)
        if let error { throw error }
        if hold { await withCheckedContinuation { gate = $0 } }
        try Task.checkCancellation()
        return written
    }

    func cancel() { cancelCalled = true }
    func release() { gate?.resume(); gate = nil }
}

// The batch model waits for this fake on the main actor; production uses an actor.
private final class BatchMockVerifier: VideoVerifying {
    var inspectBytes: Int64 = 1_000
    var inspectWidth = 3840
    var inspectHeight = 2160
    var outputs: [Int64] = [600]
    var receivedCodecs: [VideoCodec?] = []
    private var verifications = 0

    func inspect(_ url: URL) async throws -> VideoMetadata {
        VideoMetadata(duration: 120, width: inspectWidth, height: inspectHeight, bytes: inspectBytes,
                      fileType: "MOV", audioTrackCount: 1, isPlayable: true, codec: .hevc,
                      nominalFrameRate: 30)
    }

    func verify(_ url: URL, source: VideoMetadata, expecting codec: VideoCodec?) async throws -> VideoMetadata {
        receivedCodecs.append(codec)
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

@MainActor private final class BatchMockFiles: TemporaryFileManaging {
    var capacityError: PipelineError?
    var cleanups = 0
    var removed: [String] = []
    private var counter = 0

    func ensureWorkspace() throws {}
    func outputURL() throws -> URL {
        counter += 1
        return URL(fileURLWithPath: "/mock-root/\(counter).mov")
    }
    func remove(_ url: URL) throws { removed.append(url.lastPathComponent) }
    func requireCapacity(for bytes: Int64) throws { if let capacityError { throw capacityError } }
    func cleanup() throws { cleanups += 1 }
}

@MainActor private final class BatchMockHistory: ShrinkHistoryStoring {
    var identifiers: Set<String> = []
    /// The copies this app created, as the on-device store would remember them.
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
