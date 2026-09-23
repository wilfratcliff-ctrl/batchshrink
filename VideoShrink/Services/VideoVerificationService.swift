import AVFoundation
import CoreVideo
import CoreMedia

// An actor keeps synchronous frame decoding off the UI's main actor.
actor VideoVerificationService: VideoVerifying {
    func inspect(_ url: URL) async throws -> VideoMetadata {
        try Task.checkCancellation()
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let size = values.fileSize, size > 0 else { throw PipelineError.verification }
        let asset = AVURLAsset(url: url)
        let playable = try await asset.load(.isPlayable)
        let duration = try await asset.load(.duration).seconds
        let videos = try await asset.loadTracks(withMediaType: .video)
        let audios = try await asset.loadTracks(withMediaType: .audio)
        guard playable, duration.isFinite, duration > 0, videos.count == 1, audios.count <= 1,
              let video = videos.first else { throw PipelineError.unsupported }
        let naturalSize = try await video.load(.naturalSize)
        let transform = try await video.load(.preferredTransform)
        let rect = CGRect(origin: .zero, size: naturalSize).applying(transform)
        guard rect.width.isFinite, rect.height.isFinite, abs(rect.width) > 0, abs(rect.height) > 0,
              abs(rect.width) < 100_000, abs(rect.height) < 100_000 else { throw PipelineError.unsupported }
        let formats = try await video.load(.formatDescriptions)
        let frameRate = try await video.load(.nominalFrameRate)
        return VideoMetadata(duration: duration, width: Int(abs(rect.width).rounded()),
                             height: Int(abs(rect.height).rounded()), bytes: Int64(size),
                             fileType: url.pathExtension.isEmpty ? "Unknown container" : url.pathExtension.uppercased(),
                             audioTrackCount: audios.count, isPlayable: playable,
                             codec: Self.codec(of: formats),
                             nominalFrameRate: Double(frameRate))
    }

    func verify(_ url: URL, source: VideoMetadata, expecting codec: VideoCodec?) async throws -> VideoMetadata {
        guard FileManager.default.fileExists(atPath: url.path) else { throw PipelineError.verification }
        let output = try await inspect(url)
        try VerificationRules.validate(source: source, output: output, expecting: codec)
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw PipelineError.verification }
        try await decodeSamples(of: asset, track: track)
        if source.audioTrackCount > 0 {
            try await confirmAudioIsPresent(in: asset)
        }
        return output
    }

    /// Decodes a frame near the start, the middle and the end of the track. One frame at the
    /// start cannot show a broken tail, and sampling stays cheap because it seeks instead of
    /// reading the whole file. The container's own duration check still catches truncation.
    /// This is not an end-to-end playback proof.
    private func decodeSamples(of asset: AVAsset, track: AVAssetTrack) async throws {
        let trackRange = try await track.load(.timeRange)
        let start = trackRange.start.seconds
        let length = trackRange.duration.seconds
        guard start.isFinite, length.isFinite, length > 0 else { throw PipelineError.verification }
        var decoded = 0
        for fraction in [0.1, 0.5, 0.9] {
            try Task.checkCancellation()
            let offset = start + length * fraction
            let remaining = start + length - offset
            guard remaining > 0.05 else { continue }
            if try await decodesFrame(of: asset, track: track, at: offset, window: min(0.5, remaining)) {
                decoded += 1
            }
        }
        guard decoded > 0 else { throw PipelineError.verification }
    }

    private func decodesFrame(of asset: AVAsset, track: AVAssetTrack,
                              at seconds: Double, window: Double) async throws -> Bool {
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: seconds, preferredTimescale: 600),
                                       duration: CMTime(seconds: window, preferredTimescale: 600))
        let frames = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        frames.alwaysCopiesSampleData = false
        guard reader.canAdd(frames) else { return false }
        reader.add(frames)
        guard reader.startReading() else { return false }
        defer { reader.cancelReading() }
        guard let sample = frames.copyNextSampleBuffer() else { return false }
        return CMSampleBufferGetImageBuffer(sample) != nil
    }

    /// A copy of a video with sound must carry sound. Track counts are checked already; this
    /// catches an audio track that survived as an empty shell.
    private func confirmAudioIsPresent(in asset: AVAsset) async throws {
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let audio = tracks.first else { throw PipelineError.audioMismatch }
        let range = try await audio.load(.timeRange)
        let duration = range.duration.seconds
        guard duration.isFinite, duration > 0 else { throw PipelineError.audioMismatch }
    }

    private static func codec(of formats: [CMFormatDescription]) -> VideoCodec {
        guard !formats.isEmpty else { return .other }
        let subtypes = formats.map { CMFormatDescriptionGetMediaSubType($0) }
        if subtypes.allSatisfy({ $0 == kCMVideoCodecType_HEVC }) { return .hevc }
        if subtypes.allSatisfy({ $0 == kCMVideoCodecType_H264 }) { return .h264 }
        return .other
    }
}
