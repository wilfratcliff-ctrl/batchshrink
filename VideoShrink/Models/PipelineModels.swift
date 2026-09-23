import Foundation
import AVFoundation

enum PipelineStage: String, CaseIterable {
    case idle, waitingForPermission, choosing, retrieving, preparing, transcoding
    case verifying, readyToSave, saving, saved, failed, cancelled

    var title: String {
        switch self {
        case .idle: return "Choose one video to begin"
        case .waitingForPermission: return "Waiting for permission"
        case .choosing: return "Choose a video"
        case .retrieving: return "Retrieving video"
        case .preparing: return "Preparing"
        case .transcoding: return "Transcoding"
        case .verifying: return "Verifying"
        case .readyToSave: return "Ready to save"
        case .saving: return "Saving to Photos"
        case .saved: return "Saved"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        }
    }

    var canCancel: Bool {
        [.waitingForPermission, .retrieving, .preparing, .transcoding, .verifying, .readyToSave].contains(self)
    }

    func allows(_ next: PipelineStage) -> Bool {
        if next == .cancelled { return canCancel || self == .choosing }
        if next == .failed { return ![.idle, .saved, .cancelled].contains(self) }
        switch (self, next) {
        case (.idle, .waitingForPermission), (.saved, .waitingForPermission),
             (.failed, .waitingForPermission), (.cancelled, .waitingForPermission),
             (.waitingForPermission, .choosing), (.choosing, .retrieving),
             (.retrieving, .preparing), (.preparing, .transcoding),
             (.transcoding, .verifying), (.verifying, .readyToSave),
             (.readyToSave, .saving), (.saving, .saved): return true
        default: return false
        }
    }
}

struct VideoMetadata: Equatable, Sendable {
    let duration: Double
    let width: Int
    let height: Int
    let bytes: Int64
    let fileType: String
    let audioTrackCount: Int
    let isPlayable: Bool
    let codec: VideoCodec
    let nominalFrameRate: Double

    var isHEVC: Bool { codec == .hevc }
    var longEdge: Int { max(width, height) }
}

struct RetrievedVideo {
    // Retain the PhotoKit representation for the lifetime of the export.
    let asset: AVURLAsset
    let identity: AssetIdentity
}

struct Savings: Equatable, Sendable {
    let originalBytes: Int64
    let compressedBytes: Int64
    var bytesSaved: Int64 { originalBytes - compressedBytes }
    var percentage: Double? {
        guard originalBytes > 0 else { return nil }
        return Double(bytesSaved) / Double(originalBytes) * 100
    }
    var isSmaller: Bool { originalBytes > 0 && compressedBytes > 0 && bytesSaved > 0 }
}

enum VerificationRules {
    static func validate(source: VideoMetadata, output: VideoMetadata, expecting codec: VideoCodec?) throws {
        guard output.bytes > 0, output.isPlayable, output.width > 0, output.height > 0,
              output.codec == .hevc || output.codec == .h264 else { throw PipelineError.verification }
        if let codec {
            // Receiving the better codec than the one requested is not a failure.
            let acceptable = output.codec == codec || (codec == .h264 && output.codec == .hevc)
            guard acceptable else { throw PipelineError.codecMismatch }
        }
        guard source.duration.isFinite, source.duration > 0,
              output.duration.isFinite, output.duration > 0,
              abs(source.duration - output.duration) <= max(0.25, source.duration * 0.001)
        else { throw PipelineError.durationMismatch }
        guard source.audioTrackCount == output.audioTrackCount else { throw PipelineError.audioMismatch }
        let sourceAspect = Double(source.width) / Double(max(1, source.height))
        let outputAspect = Double(output.width) / Double(output.height)
        guard abs(sourceAspect - outputAspect) / max(sourceAspect, 0.001) < 0.02 else {
            throw PipelineError.orientationMismatch
        }
        // A copy is never larger than its original, in pixels or in frames per second.
        guard output.longEdge <= source.longEdge + 2 else { throw PipelineError.resolutionMismatch }
        if source.nominalFrameRate > 1, output.nominalFrameRate > 1 {
            guard output.nominalFrameRate <= source.nominalFrameRate * 1.05 + 0.01 else {
                throw PipelineError.frameRateMismatch
            }
        }
    }
}
