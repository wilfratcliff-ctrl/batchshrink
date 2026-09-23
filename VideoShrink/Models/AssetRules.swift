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
        /// A cinematic video: the focus point moves after capture, and a flat export loses it.
        var isCinematic = false
        /// A high-dynamic-range video: an SDR-shaped export can change how it looks.
        var isHDR = false
        /// An Apple ProRes video, which no preset this app exports with reproduces.
        var isProRes = false
        /// A shared-album, synced or otherwise restricted item this app may not replace.
        var isSharedOrRestricted = false
    }

    /// Returns a short, user-facing reason when the pipeline cannot process this item.
    ///
    /// Order decides the reason when an item carries several traits. A non-video is not media
    /// at all, and a Live Photo is refused as a Live Photo rather than reclassified: its paired
    /// resources are the reason it cannot be replaced, and calling it an edited or cinematic
    /// video instead would hide that. The traits added after the edited check are additive, so
    /// every reason that existed before still wins where it did.
    static func unsupportedReason(_ traits: Traits) -> String? {
        if !traits.isVideo { return "This item isn’t a video." }
        if traits.hasPairedVideo { return "Live Photos aren’t supported yet." }
        if traits.isTimeLapse { return "Time-lapse videos aren’t supported yet." }
        if traits.isSpatial { return "Spatial videos aren’t supported yet." }
        if traits.isHighFrameRate { return "Slow-motion videos aren’t supported yet." }
        if traits.hasAdjustmentData || traits.hasFullSizeVideo { return "Edited videos aren’t supported yet." }
        if traits.isCinematic { return "Cinematic videos aren’t supported yet." }
        if traits.isProRes { return "ProRes videos aren’t supported yet." }
        if traits.isHDR { return "HDR videos aren’t supported yet." }
        if traits.isSharedOrRestricted { return "Shared or restricted videos aren’t supported yet." }
        return nil
    }
}
