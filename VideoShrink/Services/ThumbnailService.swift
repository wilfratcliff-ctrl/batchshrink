import Photos
import UIKit

/// Small previews for the library list.
///
/// Thumbnails are the only thing this app fetches without the user starting a job: Photos can
/// hand over a cached preview of a video whose original lives in iCloud, and only that
/// preview is ever requested. Originals are never downloaded here, and the library scan
/// still asks PhotoKit with network access switched off.
@MainActor final class ThumbnailService {
    static let shared = ThumbnailService()

    private let manager = PHImageManager.default()
    private let cache = NSCache<NSString, UIImage>()
    /// The cache keys held for each video, per identifier. `NSCache` cannot be enumerated, so
    /// this is what lets a change reported by Photos drop exactly the stale previews.
    private var keysByIdentifier: [String: Set<NSString>] = [:]

    private init() {
        cache.countLimit = 240
    }

    /// Drops every cached preview of the given videos, at every size.
    ///
    /// Photos keeps the same identifier when a video is edited, so without this the app would
    /// keep showing the picture from before the edit. The next request asks Photos again at
    /// `.current` and caches the new picture.
    func invalidate(identifiers: [String]) {
        for identifier in identifiers {
            guard let keys = keysByIdentifier.removeValue(forKey: identifier) else { continue }
            for key in keys { cache.removeObject(forKey: key) }
        }
    }

    func image(identifier: String, size: CGSize) async -> UIImage? {
        let key = Self.key(identifier, size)
        if let cached = cache.object(forKey: key) { return cached }
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject
        else { return nil }
        let options = PHImageRequestOptions()
        options.deliveryMode = .fastFormat
        options.resizeMode = .fast
        options.version = .current
        options.isNetworkAccessAllowed = true
        let target = CGSize(width: max(1, size.width) * 3, height: max(1, size.height) * 3)
        let image: UIImage? = await withCheckedContinuation { continuation in
            // `.fastFormat` delivers once, and the flag keeps a late callback from resuming twice.
            var finished = false
            manager.requestImage(for: asset, targetSize: target, contentMode: .aspectFill,
                                 options: options) { image, _ in
                guard !finished else { return }
                finished = true
                continuation.resume(returning: image)
            }
        }
        if let image {
            cache.setObject(image, forKey: key)
            keysByIdentifier[identifier, default: []].insert(key)
        }
        return image
    }

    private static func key(_ identifier: String, _ size: CGSize) -> NSString {
        "\(identifier)|\(Int(size.width.rounded()))x\(Int(size.height.rounded()))" as NSString
    }
}
