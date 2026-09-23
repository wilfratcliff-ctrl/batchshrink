import Foundation

/// Eligibility rules shared by the library scan and the retrieval path, so a video the
/// scan offers is one the pipeline can actually process.
///
/// Photos types stay in the service layer; the service maps `PHAsset` and
/// `PHAssetResource` onto these plain values so the rules stay testable.
enum AssetRules {
    struct Traits: Equatable, Sendable {
        var isVideo = true
        var isHighFrameRate = false
        var isTimeLapse = false
        var isSpatial = false
        var hasAdjustmentData = false
        var hasFullSizeVideo = false
        var hasPairedVideo = false
    }

    /// Returns a short, user-facing reason when the pipeline cannot process this item.
    static func unsupportedReason(_ traits: Traits) -> String? {
        if !traits.isVideo { return "This item isn’t a video." }
        if traits.hasPairedVideo { return "Live Photos aren’t supported yet." }
        if traits.isTimeLapse { return "Time-lapse videos aren’t supported yet." }
        if traits.isSpatial { return "Spatial videos aren’t supported yet." }
        if traits.isHighFrameRate { return "Slow-motion videos aren’t supported yet." }
        if traits.hasAdjustmentData || traits.hasFullSizeVideo { return "Edited videos aren’t supported yet." }
        return nil
    }
}
