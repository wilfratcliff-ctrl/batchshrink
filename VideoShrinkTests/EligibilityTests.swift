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
}
