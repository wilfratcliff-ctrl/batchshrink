import XCTest
@testable import VideoShrink

final class DeviceConditionsTests: XCTestCase {
    func testOnlyACriticalThermalStateStopsTheBatch() {
        XCTAssertEqual(DeviceConditions.pacing(thermalState: .nominal), .normal)
        XCTAssertEqual(DeviceConditions.pacing(thermalState: .fair), .normal)
        XCTAssertEqual(DeviceConditions.pacing(thermalState: .serious), .normal)
        XCTAssertEqual(DeviceConditions.pacing(thermalState: .critical), .tooWarm)
    }

    func testEveryThermalStateIsHandled() {
        for state in [ProcessInfo.ThermalState.nominal, .fair, .serious, .critical] {
            XCTAssertEqual(state == .critical,
                           DeviceConditions.pacing(thermalState: state) == .tooWarm)
        }
    }

    /// The overloads the app actually calls take `ProcessInfo` and default to this process. They
    /// can only be checked against the live machine, so each one is compared with the same value
    /// read at the same moment: a stripped-out forward would show up as a mismatch.
    func testTheLiveOverloadsReportWhatTheSystemSays() {
        let live = ProcessInfo.processInfo
        XCTAssertEqual(DeviceConditions.pacing(processInfo: live),
                       DeviceConditions.pacing(thermalState: live.thermalState))
        XCTAssertEqual(DeviceConditions.pacing(),
                       DeviceConditions.pacing(thermalState: live.thermalState))
        XCTAssertEqual(DeviceConditions.isLowPowerMode(processInfo: live), live.isLowPowerModeEnabled)
        XCTAssertEqual(DeviceConditions.isLowPowerMode(), live.isLowPowerModeEnabled)
    }
}
