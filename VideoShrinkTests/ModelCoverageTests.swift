import XCTest
import Foundation
import AVFoundation
import Photos
@testable import VideoShrink

/// Cases for the pure decision-making the other suites leave alone: the savings model, the
/// quality choices, the stored history and its bounds, the failure vocabulary, the queue's
/// on-disk shape, the number formatting the interface shows, and the words the one-video flow
/// fails in.
///
/// Nothing here needs PhotoKit, AVFoundation media, a device or a real library: the inputs are
/// plain values plus one temporary directory.
@MainActor final class ModelCoverageTests: XCTestCase {

    // MARK: - What a measured copy is allowed to say

    func testAMeasurementIsOnlyTrustedInsideItsDocumentedRange() {
        XCTAssertTrue(CopyMeasurement(bitsPerSecond: 5_000_000, longEdge: 1_920).isValid)
        XCTAssertTrue(CopyMeasurement(bitsPerSecond: 250_001, longEdge: 1).isValid)
        XCTAssertTrue(CopyMeasurement(bitsPerSecond: 79_999_999, longEdge: 3_840).isValid)

        // The two exact bounds are the ones the band filter compares against.
        XCTAssertFalse(CopyMeasurement(bitsPerSecond: 250_000, longEdge: 1_920).isValid)
        XCTAssertFalse(CopyMeasurement(bitsPerSecond: 80_000_000, longEdge: 1_920).isValid)

        XCTAssertFalse(CopyMeasurement(bitsPerSecond: 0, longEdge: 1_920).isValid)
        XCTAssertFalse(CopyMeasurement(bitsPerSecond: -5_000_000, longEdge: 1_920).isValid)
        XCTAssertFalse(CopyMeasurement(bitsPerSecond: .nan, longEdge: 1_920).isValid)
        XCTAssertFalse(CopyMeasurement(bitsPerSecond: .infinity, longEdge: 1_920).isValid)
        XCTAssertFalse(CopyMeasurement(bitsPerSecond: 5_000_000, longEdge: 0).isValid)
        XCTAssertFalse(CopyMeasurement(bitsPerSecond: 5_000_000, longEdge: -1_920).isValid)
    }

    func testAMeasuredCopyOnlyRefinesTheBandItWasMeasuredAt() {
        // The tolerance is a twentieth of the long edge, with a floor of eight pixels.
        XCTAssertTrue(CopySizeModel.matches(1_216, resolution: .hd720))
        XCTAssertTrue(CopySizeModel.matches(1_344, resolution: .hd720))
        XCTAssertFalse(CopySizeModel.matches(1_215, resolution: .hd720))
        XCTAssertFalse(CopySizeModel.matches(1_345, resolution: .hd720))

        XCTAssertTrue(CopySizeModel.matches(1_824, resolution: .hd1080))
        XCTAssertTrue(CopySizeModel.matches(2_016, resolution: .hd1080))
        XCTAssertFalse(CopySizeModel.matches(1_823, resolution: .hd1080))
        XCTAssertFalse(CopySizeModel.matches(2_017, resolution: .hd1080))

        XCTAssertTrue(CopySizeModel.matches(3_648, resolution: .uhd4k))
        XCTAssertTrue(CopySizeModel.matches(4_032, resolution: .uhd4k))
        XCTAssertFalse(CopySizeModel.matches(3_647, resolution: .uhd4k))
        XCTAssertFalse(CopySizeModel.matches(4_033, resolution: .uhd4k))

        // A 1080p measurement must never retune the 720p band, or the other way round.
        XCTAssertFalse(CopySizeModel.matches(1_920, resolution: .hd720))
        XCTAssertFalse(CopySizeModel.matches(1_280, resolution: .hd1080))
    }

    func testTheMeasuredBandIsHeldInsideItsDocumentedBounds() {
        let tiny = (0..<3).map { _ in CopyMeasurement(bitsPerSecond: 260_000, longEdge: 1_920) }
        let low = CopySizeModel.make(for: .hd1080, frameRate: .original, measured: tiny)
        XCTAssertEqual(low.basis, .measured(samples: 3, frameRate: .original))
        // 260 kbps less a tenth is 234 kbps, which the floor raises to 250 kbps.
        XCTAssertEqual(low.lowBitsPerSecond, 250_000, accuracy: 0.5)
        XCTAssertEqual(low.highBitsPerSecond, 286_000, accuracy: 0.5)

        let huge = (0..<3).map { _ in CopyMeasurement(bitsPerSecond: 79_000_000, longEdge: 1_920) }
        let high = CopySizeModel.make(for: .hd1080, frameRate: .original, measured: huge)
        XCTAssertEqual(high.lowBitsPerSecond, 71_100_000, accuracy: 1)
        // 79 Mbps plus a tenth is 86.9 Mbps, which the ceiling cuts back to 80 Mbps.
        XCTAssertEqual(high.highBitsPerSecond, 80_000_000, accuracy: 1)
    }

    func testAMeasurementThatCannotBeTrustedNeverRetunesTheBand() {
        let unusable = (0..<5).map { _ in CopyMeasurement(bitsPerSecond: 0, longEdge: 1_920) }
        XCTAssertEqual(CopySizeModel.make(for: .hd1080, frameRate: .original, measured: unusable).basis,
                       .planning(resolution: .hd1080, frameRate: .original))

        // Three usable copies are the threshold, and unusable entries are not counted towards it.
        let usable = (0..<3).map { _ in CopyMeasurement(bitsPerSecond: 5_000_000, longEdge: 1_920) }
        XCTAssertEqual(CopySizeModel.make(for: .hd1080, frameRate: .original,
                                          measured: unusable + usable).basis,
                       .measured(samples: 3, frameRate: .original))
        let two = Array(usable.prefix(2))
        XCTAssertEqual(CopySizeModel.make(for: .hd1080, frameRate: .original, measured: two).basis,
                       .planning(resolution: .hd1080, frameRate: .original))
    }

    // MARK: - The numbers the savings screen shows

    func testTheSavingsBandIsTheOneTheNumbersComeFrom() throws {
        let model = CopySizeModel.make(for: .hd1080, frameRate: .original, measured: [])
        // 120 seconds at the 1080p planning band: 60 MB at the bottom, 120 MB at the top.
        let copy = try XCTUnwrap(model.copyBytes(forDuration: 120))
        XCTAssertEqual(copy.lowerBound, 60_000_000)
        XCTAssertEqual(copy.upperBound, 120_000_000)

        let saving = try XCTUnwrap(model.savings(sourceBytes: 200_000_000, duration: 120))
        XCTAssertEqual(saving.conservativeBytes, 80_000_000)
        XCTAssertEqual(saving.optimisticBytes, 140_000_000)
        XCTAssertTrue(saving.likelyShrinks)

        // A source already smaller than the top of the band cannot be promised anything.
        let noRoom = try XCTUnwrap(model.savings(sourceBytes: 50_000_000, duration: 120))
        XCTAssertEqual(noRoom.conservativeBytes, 0)
        XCTAssertEqual(noRoom.optimisticBytes, 0)
        XCTAssertFalse(noRoom.likelyShrinks)
    }

    func testASavingIsOnlyPromisedWhenBothNumbersAreUsable() {
        let model = CopySizeModel.make(for: .hd1080, frameRate: .original, measured: [])
        XCTAssertNil(model.savings(sourceBytes: 0, duration: 120))
        XCTAssertNil(model.savings(sourceBytes: -1, duration: 120))
        XCTAssertNil(model.savings(sourceBytes: 200_000_000, duration: 0))
        XCTAssertNil(model.savings(sourceBytes: 200_000_000, duration: -120))
        XCTAssertNil(model.savings(sourceBytes: 200_000_000, duration: .nan))
        XCTAssertNil(model.savings(sourceBytes: 200_000_000, duration: .infinity))
        XCTAssertNil(model.copyBytes(forDuration: 0))
        XCTAssertNil(model.copyBytes(forDuration: -1))
        XCTAssertNil(model.copyBytes(forDuration: .nan))
        XCTAssertNil(model.copyBytes(forDuration: .infinity))
    }

    /// Before this change the two conversions inside `copyBytes(forDuration:)` trapped - aborting
    /// the whole test process rather than failing a case - so a duration this large could not even
    /// be written into a test. It can now, and it is refused instead.
    func testACopySizeTooLargeForAnInt64IsRefusedInsteadOfTrapping() {
        let model = CopySizeModel.make(for: .uhd4k, frameRate: .original, measured: [])
        // 24 Mbps over 1e18 seconds is about 3e24 bytes, far past Int64.max's 9.2e18.
        XCTAssertNil(model.copyBytes(forDuration: 1e18))
        XCTAssertNil(model.savings(sourceBytes: 1_000, duration: 1e18))
        XCTAssertNil(model.copyBytes(forDuration: .greatestFiniteMagnitude))
        // A duration that only looks huge is still answered: the guard is about the range of the
        // result, not about how big the duration is. 12 Mbps over 1e9 seconds is 1.5e15 bytes.
        XCTAssertEqual(model.copyBytes(forDuration: 1e9)?.lowerBound, 1_500_000_000_000_000)
    }

    func testEstimatedCopyBytesAndAggregatesComeFromTheSameBand() {
        let big = coverageAsset("big", bytes: 200_000_000)
        let unsized = coverageAsset("unsized", bytes: nil)
        let edited = coverageAsset("edited", bytes: 200_000_000, unsupported: "Not supported yet.")
        let zeroLength = coverageAsset("zero", bytes: 200_000_000, duration: 0)

        let estimate = SavingsEstimate.make(assets: [big, unsized, edited, zeroLength],
                                            settings: TranscodeSettings(),
                                            measured: [])
        XCTAssertEqual(estimate.sizedCount, 1)
        XCTAssertEqual(estimate.sizedBytes, 200_000_000)
        XCTAssertEqual(estimate.conservativeBytes, 80_000_000)
        XCTAssertEqual(estimate.optimisticBytes, 140_000_000)
        XCTAssertEqual(estimate.likelyNoReductionCount, 0)
        XCTAssertTrue(estimate.hasNumbers)
        XCTAssertEqual(estimate.basis, .planning(resolution: .hd1080, frameRate: .original))
        XCTAssertEqual(estimate.basis.frameRate, .original)
        // The midpoint of the band is what the "copies about" line shows.
        XCTAssertEqual(estimate.estimatedCopyBytes, 90_000_000)
    }

    /// The copy figure describes copies, so a video the estimate expects to skip is not counted in
    /// it at its own full size.
    ///
    /// This case used to pin the opposite. The 50 MB original here is smaller than the bottom of
    /// the 1080p band, so the run is expected to skip it and make no copy of it at all; the old
    /// arithmetic still added its 250 MB selection to the "copies about" figure and then took the
    /// average saving off the whole sum, which reported 140 MB of copies where the one copy the
    /// band describes is 60-120 MB. The saving figures are unchanged: what changed is which
    /// originals the copy figure is about.
    func testAVideoThatCannotShrinkIsNotCountedInTheCopyFigure() {
        let big = coverageAsset("big", bytes: 200_000_000)
        let small = coverageAsset("small", bytes: 50_000_000)
        let estimate = SavingsEstimate.make(assets: [big, small], settings: TranscodeSettings(),
                                            measured: [])
        XCTAssertEqual(estimate.sizedCount, 2)
        XCTAssertEqual(estimate.sizedBytes, 250_000_000)
        XCTAssertEqual(estimate.conservativeBytes, 80_000_000)
        XCTAssertEqual(estimate.optimisticBytes, 140_000_000)
        XCTAssertEqual(estimate.likelyNoReductionCount, 1)
        XCTAssertEqual(estimate.mayShrinkCount, 2,
                       "both videos have room at the top of the band, so both may get a copy")
        // Only the 200 MB original is expected to get a copy, so the copy figure is its 90 MB
        // midpoint and not the 140 MB that counting the skipped video's original produced.
        XCTAssertEqual(estimate.copiedBytes, 200_000_000)
        XCTAssertEqual(estimate.estimatedCopyBytes, 90_000_000)
        XCTAssertLessThan(estimate.estimatedCopyBytes, estimate.sizedBytes)
        XCTAssertFalse(estimate.predictsNoSaving)
    }

    /// The copy figure is about copies, so a video whose copy may still come out smaller stays in
    /// it even when the conservative end of its band promises nothing.
    ///
    /// This is the boundary the case above must not cross the other way: excluding a video that
    /// might shrink would understate the copies the run makes, and including one whose whole band
    /// is above its original was the defect. 70 MB sits inside the 1080p band's 60-120 MB, so only
    /// the optimistic end has room for a saving.
    func testAVideoThatMightStillShrinkStaysInTheCopyFigure() {
        let borderline = coverageAsset("borderline", bytes: 70_000_000)
        let estimate = SavingsEstimate.make(assets: [borderline], settings: TranscodeSettings(),
                                            measured: [])
        XCTAssertEqual(estimate.likelyNoReductionCount, 1)
        XCTAssertEqual(estimate.mayShrinkCount, 1,
                       "the loose end of the band is what says whether there is anything here")
        XCTAssertEqual(estimate.copiedBytes, 70_000_000, "a copy may still be made for it")
        // 70 MB less the 5 MB of average saving at the middle of its own band.
        XCTAssertEqual(estimate.estimatedCopyBytes, 65_000_000)
        XCTAssertLessThan(estimate.estimatedCopyBytes, 70_000_000,
                          "the copy figure is never larger than the original it copies")
        XCTAssertFalse(estimate.predictsNoSaving, "one end of the band still has room")
    }

    /// The headline and the card under it are about the same estimate, so they must agree.
    ///
    /// They read opposite ends of the band for a round. A single borderline video - one whose band
    /// straddles its own size, which the case above builds - counts as "no reduction" at the
    /// conservative end and as a copy at the optimistic one, so the headline announced "Nothing
    /// here is likely to get lighter" directly above a card reading "up to 10 MB". Both now read the
    /// optimistic end, and the conservative end is what decides the qualifier in the sentence.
    func testTheSummaryHeadlineAgreesWithTheCardBeneathIt() {
        let borderline = coverageAsset("borderline", bytes: 70_000_000)
        let estimate = SavingsEstimate.make(assets: [borderline], settings: TranscodeSettings(),
                                            measured: [])
        XCTAssertFalse(estimate.predictsNoSaving)

        let headline = BatchSummaryScreen.summaryHeadline(eligibleCount: 1, estimate: estimate)
        XCTAssertEqual(headline, "One video might get lighter.",
                       "the card below shows a figure, so the headline cannot deny one")
        XCTAssertFalse(headline.contains("Nothing"),
                       "the headline must not contradict a card that has a saving to show")

        // The other direction, for the same reason: when every video's conservative end is above
        // zero too, there is nothing left to qualify and the sentence says so plainly.
        let clear = SavingsEstimate.make(assets: [coverageAsset("big", bytes: 200_000_000)],
                                         settings: TranscodeSettings(), measured: [])
        XCTAssertEqual(BatchSummaryScreen.summaryHeadline(eligibleCount: 1, estimate: clear),
                       "One video can get lighter.")
        XCTAssertEqual(BatchSummaryScreen.summaryHeadline(eligibleCount: 9, estimate: clear),
                       "One video can get lighter.",
                       "the count is the estimate's, not the library's: one video was sized, so the "
                           + "headline is about one whatever the library holds")

        // And the case the card has nothing to show for at all.
        let none = SavingsEstimate.make(assets: [coverageAsset("small", bytes: 50_000_000)],
                                        settings: TranscodeSettings(), measured: [])
        XCTAssertEqual(BatchSummaryScreen.summaryHeadline(eligibleCount: 1, estimate: none),
                       "Nothing here is likely to get lighter.")
    }

    /// A selection whose whole band is at or above its originals has nothing to save, and the two
    /// cards that draw it say so. Before this they drew the formatter's rendering of a single zero
    /// - "Zero KB" - in the largest type on the screen, under the heading "ROOM TO RECLAIM".
    func testAnEstimateWithNothingToSaveIsOneTheCardsCanSaySoAbout() {
        let small = coverageAsset("small", bytes: 50_000_000)
        let estimate = SavingsEstimate.make(assets: [small], settings: TranscodeSettings(),
                                            measured: [])
        XCTAssertTrue(estimate.hasNumbers, "a size was reported; there is simply nothing to save")
        XCTAssertTrue(estimate.predictsNoSaving)
        XCTAssertEqual(estimate.conservativeBytes, 0)
        XCTAssertEqual(estimate.optimisticBytes, 0)
        XCTAssertEqual(estimate.estimatedCopyBytes, 0, "no copy is expected, so no bytes are")
        XCTAssertEqual(estimate.mayShrinkCount, 0)

        // An estimate with no videos in it at all is a different thing, and the cards say
        // something different about it: nothing has been measured rather than nothing being saved.
        XCTAssertFalse(SavingsEstimate.make(assets: [], settings: TranscodeSettings(),
                                            measured: []).predictsNoSaving)
    }

    func testAnEmptyEstimateSaysNothingRatherThanZero() {
        let empty = SavingsEstimate.make(assets: [], settings: TranscodeSettings(), measured: [])
        XCTAssertFalse(empty.hasNumbers)
        XCTAssertEqual(empty.sizedCount, 0)
        XCTAssertEqual(empty.sizedBytes, 0)
        XCTAssertEqual(empty.conservativeBytes, 0)
        XCTAssertEqual(empty.optimisticBytes, 0)
        XCTAssertEqual(empty.likelyNoReductionCount, 0)
        XCTAssertEqual(empty.estimatedCopyBytes, 0)
        XCTAssertEqual(empty.basis, .planning(resolution: .hd1080, frameRate: .original))
    }

    /// A mixed selection uses more than one band, and only one can be named. Before this change
    /// the last sized video won, so the same selection reversed claimed a different band: the
    /// first assertion below read `.planning(resolution: .uhd4k)`.
    func testTheEstimateNamesTheBandThatHoldsMostOfTheBytes() {
        let fourK = TranscodeSettings(resolution: .uhd4k, frameRate: .original)
        // Three 1080p originals at 200 MB each against one 4K original at 50 MB. The 4K setting
        // is not what a 1080p original gets: it is copied at its own nearest size, 1080p.
        let first = coverageAsset("a", bytes: 200_000_000)
        let second = coverageAsset("b", bytes: 200_000_000)
        let third = coverageAsset("c", bytes: 200_000_000)
        let big = coverageAsset("d", bytes: 50_000_000, width: 3_840, height: 2_160)

        let forward = SavingsEstimate.make(assets: [first, second, third, big],
                                           settings: fourK, measured: [])
        let reversed = SavingsEstimate.make(assets: [big, third, second, first],
                                            settings: fourK, measured: [])
        XCTAssertEqual(forward.basis, .planning(resolution: .hd1080, frameRate: .original),
                       "Most of the bytes are copied at 1080p, so that is the band to name")
        XCTAssertEqual(reversed.basis, forward.basis,
                       "Reversing the same selection cannot change what the caption claims")
        // The caption changed; the numbers it explains did not.
        XCTAssertEqual(reversed.sizedCount, forward.sizedCount)
        XCTAssertEqual(reversed.sizedBytes, forward.sizedBytes)
        XCTAssertEqual(reversed.conservativeBytes, forward.conservativeBytes)
        XCTAssertEqual(reversed.optimisticBytes, forward.optimisticBytes)
    }

    /// An exact tie in bytes is settled by the band itself, so the same selection always gets the
    /// same caption. The larger band is the one named.
    func testATieInBytesIsSettledByTheBandRatherThanByTheOrder() {
        let fourK = TranscodeSettings(resolution: .uhd4k, frameRate: .original)
        let hd = coverageAsset("hd", bytes: 100_000_000)
        let big = coverageAsset("4k", bytes: 100_000_000, width: 3_840, height: 2_160)
        let forward = SavingsEstimate.make(assets: [hd, big], settings: fourK, measured: [])
        let reversed = SavingsEstimate.make(assets: [big, hd], settings: fourK, measured: [])
        XCTAssertEqual(forward.basis, .planning(resolution: .uhd4k, frameRate: .original))
        XCTAssertEqual(reversed.basis, forward.basis)
    }

    /// The addition operator this once also covered was removed as dead code: the app totals a
    /// selection by accumulating two fields inside `SavingsEstimate.make`, not by adding
    /// `AssetSavings` values. What is still worth pinning is the rule below, so it survives here.
    func testASavingOnlyCountsWhenTheConservativeEndShrinks() {
        XCTAssertTrue(AssetSavings(conservativeBytes: 1, optimisticBytes: 1).likelyShrinks)
        XCTAssertFalse(AssetSavings(conservativeBytes: 0, optimisticBytes: 400).likelyShrinks)
    }

    // MARK: - Quality choices

    func testTheDefaultQualityIsTheOneTheAppShipsWith() {
        XCTAssertEqual(TranscodeSettings.standard.resolution, .hd1080)
        XCTAssertEqual(TranscodeSettings.standard.frameRate, .original)
        XCTAssertEqual(TranscodeSettings.standard.codec, .hevc)
        XCTAssertEqual(TranscodeSettings().resolution, .hd1080)
        XCTAssertEqual(TranscodeSettings().frameRate, .original)
    }

    func testEveryResolutionKeepsItsOwnSizeCodecAndPreset() {
        XCTAssertEqual(CopyResolution.allCases.count, 3)
        XCTAssertEqual(CopyResolution.hd720.longEdge, 1_280)
        XCTAssertEqual(CopyResolution.hd1080.longEdge, 1_920)
        XCTAssertEqual(CopyResolution.uhd4k.longEdge, 3_840)
        XCTAssertEqual(CopyResolution.hd720.codec, .h264)
        XCTAssertEqual(CopyResolution.hd1080.codec, .hevc)
        XCTAssertEqual(CopyResolution.uhd4k.codec, .hevc)
        XCTAssertEqual(CopyResolution.hd720.title, "720p")
        XCTAssertEqual(CopyResolution.hd1080.title, "1080p")
        XCTAssertEqual(CopyResolution.uhd4k.title, "4K")
        // The preset each size exports with is what the copy is checked against afterwards.
        XCTAssertEqual(CopyResolution.hd720.presetName, AVAssetExportPreset1280x720)
        XCTAssertEqual(CopyResolution.hd1080.presetName, AVAssetExportPresetHEVC1920x1080)
        XCTAssertEqual(CopyResolution.uhd4k.presetName, AVAssetExportPresetHEVC3840x2160)
    }

    func testASourceIsRoundedDownToTheNearestSupportedSize() {
        XCTAssertEqual(CopyResolution.nearest(longEdge: 3_840), .uhd4k)
        XCTAssertEqual(CopyResolution.nearest(longEdge: 2_561), .uhd4k)
        XCTAssertEqual(CopyResolution.nearest(longEdge: 2_560), .hd1080)
        XCTAssertEqual(CopyResolution.nearest(longEdge: 1_920), .hd1080)
        XCTAssertEqual(CopyResolution.nearest(longEdge: 1_601), .hd1080)
        XCTAssertEqual(CopyResolution.nearest(longEdge: 1_600), .hd720)
        XCTAssertEqual(CopyResolution.nearest(longEdge: 1_280), .hd720)
        XCTAssertEqual(CopyResolution.nearest(longEdge: 0), .hd720)
    }

    func testTheFrameRateChoicesAreTheThreeTheInterfaceOffers() {
        XCTAssertEqual(FrameRateOption.allCases.count, 3)
        XCTAssertEqual(FrameRateOption.original.title, "Keep original")
        XCTAssertEqual(FrameRateOption.fps30.title, "30 fps")
        XCTAssertEqual(FrameRateOption.fps24.title, "24 fps")
        XCTAssertEqual(FrameRateOption.original.shortTitle, "Original")
        XCTAssertEqual(FrameRateOption.fps30.shortTitle, "30 fps")
        XCTAssertEqual(FrameRateOption.fps24.shortTitle, "24 fps")
        XCTAssertNil(FrameRateOption.original.framesPerSecond)
        XCTAssertEqual(FrameRateOption.fps30.framesPerSecond, 30.0)
        XCTAssertEqual(FrameRateOption.fps24.framesPerSecond, 24.0)
    }

    func testAFrameRateIsOnlyLoweredAndOnlyWhenItIsWorthIt() {
        let thirty = TranscodeSettings(resolution: .hd1080, frameRate: .fps30)
        XCTAssertNil(thirty.targetFrameRate(sourceFrameRate: 30))
        XCTAssertNil(thirty.targetFrameRate(sourceFrameRate: 30.4))
        // Half a frame below the target is already too close to be worth a re-render.
        XCTAssertNil(thirty.targetFrameRate(sourceFrameRate: 30.5))
        XCTAssertEqual(thirty.targetFrameRate(sourceFrameRate: 30.6), 30)
        XCTAssertEqual(thirty.targetFrameRate(sourceFrameRate: 60), 30)
        XCTAssertNil(thirty.targetFrameRate(sourceFrameRate: 0))
        XCTAssertNil(thirty.targetFrameRate(sourceFrameRate: -30))
        XCTAssertNil(thirty.targetFrameRate(sourceFrameRate: .nan))
        XCTAssertNil(TranscodeSettings(resolution: .hd1080, frameRate: .original)
            .targetFrameRate(sourceFrameRate: 60))

        let twentyFour = TranscodeSettings(resolution: .hd1080, frameRate: .fps24)
        XCTAssertEqual(twentyFour.targetFrameRate(sourceFrameRate: 60), 24)
        XCTAssertNil(twentyFour.targetFrameRate(sourceFrameRate: 24))
    }

    func testASourceWithNoKnownSizeIsEstimatedAsTheSmallestOption() {
        // A video Photos reported no pixel size for arrives as 0x0. The estimate falls back to
        // the smallest band rather than assuming the largest one.
        let unknown = coverageAsset("unknown-size", bytes: 200_000_000, width: 0, height: 0)
        XCTAssertEqual(unknown.longEdge, 0)
        XCTAssertEqual(TranscodeSettings().effectiveResolution(sourceLongEdge: 0), .hd720)
        XCTAssertEqual(TranscodeSettings(resolution: .uhd4k, frameRate: .original)
            .effectiveResolution(sourceLongEdge: 0), .hd720)

        let estimate = SavingsEstimate.make(assets: [unknown], settings: TranscodeSettings(), measured: [])
        XCTAssertEqual(estimate.sizedCount, 1)
        XCTAssertEqual(estimate.basis, .planning(resolution: .hd720, frameRate: .original))
        XCTAssertGreaterThan(estimate.conservativeBytes, 0)
    }

    func testALowerFrameRateShrinksTheEstimateByAFifth() {
        XCTAssertEqual(CopySizeModel.frameRateScale(.original), 1.0)
        XCTAssertEqual(CopySizeModel.frameRateScale(.fps30), 1.0)
        XCTAssertEqual(CopySizeModel.frameRateScale(.fps24), 0.8, accuracy: 0.0001)
    }

    /// Only a frame rate that moves the band is named beside it.
    ///
    /// The caption read "scaled for 30 fps" while the band is documented as a 30 fps band and the
    /// scale for 30 fps is 1.0, so it claimed a scaling that never happened - and it said nothing
    /// about the 0.8x a measured band at 24 fps gets. The choice travels inside the basis, so the
    /// caption reads the same value the arithmetic scaled with.
    func testAFrameRateIsNamedOnlyWhenItActuallyScalesTheBand() {
        XCTAssertFalse(CopySizeModel.frameRateScales(.original))
        XCTAssertFalse(CopySizeModel.frameRateScales(.fps30),
                       "30 fps is this band's own baseline, so nothing was scaled for it")
        XCTAssertTrue(CopySizeModel.frameRateScales(.fps24))

        let planningThirty = CopySizeModel.make(for: .hd1080, frameRate: .fps30, measured: [])
        XCTAssertEqual(planningThirty.basis, .planning(resolution: .hd1080, frameRate: .fps30))
        XCTAssertNil(planningThirty.basis.frameRateScaling)

        let planningTwentyFour = CopySizeModel.make(for: .hd1080, frameRate: .fps24, measured: [])
        XCTAssertEqual(planningTwentyFour.basis.frameRateScaling, "scaled for 24 fps")
        XCTAssertEqual(planningTwentyFour.highBitsPerSecond, 6_400_000, accuracy: 1)

        // A measured band is scaled the same way, and its basis carries the choice too.
        let measurements = (0..<3).map { _ in CopyMeasurement(bitsPerSecond: 5_000_000, longEdge: 1_920) }
        let measured = CopySizeModel.make(for: .hd1080, frameRate: .fps24, measured: measurements)
        XCTAssertEqual(measured.basis, .measured(samples: 3, frameRate: .fps24))
        XCTAssertEqual(measured.basis.frameRateScaling, "scaled for 24 fps")
        XCTAssertEqual(measured.highBitsPerSecond, 5_500_000 * 0.8, accuracy: 1)
    }

    // MARK: - Stored choices

    func testANewDeviceStartsWithTheSafeDefaults() throws {
        let name = "videoshrink.coverage.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = ShrinkSettings(defaults: defaults)

        XCTAssertEqual(settings.resolution, .hd1080)
        XCTAssertEqual(settings.frameRate, .original)
        // The one default that must never flip on by itself.
        XCTAssertEqual(settings.deletionMode, .off)
        XCTAssertFalse(settings.keepScreenAwake)
        XCTAssertEqual(settings.transcode.resolution, .hd1080)
        XCTAssertEqual(settings.transcode.frameRate, .original)
    }

    func testAStoredChoiceIsReadBackAndAnUnknownOneFallsBack() throws {
        let name = "videoshrink.coverage.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }

        let chosen = ShrinkSettings(defaults: defaults)
        chosen.resolution = .hd720
        chosen.frameRate = .fps24
        chosen.deletionMode = .afterRun
        chosen.keepScreenAwake = true

        let reloaded = ShrinkSettings(defaults: defaults)
        XCTAssertEqual(reloaded.resolution, .hd720)
        XCTAssertEqual(reloaded.frameRate, .fps24)
        XCTAssertEqual(reloaded.deletionMode, .afterRun)
        XCTAssertTrue(reloaded.keepScreenAwake)

        // These two keys are the stored contract, so writing to them proves the fallback below is
        // reading the same place the app writes.
        defaults.set("hd2160", forKey: "shrink.resolution")
        defaults.set("delete-everything", forKey: "shrink.deletionMode")
        let repaired = ShrinkSettings(defaults: defaults)
        XCTAssertEqual(repaired.resolution, .hd1080)
        XCTAssertEqual(repaired.deletionMode, .off)
        XCTAssertEqual(repaired.frameRate, .fps24)
    }

    // MARK: - On-device history

    func testTheIdentifierListDropsItsOldestAndMovesARepeatToTheEnd() throws {
        let name = "videoshrink.coverage.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = UserDefaultsShrinkHistoryStore(defaults: defaults)
        let limit = UserDefaultsShrinkHistoryStore.identifierLimit
        XCTAssertGreaterThan(limit, 1)

        for index in 0..<limit {
            store.record(identifier: "id-\(index)", measurement: nil)
        }
        XCTAssertEqual(store.completedIdentifiers().count, limit)

        // Re-recording moves an identifier to the end, so it outlives the next eviction.
        store.record(identifier: "id-0", measurement: nil)
        XCTAssertEqual(store.completedIdentifiers().count, limit)
        store.record(identifier: "newest", measurement: nil)

        let kept = store.completedIdentifiers()
        XCTAssertEqual(kept.count, limit)
        XCTAssertTrue(kept.contains("id-0"))
        XCTAssertTrue(kept.contains("newest"))
        XCTAssertFalse(kept.contains("id-1"))
    }

    func testAStoredMeasurementThatCannotBeReadIsSkippedRatherThanLosingTheRest() throws {
        let name = "videoshrink.coverage.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        // A shape a future version might leave, or a hand-edited defaults file.
        let words: [String] = ["not", "a", "pair"]
        let pair: [Int] = [5_000_000, 1_920]
        let tooShort: [Int] = [1]
        let otherWords: [String] = ["x", "y"]
        let stored: [Any] = [words, pair, tooShort, otherWords]
        defaults.set(stored, forKey: "shrink.copyMeasurements")

        let store = UserDefaultsShrinkHistoryStore(defaults: defaults)
        let kept = store.copyMeasurements()
        XCTAssertEqual(kept.count, 1)
        XCTAssertEqual(kept.first?.bitsPerSecond, 5_000_000)
        XCTAssertEqual(kept.first?.longEdge, 1_920)
    }

    // MARK: - Failures and their wording

    func testADiskFullErrorIsRecognisedThroughEveryDomainItArrivesIn() {
        XCTAssertEqual(PipelineError.normalize(NSError(domain: NSCocoaErrorDomain,
                                                       code: NSFileWriteOutOfSpaceError),
                                               fallback: .export), .insufficientStorage)
        XCTAssertEqual(PipelineError.normalize(NSError(domain: NSPOSIXErrorDomain, code: 28),
                                               fallback: .export), .insufficientStorage)
        XCTAssertEqual(PipelineError.normalize(NSError(domain: AVFoundationErrorDomain,
                                                       code: AVError.diskFull.rawValue),
                                               fallback: .export), .insufficientStorage)
        // The same number in another domain does not mean "no space".
        XCTAssertEqual(PipelineError.normalize(NSError(domain: "SomeOtherDomain", code: 28),
                                               fallback: .export), .export)
        XCTAssertEqual(PipelineError.normalize(NSError(domain: NSURLErrorDomain, code: 28),
                                               fallback: .save), .save)
    }

    func testAKnownErrorIsNeverReplacedByTheCallersGuess() {
        XCTAssertEqual(PipelineError.normalize(PipelineError.verification, fallback: .save), .verification)
        XCTAssertEqual(PipelineError.normalize(PipelineError.insufficientStorage, fallback: .export),
                       .insufficientStorage)
        XCTAssertEqual(PipelineError.normalize(CancellationError(), fallback: .save), .cancelled)
        // Anything the app cannot read becomes the caller's own error rather than silence.
        XCTAssertEqual(PipelineError.normalize(NSError(domain: "Unknown", code: 7),
                                               fallback: .libraryScan), .libraryScan)
    }

    func testTheUnderlyingErrorSearchIsBounded() {
        func wrapped(_ error: NSError, times: Int) -> NSError {
            var current = error
            for _ in 0..<times {
                current = NSError(domain: "Wrapped", code: 1, userInfo: [NSUnderlyingErrorKey: current])
            }
            return current
        }
        let full = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)
        XCTAssertEqual(PipelineError.normalize(wrapped(full, times: 1), fallback: .export),
                       .insufficientStorage)
        XCTAssertEqual(PipelineError.normalize(wrapped(full, times: 7), fallback: .export),
                       .insufficientStorage)
        // The search is capped on purpose, so a longer chain falls back to the caller's error
        // instead of walking an error chain that never ends.
        XCTAssertEqual(PipelineError.normalize(wrapped(full, times: 8), fallback: .export), .export)
    }

    func testEveryFailureTheUserSeesHasItsOwnSentence() {
        // The refusal the media layer decides has no words of its own: it carries `AssetRules`'
        // sentence in, so this checks the sentence comes straight back out.
        let carriedReason = "HDR videos aren't supported yet."
        let carried = PipelineError.unsupportedOriginal(reason: carriedReason)
        XCTAssertEqual(carried.errorDescription, carriedReason,
                       "The case carries the sentence it was given rather than restating it")
        // The other case that carries its sentence in: an export Apple would not build says which
        // quality it asked for and what came back instead of a session, so it comes straight back
        // out here too.
        let carriedExport = PipelineError.exportUnavailable(
            reason: "There's no 4K export for this video on this iPhone.")
        XCTAssertEqual(carriedExport.errorDescription, "There's no 4K export for this video on this iPhone.",
                       "The case carries the sentence it was given rather than restating it")
        let cases: [PipelineError] = [.permissionDenied, .assetUnavailable, .unsupported, .retrieval,
                                      .export, .verification, .durationMismatch, .audioMismatch,
                                      .orientationMismatch, .insufficientStorage, .codecMismatch,
                                      .resolutionMismatch, .frameRateMismatch, .save, .temporaryFiles,
                                      .libraryScan, .cancelled, carried, carriedExport]
        for error in cases {
            let text = error.errorDescription ?? ""
            XCTAssertFalse(text.isEmpty, "This error needs a sentence the user can act on")
            XCTAssertFalse(text.contains("PipelineError"), "The case name must never reach the user")
        }
        // Two failures that share a sentence would tell the user the wrong thing.
        XCTAssertEqual(Set(cases.map(\.errorDescription)).count, cases.count)
    }

    // MARK: - A space refusal says what it asked for

    /// The audit's finding: a storage refusal named no figure at all, so the one thing the user
    /// needs in order to act - how much room this step wanted - was missing from the sentence.
    func testASpaceRefusalStatesTheFigureTheStepAskedFor() {
        let figure = DiskHeadroom.neededToWrite(3_000_000_000)
        let sentence = PipelineError.insufficientStorageSentence(needed: figure)
        XCTAssertTrue(sentence.contains(ShrinkFormat.bytes(figure)),
                      "the figure the check asked for is what makes the refusal actionable")
        XCTAssertTrue(sentence.contains(ShrinkFormat.bytes(DiskHeadroom.reserve)),
                      "the working room inside that figure is named too, so a demand larger than the copy reads as a reason rather than a mystery")
        XCTAssertTrue(sentence.contains("unchanged"), "a refusal that wrote nothing has to say so")
        XCTAssertFalse(sentence.contains("PipelineError"))
        XCTAssertNotEqual(sentence, PipelineError.insufficientStorage.localizedDescription,
                          "a step that holds a figure never falls back to the sentence of one that does not")
    }

    /// Before a video has been measured - before a retrieval whose original may still be in iCloud
    /// - the demand is the working reserve alone, and it is the same figure whatever follows it.
    /// That sameness is the whole reason a run stops on it instead of failing every remaining
    /// video with one repeated sentence.
    func testTheDemandMadeBeforeAnyVideoIsMeasuredIsTheWorkingReserveAlone() {
        let floor = DiskHeadroom.neededToWrite(nil)
        XCTAssertEqual(floor, DiskHeadroom.reserve)
        let sentence = PipelineError.insufficientStorageSentence(needed: floor)
        XCTAssertTrue(sentence.contains(ShrinkFormat.bytes(floor)))
        XCTAssertFalse(sentence.contains("the copy itself"),
                       "nothing has measured a copy at that point, so the sentence must not name one")
        XCTAssertNotEqual(sentence,
                          PipelineError.insufficientStorageSentence(needed: DiskHeadroom.neededToWrite(3_000_000_000)))
    }

    /// The sentence a restored queue and a disk-full error from Photos still show. It names no
    /// figure because nothing at that point holds one, and it stays specific about what to do.
    func testTheSpaceRefusalWithoutAFigureStaysSpecificAboutWhatToDo() {
        let coarse = PipelineError.insufficientStorage.localizedDescription
        XCTAssertTrue(coarse.contains("free some space"))
        XCTAssertTrue(coarse.contains("unchanged"))
        XCTAssertFalse(coarse.contains(ShrinkFormat.bytes(DiskHeadroom.reserve)),
                       "a figure here would be one the queue and Photos cannot back up")
    }

    // MARK: - The one-video flow's own failure wording

    /// The batch flow learned in round 15 that a restriction is not a refusal. The one-video flow
    /// did not, and sent a device held back by Screen Time or a device management profile to a
    /// Photos switch that is not on this app's Settings page.
    func testARestrictedDeviceIsNotSentToASwitchThatIsNotThere() async {
        let refused = OneVideoFixture()
        refused.photos.accessError = .permissionDenied
        refused.model.chooseVideo()
        await eventually { refused.model.stage == .failed }
        XCTAssertEqual(refused.model.message, PipelineError.refusedAccess)

        let restricted = OneVideoFixture(authorizationStatus: { .restricted })
        restricted.photos.accessError = .permissionDenied
        restricted.model.chooseVideo()
        await eventually { restricted.model.stage == .failed }
        XCTAssertEqual(restricted.model.message, PipelineError.restrictedAccess)
        XCTAssertFalse((restricted.model.message ?? "").lowercased().contains("settings"),
                       "a restricted device has no Photos switch to send anyone to")
    }

    /// A space refusal in the one-video flow states the figure the step asked for, and the figure
    /// follows the step that refused rather than the last one that ran.
    func testASpaceRefusalInTheOneVideoFlowStatesTheFigureTheRefusedStepAskedFor() async {
        let floorRefused = OneVideoFixture()
        floorRefused.files.capacityError = .insufficientStorage
        await chooseVideo(floorRefused)
        floorRefused.model.selected(identifier: "a")
        await eventually { floorRefused.model.stage == .failed }
        let floor = DiskHeadroom.neededToWrite(nil)
        XCTAssertEqual(floorRefused.model.message, PipelineError.insufficientStorageSentence(needed: floor))
        XCTAssertEqual(floorRefused.photos.retrieveCount, 0,
                       "a refusal taken before retrieval never asks Photos for anything")

        // The same flow with the floor check let through: the refusal that lands is the one taken
        // after the video was measured, and the sentence names that step's own figure.
        let copyRefused = OneVideoFixture()
        copyRefused.verifier.inspectBytes = 3_000_000_000
        copyRefused.files.refuseDemand = 2
        copyRefused.files.capacityError = .insufficientStorage
        await chooseVideo(copyRefused)
        copyRefused.model.selected(identifier: "a")
        await eventually { copyRefused.model.stage == .failed }
        let copyRoom = DiskHeadroom.neededToWrite(3_000_000_000)
        XCTAssertEqual(copyRefused.model.message, PipelineError.insufficientStorageSentence(needed: copyRoom))
        XCTAssertNotEqual(copyRoom, floor)
        XCTAssertEqual(copyRefused.photos.retrieveCount, 1)
        XCTAssertEqual(copyRefused.photos.saveCount, 0)
    }

    /// The check the save makes on its own, which is the last place a run can be refused for room.
    func testASpaceRefusalAtTheSaveStepNamesThatStepsOwnFigure() async {
        let fixture = OneVideoFixture()
        fixture.verifier.inspectBytes = 3_000_000_000
        await chooseVideo(fixture)
        fixture.model.selected(identifier: "a")
        await eventually { fixture.model.stage == .readyToSave }

        // The two checks before this one were let through, so the demand that refuses is the
        // save's own and not one of theirs.
        fixture.files.refuseDemand = 3
        fixture.files.capacityError = .insufficientStorage
        fixture.model.save()
        await eventually { fixture.model.stage == .failed }

        XCTAssertEqual(fixture.model.message,
                       PipelineError.insufficientStorageSentence(needed: DiskHeadroom.neededToWrite(fixture.verifier.verifiedBytes)))
        XCTAssertEqual(fixture.photos.saveCount, 0,
                       "a refusal before the save never asks Photos to keep anything")
    }

    // MARK: - One item, one row, one summary

    func testAFinishedVideoIsTheOneTheRunWillNotTouchAgain() {
        let finished: [BatchItemState] = [.saved(Savings(originalBytes: 1_000, compressedBytes: 600)),
                                          .skipped("Not smaller"), .failed(.export), .needsCheck]
        for state in finished {
            XCTAssertTrue(state.isFinished, "\(state) is finished")
        }
        let unfinished: [BatchItemState] = [.pending, .retrieving(nil), .retrieving(0.5), .preparing,
                                            .transcoding(nil), .verifying, .saving]
        for state in unfinished {
            XCTAssertFalse(state.isFinished, "\(state) is not finished")
        }
    }

    func testOnlyOneStateMeansPhotosIsMidWriteAndOnlyOneMeansFailure() {
        XCTAssertTrue(BatchItemState.saving.isSaving)
        XCTAssertFalse(BatchItemState.pending.isSaving)
        XCTAssertFalse(BatchItemState.needsCheck.isSaving)
        XCTAssertTrue(BatchItemState.failed(.save).isFailed)
        XCTAssertFalse(BatchItemState.skipped("No").isFailed)
        XCTAssertFalse(BatchItemState.needsCheck.isFailed)
    }

    func testEveryStateTheListCanShowHasItsOwnLabel() {
        let states: [BatchItemState] = [.pending, .retrieving(nil), .preparing, .transcoding(nil),
                                        .verifying, .saving,
                                        .saved(Savings(originalBytes: 1_000, compressedBytes: 600)),
                                        .skipped("Not smaller"), .failed(.export), .needsCheck]
        for state in states {
            XCTAssertFalse(state.title.isEmpty)
        }
        XCTAssertEqual(BatchItemState.pending.title, "Waiting")
        XCTAssertEqual(BatchItemState.saving.title, "Keeping the copy")
        XCTAssertEqual(BatchItemState.needsCheck.title, "Check Photos")
        XCTAssertEqual(Set(states.map(\.title)).count, states.count)
    }

    func testARowIsIdentifiedByTheVideoItIsWorkingOn() {
        let asset = coverageAsset("video-a", bytes: 1_000)
        let item = BatchItem(asset: asset, state: .pending)
        XCTAssertEqual(item.id, "video-a")
        XCTAssertEqual(item.state, .pending)
    }

    func testARunTotalOnlyClaimsSavingsWhenItMeasuredBothSides() {
        var summary = BatchSummary()
        XCTAssertNil(summary.measuredSavings)
        summary.originalBytes = 1_000
        XCTAssertNil(summary.measuredSavings)
        summary.copyBytes = 600
        XCTAssertEqual(summary.measuredSavings, Savings(originalBytes: 1_000, compressedBytes: 600))
        XCTAssertEqual(summary.measuredSavings?.percentage, 40.0)

        summary.copyBytes = 0
        XCTAssertNil(summary.measuredSavings)
        summary.originalBytes = 0
        summary.copyBytes = -5
        XCTAssertNil(summary.measuredSavings)
    }

    func testAReadBackReportCountsBothAnswers() {
        var report = ReadBackReport()
        XCTAssertEqual(report.total, 0)
        report.confirmed = 2
        report.unavailable = 1
        XCTAssertEqual(report.total, 3)
    }

    func testTheDeletionReportAddsUpWhatWasHandled() {
        var report = DeletionReport()
        XCTAssertEqual(report.handled, 0)
        report.deleted = 2
        report.skipped = 1
        report.failed = 3
        report.uncertain = 4
        XCTAssertEqual(report.handled, 10)
    }

    func testTheDiskReserveIsAlwaysKeptBackEvenForAnEmptyRun() {
        XCTAssertEqual(DiskHeadroom.reserve, 256 * 1_024 * 1_024)
        XCTAssertEqual(DiskHeadroom.bytes(0, copies: 0), DiskHeadroom.reserve)
        XCTAssertEqual(DiskHeadroom.bytes(1_000_000_000, copies: 0), DiskHeadroom.reserve)
        XCTAssertEqual(DiskHeadroom.bytes(0, copies: 3), DiskHeadroom.reserve)
        XCTAssertEqual(DiskHeadroom.bytes(1_000_000_000, copies: 2), 2_000_000_000 + DiskHeadroom.reserve)
        // A number this large cannot be a real requirement: it means "refuse", not a wrapped total.
        XCTAssertEqual(DiskHeadroom.bytes(Int64.max, copies: 2), Int64.max)
        XCTAssertEqual(DiskHeadroom.bytes(Int64.max - 1, copies: 1), Int64.max)
    }

    func testTheTimeEstimatorIgnoresSamplesThatCannotBeUseful() {
        var estimator = ProcessingEstimator()
        estimator.record(processingSeconds: -1, contentSeconds: 60)
        estimator.record(processingSeconds: .nan, contentSeconds: 60)
        estimator.record(processingSeconds: .infinity, contentSeconds: 60)
        XCTAssertEqual(estimator.sampleCount, 0)
        XCTAssertFalse(estimator.hasEstimate)
    }

    func testASampleWithNoUsableDurationStillSizesTheNextVideo() throws {
        var estimator = ProcessingEstimator()
        // Half a second is too short to scale from, so this counts as an item with no duration.
        estimator.record(processingSeconds: 2, contentSeconds: 0.5)
        XCTAssertEqual(estimator.sampleCount, 1)
        XCTAssertTrue(estimator.hasEstimate)

        let estimate = try XCTUnwrap(estimator.remainingSeconds(pendingContentSeconds: [60],
                                                               activeContentSeconds: nil,
                                                               activeElapsedSeconds: 0))
        // With no usable ratio the only answer left is the finished item's own time.
        XCTAssertEqual(estimate.lowerBound, 1.2, accuracy: 0.0001)
        XCTAssertEqual(estimate.upperBound, 3.6, accuracy: 0.0001)
    }

    func testTheEstimatorKeepsItsMostRecentSamples() {
        var estimator = ProcessingEstimator()
        for _ in 0..<45 {
            estimator.record(processingSeconds: 10, contentSeconds: 20)
        }
        XCTAssertEqual(estimator.sampleCount, 40)
    }

    func testAPortraitVideoIsMeasuredByItsLongEdge() {
        let portrait = coverageAsset("portrait", bytes: 200_000_000, width: 1_080, height: 1_920)
        XCTAssertEqual(portrait.longEdge, 1_920)
        XCTAssertTrue(portrait.isEligible)
        let restored = portrait.withBytes(nil)
        XCTAssertNil(restored.bytes)
        XCTAssertEqual(restored.id, "portrait")
        XCTAssertEqual(restored.duration, 120)
        XCTAssertEqual(restored.longEdge, 1_920)
        XCTAssertEqual(restored.withBytes(5).bytes, 5)
    }

    // MARK: - The stored queue's shape

    func testAQueueFileTheAppCannotReadIsIgnoredInsteadOfCrashing() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("coverage-queue-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileBatchQueueStore(directory: directory)
        let record = BatchQueueRecord(
            settings: BatchQueueRecord.Settings(resolution: "hd1080", frameRate: "original",
                                                deletion: "off"),
            items: [coverageQueueItem("a")])
        try store.save(record)
        // Reading it back proves where the store keeps its file.
        XCTAssertEqual(store.load(), record)

        let url = directory.appendingPathComponent("VideoShrink", isDirectory: true)
            .appendingPathComponent("queue.json")
        try Data("this is not a queue".utf8).write(to: url)
        XCTAssertNil(store.load())

        // Valid JSON of the wrong shape.
        try Data("[]".utf8).write(to: url)
        XCTAssertNil(store.load())

        // A record missing a field this version requires.
        let incomplete = "{\"version\":1,\"settings\":{\"resolution\":\"hd1080\",\"frameRate\":\"original\"},\"items\":[{\"identifier\":\"a\",\"duration\":120,\"pixelWidth\":1920,\"pixelHeight\":1080}]}"
        try Data(incomplete.utf8).write(to: url)
        XCTAssertNil(store.load())
    }

    func testARestoredItemStillDescribesTheVideoItWasWorkingOn() {
        let item = BatchQueueRecord.Item(identifier: "a", creationDate: nil, duration: 120,
                                         pixelWidth: 3_840, pixelHeight: 2_160, bytes: 900_000_000,
                                         state: .skipped(reason: "Not smaller"))
        let asset = item.asset
        XCTAssertEqual(asset.id, "a")
        XCTAssertEqual(asset.duration, 120)
        XCTAssertEqual(asset.pixelWidth, 3_840)
        XCTAssertEqual(asset.pixelHeight, 2_160)
        XCTAssertEqual(asset.bytes, 900_000_000)
        XCTAssertEqual(asset.longEdge, 3_840)
        // Only videos that were eligible ever reach the queue, so a restored item is eligible.
        XCTAssertTrue(asset.isEligible)
        XCTAssertNil(asset.unsupportedReason)
    }

    func testARestoredQueueIsBroughtUpToThisVersionsShape() {
        var record = BatchQueueRecord(
            settings: BatchQueueRecord.Settings(resolution: "hd720", frameRate: "fps24",
                                                deletion: nil),
            items: [coverageQueueItem("a")])
        record.version = 0
        let reconciled = BatchQueueReconciliation.reconcile(record)
        XCTAssertEqual(reconciled.version, BatchQueueRecord.currentVersion)
        XCTAssertEqual(reconciled.items, record.items)
        // Dropping a queue a user was in the middle of is the one thing the stored version
        // guards, so the version the store accepts must not move without a migration.
        XCTAssertEqual(BatchQueueRecord.currentVersion, 1)
    }

    // MARK: - Identity

    func testAnAssetWithNothingRecordedSaysSo() {
        XCTAssertNil(AssetIdentity.unknown.creationDate)
        XCTAssertNil(AssetIdentity.unknown.originalFilename)
        XCTAssertNil(AssetIdentity.unknown.coordinate)
        XCTAssertFalse(AssetIdentity.unknown.isFavorite)
        XCTAssertFalse(AssetIdentity.unknown.isHidden)
    }

    func testACoordinateIsOnlyUsableInsideTheGlobe() {
        XCTAssertTrue(AssetIdentity.Coordinate(latitude: 90, longitude: 180).isValid)
        XCTAssertTrue(AssetIdentity.Coordinate(latitude: -90, longitude: -180).isValid)
        XCTAssertTrue(AssetIdentity.Coordinate(latitude: 0, longitude: 0).isValid)
        XCTAssertFalse(AssetIdentity.Coordinate(latitude: 90.0001, longitude: 0).isValid)
        XCTAssertFalse(AssetIdentity.Coordinate(latitude: 0, longitude: 180.0001).isValid)
        XCTAssertFalse(AssetIdentity.Coordinate(latitude: .infinity, longitude: 0).isValid)
        XCTAssertFalse(AssetIdentity.Coordinate(latitude: 0, longitude: .nan).isValid)
    }

    // MARK: - The numbers on the screen

    func testARoughDurationStaysRoughAndRoundsAtItsOwnBoundaries() {
        XCTAssertEqual(ShrinkFormat.roughDuration(0), "a moment")
        XCTAssertEqual(ShrinkFormat.roughDuration(-30), "a moment")
        XCTAssertEqual(ShrinkFormat.roughDuration(.nan), "a moment")
        XCTAssertEqual(ShrinkFormat.roughDuration(44), "under a minute")
        XCTAssertEqual(ShrinkFormat.roughDuration(45), "about 1 min")
        XCTAssertEqual(ShrinkFormat.roughDuration(60), "about 1 min")
        XCTAssertEqual(ShrinkFormat.roughDuration(90), "about 2 min")
        XCTAssertEqual(ShrinkFormat.roughDuration(3_540), "about 59 min")
        XCTAssertEqual(ShrinkFormat.roughDuration(3_600), "about 1.0 hr")
        XCTAssertEqual(ShrinkFormat.roughDuration(36_000), "about 10 hr")
    }

    func testAnEstimatedBandCollapsesWhenBothEndsShareAUnit() {
        XCTAssertEqual(ShrinkFormat.durationRange(0...0), "under a minute")
        XCTAssertEqual(ShrinkFormat.durationRange(120...600), "2\u{2013}10 min")
        XCTAssertEqual(ShrinkFormat.durationRange(3_600...7_200), "1.0\u{2013}2.0 hr")
        // Ends that do not share a unit cannot collapse, so the range is spelled out.
        XCTAssertEqual(ShrinkFormat.durationRange(30...600), "under a minute to 10 min")
    }

    func testFrameRateAndDurationFormattingRefuseNonsense() {
        XCTAssertEqual(ShrinkFormat.frameRate(0), "\u{2014}")
        XCTAssertEqual(ShrinkFormat.frameRate(-30), "\u{2014}")
        XCTAssertEqual(ShrinkFormat.frameRate(.nan), "\u{2014}")
        XCTAssertEqual(ShrinkFormat.frameRate(0.5), "\u{2014}")
        XCTAssertEqual(ShrinkFormat.frameRate(0.6), "1 fps")
        XCTAssertEqual(ShrinkFormat.frameRate(29.97), "30 fps")
        XCTAssertEqual(ShrinkFormat.frameRate(24), "24 fps")

        XCTAssertEqual(ShrinkFormat.duration(0), "\u{2014}")
        XCTAssertEqual(ShrinkFormat.duration(.nan), "\u{2014}")
        XCTAssertFalse(ShrinkFormat.duration(150).isEmpty)
        XCTAssertNotEqual(ShrinkFormat.duration(150), "\u{2014}")
        XCTAssertEqual(ShrinkFormat.date(nil), "Undated video")
    }

    func testAByteRangeCollapsesOrSpellsItselfOutWithoutInventingNumbers() {
        XCTAssertEqual(ShrinkFormat.byteRange(low: 0, high: 0), ShrinkFormat.bytes(0))
        XCTAssertEqual(ShrinkFormat.byteRange(low: -1, high: 0), ShrinkFormat.bytes(0))
        XCTAssertEqual(ShrinkFormat.byteRange(low: 100, high: 100), ShrinkFormat.bytes(100))
        XCTAssertTrue(ShrinkFormat.byteRange(low: 0, high: 5_000_000).hasPrefix("up to "))
        XCTAssertTrue(ShrinkFormat.byteRange(low: -10, high: 5_000_000).hasPrefix("up to "))
        // Ends that share a unit collapse; ends that do not keep the words between them.
        XCTAssertFalse(ShrinkFormat.byteRange(low: 1_000_000_000, high: 2_000_000_000).contains(" to "))
        XCTAssertTrue(ShrinkFormat.byteRange(low: 900, high: 2_000_000).contains(" to "))
        XCTAssertEqual(ShrinkFormat.compactBytes(1_500_000_000), ShrinkFormat.bytes(1_500_000_000))
    }

    // MARK: - What the app plays

    /// What the haptics switch's own type promises: one stored key, and every moment it names
    /// answering to the switch.
    ///
    /// **What this does not prove, and must not be read as proving.** A9's defect was that the
    /// quality pills never asked this type at all - they played `.selection` directly - and no case
    /// here can catch that, because the fault is at a *call site* in a view body. Reverting
    /// `QualitySelector` to a bare `.sensoryFeedback(.selection, trigger:)` leaves this test green.
    /// Only a render, or a UI test that can toggle the setting, could hold the call sites; what is
    /// held here is the vocabulary they call into, which is the part that can drift silently: a
    /// moment that plays nothing when the switch is on, or a stored key renamed along with the row
    /// (which would be a different preference, and would find everyone's off choice turned back on).
    func testTheOneHapticsSwitchCoversEveryMomentTheAppPlays() {
        XCTAssertEqual(ShrinkHaptics.Moment.allCases, [.qualityChoice, .finished, .failed],
                       "choosing a pill is a haptic moment like the end of a run")
        for moment in ShrinkHaptics.Moment.allCases {
            XCTAssertNil(ShrinkHaptics.feedback(moment, enabled: false),
                         "\(moment) must be silent when the switch is off")
            XCTAssertNotNil(ShrinkHaptics.feedback(moment, enabled: true),
                            "\(moment) is a moment the app plays, so it needs something to play")
        }

        // The stored key is the row's original name on purpose: following the row's new name would
        // be a different preference, and everyone who had turned haptics off would find them on.
        XCTAssertEqual(ShrinkHaptics.storageKey, "completionHaptics")
    }

    // MARK: - Driving the one-video flow

    /// Takes the flow as far as the picker, which is the state a chosen video is handed over from.
    private func chooseVideo(_ fixture: OneVideoFixture) async {
        fixture.model.chooseVideo()
        await eventually { fixture.model.stage == .choosing }
    }

    private func eventually(_ predicate: () -> Bool, file: StaticString = #filePath,
                            line: UInt = #line) async {
        for _ in 0..<500 {
            if predicate() { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("Timed out waiting for the pipeline", file: file, line: line)
    }
}

// MARK: - Fixtures

private func coverageAsset(_ id: String, bytes: Int64?, duration: Double = 120,
                           width: Int = 1_920, height: Int = 1_080,
                           unsupported: String? = nil) -> LibraryAsset {
    LibraryAsset(id: id, creationDate: nil, duration: duration, pixelWidth: width,
                 pixelHeight: height, bytes: bytes, unsupportedReason: unsupported)
}

private func coverageQueueItem(_ id: String, bytes: Int64? = 1_000) -> BatchQueueRecord.Item {
    BatchQueueRecord.Item(identifier: id, creationDate: nil, duration: 120,
                          pixelWidth: 1_920, pixelHeight: 1_080, bytes: bytes, state: .pending)
}

// MARK: - The one-video flow, without Photos or media

/// The one-video view model, driven by fakes: no library, no media file and no device are
/// involved, and the authorization status is the state a simulator cannot be put in.
@MainActor private final class OneVideoFixture {
    let photos = OneVideoMockPhotos()
    let transcoder = OneVideoMockTranscoder()
    let verifier = OneVideoMockVerifier()
    let files = OneVideoMockFiles()
    /// The Photos status the model reads for the one question a permission failure cannot answer
    /// by itself: refused by the user, or restricted by something outside the app.
    private let authorizationStatus: () -> PHAuthorizationStatus
    let settings = ShrinkSettings(defaults: UserDefaults(suiteName: "videoshrink.tests.\(UUID().uuidString)")
                                  ?? .standard)
    /// The one-video model writes the identifier of the copy Photos hands back to its device
    /// memory, so a fixture without a store of its own would write into the machine's standard
    /// defaults. Its own suite, like the other one-video fixtures.
    let history = UserDefaultsShrinkHistoryStore(defaults: UserDefaults(suiteName: "videoshrink.tests.\(UUID().uuidString)")
                                                 ?? .standard)
    /// Built on first use, like the batch fixture: an initialiser that read the fakes to build the
    /// model would be reading `self` before every stored property was set.
    lazy var model = CompressionViewModel(photos: photos, transcoder: transcoder, verifier: verifier,
                                          temporary: files, history: history, settings: settings,
                                          authorizationStatus: authorizationStatus)

    init(authorizationStatus: @escaping () -> PHAuthorizationStatus = { .authorized }) {
        self.authorizationStatus = authorizationStatus
    }
}

@MainActor private final class OneVideoMockPhotos: PhotoLibraryServing {
    var accessError: PipelineError?
    var retrievalError: PipelineError?
    var saveError: PipelineError?
    var limited = false
    var retrieveCount = 0
    var saveCount = 0

    func requestAccess() async throws -> Bool {
        if let accessError { throw accessError }
        return limited
    }
    func retrieve(identifier: String, progress: @escaping @MainActor (Double) -> Void) async throws -> RetrievedVideo {
        retrieveCount += 1
        if let retrievalError { throw retrievalError }
        return RetrievedVideo(asset: AVURLAsset(url: URL(fileURLWithPath: "/mock-source.mov")),
                              identity: .unknown)
    }
    func cancelRetrieval() {}
    func save(videoAt url: URL, identity: AssetIdentity) async throws -> String? {
        saveCount += 1
        if let saveError { throw saveError }
        return "created-\(saveCount)"
    }
    func localFileURL(identifier: String) async -> URL? { nil }
    func playerItem(identifier: String) async throws -> AVPlayerItem { throw PipelineError.assetUnavailable }
    // This flow has no deletion path at all, so the fake never writes a receipt and never approves
    // a delete.
    func deletionEvidence(originalIdentifier: String, copyIdentifier: String) -> DeletionEvidence? { nil }
    func revalidateForDeletion(_ evidence: DeletionEvidence) -> CopyRevalidation { .unavailable }
    func deleteOriginals(afterRevalidating evidence: [String: DeletionEvidence]) async throws -> DeletionResult {
        DeletionResult()
    }
}

@MainActor private final class OneVideoMockTranscoder: VideoTranscoding {
    var error: PipelineError?
    var exports = 0
    var written = URL(fileURLWithPath: "/mock-output.mov")

    func transcode(_ source: RetrievedVideo, metadata: VideoMetadata, settings: TranscodeSettings,
                   progress: @escaping @MainActor (Double) -> Void) async throws -> URL {
        exports += 1
        if let error { throw error }
        return written
    }
    func cancel() {}
}

private final class OneVideoMockVerifier: VideoVerifying {
    /// What the original is measured as. A real inspection reads the media; this is the one figure
    /// the space checks are sized from.
    var inspectBytes: Int64 = 1_000
    /// What the copy comes out as, which is the figure the save's own space check asks for.
    var verifiedBytes: Int64 = 600

    func inspect(_ url: URL) async throws -> VideoMetadata {
        VideoMetadata(duration: 120, width: 1_920, height: 1_080, bytes: inspectBytes,
                      fileType: "MOV", audioTrackCount: 1, isPlayable: true, codec: .hevc,
                      nominalFrameRate: 30)
    }
    func verify(_ url: URL, source: VideoMetadata, expecting codec: VideoCodec?) async throws -> VideoMetadata {
        VideoMetadata(duration: source.duration, width: 1_920, height: 1_080, bytes: verifiedBytes,
                      fileType: "MOV", audioTrackCount: 1, isPlayable: true, codec: codec ?? .hevc,
                      nominalFrameRate: 30)
    }
    func verifyImportedCopy(_ url: URL, matching expected: VideoMetadata) async throws -> VideoMetadata {
        expected
    }
}

/// The workspace's space check, counted so a test can let one demand through and refuse the next.
@MainActor private final class OneVideoMockFiles: TemporaryFileManaging {
    var capacityError: PipelineError?
    /// The 1-based demand this fake refuses. Nil means every demand is answered with
    /// `capacityError`, which is how the check taken before retrieval behaves on a full iPhone.
    var refuseDemand: Int?
    private var demands = 0

    func ensureWorkspace() throws {}
    func outputURL() throws -> URL { URL(fileURLWithPath: "/mock-output.mov") }
    func remove(_ url: URL) throws {}
    func requireCapacity(for bytes: Int64) throws {
        demands += 1
        if let refuseDemand, demands != refuseDemand { return }
        if let capacityError { throw capacityError }
    }
    func cleanup() throws {}
}
