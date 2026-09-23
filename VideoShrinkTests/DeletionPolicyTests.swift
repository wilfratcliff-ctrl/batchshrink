import XCTest
@testable import VideoShrink

final class DeletionPolicyTests: XCTestCase {
    private let saving = Savings(originalBytes: 1_000, compressedBytes: 600)
    private let larger = Savings(originalBytes: 1_000, compressedBytes: 1_200)

    func testDeletingStaysOffUnlessItIsTurnedOn() {
        XCTAssertEqual(DeletionPolicy.decision(mode: .off, saving: saving,
                                              readBack: .confirmed, alreadyDeleted: false),
                       .skip("Deleting originals is turned off."))
    }

    func testEveryDeletingModeNeedsAConfirmedCopy() {
        for mode in [DeletionMode.afterEachCopy, .afterRun] {
            XCTAssertEqual(DeletionPolicy.decision(mode: mode, saving: saving,
                                                   readBack: .confirmed, alreadyDeleted: false),
                           .delete)
            XCTAssertNotEqual(DeletionPolicy.decision(mode: mode, saving: saving,
                                                      readBack: .unavailable, alreadyDeleted: false),
                              .delete)
            XCTAssertNotEqual(DeletionPolicy.decision(mode: mode, saving: saving,
                                                      readBack: nil, alreadyDeleted: false),
                              .delete)
        }
    }

    func testACopyThatIsNotSmallerKeepsTheOriginal() {
        XCTAssertNotEqual(DeletionPolicy.decision(mode: .afterRun, saving: larger,
                                                  readBack: .confirmed, alreadyDeleted: false),
                          .delete)
        XCTAssertNotEqual(DeletionPolicy.decision(mode: .afterRun, saving: nil,
                                                  readBack: .confirmed, alreadyDeleted: false),
                          .delete)
    }

    func testAnOriginalThatWasAlreadyHandledIsNotDeletedTwice() {
        XCTAssertNotEqual(DeletionPolicy.decision(mode: .afterRun, saving: saving,
                                                  readBack: .confirmed, alreadyDeleted: true),
                          .delete)
    }

    func testTheModeTitlesAndDetailsAreUsable() {
        for mode in DeletionMode.allCases {
            XCTAssertFalse(mode.title.isEmpty)
            XCTAssertFalse(mode.detail.isEmpty)
            XCTAssertFalse(mode.shortTitle.isEmpty)
        }
        XCTAssertFalse(DeletionMode.off.deletesOriginals)
        XCTAssertTrue(DeletionMode.afterEachCopy.deletesOriginals)
        XCTAssertTrue(DeletionMode.afterRun.deletesOriginals)
    }

    func testCoordinatesAreCheckedBeforeTheyAreUsed() {
        XCTAssertTrue(AssetIdentity.Coordinate(latitude: 51.5, longitude: -0.1).isValid)
        XCTAssertFalse(AssetIdentity.Coordinate(latitude: 91, longitude: 0).isValid)
        XCTAssertFalse(AssetIdentity.Coordinate(latitude: 0, longitude: 181).isValid)
        XCTAssertFalse(AssetIdentity.Coordinate(latitude: .nan, longitude: 0).isValid)
    }
}
