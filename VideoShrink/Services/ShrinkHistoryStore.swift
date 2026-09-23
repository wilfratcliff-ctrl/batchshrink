import Foundation

/// Remembers on this device which videos have already been shrunk, how large those copies
/// turned out, and which Photos assets this app created itself.
///
/// The identifiers are the local ones Photos already uses for the user's own library. They
/// are kept so an already-shrunk video can be marked and left out of a bulk selection, and
/// the measured copy sizes sharpen later estimates. The created-copy list names this app's own
/// output, which is a new asset with an identifier of its own, so a later bulk selection can
/// leave it alone as well. Nothing is uploaded, and no media, filename, location or date is
/// stored here.
@MainActor final class UserDefaultsShrinkHistoryStore: ShrinkHistoryStoring {
    static let identifierLimit = 2_000
    static let measurementLimit = 80

    private let defaults: UserDefaults
    private let identifiersKey = "shrink.completedIdentifiers"
    private let createdCopyIdentifiersKey = "shrink.createdCopyIdentifiers"
    private let measurementsKey = "shrink.copyMeasurements"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func completedIdentifiers() -> Set<String> {
        Set(defaults.stringArray(forKey: identifiersKey) ?? [])
    }

    /// The copies this app created. Kept in the same order they were made and under the same
    /// bound as the shrunk originals, so this list cannot grow without limit.
    func createdCopyIdentifiers() -> Set<String> {
        Set(defaults.stringArray(forKey: createdCopyIdentifiersKey) ?? [])
    }

    func copyMeasurements() -> [CopyMeasurement] {
        let stored = defaults.array(forKey: measurementsKey) ?? []
        return stored.compactMap { entry in
            guard let pair = entry as? [NSNumber], pair.count == 2 else { return nil }
            return CopyMeasurement(bitsPerSecond: pair[0].doubleValue, longEdge: pair[1].intValue)
        }
    }

    func record(identifier: String, measurement: CopyMeasurement?) {
        append(identifier, forKey: identifiersKey)

        guard let measurement, measurement.isValid else { return }
        var measurements = copyMeasurements()
        measurements.append(measurement)
        if measurements.count > Self.measurementLimit {
            measurements.removeFirst(measurements.count - Self.measurementLimit)
        }
        defaults.set(measurements.map { [$0.bitsPerSecond, Double($0.longEdge)] }, forKey: measurementsKey)
    }

    /// Records one copy Photos handed back to this app, so a later bulk selection can leave it
    /// alone. Nothing else about the copy is kept: no media, filename, location or date.
    func recordCreatedCopy(identifier: String) {
        append(identifier, forKey: createdCopyIdentifiersKey)
    }

    /// Adds one identifier to the end of a list and holds that list to `identifierLimit`. A
    /// repeated identifier moves to the end rather than appearing twice.
    private func append(_ identifier: String, forKey key: String) {
        var identifiers = defaults.stringArray(forKey: key) ?? []
        identifiers.removeAll { $0 == identifier }
        identifiers.append(identifier)
        if identifiers.count > Self.identifierLimit {
            identifiers.removeFirst(identifiers.count - Self.identifierLimit)
        }
        defaults.set(identifiers, forKey: key)
    }
}
