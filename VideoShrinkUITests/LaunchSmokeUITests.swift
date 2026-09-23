import XCTest

/// The first observation of a rendered screen in this project.
///
/// Everything else in this repository is a static check: pattern scans on Windows, Swift
/// compilation and unit tests on a macOS runner. All of them can be green while the app has
/// never drawn anything, and for the whole life of this project that has been exactly the case.
/// This test is the smallest thing that changes that. It launches the app on a simulator and
/// asks the interface what is there, which is a question no scanner can answer.
///
/// It is deliberately one test with two assertions. A failure means the app did not launch,
/// did not draw its introduction, or did not answer a tap on it -- and XCTest records which, with
/// the screen attached to the result bundle at the moment it gave up. What it cannot say is
/// anything about Photos, iCloud, exporting, saving, deleting or recovery, because a simulator
/// has none of the things those need. See docs/PHYSICAL_DEVICE_TEST_PLAN.md for that.
final class LaunchSmokeUITests: XCTestCase {

    override func setUp() {
        super.setUp()
        // The second assertion is only worth reading if the first one passed.
        continueAfterFailure = false
    }

    /// A fresh install opens on the introduction, and Skip leads to the batch screen.
    ///
    /// Both the introduction and the batch screen are drawn by the flow the product actually
    /// ships: `ContentView`, `ShrinkOnboarding` and `BatchScreens`, mirrored into the Expo pod
    /// by scripts/sync-native-sources.mjs. The harness around them is not the shipping app, so
    /// this is evidence about the screens rather than about the two Expo bridge files.
    func testTheIntroductionDrawsAndSkipReachesTheBatchScreen() {
        let app = XCUIApplication()

        // Whether the introduction appears is decided by one persisted default, and a developer
        // who has run this test once on their own simulator would otherwise see a different
        // screen from the one CI sees. Setting it in the argument domain pins the state the test
        // is about, without deleting anything the app owns. The value is spelled as a property
        // list fragment because that is what the argument domain parses; a plain "YES" would be
        // read as a string and silently ignored by the Boolean property wrapper.
        app.launchArguments += ["-batchShrink.onboarding.v1", "<false/>"]
        app.launch()

        XCTAssertEqual(
            app.state, .runningForeground,
            "The app did not reach the foreground. It either crashed on launch or never started, "
                + "which is the failure this test exists to make visible."
        )

        // The introduction is the first screen a new user meets, and it needs no Photos
        // permission, so a simulator can always reach it. Its own Skip control is the anchor:
        // a blank screen, a crash, or a view that never appears all fail this wait.
        let skip = app.buttons["Skip"]
        XCTAssertTrue(
            skip.waitForExistence(timeout: 30),
            "The introduction never drew. Skipping onboarding is expected to be on screen for a "
                + "fresh install; if it is not, the launch path is broken rather than slow."
        )
        skip.tap()

        // One tap, one navigation. This is the smallest end-to-end claim the app can make about
        // itself without a Photos library: the introduction is gone and the batch screen is up,
        // with the control that starts a scan and the control that offers the one-video flow.
        let scan = app.buttons["scanLibrary"]
        XCTAssertTrue(
            scan.waitForExistence(timeout: 30),
            "Tapping Skip did not reach the batch screen. The introduction dismissed but the flow "
                + "behind it never drew."
        )
        XCTAssertTrue(
            app.buttons["useSingleVideo"].exists,
            "The batch screen drew without its second way in, so the screen is not the one the "
                + "source describes."
        )
    }
}
