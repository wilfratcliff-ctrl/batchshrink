import AVFoundation
import CoreMedia

/// Runs Apple's HEVC and H.264 presets, with a video composition only when the preset alone
/// cannot reach the requested size or frame rate.
@MainActor final class VideoTranscodingService: VideoTranscoding {
    private let temporary: any TemporaryFileManaging
    private var active: AVAssetExportSession?
    /// Set when a stop has been asked for, and cleared when a new export begins.
    ///
    /// A later plan builds a session of its own, so the session `cancel()` reaches at the instant
    /// it is called may not be the one that ends up running: a stop has to be remembered, not only
    /// delivered, or an attempt built after it runs to the end with nothing able to cancel it.
    /// Both callers cancel the task their export runs in, which is the other half of the same
    /// stop; this is the half the service owns.
    private var stopRequested = false

    init(temporary: any TemporaryFileManaging) {
        self.temporary = temporary
    }

    func transcode(_ source: RetrievedVideo,
                   metadata: VideoMetadata,
                   settings: TranscodeSettings,
                   progress: @escaping @MainActor (Double) -> Void) async throws -> URL {
        try Task.checkCancellation()
        // A stop belongs to the work it stopped. This service is shared by both flows, so one an
        // earlier run asked for must not refuse this one.
        stopRequested = false
        let destination = try temporary.outputURL()
        // The encoder writes straight into `destination`, so every way out of the work below that
        // is not a completed copy has to take that file with it. A failed attempt can leave bytes
        // behind - a stop can interrupt one mid-write - and nothing outside this function is ever
        // handed the URL on a failure path, so the partial copy would otherwise sit in the shared
        // workspace until the run ended. `BatchViewModel` can only remove an output it was given,
        // and this is exactly the case where it never gets one.
        do {
            let composition = settings.needsComposition(sourceLongEdge: metadata.longEdge,
                                                        sourceFrameRate: metadata.nominalFrameRate)
                ? await makeComposition(asset: source.asset, metadata: metadata, settings: settings)
                : nil
            let preserved = await preservedMetadata(of: source.asset)
            var plans = [TranscodePlan(composition: composition, metadata: preserved)]
            if composition != nil {
                plans.append(TranscodePlan(composition: nil, metadata: preserved))
            }
            if !preserved.isEmpty {
                plans.append(TranscodePlan(composition: nil, metadata: []))
            }
            var lastError: Error = PipelineError.export
            for (index, plan) in plans.enumerated() {
                // The stop is asked about again before every attempt, so an attempt is never started
                // under a stop that arrived while the one before it was unwinding.
                try checkStop()
                if index > 0 { try? temporary.remove(destination) }
                do {
                    let session = try makeSession(asset: source.asset, settings: settings)
                    session.videoComposition = plan.composition
                    session.metadata = plan.metadata
                    try await run(session, to: destination, progress: progress)
                    return destination
                } catch {
                    // A stopped attempt is answered by rethrowing rather than by trying the next
                    // plan: another plan would encode the whole clip again, and that is the work the
                    // stop was asked for in the first place.
                    if stopRequested || Task.isCancelled { throw error }
                    lastError = error
                }
            }
            throw lastError
        } catch {
            // Whatever the encoder managed to write is not a copy this run wants, so it goes now.
            // A removal that fails leaves the workspace for the run's own cleanup to sweep.
            try? temporary.remove(destination)
            throw error
        }
    }

    func cancel() {
        stopRequested = true
        active?.cancelExport()
    }

    /// Whether a stop is in hand, from either half of it: this service's own memory of `cancel()`,
    /// or the cancellation of the task this export runs in, which is what the one-video flow and
    /// the batch both use.
    private func checkStop() throws {
        if stopRequested || Task.isCancelled { throw PipelineError.cancelled }
    }

    /// One way of writing the copy. Later plans give up the extras so a stubborn file still
    /// produces something, and every attempt starts from a clean destination.
    private struct TranscodePlan {
        let composition: AVVideoComposition?
        let metadata: [AVMetadataItem]
    }

    private func makeSession(asset: AVURLAsset, settings: TranscodeSettings) throws -> AVAssetExportSession {
        guard let session = AVAssetExportSession(asset: asset, presetName: settings.resolution.presetName)
        else { throw ExportRefusal.noSession(resolution: settings.resolution).error }
        guard session.supportedFileTypes.contains(.mov)
        else { throw ExportRefusal.cannotWriteMovieFile(resolution: settings.resolution).error }
        session.shouldOptimizeForNetworkUse = false
        return session
    }

    /// Descriptive metadata the original exposes, camera and location tags included, is written
    /// into the copy rather than dropped. AVFoundation decides what a given container can carry,
    /// and nothing is invented here.
    private func preservedMetadata(of asset: AVAsset) async -> [AVMetadataItem] {
        if let all = try? await asset.load(.metadata), !all.isEmpty { return all }
        return (try? await asset.load(.commonMetadata)) ?? []
    }

    private func run(_ session: AVAssetExportSession, to url: URL,
                     progress: @escaping @MainActor (Double) -> Void) async throws {
        active = session
        let observer = Task { @MainActor in
            for await state in session.states(updateInterval: 0.25) {
                guard !Task.isCancelled else { break }
                if case let .exporting(value) = state { progress(value.fractionCompleted) }
            }
        }
        defer {
            observer.cancel()
            active = nil
        }
        // The session is active before anything is asked of it, so a stop that arrived between the
        // plan's own check and here still lands on it rather than on a session that has finished.
        try checkStop()
        // The iOS 18 async API handles task cancellation; cancel() stops the session explicitly.
        try await session.export(to: url, as: .mov)
        // An export that finished anyway under a stop is not handed back as a success: the caller
        // asked for this work to stop, and a copy this run no longer wants is not a copy it should
        // spend the next steps checking and saving.
        try checkStop()
    }

    private func makeComposition(asset: AVURLAsset, metadata: VideoMetadata,
                                 settings: TranscodeSettings) async -> AVVideoComposition? {
        guard let composition = try? await AVMutableVideoComposition.videoComposition(withPropertiesOf: asset)
        else { return nil }
        if let size = renderSize(metadata: metadata, settings: settings) {
            composition.renderSize = size
        }
        if let frames = settings.targetFrameRate(sourceFrameRate: metadata.nominalFrameRate) {
            composition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(frames.rounded()))
        }
        // Keep HDR display metadata on the rendered frames instead of dropping it quietly.
        composition.perFrameHDRDisplayMetadataPolicy = .propagate
        return composition
    }

    /// The size to render at: the requested long edge, never larger than the source, always
    /// with even dimensions because encoders require them.
    private func renderSize(metadata: VideoMetadata, settings: TranscodeSettings) -> CGSize? {
        guard metadata.width > 0, metadata.height > 0, metadata.longEdge > 0 else { return nil }
        let longEdge = settings.renderLongEdge(sourceLongEdge: metadata.longEdge)
        let scale = min(1, Double(longEdge) / Double(metadata.longEdge))
        let width = (Double(metadata.width) * scale / 2).rounded() * 2
        let height = (Double(metadata.height) * scale / 2).rounded() * 2
        return CGSize(width: max(2, width), height: max(2, height))
    }
}

/// What AVFoundation answered when this run asked it for an export it will not build.
///
/// Both answers are facts about this attempt rather than traits of the media, and together they
/// are everything the app can honestly tell someone whose video will never be exported: there is
/// no export session for the preset the quality they chose names, or the session Apple built
/// cannot write the container this app saves. Nothing here guesses at HDR, ProRes or an edit -
/// those are refused earlier, by `AssetRules`, in its own words.
///
/// The sentences live here rather than at the two `throw` sites so the mapping can be driven
/// without media to export, which is the only way this project can test it: the finding itself
/// comes from Apple's encoders, and no machine here has an encoder to refuse anything.
enum ExportRefusal: Equatable, Sendable {
    /// `AVAssetExportSession(asset:presetName:)` produced nothing: this iPhone has no export for
    /// this video at the preset the chosen quality names.
    case noSession(resolution: CopyResolution)
    /// A session exists, and `.mov` is not among the file types it can write.
    case cannotWriteMovieFile(resolution: CopyResolution)

    /// The error a caller sees, carrying the sentence for what was found.
    var error: PipelineError { .exportUnavailable(reason: sentence) }

    /// The finding in the app's own words, naming the quality the run actually asked for.
    ///
    /// The two cases deliberately read differently. "There is no export for this video at that
    /// quality" and "the export cannot write what this app saves" are different findings, and each
    /// one asks the user for something different, so neither sentence may be the other's.
    var sentence: String {
        switch self {
        case .noSession(let resolution):
            return "There's no \(resolution.title) export for this video on this iPhone, so BatchShrink can't make a smaller copy of it. Nothing was saved and your original is unchanged. Try a lower quality, or choose a different video."
        case .cannotWriteMovieFile(let resolution):
            return "The \(resolution.title) export this iPhone built for this video can't write a QuickTime movie, which is the only kind of file BatchShrink saves. Nothing was saved and your original is unchanged. Try a different quality, or choose a different video."
        }
    }
}
