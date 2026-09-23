import AVFoundation
import CoreVideo
import CoreMedia

// An actor keeps synchronous frame decoding off the UI's main actor.
actor VideoVerificationService: VideoVerifying {

    /// One decode attempt that verification requires to produce at least one sample.
    struct SampleWindow: Equatable, Sendable {
        let offset: Double
        let window: Double
    }

    /// The shortest slice of track worth reading. A tail shorter than this cannot reliably
    /// hold a frame, so the policy below leaves that window out instead of guessing at it.
    static let minimumSampleWindow: Double = 0.05

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

    /// Verifies an export this run produced, compared with the original it came from.
    func verify(_ url: URL, source: VideoMetadata, expecting codec: VideoCodec?) async throws -> VideoMetadata {
        try await verifyCopy(at: url, against: source, expecting: codec)
    }

    /// Verifies a copy Photos handed back after import, compared with the output properties
    /// this run measured and approved before saving. Both checks share one comparison, so the
    /// read-back path cannot drift into a weaker rule set of its own. This says nothing about
    /// audio sync or how the picture looks; those are not measurable here.
    func verifyImportedCopy(_ url: URL, matching expected: VideoMetadata) async throws -> VideoMetadata {
        try await verifyCopy(at: url, against: expected, expecting: expected.codec)
    }

    /// The one comparison both entry points above use. It delegates to `VerificationRules`
    /// rather than restating a rule here, and it takes already measured properties so that
    /// mismatched duration, audio, shape or resolution can be exercised without a media fixture.
    static func validate(expected: VideoMetadata, observed: VideoMetadata,
                         expecting codec: VideoCodec?) throws {
        try VerificationRules.validate(source: expected, output: observed, expecting: codec)
    }

    private func verifyCopy(at url: URL, against expected: VideoMetadata,
                            expecting codec: VideoCodec?) async throws -> VideoMetadata {
        guard FileManager.default.fileExists(atPath: url.path) else { throw PipelineError.verification }
        let observed = try await inspect(url)
        try Self.validate(expected: expected, observed: observed, expecting: codec)
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw PipelineError.verification }
        try await decodeSamples(of: asset, track: track)
        if expected.audioTrackCount > 0 {
            try await confirmAudioIsPresent(in: asset)
        }
        return observed
    }

    /// Requires a frame from every window this clip can host: near the start, the middle and
    /// the end of the track. One frame at the start cannot show a broken tail, and sampling
    /// stays cheap because it seeks instead of reading the whole file.
    ///
    /// Policy: a window that fails to decode fails verification. A window is required only when
    /// its own range is at least `minimumSampleWindow` long; that is the stated reason a tail
    /// window can be absent for a short clip. A clip too short to host that window is not
    /// skipped - it is sampled as one window covering the whole clip - so a stunted clip fails
    /// rather than passing by omission, and a short but valid clip passes because the window it
    /// does have decoded. This is a sampling check, not an end-to-end playback proof.
    private func decodeSamples(of asset: AVAsset, track: AVAssetTrack) async throws {
        let trackRange = try await track.load(.timeRange)
        let start = trackRange.start.seconds
        let length = trackRange.duration.seconds
        guard start.isFinite, length.isFinite, length > 0 else { throw PipelineError.verification }
        var decoded: [Bool] = []
        for sample in Self.sampleWindows(start: start, length: length) {
            try Task.checkCancellation()
            decoded.append(try await decodesFrame(of: asset, track: track,
                                                  at: sample.offset, window: sample.window))
        }
        guard Self.allWindowsDecoded(decoded) else { throw PipelineError.verification }
    }

    /// The windows verification requires for a track that runs from `start` for `length`.
    /// Positions are fractions of that track's own range, so a track that does not begin at
    /// zero is sampled on its own timeline.
    ///
    /// A window is required only when at least `minimumSampleWindow` of track remains after
    /// its start, which is the documented reason a tail window can be left out of a short
    /// clip. When no window fits at all the clip is sampled as a single window covering the
    /// whole of it, so nothing is ever skipped without a stated reason. An empty result means
    /// the range itself was unusable. Only the 0.1, 0.5 and 0.9 positions are sampled.
    static func sampleWindows(start: Double, length: Double) -> [SampleWindow] {
        guard start.isFinite, length.isFinite, length > 0 else { return [] }
        let end = start + length
        var windows: [SampleWindow] = []
        for fraction in [0.1, 0.5, 0.9] {
            let offset = start + length * fraction
            let remaining = end - offset
            if remaining >= minimumSampleWindow {
                windows.append(SampleWindow(offset: offset, window: min(0.5, remaining)))
            }
        }
        if windows.isEmpty {
            windows.append(SampleWindow(offset: start, window: length))
        }
        return windows
    }

    /// True only when every required window produced a sample. An empty result means nothing
    /// was checked, which is not a pass.
    static func allWindowsDecoded(_ results: [Bool]) -> Bool {
        !results.isEmpty && results.allSatisfy { $0 }
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

    /// A copy of a video with sound must carry audio that can actually be read back. Track
    /// counts are compared already; this catches an audio track that survived as an empty
    /// shell. It proves readable samples exist at the sampled positions of the audio track,
    /// under the same short-clip policy used for the picture. It does not measure loudness,
    /// whether the sound is audible, or how it lines up with the picture, so no claim is made
    /// about any of those.
    private func confirmAudioIsPresent(in asset: AVAsset) async throws {
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let audio = tracks.first else { throw PipelineError.audioMismatch }
        let range = try await audio.load(.timeRange)
        let start = range.start.seconds
        let length = range.duration.seconds
        guard start.isFinite, length.isFinite, length > 0 else { throw PipelineError.audioMismatch }
        var decoded: [Bool] = []
        for sample in Self.sampleWindows(start: start, length: length) {
            try Task.checkCancellation()
            decoded.append(try await decodesAudio(of: asset, track: audio,
                                                  at: sample.offset, window: sample.window))
        }
        guard Self.allWindowsDecoded(decoded) else { throw PipelineError.audioMismatch }
    }

    /// Reads one audio sample out of a window. No output settings means each sample is passed
    /// through in its stored format, which is all this check needs: at least one real sample,
    /// not a particular decoded layout.
    private func decodesAudio(of asset: AVAsset, track: AVAssetTrack,
                              at seconds: Double, window: Double) async throws -> Bool {
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: seconds, preferredTimescale: 600),
                                       duration: CMTime(seconds: window, preferredTimescale: 600))
        let samples = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        samples.alwaysCopiesSampleData = false
        guard reader.canAdd(samples) else { return false }
        reader.add(samples)
        guard reader.startReading() else { return false }
        defer { reader.cancelReading() }
        guard let sample = samples.copyNextSampleBuffer() else { return false }
        return CMSampleBufferGetNumSamples(sample) > 0
    }

    private static func codec(of formats: [CMFormatDescription]) -> VideoCodec {
        guard !formats.isEmpty else { return .other }
        let subtypes = formats.map { CMFormatDescriptionGetMediaSubType($0) }
        if subtypes.allSatisfy({ $0 == kCMVideoCodecType_HEVC }) { return .hevc }
        if subtypes.allSatisfy({ $0 == kCMVideoCodecType_H264 }) { return .h264 }
        return .other
    }
}
