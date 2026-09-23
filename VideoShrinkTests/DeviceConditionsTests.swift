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
}
