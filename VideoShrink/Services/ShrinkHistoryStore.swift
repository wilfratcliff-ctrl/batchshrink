import Foundation

/// Remembers on this device which videos have already been shrunk and how large those copies
/// turned out.
///
/// The identifiers are the local ones Photos already uses for the user's own library. They
/// are kept so an already-shrunk video can be marked and left out of a bulk selection, and
/// the measured copy sizes sharpen later estimates. Nothing is uploaded, and no media,
/// filename, location or date is stored here.
@MainActor final class UserDefaultsShrinkHistoryStore: ShrinkHistoryStoring {
    static let identifierLimit = 2_000
    static let measurementLimit = 80

    private let defaults: UserDefaults
    private let identifiersKey = "shrink.completedIdentifiers"
    private let measurementsKey = "shrink.copyMeasurements"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func completedIdentifiers() -> Set<String> {
        Set(defaults.stringArray(forKey: identifiersKey) ?? [])
    }

    func copyMeasurements() -> [CopyMeasurement] {
        let stored = defaults.array(forKey: measurementsKey) ?? []
        return stored.compactMap { entry in
            guard let pair = entry as? [NSNumber], pair.count == 2 else { return nil }
            return CopyMeasurement(bitsPerSecond: pair[0].doubleValue, longEdge: pair[1].intValue)
        }
    }

    func record(identifier: String, measurement: CopyMeasurement?) {
        var identifiers = defaults.stringArray(forKey: identifiersKey) ?? []
        identifiers.removeAll { $0 == identifier }
        identifiers.append(identifier)
        if identifiers.count > Self.identifierLimit {
            identifiers.removeFirst(identifiers.count - Self.identifierLimit)
        }
        defaults.set(identifiers, forKey: identifiersKey)

        guard let measurement, measurement.isValid else { return }
        var measurements = copyMeasurements()
        measurements.append(measurement)
        if measurements.count > Self.measurementLimit {
            measurements.removeFirst(measurements.count - Self.measurementLimit)
        }
        defaults.set(measurements.map { [$0.bitsPerSecond, Double($0.longEdge)] }, forKey: measurementsKey)
    }
}
