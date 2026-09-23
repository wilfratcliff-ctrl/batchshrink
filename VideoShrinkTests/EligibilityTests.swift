import XCTest
@testable import VideoShrink

/// Eligibility, one case per trait. Each case asserts the exact sentence the interface shows,
/// so a rule that changes its wording has to change its test with it, and a trait that is
/// added without a reason cannot pass silently.
final class EligibilityTests: XCTestCase {

    // MARK: - Ordinary video

    func testAnOrdinaryVideoIsSupported() {
        XCTAssertNil(AssetRules.unsupportedReason(AssetRules.Traits()))
    }

    // MARK: - One case per trait

    func testSomethingThatIsNotAVideoIsRefused() {
        XCTAssertEqual(AssetRules.unsupportedReason(AssetRules.Traits(isVideo: false)),
                       "This item isn’t a video.")
    }

    func testALivePhotoIsRefusedAsALivePhoto() {
        XCTAssertEqual(AssetRules.unsupportedReason(AssetRules.Traits(hasPairedVideo: true)),
                       "Live Photos aren’t supported yet.")
    }

    func testATimeLapseVideoIsRefused() {
        XCTAssertEqual(AssetRules.unsupportedReason(AssetRules.Traits(isTimeLapse: true)),
                       "Time-lapse videos aren’t supported yet.")
    }

    func testASpatialVideoIsRefused() {
        XCTAssertEqual(AssetRules.unsupportedReason(AssetRules.Traits(isSpatial: true)),
                       "Spatial videos aren’t supported yet.")
    }

    func testASlowMotionVideoIsRefused() {
        XCTAssertEqual(AssetRules.unsupportedReason(AssetRules.Traits(isHighFrameRate: true)),
                       "Slow-motion videos aren’t supported yet.")
    }

    func testAnEditedVideoIsRefused() {
        XCTAssertEqual(AssetRules.unsupportedReason(AssetRules.Traits(hasAdjustmentData: true)),
                       "Edited videos aren’t supported yet.")
        XCTAssertEqual(AssetRules.unsupportedReason(AssetRules.Traits(hasFullSizeVideo: true)),
                       "Edited videos aren’t supported yet.")
    }

    func testACinematicVideoIsRefused() {
        XCTAssertEqual(AssetRules.unsupportedReason(AssetRules.Traits(isCinematic: true)),
                       "Cinematic videos aren’t supported yet.")
    }

    func testAProResVideoIsRefused() {
        XCTAssertEqual(AssetRules.unsupportedReason(AssetRules.Traits(isProRes: true)),
                       "ProRes videos aren’t supported yet.")
    }

    func testAnHDRVideoIsRefused() {
        XCTAssertEqual(AssetRules.unsupportedReason(AssetRules.Traits(isHDR: true)),
                       "HDR videos aren’t supported yet.")
    }

    func testASharedOrRestrictedVideoIsRefused() {
        XCTAssertEqual(AssetRules.unsupportedReason(AssetRules.Traits(isSharedOrRestricted: true)),
                       "Shared or restricted videos aren’t supported yet.")
    }

    // MARK: - Precedence

    func testTheFirstMatchingRuleDecidesTheReason() {
        // Every trait at once still reads as a Live Photo. Paired resources are why this app
        // cannot replace the item, and reporting a format problem instead would hide that.
        let everything = AssetRules.Traits(isHighFrameRate: true,
                                           isTimeLapse: true,
                                           isSpatial: true,
                                           hasAdjustmentData: true,
                                           hasFullSizeVideo: true,
                                           hasPairedVideo: true,
                                           isCinematic: true,
                                           isHDR: true,
                                           isProRes: true,
                                           isSharedOrRestricted: true)
        XCTAssertEqual(AssetRules.unsupportedReason(everything), "Live Photos aren’t supported yet.")

        // An edit outranks the special formats and the library restriction.
        let edited = AssetRules.Traits(hasAdjustmentData: true,
                                       isCinematic: true,
                                       isHDR: true,
                                       isProRes: true,
                                       isSharedOrRestricted: true)
        XCTAssertEqual(AssetRules.unsupportedReason(edited), "Edited videos aren’t supported yet.")

        // With the earlier traits cleared, each later reason wins in the order the rules use.
        let cinematic = AssetRules.Traits(isCinematic: true, isHDR: true,
                                          isProRes: true, isSharedOrRestricted: true)
        XCTAssertEqual(AssetRules.unsupportedReason(cinematic), "Cinematic videos aren’t supported yet.")
        let proRes = AssetRules.Traits(isHDR: true, isProRes: true, isSharedOrRestricted: true)
        XCTAssertEqual(AssetRules.unsupportedReason(proRes), "ProRes videos aren’t supported yet.")
        let hdr = AssetRules.Traits(isHDR: true, isSharedOrRestricted: true)
        XCTAssertEqual(AssetRules.unsupportedReason(hdr), "HDR videos aren’t supported yet.")
        let restricted = AssetRules.Traits(isSharedOrRestricted: true)
        XCTAssertEqual(AssetRules.unsupportedReason(restricted), "Shared or restricted videos aren’t supported yet.")
    }

    // MARK: - The two traits only the media itself can decide

    /// The library steps cannot see a codec subtype or a colour tag, so HDR and ProRes are
    /// decided once an original can be read. That is a second entry point into the same table,
    /// and it has to produce the same sentences in the same order.
    func testTheFormatEntriesDecideTheSameSentences() {
        XCTAssertEqual(AssetRules.unsupportedFormatReason(isHDR: true, isProRes: false),
                       "HDR videos aren’t supported yet.")
        XCTAssertEqual(AssetRules.unsupportedFormatReason(isHDR: false, isProRes: true),
                       "ProRes videos aren’t supported yet.")
        XCTAssertNil(AssetRules.unsupportedFormatReason(isHDR: false, isProRes: false))
        XCTAssertEqual(AssetRules.unsupportedFormatReason(isHDR: true, isProRes: true),
                       "ProRes videos aren’t supported yet.",
                       "The trait order decides, exactly as it does for a listed video")
    }

    /// The two paths must not drift: whatever the trait table says about these two facts is what
    /// the format entry point says about them.
    func testBothEntryPointsAgreeAboutHDRAndProRes() {
        for isHDR in [true, false] {
            for isProRes in [true, false] {
                XCTAssertEqual(
                    AssetRules.unsupportedFormatReason(isHDR: isHDR, isProRes: isProRes),
                    AssetRules.unsupportedReason(AssetRules.Traits(isHDR: isHDR, isProRes: isProRes)),
                    "HDR \(isHDR), ProRes \(isProRes)")
            }
        }
    }
}
