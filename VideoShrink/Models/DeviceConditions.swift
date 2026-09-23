import Foundation

/// What the device is saying about its own limits.
///
/// Encoding video for an hour heats a phone, and iOS will shut work down when it gets too hot.
/// Reading the thermal state lets the batch stop on its own terms instead of being killed
/// mid-export.
enum DeviceConditions {
    enum Pacing: Equatable, Sendable {
        case normal
        /// Hot enough that iOS may start refusing work. Stop, let it cool, continue later.
        case tooWarm
    }

    static func pacing(thermalState: ProcessInfo.ThermalState) -> Pacing {
        thermalState == .critical ? .tooWarm : .normal
    }

    static func pacing(processInfo: ProcessInfo = .processInfo) -> Pacing {
        pacing(thermalState: processInfo.thermalState)
    }

    /// Low Power Mode slows the encoder down. It is not a reason to stop, only to say so.
    static func isLowPowerMode(processInfo: ProcessInfo = .processInfo) -> Bool {
        processInfo.isLowPowerModeEnabled
    }
}
