import XCTest
import AVFoundation
import Photos
import SwiftUI
@testable import VideoShrink

@MainActor final class BatchTests: XCTestCase {

    // MARK: - Quality options

    func testPlanningBandFollowsTheChosenResolution() {
        let hd = CopySizeModel.make(for: .hd1080, frameRate: .original, measured: [])
        XCTAssertEqual(hd.lowBitsPerSecond, 4_000_000, accuracy: 1)
        XCTAssertEqual(hd.highBitsPerSecond, 8_000_000, accuracy: 1)
        XCTAssertEqual(hd.basis, .planning(resolution: .hd1080, frameRate: .original))
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
        XCTAssertEqual(hd.basis, .measured(samples: 3, frameRate: .original))
        XCTAssertEqual(hd.lowBitsPerSecond, 4_500_000, accuracy: 1)
        XCTAssertEqual(hd.highBitsPerSecond, 5_940_000, accuracy: 1)
        XCTAssertEqual(CopySizeModel.make(for: .uhd4k, frameRate: .original, measured: measurements).basis,
                       .planning(resolution: .uhd4k, frameRate: .original))
        // Two samples are not enough to retune the band.
        XCTAssertEqual(CopySizeModel.make(for: .hd1080, frameRate: .original,
                                          measured: [CopyMeasurement(bitsPerSecond: 5_000_000, longEdge: 1920)]).basis,
                       .planning(resolution: .hd1080, frameRate: .original))
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
        XCTAssertEqual(estimate.basis, .planning(resolution: .hd1080, frameRate: .original))
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
        // Sizes are realistic on purpose. `CopyMeasurement.isValid` rejects a bitrate below
        // 250 kbps, so a toy 600-byte "video" over 120 seconds would be refused as nonsense and
        // the history assertion below would be testing the guard rather than the recording.
        let fixture = BatchFixture(assets: [asset("a", bytes: 20_000_000), asset("b", bytes: 20_000_000)])
        // The pipeline measures the original through the verifier, not from the library listing,
        // so both numbers have to agree or every copy looks bigger than the original it replaced.
        fixture.verifier.inspectBytes = 20_000_000
        fixture.verifier.outputs = [10_000_000, 30_000_000]
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

    func testARetrievalPhotoKitCancelledWithNoStopIsRetriedTwiceThenFails() async {
        // The audit's finding: `process`'s catch put a cancelled item straight back to `.pending`,
        // and the run loop picked the same video up again with no attempt cap, so a persistent
        // cause would spin the run on one video for ever. Every stop of the user's own sets its
        // flag before it cancels any work, so a `.cancelled` failure with no stop asked for can
        // only be PhotoKit answering the app's own retrieval that way. Three attempts is the
        // ceiling, and the video then fails in the retrieval's own words: `.cancelled` persists as
        // the export code, which would name a step that never ran.
        let fixture = BatchFixture(assets: [asset("a", bytes: 1_000), asset("b", bytes: 1_000)])
        fixture.photos.retrievalFailures = ["a": .cancelled]
        await scan(fixture)
        fixture.batch.beginSelecting()
        fixture.batch.selectAll()
        fixture.batch.start()
        await eventually { fixture.batch.phase == .finished }

        // Two immediate retries, so three attempts on "a" in all, and the run then moves on to "b".
        XCTAssertEqual(fixture.photos.retrieveCount, 3 + 1)
        XCTAssertEqual(fixture.batch.items.first?.state, BatchItemState.failed(.retrieval))
        XCTAssertEqual(fixture.batch.summary.failedCount, 1)
        XCTAssertEqual(fixture.batch.summary.savedCount, 1)
        XCTAssertEqual(fixture.batch.summary.pendingCount, 0)
        XCTAssertFalse(fixture.batch.hasPendingWork)
        // What reached disk is the retrieval's code, not the export fallback `.cancelled` would be
        // stored as, and it is a failure the Retry button can pick up rather than a stuck item.
        XCTAssertEqual(fixture.queue.stored?.items.first?.state, .failed(code: .retrieval))
    }

    func testARunStoppedByTheUserStillLeavesTheItemWaitingRatherThanFailingIt() async {
        // The bound above must not reach the one cancellation that is not a fault. A stop cancels
        // the retrieval too, and that item has to wait for the resume instead of being counted
        // against the cap and failed.
        let fixture = BatchFixture(assets: [asset("a", bytes: 1_000)])
        fixture.photos.holdRetrieval = true
        await scan(fixture)
        fixture.batch.beginSelecting()
        fixture.batch.selectAll()
        fixture.batch.start()
        await eventually { fixture.photos.retrieveGate != nil }

        fixture.batch.pause()
        await eventually { fixture.batch.phase == .paused }

        XCTAssertEqual(fixture.batch.items.first?.state, BatchItemState.pending)
        XCTAssertEqual(fixture.batch.summary.failedCount, 0)
        XCTAssertTrue(fixture.batch.hasPendingWork)
    }

    func testASavePhotosDidNotConfirmIsAQuestionRatherThanAFailure() async {
        // The audit's finding: a save failure was shown as "HEVC export failed", and the item was
        // persisted as a failure, so one tap on "Try the failed ones again" ran the video a second
        // time. Photos may already hold the first copy, so a save that did not confirm is a
        // question, not a failure.
        let fixture = BatchFixture(assets: [asset("a", bytes: 1_000)])
        fixture.photos.saveError = .save
        await scan(fixture)
        fixture.batch.beginSelecting()
        fixture.batch.selectAll()
        fixture.batch.start()
        await eventually { fixture.batch.phase == .finished }

        XCTAssertEqual(fixture.batch.items.first?.state, BatchItemState.needsCheck)
        XCTAssertEqual(fixture.batch.summary.needsCheckCount, 1)
        XCTAssertEqual(fixture.batch.summary.failedCount, 0)
        XCTAssertEqual(fixture.batch.summary.savedCount, 0)
        XCTAssertFalse(fixture.batch.items.contains { $0.state == .failed(.export) },
                       "a save is not an export, and Photos' answer about it is not an export failure")
        // The row says what happened in the save's own words.
        XCTAssertEqual(fixture.batch.midSaveFindings["a"],
                       MidSaveFinding.unresolved(question: PipelineError.save.localizedDescription))
        XCTAssertTrue(fixture.history.records.isEmpty)
        XCTAssertTrue(fixture.history.identifiers.isEmpty)
        // What reached disk keeps the sizes the run measured for the copy Photos may hold, so a
        // later launch can describe it, and it is not a state anything runs again on its own.
        XCTAssertEqual(fixture.queue.stored?.items.first?.state, BatchQueueRecord.State.needsCheck)
        XCTAssertEqual(fixture.queue.stored?.items.first?.attemptedSave,
                       AttemptedSave(Savings(originalBytes: 1_000, compressedBytes: 600)))
        // "Try the failed ones again" cannot pick it up, because it is not a failure.
        fixture.batch.retryFailed()
        XCTAssertEqual(fixture.photos.retrieveCount, 1)
        XCTAssertEqual(fixture.batch.items.first?.state, BatchItemState.needsCheck)
    }

    /// A video this app still has a question about is left out of Select all, and can still be
    /// ticked by hand.
    ///
    /// The question is whether Photos already took a copy, and its answer decides whether running
    /// the video again makes a second copy - the outcome this whole area exists to prevent. The
    /// finding lived in `midSaveFindings`, which nothing consulted when the library was read again,
    /// so the ordinary route "finish, shrink more videos, scan, Select all" put the video straight
    /// back into a run. It is now left out of automatic selection exactly as a copy this app made
    /// is, and it stays on screen and tickable, so the decision is the user's rather than the app's.
    func testAVideoWithAnOpenQuestionIsLeftOutOfSelectAllAndStillTickable() async {
        let fixture = BatchFixture(assets: [asset("a", bytes: 1_000), asset("b", bytes: 1_000)])
        fixture.photos.saveError = .save
        await scan(fixture)
        fixture.batch.beginSelecting()
        fixture.batch.selectAll()
        fixture.batch.start()
        await eventually { fixture.batch.phase == .finished }

        // Both copies are unanswered questions, and both are named as such.
        XCTAssertEqual(fixture.batch.unaccountedIdentifiers, ["a", "b"])
        XCTAssertEqual(fixture.batch.unaccountedAssets.map(\.id), ["a", "b"])

        // A bulk selection leaves them alone...
        fixture.batch.beginSelecting()
        fixture.batch.selectAll()
        XCTAssertEqual(fixture.batch.selectableCount, 0)
        XCTAssertTrue(fixture.batch.selection.isEmpty)

        // ...and reading the library again does not put them back in reach, which is the step that
        // used to: a scan answers what is in the library, not what Photos did with a copy.
        await scan(fixture)
        fixture.batch.beginSelecting()
        fixture.batch.selectAll()
        XCTAssertTrue(fixture.batch.selection.isEmpty)

        // The user can still choose one deliberately, once they have looked in Photos.
        fixture.batch.toggle("a")
        XCTAssertEqual(fixture.batch.selection, ["a"])
        XCTAssertEqual(fixture.batch.selectedAssets.map(\.id), ["a"])
    }

    /// The question survives "Done", which sits next to "Shrink more videos".
    ///
    /// Both buttons are on the finished screen and they end the run in different ways, so the fix
    /// held for one of them and not the other: "Shrink more videos" went through `beginSelecting`,
    /// which clears nothing, while "Done" went through `reset`, which cleared every per-item
    /// dictionary including the findings. That left the library already scanned (`reset` settles on
    /// `.scanned` when there is a listing), so the flagged video was one tap of Select all away
    /// again - in the same session, through the ordinary button.
    func testTheQuestionSurvivesDoneAsWellAsShrinkMoreVideos() async {
        let fixture = BatchFixture(assets: [asset("a", bytes: 1_000)])
        fixture.photos.saveError = .save
        await scan(fixture)
        fixture.batch.beginSelecting()
        fixture.batch.selectAll()
        fixture.batch.start()
        await eventually { fixture.batch.phase == .finished }
        XCTAssertEqual(fixture.batch.unaccountedIdentifiers, ["a"])

        fixture.batch.reset()

        XCTAssertEqual(fixture.batch.unaccountedIdentifiers, ["a"],
                       "Done ends the run, not the question")
        XCTAssertEqual(fixture.batch.unaccountedAssets.map(\.id), ["a"])
        fixture.batch.beginSelecting()
        fixture.batch.selectAll()
        XCTAssertTrue(fixture.batch.selection.isEmpty)
    }

    /// The row under a flagged video is the question, not the refusal's own words.
    ///
    /// The list component was generalised at its heading and its summary and not at its rows, so
    /// every row of the new card read "This video is not supported yet." - of a video the app can
    /// process perfectly well and is inviting the user to tick by hand - and told VoiceOver it could
    /// not be chosen. The question the finding carries is what a row has to say.
    func testARowForAFlaggedVideoSaysWhatTheQuestionIs() async {
        let fixture = BatchFixture(assets: [asset("a", bytes: 1_000)])
        fixture.photos.saveError = .save
        await scan(fixture)
        fixture.batch.beginSelecting()
        fixture.batch.selectAll()
        fixture.batch.start()
        await eventually { fixture.batch.phase == .finished }

        XCTAssertEqual(fixture.batch.midSaveQuestion(for: "a"),
                       PipelineError.save.localizedDescription)
        XCTAssertNotEqual(fixture.batch.midSaveQuestion(for: "a"),
                          "This video is not supported yet.")
        // A video with no finding at all still gets a sentence rather than an empty row.
        XCTAssertEqual(fixture.batch.midSaveQuestion(for: "not-here"),
                       MidSaveFinding.unknownQuestion)
    }

    /// The deletion confirmation says what happens to its own count.
    ///
    /// The count comes from the last look this run took, and a copy edited in Photos since then
    /// would make it wrong - the tap re-looks and can delete fewer, recording each refusal as kept
    /// with its reason. The dialog now says so, which turns a surprise into a rule the user was
    /// told, without weakening what "delete" means.
    func testTheDeletionPromptSaysWhatHappensToItsOwnCount() {
        let one = BatchFinishedScreen.deletionPrompt(count: 1)
        XCTAssertEqual(one.title, "Delete 1 original?")
        XCTAssertEqual(one.button, "Delete 1 original")
        XCTAssertTrue(one.message.contains("looked at again before Photos is asked"))
        XCTAssertTrue(one.message.contains("is kept instead"))
        XCTAssertTrue(one.message.contains("Recently Deleted"))

        let many = BatchFinishedScreen.deletionPrompt(count: 3)
        XCTAssertEqual(many.title, "Delete 3 originals?")
        XCTAssertEqual(many.button, "Delete 3 originals")
        // The message names no count, so it is the same sentence whatever the number is. (It used to
        // assert `!contains("3")`, which the "30 days" in it made false - a case that could not pass.)
        XCTAssertEqual(one.message, many.message)
    }

    /// The selection screen's own words for the videos it leaves out.
    func testTheSelectionScreenNamesTheVideosItLeavesOutOfSelectAll() {
        XCTAssertEqual(BatchSelectionScreen.unaccountedHeading, "Left out of Select all")

        let one = BatchSelectionScreen.unaccountedExplanation(1)
        XCTAssertTrue(one.contains("cannot tell whether a copy already exists"))
        XCTAssertTrue(one.contains("left out of Select all"))
        XCTAssertTrue(one.contains("Tick it by hand"))

        let many = BatchSelectionScreen.unaccountedExplanation(2)
        XCTAssertTrue(many.contains("these videos"))
        XCTAssertTrue(many.contains("Tick one by hand"))
    }

    /// A count and its noun, where a single video is the commonest run there is.
    ///
    /// The screens wrote "1 videos to explore", "1 videos left" and "Delete 1 originals": each count
    /// was right and each sentence wrong, and each was reachable with one video in the library.
    func testTheCountHelperUsesTheSingularWhereTheCountIsOne() {
        XCTAssertEqual(ShrinkFormat.counted(1, "video", "videos"), "1 video")
        XCTAssertEqual(ShrinkFormat.counted(0, "video", "videos"), "0 videos")
        XCTAssertEqual(ShrinkFormat.counted(2, "video", "videos"), "2 videos")
        XCTAssertEqual(ShrinkFormat.counted(1, "original", "originals"), "1 original")
    }

    /// And the two sentences the audit named, which are static so a case can state them.
    func testTheEmptyStatesAndTheUncertainDeletionCountNameTheirOwnNumber() {
        let empty = LibraryScanResult(assets: [], videoCount: 0, unsupportedCount: 0,
                                      unknownSizeCount: 0, sizeSource: .reportedByPhotos,
                                      measuredOnDeviceCount: 0)
        // The empty title itself is pinned by `testAnEmptyLibraryDoesNotClaimVideosWereRefused`, which
        // predates this round; what that case does not say is that the heading does not depend on
        // whether Photos access is limited, because the detail below it carries that difference.
        XCTAssertEqual(BatchEmptyNotice(result: empty, limitedAccess: true).title, "No videos to shrink")
        // The other empty state: a library whose videos are all ones this app cannot use, which the
        // notice has to name as itself rather than as an empty library.
        let unusable = LibraryScanResult(assets: [], videoCount: 3, unsupportedCount: 3,
                                         unknownSizeCount: 0, sizeSource: .reportedByPhotos,
                                         measuredOnDeviceCount: 0)
        XCTAssertEqual(BatchEmptyNotice(result: unusable, limitedAccess: false).title,
                       "No videos BatchShrink can use")

        var one = DeletionReport()
        one.uncertain = 1
        XCTAssertEqual(BatchPausedScreen.settledOriginalsNote(one),
                       "1 original may already have been deleted. Check Photos before running it again.")
        // The plural form is pinned by `testThePausedScreenNamesOnlyDeletionsThatHaveAlreadyHappened`.
    }

    /// The overflow control's hint names what is actually behind it.
    ///
    /// It named all three actions whatever the menu held, so a run with only failures read a hint
    /// promising a Delete that was not there. The list already decided the trigger's contents.
    func testTheOverflowHintNamesOnlyWhatTheMenuHolds() {
        XCTAssertEqual(BatchFinishedScreen.overflowHint([]), "")
        XCTAssertEqual(BatchFinishedScreen.overflowHint([.retryFailed]),
                       "Try the failed ones again.")
        XCTAssertEqual(BatchFinishedScreen.overflowHint([.requeueUncertain]),
                       "Run the ones you checked in Photos.")
        XCTAssertEqual(BatchFinishedScreen.overflowHint([.deleteOriginals]),
                       "Delete the originals that have copies.")
        XCTAssertEqual(BatchFinishedScreen.overflowHint([.deleteOriginals, .retryFailed,
                                                        .requeueUncertain]),
                       "Delete the originals that have copies, try the failed ones again, or run the ones you checked in Photos.")
        XCTAssertEqual(BatchFinishedScreen.overflowHint([.deleteOriginals, .retryFailed]),
                       "Delete the originals that have copies, or try the failed ones again.")
        XCTAssertEqual(BatchFinishedScreen.overflowHint([.deleteOriginals, .requeueUncertain]),
                       "Delete the originals that have copies, or run the ones you checked in Photos.")
        XCTAssertEqual(BatchFinishedScreen.overflowHint([.retryFailed, .requeueUncertain]),
                       "Try the failed ones again, or run the ones you checked in Photos.")
    }

    func testAnErrorPhotosReportsAfterASaveIsNotAFailureEither() async {
        // A change transaction that fails in Photos' own vocabulary is the error the app cannot
        // place, and it arrives after Photos was handed the copy: the copy may be in the library
        // whatever the error says, so this is the same question the mid-save stop leaves.
        let fixture = BatchFixture(assets: [asset("a", bytes: 1_000)])
        fixture.photos.saveRawError = NSError(domain: "PHPhotosErrorDomain", code: -1)
        await scan(fixture)
        fixture.batch.beginSelecting()
        fixture.batch.selectAll()
        fixture.batch.start()
        await eventually { fixture.batch.phase == .finished }

        XCTAssertEqual(fixture.batch.items.first?.state, BatchItemState.needsCheck)
        XCTAssertEqual(fixture.batch.summary.failedCount, 0)
        XCTAssertEqual(fixture.batch.summary.savedCount, 0)
        XCTAssertFalse(fixture.batch.items.contains { $0.state == .failed(.export) },
                       "an unplaceable error is never dressed as an export failure")
        XCTAssertEqual(fixture.batch.midSaveFindings["a"],
                       MidSaveFinding.unresolved(question: PipelineError.save.localizedDescription))
        // The copy remains a question on disk too, in the form a launch reconciles a mid-save stop
        // into rather than a failure it may repeat.
        let stored = fixture.queue.stored?.items.map(\.state) ?? []
        XCTAssertEqual(stored, [BatchQueueRecord.State.needsCheck])
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

    func testAPauseReachesTheExportInFlightAndNotOnlyTheSessionItHandedOver() async {
        // The transcoder cancels only the session running at that instant, and it tries another
        // plan when an attempt fails: that attempt builds a session of its own, and nothing can
        // cancel a session that does not exist yet. What its plan loop reads before it would start
        // one is the cancellation of the task the export runs in, so a stop has to reach that task
        // - which is what the one-video flow's own cancel does.
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

        XCTAssertTrue(fixture.transcoder.workWasStopped,
                      "the stop has to reach the work in flight, not only the session handed to it")
        XCTAssertTrue(fixture.transcoder.cancelCalled)
        // The stopped export was not asked for again, and nothing of it was saved.
        XCTAssertEqual(fixture.transcoder.receivedSettings.count, 1)
        XCTAssertEqual(fixture.batch.summary.pendingCount, 2)
        XCTAssertEqual(fixture.photos.saveCount, 0)
    }

    func testFinishingEarlyAlsoStopsTheExportInFlight() async {
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

        XCTAssertTrue(fixture.transcoder.workWasStopped)
        XCTAssertEqual(fixture.batch.summary.pendingCount, 2)
        XCTAssertEqual(fixture.photos.saveCount, 0)
    }

    func testLowStorageStopsTheRunOnceInsteadOfFailingEveryVideo() async {
        // The check that refuses here is the one the run makes before it has measured anything:
        // the same figure for every video, and nothing the run does to one video changes it.
        // Failing each remaining video would repeat one sentence per item and end on "No copies
        // were saved." The run stops once instead, with every video still waiting.
        let fixture = BatchFixture(assets: [asset("a", bytes: 1_000), asset("b", bytes: 1_000),
                                            asset("c", bytes: 1_000)])
        fixture.files.capacityError = .insufficientStorage
        await scan(fixture)
        fixture.batch.beginSelecting()
        fixture.batch.selectAll()
        fixture.batch.start()
        await eventually { fixture.batch.phase == .paused }

        XCTAssertEqual(fixture.batch.pauseReason, .storage)
        XCTAssertEqual(fixture.batch.summary.failedCount, 0)
        XCTAssertEqual(fixture.batch.summary.savedCount, 0)
        XCTAssertEqual(fixture.batch.summary.pendingCount, 3)
        XCTAssertEqual(fixture.batch.remainingCount, 3)
        XCTAssertEqual(fixture.photos.retrieveCount, 0)
        XCTAssertEqual(fixture.photos.saveCount, 0)
        // Nothing was lost and nothing was called a failure: what reached disk says every video is
        // still waiting for the space it needs.
        XCTAssertEqual(fixture.queue.stored?.items.map(\.state) ?? [],
                       [.pending, .pending, .pending])
    }

    func testASizeSpecificStorageRefusalFailsOnlyTheVideoItMeasured() async {
        // The run's own floor check is let through and the refusal lands on the room for one
        // video's copy, which is a figure measured for that video. A later video may be small
        // enough, so the run carries on and only the video that did not fit fails.
        let fixture = BatchFixture(assets: [asset("a", bytes: 1_000), asset("b", bytes: 1_000)])
        fixture.files.refuseDemand = 2
        fixture.files.capacityError = .insufficientStorage
        await scan(fixture)
        fixture.batch.beginSelecting()
        fixture.batch.selectAll()
        fixture.batch.start()
        await eventually { fixture.batch.phase == .finished }

        XCTAssertNil(fixture.batch.pauseReason)
        XCTAssertEqual(fixture.batch.summary.failedCount, 1)
        XCTAssertEqual(fixture.batch.summary.savedCount, 1)
        XCTAssertEqual(fixture.photos.saveCount, 1)
    }

    func testAStopTheUserDidNotAskForAlwaysExplainsItself() {
        XCTAssertNil(BatchPauseReason.asked.explanation,
                     "a pause the user asked for needs no explanation")
        for reason in BatchPauseReason.allCases where reason != .asked {
            let text = reason.explanation
            XCTAssertNotNil(text, "\(reason) must not rest on a screen that explains nothing")
            XCTAssertFalse(text?.isEmpty ?? true)
        }
        // The storage stop names the figure the check asked for: the working reserve, because
        // nothing has measured a video at the point this check refuses.
        XCTAssertEqual(BatchPauseReason.storage.explanation,
                       PipelineError.insufficientStorageSentence(needed: DiskHeadroom.neededToWrite(nil)))
        XCTAssertTrue(BatchPauseReason.storage.explanation?.contains("some space") ?? false)
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

    func testARefusedVideoIsNamedWithItsReasonAndCanNeverBeSelected() async {
        // What the on-device pass does with a video it read and refused: the video leaves the list a
        // run can pick from and comes back carrying the reason, so the screen can name it.
        let reason = AssetRules.unsupportedFormatReason(isHDR: true, isProRes: false) ?? ""
        XCTAssertFalse(reason.isEmpty, "The rule this test drives must have a sentence")
        let refused = asset("hdr", bytes: 3_000_000_000, unsupported: reason)
        let fixture = BatchFixture(assets: [asset("a", bytes: 3_000_000_000)])
        fixture.scanner.result = LibraryScanResult(assets: [asset("a", bytes: 3_000_000_000)],
                                                   videoCount: 2,
                                                   unsupportedCount: 1,
                                                   unknownSizeCount: 0,
                                                   sizeSource: .reportedByPhotos,
                                                   measuredOnDeviceCount: 0,
                                                   refusedAssets: [refused])
        fixture.batch.scan()
        await eventually { fixture.batch.phase == .scanned }

        XCTAssertEqual(fixture.batch.refusedAssets.map(\.id), ["hdr"])
        XCTAssertEqual(fixture.batch.refusedAssets.first?.unsupportedReason, reason)
        // It is not one of the videos on offer, so no bulk shortcut can reach it.
        XCTAssertEqual(fixture.batch.eligibleAssets.map(\.id), ["a"])

        fixture.batch.beginSelecting()
        fixture.batch.selectAll()
        XCTAssertEqual(fixture.batch.selection, ["a"])
        XCTAssertEqual(fixture.batch.selectableCount, 1)

        // The refused rows carry no button; this is the backstop for anything else that asks.
        fixture.batch.toggle("hdr")
        XCTAssertEqual(fixture.batch.selection, ["a"])
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

    /// A second run counts only its own deletions.
    ///
    /// Everything the finished screen reads is keyed by a video identifier and describes what *one*
    /// run found out, and none of it was cleared when a new run began. So after "Shrink more
    /// videos" the note counted originals the previous run had deleted - "2 originals deleted" over
    /// a run that deleted none, with no rows left to explain the figure, because those items are
    /// not in this run at all. `beginRun` now clears the run's own facts; `restoreQueue` still
    /// restores them, deliberately, because a resumed run is the same run.
    func testASecondRunCountsOnlyItsOwnDeletions() async {
        let fixture = BatchFixture(assets: [asset("a", bytes: 1_000), asset("b", bytes: 1_000)])
        fixture.settings.deletionMode = .afterEachCopy
        await scan(fixture)
        fixture.batch.beginSelecting()
        fixture.batch.selectAll()
        fixture.batch.start()
        await eventually { fixture.batch.phase == .finished }
        XCTAssertEqual(fixture.batch.deletionReport.deleted, 2)
        XCTAssertEqual(fixture.photos.deletedIdentifiers, ["a", "b"])

        // The user starts again and turns deleting off first, which is the arrangement in which a
        // leftover conclusion would be most obviously wrong.
        fixture.settings.deletionMode = .off
        fixture.batch.beginSelecting()
        fixture.batch.selectAll()
        fixture.batch.start()
        await eventually { fixture.batch.phase == .finished }

        XCTAssertEqual(fixture.batch.deletionReport.deleted, 0,
                       "the note describes this run, not the one before it")
        XCTAssertTrue(fixture.batch.deletionOutcomes.isEmpty)
        XCTAssertTrue(fixture.batch.deletableItemIDs.isEmpty)
        XCTAssertEqual(fixture.photos.deletedIdentifiers, ["a", "b"],
                       "and nothing the first run deleted is deleted again")
    }

    /// Originals one run left waiting cannot be deleted by the next one.
    ///
    /// This is the defect the harness under it was written for. A run in "delete as it goes" queues
    /// candidates and flushes them to Photos when it ends - or at the end of the run, whichever
    /// comes first - and pausing leaves that queue holding whatever had been collected. Nothing
    /// cleared it when the next run began and the flush itself asked no question about the mode, so
    /// a later run could delete an original it never named, during a run whose own setting said
    /// deleting was off. The destructive gate still held - a receipt and a fresh look at both
    /// assets are required - but the deletion happened outside any mode the user could see.
    func testOriginalsLeftWaitingByOneRunAreNotDeletedByTheNext() async {
        let fixture = BatchFixture(assets: [asset("a", bytes: 1_000), asset("b", bytes: 1_000)])
        fixture.settings.deletionMode = .afterEachCopy
        // Let the first copy finish, then stop the second export in flight, so the run is paused
        // with an original already queued for Photos.
        fixture.transcoder.holdAfter = 2
        await scan(fixture)
        fixture.batch.beginSelecting()
        fixture.batch.selectAll()
        fixture.batch.start()
        // The second export is the one being held, so by the time the gate opens the first copy
        // has been saved and its original queued.
        await eventually { fixture.transcoder.gate != nil }
        XCTAssertEqual(fixture.photos.saveCount, 1)
        fixture.batch.pause()
        fixture.transcoder.release()
        await eventually { fixture.batch.phase == .paused }

        // Nothing has been deleted yet: the queued original is waiting for the flush at the end.
        XCTAssertTrue(fixture.photos.deletedIdentifiers.isEmpty)

        // "Finish with what's done", turn deleting off, and start again on the same videos.
        fixture.batch.finishNow()
        await eventually { fixture.batch.phase == .finished }
        fixture.transcoder.holdAfter = nil
        fixture.settings.deletionMode = .off
        fixture.batch.beginSelecting()
        fixture.batch.selectAll()
        fixture.batch.start()
        await eventually { fixture.batch.phase == .finished }

        XCTAssertTrue(fixture.photos.deletedIdentifiers.isEmpty,
                      "a run with deleting off cannot delete the last run's waiting originals")
        XCTAssertEqual(fixture.batch.deletionReport.deleted, 0)
    }

    // MARK: - What the screens say while originals are in play

    /// The working screen's shield line follows the mode the run is actually in.
    ///
    /// It read "Original protected" in every mode, including the two that remove originals, and it
    /// said so while the card beneath it drew rows reading "original deleted" - which is the same
    /// mismatch round 10 fixed in the pre-run dialog, on the screen a user watches for the whole of
    /// a long run.
    func testTheWorkingScreensShieldLineFollowsTheDeletionMode() {
        XCTAssertEqual(BatchProcessingScreen.eyebrow(mode: .off, pausing: false), "Original protected")
        XCTAssertEqual(BatchProcessingScreen.eyebrow(mode: .afterEachCopy, pausing: false),
                       "Copy checked first")
        XCTAssertEqual(BatchProcessingScreen.eyebrow(mode: .afterRun, pausing: false),
                       "Copy checked first")
        // A stop says what it is doing, whatever the mode is doing with originals.
        XCTAssertEqual(BatchProcessingScreen.eyebrow(mode: .afterEachCopy, pausing: true),
                       "Pausing safely")
    }

    /// The paused headline does not deny a deletion this run has already made.
    func testThePausedHeadlineDoesNotDenyADeletionThisRunMade() {
        XCTAssertEqual(BatchPausedScreen.pauseHeadline(deletion: DeletionReport()),
                       "Paused.\nNothing was lost.")

        var deleted = DeletionReport()
        deleted.deleted = 2
        let afterDeleting = BatchPausedScreen.pauseHeadline(deletion: deleted)
        XCTAssertFalse(afterDeleting.contains("Nothing was lost"),
                       "the run deleted originals; the headline may not say nothing was lost")

        var uncertain = DeletionReport()
        uncertain.uncertain = 1
        XCTAssertTrue(BatchPausedScreen.pauseHeadline(deletion: uncertain).contains("needs a look"),
                      "an original whose fate is unknown is the one thing to send the user to Photos")
    }

    /// The paused counts account for the copies the run can vouch for, and name the rest.
    ///
    /// The screen read "\(finishedCount) of \(items.count) finished", and a video whose save Photos
    /// never confirmed counts as finished - so a run of one saved, one flagged and one waiting said
    /// "2 of 3 finished. Copies already saved are in Photos", which is a claim about a copy the app
    /// does not know the outcome of.
    func testThePausedCountsDescribeOnlyWhatIsAccountedFor() {
        XCTAssertEqual(BatchPausedScreen.pauseSubhead(saved: 2, total: 3, toCheck: 0),
                       "2 of 3 saved. Copies already saved are in Photos.")
        XCTAssertEqual(BatchPausedScreen.pauseSubhead(saved: 1, total: 3, toCheck: 1),
                       "1 of 3 saved. The copy already saved is in Photos. One more needs a look in Photos.")
        XCTAssertEqual(BatchPausedScreen.pauseSubhead(saved: 1, total: 4, toCheck: 2),
                       "1 of 4 saved. Copies already saved are in Photos. 2 more need a look in Photos.")
    }

    /// The same rule on the screen a run spends its whole life on, which had the same sentence.
    ///
    /// The working screen said "\(finishedCount) of \(items.count) finished", and a video whose save
    /// Photos never confirmed counts as finished - so a run of four saved videos and one question read
    /// "5 of 5 finished" directly above a card whose own row says Photos did not confirm that save.
    func testTheWorkingCountAlsoAccountsForWhatIsStillAQuestion() {
        XCTAssertEqual(BatchProcessingScreen.processingSubhead(finished: 3, total: 5, toCheck: 0),
                       "3 of 5 finished.")
        XCTAssertEqual(BatchProcessingScreen.processingSubhead(finished: 5, total: 5, toCheck: 1),
                       "4 of 5 finished. One more needs a look in Photos.")
        XCTAssertEqual(BatchProcessingScreen.processingSubhead(finished: 4, total: 6, toCheck: 2),
                       "2 of 6 finished. 2 more need a look in Photos.")
    }

    /// The paused screen names a deletion that has happened, and never a state the run has not
    /// reached.
    func testThePausedScreenNamesOnlyDeletionsThatHaveAlreadyHappened() {
        XCTAssertNil(BatchPausedScreen.settledOriginalsNote(DeletionReport()),
                     "a run that has not deleted anything says nothing here")

        var deleted = DeletionReport()
        deleted.deleted = 1
        XCTAssertEqual(BatchPausedScreen.settledOriginalsNote(deleted),
                       "1 original has already been deleted. It sits in Recently Deleted for 30 days.")

        var uncertain = DeletionReport()
        uncertain.uncertain = 2
        XCTAssertEqual(BatchPausedScreen.settledOriginalsNote(uncertain),
                       "2 originals may already have been deleted. Check Photos before running those again.")

        // A run that is merely waiting for a confirmation has not reached anything reportable.
        var waiting = DeletionReport()
        waiting.skipped = 3
        XCTAssertNil(BatchPausedScreen.settledOriginalsNote(waiting))
    }

    /// A kept original says why it was kept, in the policy's own words.
    ///
    /// The row rendered " · original kept" for every refusal and dropped the reason with it, so a
    /// copy that had changed, a copy that had gone, an original Photos could no longer find and a
    /// withdrawn permission all read the same. `docs/BATCH_PHASE.md` promises the reason reaches
    /// this list.
    func testAKeptOriginalSaysWhyItWasKept() {
        let item = BatchItem(asset: asset("a", bytes: 1_000),
                             state: .saved(Savings(originalBytes: 1_000, compressedBytes: 500)))
        let reason = "The copy changed after it was checked, so the original stays."
        let row = BatchFinishedRow(item: item, deletion: .skipped(reason))

        XCTAssertEqual(row.detail, "Saved a smaller copy · original kept. \(reason)")
        // And a deletion that did happen still says just that.
        XCTAssertEqual(BatchFinishedRow(item: item, deletion: .deleted).detail,
                       "Saved a smaller copy · original deleted")
    }

    /// "Finish with what's done" in a deleting mode offers the confirmation that mode promises.
    ///
    /// A paused run has no loop left to take the fresh look the finished screen's offer depends on,
    /// so the candidates it had queued were never re-looked, `deletableItemIDs` came out empty and
    /// the "Delete N originals" control was never drawn - the confirmation became originals that
    /// were simply never deleted, and the note claimed none had qualified. Taking the look here is
    /// the same single look per candidate that the run's own tail takes before it flushes.
    func testFinishingEarlyStillOffersTheConfirmationTheModePromises() async {
        let fixture = BatchFixture(assets: [asset("a", bytes: 1_000), asset("b", bytes: 1_000)])
        fixture.settings.deletionMode = .afterEachCopy
        fixture.transcoder.holdAfter = 2
        await scan(fixture)
        fixture.batch.beginSelecting()
        fixture.batch.selectAll()
        fixture.batch.start()
        await eventually { fixture.transcoder.gate != nil }
        XCTAssertEqual(fixture.photos.saveCount, 1)
        fixture.batch.pause()
        fixture.transcoder.release()
        await eventually { fixture.batch.phase == .paused }

        fixture.batch.finishNow()
        await eventually { fixture.batch.phase == .finished }

        // The original whose copy was made is offered, nothing has been deleted yet, and the note
        // says exactly that rather than claiming no original qualified.
        XCTAssertEqual(fixture.batch.deletableItemIDs, ["a"])
        XCTAssertEqual(fixture.batch.deletionReport.deleted, 0)
        XCTAssertEqual(BatchFinishedScreen.deletionNote(fixture.batch),
                       "1 original is ready to confirm. Nothing has been deleted yet.")
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
        // Nothing left the library: "b" is gone from Photos but is carried as the running job, so
        // it is still present in the result and is not reported as removed.
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
        // There was no earlier listing for anything to leave, but the selection named a video
        // Photos no longer lists, so that one is still reported as gone.
        XCTAssertEqual(reconciliation.removedIdentifiers, ["gone"])
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

        // `running` is everything the run has not finished, so it names the pending video too.
        // Only the ones Photos stopped listing are carried, which the listing assertion below is
        // the real check on.
        XCTAssertEqual(fixture.scanner.reconciledRunning, ["a", "b"])
        // The running job is named to the scanner as one that must keep its identity, so the
        // refreshed listing carries it even though Photos no longer lists it.
        XCTAssertEqual(Set(fixture.batch.scanResult?.assets.map(\.id) ?? []), ["a", "b"])
        // ...and the job itself is untouched, still working on the video it started with.
        XCTAssertEqual(fixture.batch.items.map(\.id), ["a", "b"])
        XCTAssertEqual(fixture.batch.currentID, "a")

        fixture.transcoder.hold = false
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

    /// The first foreground of a fresh install, which is where this flow used to break.
    ///
    /// Nobody has refused anything yet: `PhotoLibraryService.requestAccess()` is what asks, and it
    /// has not run. iOS still sends `didBecomeActive` on the way up, the monitor reports that, and
    /// the model has to tell "not asked yet" from "access was withdrawn" - otherwise a new user
    /// lands on a recovery screen saying Photos access is unavailable, offering a scan they never
    /// asked for, before the app has asked for anything.
    func testTheFirstForegroundBeforeAnythingHasAskedLeavesTheStartScreenAlone() {
        let status = AccessBox(.notDetermined)
        let monitor = LibraryChangeMonitor(authorizationStatus: { status.value })
        let fixture = BatchFixture(assets: [asset("a", bytes: 3_000_000_000)], monitor: monitor)
        XCTAssertEqual(fixture.batch.phase, .start)
        XCTAssertNil(fixture.batch.message)

        // What iOS does: the app becomes active while access is still `.notDetermined`.
        // The fixture builds its view model lazily, and the view model is what wires this monitor
        // up. Touch it first, or the report below has nowhere to go and this test passes because
        // nothing happened rather than because nothing should happen.
        _ = fixture.batch
        monitor.enteredForeground()

        XCTAssertEqual(fixture.batch.phase, .start)
        XCTAssertNil(fixture.batch.message)
        // And nothing was reconciled: with no access there is no library to re-list.
        XCTAssertEqual(fixture.scanner.reconcileCount, 0)
        XCTAssertTrue(fixture.scanner.reconciledSelection.isEmpty)
    }

    /// The other side of the same report: a refusal really is access lost, and the flow says so in
    /// the words that name the route back - Settings, where they can allow access again.
    func testAccessRefusedOnTheWayInStillFailsTheFlow() {
        let monitor = LibraryChangeMonitor(authorizationStatus: { .denied })
        let fixture = BatchFixture(assets: [], monitor: monitor, authorizationStatus: { .denied })

        _ = fixture.batch
        monitor.enteredForeground()

        XCTAssertEqual(fixture.batch.phase, .failed)
        XCTAssertEqual(fixture.batch.message, PipelineError.refusedAccess)
        XCTAssertEqual(fixture.batch.accessBlock, .refused)
    }

    /// A refusal, then the user allows access in Settings and comes back.
    ///
    /// This is the first-run dead end: the grant was reported, but the report reached a refresh
    /// with no library in hand that returned without doing anything, so the failure sentence stayed
    /// on screen and the tap that would have worked was never made. The pass the user asked for is
    /// finished for them instead - which is why the sentence above promises only that the route is
    /// in Settings.
    func testAllowingAccessInSettingsFinishesThePassTheUserAskedFor() async {
        let status = AccessBox(.denied)
        let monitor = LibraryChangeMonitor(authorizationStatus: { status.value })
        let fixture = BatchFixture(assets: [asset("a", bytes: 3_000_000_000)], monitor: monitor,
                                   authorizationStatus: { status.value })

        // The first look, refused: the flow says so, and nothing has been read.
        _ = fixture.batch
        monitor.enteredForeground()
        XCTAssertEqual(fixture.batch.phase, .failed)
        XCTAssertEqual(fixture.batch.message, PipelineError.refusedAccess)
        XCTAssertEqual(fixture.batch.accessBlock, .refused)
        XCTAssertNil(fixture.batch.scanResult)
        XCTAssertTrue(fixture.batch.items.isEmpty)

        // The user allows Photos access in Settings and comes back. The library this pass is about
        // to read has to be there, or the assertions below would pass on an empty listing.
        fixture.scanner.result = LibraryScanResult(assets: fixture.assets,
                                                   videoCount: fixture.assets.count,
                                                   unsupportedCount: 0, unknownSizeCount: 0,
                                                   sizeSource: .reportedByPhotos,
                                                   measuredOnDeviceCount: 0)
        status.value = .authorized
        monitor.enteredForeground()

        await eventually { fixture.batch.phase == .scanned }
        XCTAssertEqual(fixture.batch.scanResult?.assets.map(\.id), ["a"])
        XCTAssertNil(fixture.batch.message)
        XCTAssertNil(fixture.batch.accessBlock)
    }

    /// A device restriction is not a refusal, and reading it as one cost a new user their
    /// introduction: the flow was moved off `.start` before anything had been asked for, so
    /// onboarding never ran and the screen that replaced it sent them to a Photos switch a
    /// restricted device does not show.
    func testASystemRestrictionLeavesAFreshInstallOnItsIntroduction() {
        let monitor = LibraryChangeMonitor(authorizationStatus: { .restricted })
        let fixture = BatchFixture(assets: [], monitor: monitor, authorizationStatus: { .restricted })

        _ = fixture.batch
        monitor.enteredForeground()

        // Nothing has been lost and there is nothing to re-list, so the flow that had no library in
        // hand stays where it was. Onboarding is gated on this phase, and the first look through
        // the library will say what is wrong when the user asks for it.
        XCTAssertEqual(fixture.batch.phase, .start)
        XCTAssertNil(fixture.batch.message)
        XCTAssertNil(fixture.batch.accessBlock)
        XCTAssertEqual(fixture.scanner.reconcileCount, 0)
    }

    /// The same restriction on a flow that has a library in hand: this app cannot read it any more,
    /// so the flow stops - with the truth, because Photos is not on this app's Settings page while
    /// the restriction is on and naming it would send the user to a switch that is not there.
    func testARestrictionWithALibraryInHandStopsTheFlowWithoutNamingASettingThatIsNotThere() async {
        let status = AccessBox(.authorized)
        let monitor = LibraryChangeMonitor(authorizationStatus: { status.value })
        let fixture = BatchFixture(assets: [asset("a", bytes: 3_000_000_000)], monitor: monitor,
                                   authorizationStatus: { status.value })
        await scan(fixture)
        XCTAssertEqual(fixture.batch.phase, .scanned)
        await eventually { !fixture.batch.isRunning }

        // Screen Time or a device manager is turned on while the app is in the background.
        status.value = .restricted
        monitor.enteredForeground()

        await eventually { fixture.batch.phase == .failed }
        XCTAssertEqual(fixture.batch.accessBlock, .restricted)
        XCTAssertEqual(fixture.batch.message, PipelineError.restrictedAccess)
        let sentence = (fixture.batch.message ?? "").lowercased()
        XCTAssertFalse(sentence.contains("settings"),
                       "a restricted device has no Photos switch to send anyone to")
    }

    /// A check stopped by the app leaving the foreground used to return the user to the selection
    /// screen they tapped from, exactly as it was, with nothing said - a tap that appeared to have
    /// done nothing at all.
    func testLeavingTheAppWhileCheckingTheChosenVideosSaysSo() async {
        let probe = BatchMockFormatProbe()
        probe.hold = true
        let fixture = BatchFixture(assets: [asset("a", bytes: 1_000), asset("b", bytes: 1_000)],
                                   formatProbe: probe)
        await scan(fixture)
        fixture.batch.beginSelecting()
        fixture.batch.selectAll()
        fixture.batch.start()
        await eventually { probe.gate != nil }
        XCTAssertEqual(fixture.batch.phase, .scanning)
        XCTAssertEqual(fixture.batch.preflight?.phase, .inspectingFormats)
        XCTAssertNil(fixture.batch.preflightNotice)

        // The user leaves the app while "Checking the videos you picked." is on screen, and the
        // read it was on finishes the video it was holding.
        fixture.batch.enteredBackground()
        probe.release()

        await eventually { fixture.batch.phase == .selecting }
        XCTAssertTrue(fixture.batch.items.isEmpty)
        XCTAssertNil(fixture.batch.preflight)
        XCTAssertNil(fixture.batch.message)
        // The read that was stopped had been handed the videos the user chose, in the library's own
        // order, and nothing about stopping it changed that.
        XCTAssertEqual(probe.read, ["a", "b"])
        XCTAssertEqual(fixture.batch.preflightNotice,
                       "You left BatchShrink while it was checking the videos you picked, so the run stopped before it began. Nothing was changed; tap Shrink to start again.")
        // The notice belongs to that stop alone: a fresh start clears it.
        probe.hold = false
        fixture.batch.start()
        XCTAssertNil(fixture.batch.preflightNotice)
        await eventually { fixture.batch.phase == .finished }
    }

    /// Limited access is readable, so the same first foreground keeps the flow where it is and
    /// only notes that the library is partly unreadable.
    func testLimitedAccessOnTheWayInStaysReadableAndKeepsTheFlow() {
        let monitor = LibraryChangeMonitor(authorizationStatus: { .limited })
        let fixture = BatchFixture(assets: [], monitor: monitor)

        _ = fixture.batch
        monitor.enteredForeground()

        XCTAssertTrue(monitor.canReadLibrary)
        XCTAssertTrue(fixture.batch.limitedAccess)
        XCTAssertEqual(fixture.batch.phase, .start)
        XCTAssertNil(fixture.batch.message)
    }

    /// A library with no videos was told that every video it could see had been refused, right
    /// beside the line saying there were none.
    func testAnEmptyLibraryDoesNotClaimVideosWereRefused() {
        let empty = LibraryScanResult(assets: [], videoCount: 0, unsupportedCount: 0, unknownSizeCount: 0,
                                      sizeSource: .reportedByPhotos, measuredOnDeviceCount: 0)
        let nothing = BatchEmptyNotice(result: empty, limitedAccess: false)
        // The notice used to repeat the summary's headline word for word, so an empty library read
        // "Nothing to shrink yet" twice with only "0 videos in your Photos library." between them.
        // Round 25 gave each the finding it is about; this case pins the empty one.
        XCTAssertEqual(nothing.title, "No videos to shrink")
        XCTAssertTrue(nothing.detail.contains("no videos"))
        XCTAssertFalse(nothing.detail.lowercased().contains("refused"))
        XCTAssertFalse(nothing.detail.lowercased().contains("unsupported"))

        // Nothing visible under limited access is a different fact about the library, so it says so
        // rather than claiming Photos holds no videos at all.
        let limited = BatchEmptyNotice(result: empty, limitedAccess: true)
        XCTAssertTrue(limited.detail.contains("allowed"))
        XCTAssertFalse(limited.detail.lowercased().contains("refused"))

        // The case the sentence was written for is untouched: a library whose videos this app cannot
        // use still says exactly that.
        let allRefused = LibraryScanResult(assets: [], videoCount: 3, unsupportedCount: 3,
                                           unknownSizeCount: 0, sizeSource: .reportedByPhotos,
                                           measuredOnDeviceCount: 0)
        XCTAssertEqual(BatchEmptyNotice(result: allRefused, limitedAccess: false).detail,
                       "Every video BatchShrink can see is unsupported or outside your Photos access.")
    }

    /// The batch flow has no single video to test, and two of the sentences a batch user reads were
    /// written as if it had. A restriction is never answered with a route to a switch a restricted
    /// device does not show.
    func testTheAccessSentencesFitABatchAndARestrictionIsNotSentToSettings() {
        let refused = PipelineError.permissionDenied.localizedDescription
        XCTAssertEqual(refused, PipelineError.refusedAccess)
        XCTAssertFalse(refused.lowercased().contains("test"),
                       "a batch of twenty videos is not one video being tested")
        XCTAssertTrue(refused.contains("your videos"))
        XCTAssertTrue(refused.contains("Settings"))

        // The same failure on a device Screen Time or a device manager holds back. Naming Settings
        // there would send the user to a Photos switch that does not exist, so the sentence names
        // what is really holding access back instead.
        let restricted = PipelineError.accessSentence(restricted: true)
        XCTAssertEqual(restricted, PipelineError.restrictedAccess)
        XCTAssertFalse(restricted.lowercased().contains("settings"))
        XCTAssertNotEqual(restricted, refused)

        // The third sentence that reaches batch rows carried the one-video flow's machinery into
        // them. It reads as this app's own access rule now.
        let unavailable = PipelineError.assetUnavailable.localizedDescription
        XCTAssertFalse(unavailable.contains("system picker"))
        XCTAssertFalse(unavailable.contains("select it again"))
        XCTAssertTrue(unavailable.contains("Settings"))
    }

    // MARK: - The words the batch screens show

    /// The summary promises only what the estimate beside it measured.
    ///
    /// The headline used to count every eligible video: "4 videos can get lighter" including the
    /// ones the card below says will not shrink, and it said it even when nothing had been measured
    /// at all, while that card read "No sizes yet".
    func testTheSummaryHeadlineClaimsOnlyWhatTheEstimateMeasured() {
        XCTAssertEqual(BatchSummaryScreen.summaryHeadline(eligibleCount: 0, estimate: nil),
                       "Nothing to shrink yet.")

        // Nothing measured: the headline says so rather than promising anything about videos
        // nothing has a size for.
        let unmeasured = SavingsEstimate.make(assets: [asset("a", bytes: nil)],
                                              settings: TranscodeSettings(), measured: [])
        XCTAssertFalse(unmeasured.hasNumbers)
        XCTAssertEqual(BatchSummaryScreen.summaryHeadline(eligibleCount: 3, estimate: unmeasured),
                       "No sizes to estimate from yet.")

        // A measured selection nothing is predicted to shrink: the old headline claimed all of it.
        let nothingShrinks = SavingsEstimate.make(assets: [asset("a", bytes: 50_000_000)],
                                                  settings: TranscodeSettings(), measured: [])
        XCTAssertTrue(nothingShrinks.predictsNoSaving)
        XCTAssertEqual(BatchSummaryScreen.summaryHeadline(eligibleCount: 4, estimate: nothingShrinks),
                       "Nothing here is likely to get lighter.")

        // One video of four can get lighter, and the headline names the one rather than the four.
        let one = SavingsEstimate.make(assets: [asset("a", bytes: 3_000_000_000)],
                                       settings: TranscodeSettings(), measured: [])
        XCTAssertEqual(BatchSummaryScreen.summaryHeadline(eligibleCount: 4, estimate: one),
                       "One video can get lighter.")

        let two = SavingsEstimate.make(assets: [asset("a", bytes: 3_000_000_000),
                                                asset("b", bytes: 2_000_000_000)],
                                       settings: TranscodeSettings(), measured: [])
        XCTAssertEqual(BatchSummaryScreen.summaryHeadline(eligibleCount: 4, estimate: two),
                       "2 videos can get lighter.")
    }

    /// The basis caption names the frame-rate scaling only when the arithmetic applied one.
    ///
    /// It read "Planning band 4–8 Mbps, scaled for 30 fps" while 30 fps is the band's own baseline
    /// and the scale for it is 1.0 - a scaling that did not happen - and it said nothing at all
    /// about the 0.8x a measured band at 24 fps gets.
    func testTheBasisCaptionNamesAScalingOnlyWhenThereWasOne() {
        let band = "Planning band 4–8 Mbps"
        let thirty = SavingsEstimate.make(
            assets: [asset("a", bytes: 3_000_000_000)],
            settings: TranscodeSettings(resolution: .hd1080, frameRate: .fps30), measured: [])
        XCTAssertEqual(BatchSummaryScreen.basisText(thirty),
                       "\(band), until this iPhone has measured some.")
        XCTAssertFalse(BatchSummaryScreen.basisText(thirty).contains("30 fps"),
                       "30 fps must stay an implementation detail of the band it is the baseline of")

        let twentyFour = SavingsEstimate.make(
            assets: [asset("a", bytes: 3_000_000_000)],
            settings: TranscodeSettings(resolution: .hd1080, frameRate: .fps24), measured: [])
        XCTAssertEqual(BatchSummaryScreen.basisText(twentyFour),
                       "\(band), scaled for 24 fps.")

        // A measured band is scaled the same way, and its caption named the scaling nowhere.
        let measurements = (0..<3).map { _ in CopyMeasurement(bitsPerSecond: 5_000_000, longEdge: 1_920) }
        let measuredAt24 = SavingsEstimate.make(
            assets: [asset("a", bytes: 3_000_000_000)],
            settings: TranscodeSettings(resolution: .hd1080, frameRate: .fps24), measured: measurements)
        XCTAssertEqual(BatchSummaryScreen.basisText(measuredAt24),
                       "From 3 copies measured on this iPhone, scaled for 24 fps.")
        let measuredAtOriginal = SavingsEstimate.make(
            assets: [asset("a", bytes: 3_000_000_000)],
            settings: TranscodeSettings(), measured: measurements)
        XCTAssertEqual(BatchSummaryScreen.basisText(measuredAtOriginal),
                       "From 3 copies measured on this iPhone.")
    }

    /// The confirmation before a run is the last thing read before work starts.
    ///
    /// It promised a copy "at 4K" for videos that will be copied smaller - `effectiveResolution`
    /// never upscales - and it named neither the ceiling nor the frame-rate choice.
    func testTheConfirmationNamesTheSizeAsACeilingAndTheFrameRateChoice() {
        XCTAssertEqual(
            BatchFlow.confirmationMessage(settings: TranscodeSettings(resolution: .uhd4k, frameRate: .original),
                                          deletion: .off),
            "Each smaller copy is saved to Photos as it finishes, at up to 4K, keeping every frame. Your originals stay exactly where they are.")
        XCTAssertEqual(
            BatchFlow.confirmationMessage(settings: TranscodeSettings(resolution: .hd1080, frameRate: .fps24),
                                          deletion: .afterRun),
            "Each smaller copy is saved to Photos as it finishes, at up to 1080p, targeting 24 fps. \(DeletionMode.afterRun.detail) Deleted originals sit in Recently Deleted for 30 days.")
        XCTAssertEqual(
            BatchFlow.confirmationMessage(settings: TranscodeSettings(resolution: .hd720, frameRate: .fps30),
                                          deletion: .afterEachCopy),
            "Each smaller copy is saved to Photos as it finishes, at up to 720p, targeting 30 fps. \(DeletionMode.afterEachCopy.detail) Deleted originals sit in Recently Deleted for 30 days.")
    }

    /// A selection that will not shrink is a finding, not the figure "Zero KB".
    ///
    /// Both cards that draw the band set that zero in their largest type: the summary under the
    /// heading "ROOM TO RECLAIM", and the quality chooser where the saving goes.
    func testBothEstimateCardsSayThereIsNoSavingRatherThanZero() {
        let estimate = SavingsEstimate.make(assets: [asset("a", bytes: 50_000_000)],
                                            settings: TranscodeSettings(), measured: [])
        XCTAssertTrue(estimate.predictsNoSaving)
        // The figure both cards used to draw, for the record: it is what the formatter makes of a
        // pair of zeroes, which is why the cards branch before they reach it.
        XCTAssertEqual(ShrinkFormat.byteRange(low: estimate.conservativeBytes,
                                              high: estimate.optimisticBytes),
                       ShrinkFormat.bytes(0))
        XCTAssertEqual(EstimateCopy.noSavingHeadline, "No saving expected")
        XCTAssertEqual(EstimateCopy.noSavingNote,
                       "BatchShrink only keeps a copy that comes out smaller than its original, so these videos are likely to be left as they are.")
        // The action bar draws the same band, and it read "Estimated Zero KB smaller" over these
        // videos. It says the same thing the cards do.
        XCTAssertEqual(BatchSelectionScreen.selectionSaving(estimate), EstimateCopy.noSavingHeadline)
        let saving = SavingsEstimate.make(assets: [asset("a", bytes: 3_000_000_000)],
                                         settings: TranscodeSettings(), measured: [])
        XCTAssertTrue(BatchSelectionScreen.selectionSaving(saving).hasPrefix("Estimated "))
        XCTAssertTrue(BatchSelectionScreen.selectionSaving(saving).hasSuffix(" smaller"))
        XCTAssertNotEqual(BatchSelectionScreen.selectionSaving(saving),
                          BatchSelectionScreen.selectionSaving(estimate))
    }

    /// The selection line names the videos its figure covers.
    ///
    /// It read "3 selected · 2.1 GB of originals" where one of the three had no reported size: the
    /// count was the whole selection and the figure was the subtotal of the measurable ones, so the
    /// line claimed a total the selection did not have.
    func testTheSelectionLineNamesTheVideosItsFigureCovers() {
        let estimate = SavingsEstimate.make(assets: [asset("a", bytes: 3_000_000_000),
                                                     asset("b", bytes: 2_000_000_000),
                                                     asset("c", bytes: nil)],
                                            settings: TranscodeSettings(), measured: [])
        XCTAssertEqual(estimate.sizedCount, 2)
        XCTAssertEqual(BatchSelectionScreen.selectionSummary(selectedCount: 3, estimate: estimate),
                       "3 selected · \(ShrinkFormat.bytes(estimate.sizedBytes)) of 2 measured")
    }

    /// A stored `.saved` whose copy is not smaller shows no figure, and says what it found.
    ///
    /// Only a queue file this app did not write can hold one - every path that writes `.saved` is
    /// gated on `isSmaller` - and the row rendered its negative saving as "--1.2 GB" while the
    /// totals card beside it said no smaller copies. A saving of exactly zero rendered as
    /// "-Zero KB", which is the same defect with a tidier number.
    func testAStoredCopyThatIsNotSmallerShowsNoFigureAndSaysSo() {
        let smaller = BatchFinishedRow(item: BatchItem(asset: asset("row", bytes: 200_000_000),
            state: .saved(Savings(originalBytes: 200_000_000, compressedBytes: 50_000_000))))
        XCTAssertEqual(smaller.savingDisplay?.figure, "-\(ShrinkFormat.bytes(150_000_000))")
        XCTAssertEqual(smaller.savingDisplay?.spokenLabel, "\(ShrinkFormat.bytes(150_000_000)) saved")
        XCTAssertTrue(smaller.detail.hasPrefix("Saved a smaller copy"))

        let grown = BatchFinishedRow(item: BatchItem(asset: asset("row", bytes: 200_000_000),
            state: .saved(Savings(originalBytes: 200_000_000, compressedBytes: 250_000_000))))
        XCTAssertNil(grown.savingDisplay, "there is no saving to put in the figure slot")
        XCTAssertTrue(grown.detail.contains("its recorded size is not smaller than the original"))
        XCTAssertFalse(grown.detail.contains("Saved a smaller copy"))

        let unchanged = BatchFinishedRow(item: BatchItem(asset: asset("row", bytes: 200_000_000),
            state: .saved(Savings(originalBytes: 200_000_000, compressedBytes: 200_000_000))))
        XCTAssertNil(unchanged.savingDisplay, "a zero saving is not a saving either")
    }

    /// A space refusal taken at a size the run measured names the room the check asked for.
    ///
    /// The run computed the figure and threw it away, so the row said only that there was not
    /// enough room. The floor refusal that stops a whole run was already explained this way.
    func testASizeSpecificStorageRefusalNamesTheRoomItAskedFor() async throws {
        let fixture = BatchFixture(assets: [asset("a", bytes: 1_000), asset("b", bytes: 1_000)])
        fixture.files.refuseDemand = 2
        fixture.files.capacityError = .insufficientStorage
        await scan(fixture)
        fixture.batch.beginSelecting()
        fixture.batch.selectAll()
        fixture.batch.start()
        await eventually { fixture.batch.phase == .finished }

        // The second demand of the run is the room for the first video's own copy, measured by the
        // verifier's inspect. The second video's own demand is left alone, so it still runs.
        let room = DiskHeadroom.neededToWrite(fixture.verifier.inspectBytes)
        XCTAssertEqual(fixture.batch.storageDemands["a"], room)
        XCTAssertNil(fixture.batch.storageDemands["b"])
        let failed = try XCTUnwrap(fixture.batch.items.first { $0.id == "a" })
        let row = BatchFinishedRow(item: failed, storageDemand: fixture.batch.storageDemands["a"])
        XCTAssertEqual(row.detail, PipelineError.insufficientStorageSentence(needed: room))
        XCTAssertEqual(fixture.batch.summary.failedCount, 1)
        XCTAssertEqual(fixture.batch.summary.savedCount, 1)
    }

    /// An export that runs out of room *after* the copy-room check passed is not described with
    /// that check's figure.
    ///
    /// The check asks for one file plus the reserve, and `DiskHeadroom` says in its own words that a
    /// copy larger than its source "can still run the device out of room inside the encoder". So
    /// this is reachable: the check passes, the encoder then reports the volume full, and the run
    /// holds a figure the phone demonstrably met. Naming it would tell the user this iPhone did not
    /// have room it did have, which is the same class of false attribution the round was fixing. The
    /// figure is dropped the moment the check lets the step through, exactly as the one-video flow
    /// drops its own.
    func testAnExportThatRunsOutOfRoomAfterTheCheckIsNotDescribedWithTheChecksFigure() async throws {
        let fixture = BatchFixture(assets: [asset("a", bytes: 20_000_000)])
        fixture.verifier.inspectBytes = 20_000_000
        fixture.transcoder.error = .insufficientStorage
        await scan(fixture)
        fixture.batch.beginSelecting()
        fixture.batch.selectAll()
        fixture.batch.start()
        await eventually { fixture.batch.phase == .finished }

        XCTAssertEqual(fixture.batch.summary.failedCount, 1)
        XCTAssertNil(fixture.batch.storageDemands["a"],
                     "a check that already passed is not what this failure was about")
        let failed = try XCTUnwrap(fixture.batch.items.first { $0.id == "a" })
        let row = BatchFinishedRow(item: failed, storageDemand: fixture.batch.storageDemands["a"])
        XCTAssertEqual(row.detail, PipelineError.insufficientStorage.localizedDescription)
        XCTAssertNotEqual(
            row.detail,
            PipelineError.insufficientStorageSentence(
                needed: DiskHeadroom.neededToWrite(20_000_000)),
            "the sentence may not name a figure this device met"
        )
    }

    /// The time sample covers the whole attempt, which is what the elapsed subtraction measures.
    ///
    /// The sample used to be the export alone while the elapsed ran from the moment the run started
    /// on the video, so a slow iCloud retrieval was subtracted from a prediction that had never
    /// counted one and the wait could read "a moment" while the copy was still being fetched. A
    /// retrieval that takes time and an export that takes none is exactly the case that separates
    /// the two: a sample of the export alone is a fraction of a millisecond.
    func testTheTimeSampleCoversTheWholeAttemptIncludingTheRetrieval() async throws {
        let fixture = BatchFixture(assets: [asset("a", bytes: 20_000_000)])
        fixture.verifier.inspectBytes = 20_000_000
        fixture.verifier.outputs = [10_000_000]
        // Long enough that the bound below has a wide margin: the assertion is that the sample
        // includes the retrieval, and a transcode-only sample is a fraction of a millisecond, so a
        // 10 ms margin over 60 ms was a flake waiting for a loaded runner rather than a signal.
        fixture.photos.retrievalDelay = .milliseconds(150)
        await scan(fixture)
        fixture.batch.beginSelecting()
        fixture.batch.selectAll()
        fixture.batch.start()
        await eventually { fixture.batch.phase == .finished }

        let sample = try XCTUnwrap(fixture.batch.estimator.samples.first)
        XCTAssertGreaterThan(sample.processingSeconds, 0.05,
                             "the retrieval is part of what waiting for this video is made of")
        XCTAssertEqual(sample.contentSeconds, 120)
    }

    // MARK: - What the screens offer, and where it sits

    /// The finished screen's bar keeps its primary and one secondary, and moves the rest into one
    /// menu; this list decides both what is behind the control and whether it is drawn at all.
    ///
    /// The bar could stack five controls - roughly 304pt, and roughly 450pt at accessibility text
    /// sizes - against a landscape viewport of about 330pt, which left the totals card, the read-back
    /// line and the failure list the sliver at the top. A trigger over an empty menu would be a
    /// control that does nothing, so the presence and the contents have to be the same decision.
    func testTheFinishedBarOffersExactlyTheExtraActionsThatApply() {
        XCTAssertTrue(BatchFinishedScreen.Extra.available(deletableCount: 0, failedCount: 0,
                                                          awaitingUser: 0).isEmpty,
                      "an ordinary run leaves nothing behind the overflow control")
        XCTAssertEqual(BatchFinishedScreen.Extra.available(deletableCount: 4, failedCount: 0, awaitingUser: 0),
                       [.deleteOriginals])
        XCTAssertEqual(BatchFinishedScreen.Extra.available(deletableCount: 0, failedCount: 2, awaitingUser: 0),
                       [.retryFailed])
        XCTAssertEqual(BatchFinishedScreen.Extra.available(deletableCount: 0, failedCount: 0, awaitingUser: 1),
                       [.requeueUncertain])
        // The order is the order they are read in, and all three can apply to one run.
        XCTAssertEqual(BatchFinishedScreen.Extra.available(deletableCount: 4, failedCount: 2, awaitingUser: 1),
                       [.deleteOriginals, .retryFailed, .requeueUncertain])
    }

    /// The sort pill moves under the headline at accessibility text sizes, and not a size earlier.
    ///
    /// "Make room." at `.largeTitle` and the pill shared one row with an 8pt spacer against about
    /// 327pt of usable width. The headline can wrap and the pill's single word cannot, so the order
    /// the grid is in was the thing that truncated - and the grid itself cannot say it.
    func testTheSortPillMovesUnderTheHeadlineAtAccessibilitySizes() {
        for size in [DynamicTypeSize.large, .xLarge, .xxLarge, .xxxLarge] {
            XCTAssertTrue(BatchSelectionScreen.sortSitsBesideHeadline(at: size),
                          "\(size) still has room for the headline and the pill on one line")
        }
        for size in [DynamicTypeSize.accessibility1, .accessibility2, .accessibility3,
                     .accessibility4, .accessibility5] {
            XCTAssertFalse(BatchSelectionScreen.sortSitsBesideHeadline(at: size),
                           "\(size) stacks the pill under the headline")
        }
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
    /// The chosen-video read, when a test wants one. Without it the fixture's scanner is not a
    /// format probe, so a run starts the way it did before the pre-flight existed.
    private let formatProbe: (any OriginalFormatProbing)?
    /// The Photos status the model reads for the one question the monitor cannot answer: refused,
    /// or restricted by something outside the app. The app reads Photos' own; a test says which.
    private let authorizationStatus: () -> PHAuthorizationStatus
    let settings = ShrinkSettings(defaults: UserDefaults(suiteName: "videoshrink.tests.\(UUID().uuidString)")
                                  ?? .standard)
    lazy var batch = BatchViewModel(photos: photos, scanner: scanner, transcoder: transcoder,
                                    verifier: verifier, temporary: files, history: history,
                                    queueStore: queue, screenAwake: screenAwake,
                                    libraryChanges: monitor, settings: settings,
                                    formatProbe: formatProbe,
                                    authorizationStatus: authorizationStatus)

    init(assets: [LibraryAsset], monitor: LibraryChangeMonitor? = nil,
         formatProbe: (any OriginalFormatProbing)? = nil,
         authorizationStatus: (() -> PHAuthorizationStatus)? = nil) {
        self.assets = assets
        self.monitor = monitor ?? LibraryChangeMonitor(authorizationStatus: { .authorized })
        self.formatProbe = formatProbe
        self.authorizationStatus = authorizationStatus ?? { PHPhotoLibrary.authorizationStatus(for: .readWrite) }
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
    /// A failure in Photos' own vocabulary, which is what a failed change transaction looks like
    /// to this app: nothing in `PipelineError` places it.
    var saveRawError: Error?
    var deleteError: PipelineError?
    var retrieveCount = 0
    var holdRetrieval = false
    /// How long a retrieval takes, so a case can drive the work the time estimate has to account
    /// for without a real iCloud download.
    var retrievalDelay: Duration?
    var retrieveGate: CheckedContinuation<Void, Error>?
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
        if let retrievalDelay { try await Task.sleep(for: retrievalDelay) }
        if holdRetrieval { try await withCheckedThrowingContinuation { retrieveGate = $0 } }
        try Task.checkCancellation()
        return RetrievedVideo(asset: AVURLAsset(url: URL(fileURLWithPath: "/mock-\(identifier).mov")),
                              identity: AssetIdentity(originalFilename: "\(identifier).mov"))
    }

    func cancelRetrieval() {
        retrieveGate?.resume(throwing: PipelineError.cancelled)
        retrieveGate = nil
    }

    func save(videoAt url: URL, identity: AssetIdentity) async throws -> String? {
        if let saveRawError { throw saveRawError }
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

/// The chosen-video read: the one call the batch flow makes between the tap on Shrink and the
/// first export. It can be held open so a test can leave the app while it is running, which is what
/// the real service does between the videos it reads.
@MainActor private final class BatchMockFormatProbe: OriginalFormatProbing {
    /// What the media refuses, by identifier. A video absent from here could not be read, which is
    /// not a refusal and leaves it in the run.
    var refusals: [String: String] = [:]
    var hold = false
    var gate: CheckedContinuation<Void, Error>?
    var read: [String] = []

    func refusedByFormat(among assets: [LibraryAsset],
                         progress: @escaping @MainActor (LibraryScanProgress) -> Void) async throws -> [LibraryAsset] {
        progress(LibraryScanProgress(phase: .inspectingFormats, scanned: 0, total: assets.count))
        if hold { try await withCheckedThrowingContinuation { gate = $0 } }
        read = assets.map(\.id)
        return assets.compactMap { asset in refusals[asset.id].map { asset.refusing($0) } }
    }

    /// Lets a held read answer, which is what happens on a device when a read the app stopped
    /// finishes the video it was on.
    func release() {
        gate?.resume(returning: ())
        gate = nil
    }
}

@MainActor private final class BatchMockTranscoder: VideoTranscoding {
    var error: PipelineError?
    var hold = false
    /// Hold every export from the `holdAfter`th call onwards, counting from one. `hold` stops the
    /// first one, which is what most cases want; this exists for the ones that need a run to make
    /// real progress and *then* be stopped while it still has a copy waiting - the state in which a
    /// run can be paused with an original already queued for Photos.
    var holdAfter: Int?
    var cancelCalled = false
    /// Whether the task this export runs in was cancelled while the export was held open. Cancel
    /// reaches only the session running at that instant, and the real service starts another
    /// session after a failed attempt, so this is the signal its plan loop reads before it would
    /// start one: a stop has to reach the task the work runs in, not only the service.
    var workWasStopped = false
    var gate: CheckedContinuation<Void, Never>?
    var receivedSettings: [TranscodeSettings] = []
    var written = URL(fileURLWithPath: "/mock-root/output.mov")

    func transcode(_ source: RetrievedVideo, metadata: VideoMetadata, settings: TranscodeSettings,
                   progress: @escaping @MainActor (Double) -> Void) async throws -> URL {
        receivedSettings.append(settings)
        if let error { throw error }
        let holdsThisCall = hold || (holdAfter.map { receivedSettings.count >= $0 } ?? false)
        if holdsThisCall { await withCheckedContinuation { gate = $0 } }
        workWasStopped = Task.isCancelled
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
    /// The 1-based demand this fake refuses, counting every `requireCapacity` call in one run. A
    /// test uses it to refuse one step's figure rather than every check the run makes; nil refuses
    /// whatever `capacityError` names, which is how the check taken before retrieval behaves on a
    /// full iPhone.
    var refuseDemand: Int?
    var cleanups = 0
    var removed: [String] = []
    private var counter = 0
    private var demands = 0

    func ensureWorkspace() throws {}
    func outputURL() throws -> URL {
        counter += 1
        return URL(fileURLWithPath: "/mock-root/\(counter).mov")
    }
    func remove(_ url: URL) throws { removed.append(url.lastPathComponent) }
    func requireCapacity(for bytes: Int64) throws {
        demands += 1
        if let refuseDemand, demands != refuseDemand { return }
        if let capacityError { throw capacityError }
    }
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
