import Foundation
import AVFoundation

/// The codec a copy can be expected to use. Apple ships HEVC size presets for 1080p and 4K
/// only, so the smaller option is the documented 720p H.264 preset.
enum VideoCodec: String, Equatable, Sendable {
    case h264 = "H.264"
    case hevc = "HEVC"
    case other = "Other"

    var displayName: String { rawValue }
}

/// How large a copy may be. VideoShrink never encodes larger than the original.
enum CopyResolution: String, CaseIterable, Identifiable, Equatable, Sendable {
    case hd720, hd1080, uhd4k

    var id: String { rawValue }

    /// Long edge, in pixels.
    var longEdge: Int {
        switch self {
        case .hd720: return 1_280
        case .hd1080: return 1_920
        case .uhd4k: return 3_840
        }
    }

    var title: String {
        switch self {
        case .hd720: return "720p"
        case .hd1080: return "1080p"
        case .uhd4k: return "4K"
        }
    }

    var codec: VideoCodec {
        switch self {
        case .hd720: return .h264
        case .hd1080, .uhd4k: return .hevc
        }
    }

    /// Apple's documented export preset for this size.
    var presetName: String {
        switch self {
        case .hd720: return AVAssetExportPreset1280x720
        case .hd1080: return AVAssetExportPresetHEVC1920x1080
        case .uhd4k: return AVAssetExportPresetHEVC3840x2160
        }
    }

    /// Planning band for a copy at this size, in bits per second, before any frame-rate
    /// change. Apple does not publish preset bitrates, so this is a planning assumption
    /// that measured results replace.
    var planningBand: ClosedRange<Double> {
        switch self {
        case .hd720: return 2_500_000...5_000_000
        case .hd1080: return 4_000_000...8_000_000
        case .uhd4k: return 12_000_000...24_000_000
        }
    }

    /// The option closest to a source's own size, used so an estimate never assumes a copy
    /// larger than the original.
    static func nearest(longEdge: Int) -> CopyResolution {
        if longEdge >= 2_561 { return .uhd4k }
        if longEdge >= 1_601 { return .hd1080 }
        return .hd720
    }
}

/// How many frames a second a copy may keep.
enum FrameRateOption: String, CaseIterable, Identifiable, Equatable, Sendable {
    case original, fps30, fps24

    var id: String { rawValue }

    var title: String {
        switch self {
        case .original: return "Keep original"
        case .fps30: return "30 fps"
        case .fps24: return "24 fps"
        }
    }

    var shortTitle: String {
        switch self {
        case .original: return "Original"
        case .fps30: return "30 fps"
        case .fps24: return "24 fps"
        }
    }

    var framesPerSecond: Double? {
        switch self {
        case .original: return nil
        case .fps30: return 30
        case .fps24: return 24
        }
    }
}

/// What the pipeline should produce for one video.
struct TranscodeSettings: Equatable, Sendable {
    var resolution: CopyResolution = .hd1080
    var frameRate: FrameRateOption = .original

    static let standard = TranscodeSettings()

    var codec: VideoCodec { resolution.codec }

    /// The size really used: the chosen resolution, never larger than the source.
    func renderLongEdge(sourceLongEdge: Int) -> Int {
        guard sourceLongEdge > 0 else { return resolution.longEdge }
        return min(resolution.longEdge, sourceLongEdge)
    }

    /// The size band that describes the copy this video will actually get.
    func effectiveResolution(sourceLongEdge: Int) -> CopyResolution {
        let source = CopyResolution.nearest(longEdge: sourceLongEdge)
        return source.longEdge < resolution.longEdge ? source : resolution
    }

    /// The frame rate to write, or nil to leave the source alone. Never raises a frame rate.
    func targetFrameRate(sourceFrameRate: Double) -> Double? {
        guard let wanted = frameRate.framesPerSecond, sourceFrameRate > 0 else { return nil }
        return wanted < sourceFrameRate - 0.5 ? wanted : nil
    }

    /// A video composition re-renders the picture, so it is used only when the preset alone
    /// cannot reach the requested size or frame rate.
    func needsComposition(sourceLongEdge: Int, sourceFrameRate: Double) -> Bool {
        renderLongEdge(sourceLongEdge: sourceLongEdge) != resolution.longEdge
            || targetFrameRate(sourceFrameRate: sourceFrameRate) != nil
    }
}

/// One measured copy, kept so later estimates can use this iPhone's own results.
struct CopyMeasurement: Equatable, Sendable {
    let bitsPerSecond: Double
    let longEdge: Int

    var isValid: Bool {
        bitsPerSecond.isFinite && bitsPerSecond > 250_000 && bitsPerSecond < 80_000_000 && longEdge > 0
    }
}
