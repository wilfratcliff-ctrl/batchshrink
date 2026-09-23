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

    private init() {
        cache.countLimit = 240
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
        if let image { cache.setObject(image, forKey: key) }
        return image
    }

    private static func key(_ identifier: String, _ size: CGSize) -> NSString {
        "\(identifier)|\(Int(size.width.rounded()))x\(Int(size.height.rounded()))" as NSString
    }
}
