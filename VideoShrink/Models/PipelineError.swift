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
    /// An export AVFoundation would not build for the quality this run asked for, refused with
    /// what was found rather than with a list of what might be wrong.
    ///
    /// Two answers reach here and both are answers: there is no export session for the preset the
    /// chosen quality names, or the session Apple built cannot write the container this app saves.
    /// Neither is a trait of the media that could have been read earlier - the video may be an
    /// ordinary one - which is why this is not `unsupportedOriginal` in other words. The sentence
    /// belongs to `VideoTranscodingService`, the layer that asked and heard the answer, exactly as
    /// `unsupportedOriginal` carries `AssetRules`' sentence for a refusal the rules made.
    case exportUnavailable(reason: String)

    /// The sentence for Photos access the user refused.
    ///
    /// It is read in the batch flow and in the one-video flow, so it names neither a single video
    /// nor a count: the wording it replaced - "the video you want to test" - was the one-video
    /// flow's way of talking reaching a user who had just picked twenty videos.
    static let refusedAccess = "Photos access is unavailable. In Settings, allow BatchShrink access to your videos, then come back and try again."

    /// The sentence for Photos access a restriction outside this app took away.
    ///
    /// Screen Time and a device management profile can switch Photos off for every app on the
    /// iPhone. That is not a refusal the user can undo in Settings, and while it is on, Photos is
    /// not on this app's Settings page at all - so this sentence never sends anyone there.
    ///
    /// Like `refusedAccess`, it is read in the batch flow and in the one-video flow, so it names
    /// neither a library nor a single video: the videos this app is kept away from are the same
    /// ones in either flow.
    static let restrictedAccess = "Photos is blocked on this iPhone, so BatchShrink cannot read your videos. Screen Time or a device management profile is holding it back, and nothing in BatchShrink can change it."

    /// The sentence for access the app does not have, in the words that match the reason it does
    /// not have it. The two cannot be told apart from the reading alone, so the caller that knows
    /// says which one it is.
    static func accessSentence(restricted: Bool) -> String {
        restricted ? restrictedAccess : refusedAccess
    }

    /// The sentence for a space refusal, in the words of the step that met it.
    ///
    /// A space check knows how much room it asked for: `DiskHeadroom.neededToWrite(_:)` is the
    /// figure, and the caller holds it at the instant the check refuses, so the refusal can say
    /// what it wanted instead of leaving the user to guess. Only a caller that asked for the room
    /// can write this sentence, which is why the case itself stays coarse: a queue restored from
    /// disk carries a stable code and no sentence, and Photos or the encoder can report running
    /// out of room on their own, where nothing in the app measured a figure to name.
    ///
    /// A figure that is only the working reserve is the demand made before a video has been
    /// measured - before a retrieval whose original may still be in iCloud, for instance - and it
    /// is the same demand for every video. The sentence says that rather than naming a copy
    /// nothing has measured yet.
    ///
    /// Sizes are rendered with Foundation's own formatter rather than the interface layer's, so the
    /// model keeps no dependency on the interface; it is the same arithmetic either way, and a
    /// figure therefore reads here exactly as it reads beside a saved copy.
    static func insufficientStorageSentence(needed: Int64) -> String {
        let reserve = DiskHeadroom.reserve
        guard needed > reserve else {
            return "BatchShrink needs \(bytes(reserve)) of free space before it starts on a video, and this iPhone doesn’t have that. Nothing was written and your original is unchanged. Free some space and try again."
        }
        return "BatchShrink asked for \(bytes(needed)) of free space to write this copy: the copy itself plus the \(bytes(reserve)) of working room it keeps free. This iPhone didn’t have that much, so nothing was written and your original is unchanged. Free some space and try again."
    }

    /// A size in the words every other size in the app is shown in.
    private static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    var errorDescription: String? {
        switch self {
        case .permissionDenied: return Self.refusedAccess
        case .assetUnavailable: return "This video is outside the Photos access granted to BatchShrink. Add it to your allowed videos in Settings, then try again."
        case .unsupported: return "BatchShrink cannot process this video. Live Photos, slow-motion, time-lapse, cinematic, spatial, edited, shared or restricted, HDR and ProRes videos are not supported yet. Try an ordinary, unedited video with one video track and at most one audio track."
        case .unsupportedOriginal(let reason): return reason
        case .exportUnavailable(let reason): return reason
        case .retrieval: return "Photos could not retrieve this video. If its original is in iCloud, check your connection and local storage, then try again."
        case .export: return "HEVC export failed. Keep BatchShrink open, check free storage and try a different video."
        case .verification: return "The output failed verification. No copy was saved."
        case .durationMismatch: return "The output duration differs from the source beyond the allowed tolerance. No copy was saved."
        case .audioMismatch: return "The output did not retain the source audio track count. No copy was saved."
        case .orientationMismatch: return "The output display shape differs from the source. No copy was saved."
        case .codecMismatch: return "The copy used a different video format than the chosen quality. No copy was saved."
        case .resolutionMismatch: return "The copy came out larger than the original. No copy was saved."
        case .frameRateMismatch: return "The copy did not reduce the frame rate as expected. No copy was saved."
        case .insufficientStorage: return "There wasn’t enough free space to make a copy. Nothing was saved and your original is unchanged. Getting a video from iCloud and saving a copy both need room, so free some space and try again."
        case .save: return "Photos did not confirm the save. Inspect Photos before retrying to avoid creating an extra copy. Your original was not changed."
        case .temporaryFiles: return "BatchShrink could not prepare or clean its temporary workspace. Restart the app and check local storage."
        case .libraryScan: return "BatchShrink couldn’t look through your Photos library. Check your connection and Photos access, then try again."
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
