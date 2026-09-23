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

    /// The overloads the app actually calls take `ProcessInfo` and default to this process. They can
    /// only be checked against the live machine, so each one is compared with the same value read at
    /// the same moment.
    ///
    /// **What this cannot catch on a runner**, and the reason the two cases above matter more than
    /// this one: `pacing` answers `.normal` for every thermal state but `.critical`, and no runner is
    /// ever `.critical`, so a forward that returned a constant would satisfy this case there. It holds
    /// the wiring; only a hot device can hold the wiring and the mapping at once. The doc comment here
    /// used to claim the opposite - that a stripped-out forward "would show up as a mismatch".
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
