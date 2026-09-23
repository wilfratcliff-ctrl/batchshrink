import Foundation
import AVFoundation

enum PipelineError: Error, LocalizedError, Equatable, Sendable {
    case permissionDenied, assetUnavailable, unsupported, retrieval, export, verification
    case durationMismatch, audioMismatch, orientationMismatch, insufficientStorage
    case codecMismatch, resolutionMismatch, frameRateMismatch
    case save, temporaryFiles, libraryScan, cancelled
    /// An original the app deliberately does not process, refused once the media itself could
    /// be read rather than while the library was listed. The sentence is `AssetRules`', so an
    /// HDR or ProRes original reads here exactly as it does on the screening screen.
    case unsupportedOriginal(reason: String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied: return "Photos access is unavailable. In Settings, allow VideoShrink access to the video you want to test."
        case .assetUnavailable: return "This video is outside the Photos access granted to VideoShrink. Add it to your allowed photos in Settings, then select it again. The system picker does not grant PhotoKit access by itself."
        case .unsupported: return "This video is not supported by Phase 0. Try an ordinary, unedited video with one video track and at most one audio track. Slow motion, time-lapse, spatial videos and edited compositions need separate validation."
        case .unsupportedOriginal(let reason): return reason
        case .retrieval: return "Photos could not retrieve this video. If its original is in iCloud, check your connection and local storage, then try again."
        case .export: return "HEVC export failed. Keep VideoShrink open, check free storage and try a different video."
        case .verification: return "The output failed verification. No copy was saved."
        case .durationMismatch: return "The output duration differs from the source beyond the allowed tolerance. No copy was saved."
        case .audioMismatch: return "The output did not retain the source audio track count. No copy was saved."
        case .orientationMismatch: return "The output display shape differs from the source. No copy was saved."
        case .codecMismatch: return "The copy used a different video format than the chosen quality. No copy was saved."
        case .resolutionMismatch: return "The copy came out larger than the original. No copy was saved."
        case .frameRateMismatch: return "The copy did not reduce the frame rate as expected. No copy was saved."
        case .insufficientStorage: return "There is not enough free space for this operation. Free some local storage and try again. Downloading and saving both require additional space."
        case .save: return "Photos did not confirm the save. Inspect Photos before retrying to avoid creating an extra copy. Your original was not changed."
        case .temporaryFiles: return "VideoShrink could not prepare or clean its temporary workspace. Restart the app and check local storage."
        case .libraryScan: return "VideoShrink couldn’t look through your Photos library. Check your connection and Photos access, then try again."
        case .cancelled: return "Cancelled. Your original was not changed."
        }
    }

    static func normalize(_ error: Error, fallback: PipelineError) -> PipelineError {
        if error is CancellationError { return .cancelled }
        if let known = error as? PipelineError { return known }
        var current: NSError? = error as NSError
        for _ in 0..<8 {
            guard let value = current else { break }
            if (value.domain == NSCocoaErrorDomain && value.code == NSFileWriteOutOfSpaceError)
                || (value.domain == NSPOSIXErrorDomain && value.code == 28)
                || (value.domain == AVFoundationErrorDomain && value.code == AVError.diskFull.rawValue) {
                return .insufficientStorage
            }
            current = value.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return fallback
    }
}
