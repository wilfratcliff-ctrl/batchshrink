import Foundation

/// What Photos knows about an original that should travel with its copy.
///
/// Coordinates are plain numbers rather than `CLLocation` so the value stays `Sendable` and can
/// cross actors without bringing Core Location along.
struct AssetIdentity: Equatable, Sendable {
    struct Coordinate: Equatable, Sendable {
        let latitude: Double
        let longitude: Double

        var isValid: Bool {
            latitude.isFinite && longitude.isFinite
                && abs(latitude) <= 90 && abs(longitude) <= 180
        }
    }

    var creationDate: Date?
    var originalFilename: String?
    var coordinate: Coordinate?
    var isFavorite = false
    var isHidden = false

    static let unknown = AssetIdentity()
}
