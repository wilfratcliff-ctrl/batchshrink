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

        // Whether the introduction appears is decided by one persisted default, so this test
        // needs it to be false. It is deliberately NOT forced with a launch argument, which was
        // the first thing tried and was wrong: a launch argument is read from the argument domain,
        // which sits above the application domain in the defaults search list, so it shadows the
        // key for reads *and* writes. The tap on Skip would have set the stored value while every
        // later read still saw the argument - the introduction would never have gone away, and
        // the test would have reported a broken app rather than a broken test. scripts/
        // verify-app-launch.mjs uninstalls the app before running this, so the container, and with
        // it this default, is empty on every run.
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
        //
        // The control is looked for by its identifier first and by the words on it second, so
        // that a missing identifier is reported as a missing identifier rather than as a missing
        // screen; both are defects, but only one of them means the flow never drew.
        let scan = app.buttons["scanLibrary"]
        let scanByTitle = app.buttons["Find my videos"]
        let reachedBatch = scan.waitForExistence(timeout: 30) || scanByTitle.exists
        if !reachedBatch {
            // The whole element tree, because a failure here has three very different causes and
            // the tree names which: the introduction never dismissed, the app died on the way to
            // the batch screen, or the screen drew without the control this test anchors on.
            XCTFail(
                """
                Tapping Skip did not reach the batch screen within 30 seconds.
                Application state: \(app.state.rawValue) (3 is running foreground).
                The introduction is \(app.buttons["Skip"].exists ? "STILL on screen" : "gone"), \
                so the tap \(app.buttons["Skip"].exists ? "did not take effect" : "took effect").
                The elements on screen were:
                \(app.debugDescription)
                """
            )
            return
        }
        XCTAssertTrue(
            scan.exists,
            "The batch screen drew, but its primary control answers to \"Find my videos\" and not "
                + "to the \"scanLibrary\" identifier the rest of this project's automation uses. "
                + "The screen is right and the anchor for it is missing."
        )
        XCTAssertTrue(
            app.buttons["useSingleVideo"].exists,
            "The batch screen drew without its second way in, so the screen is not the one the "
                + "source describes."
        )
    }
}
