import Foundation
import Combine
import OSLog

/// The one-video pipeline: choose, retrieve, transcode, verify, preview, then save.
@MainActor final class CompressionViewModel: ObservableObject {
    @Published private(set) var stage: PipelineStage = .idle
    @Published private(set) var progress: Double?
    @Published private(set) var retrievingFromCloud = false
    @Published private(set) var source: VideoMetadata?
    @Published private(set) var output: VideoMetadata?
    @Published private(set) var message: String?
    @Published private(set) var cleanupWarning: String?
    @Published private(set) var limitedAccess = false
    @Published private(set) var cancelling = false
    @Published var showingPicker = false
    @Published private(set) var previewURL: URL?

    let settings: ShrinkSettings

    private let photos: any PhotoLibraryServing
    private let transcoder: any VideoTranscoding
    private let verifier: any VideoVerifying
    private let temporary: any TemporaryFileManaging
    @Published private var work: Task<Void, Never>?
    private var outputURL: URL?
    private var identity = AssetIdentity.unknown
    private let log = Logger(subsystem: "VideoShrink", category: "Pipeline")
    /// Snapshot taken when a run starts, so changing quality never affects work in flight.
    private var activeSettings = TranscodeSettings.standard

    init(photos: any PhotoLibraryServing, transcoder: any VideoTranscoding,
         verifier: any VideoVerifying, temporary: any TemporaryFileManaging,
         settings: ShrinkSettings) {
        self.photos = photos
        self.transcoder = transcoder
        self.verifier = verifier
        self.temporary = temporary
        self.settings = settings
        cleanTemporaryFiles() // Remove interrupted exports from an earlier launch.
    }

    var savings: Savings? {
        guard let source, let output else { return nil }
        return Savings(originalBytes: source.bytes, compressedBytes: output.bytes)
    }
    var canChoose: Bool { work == nil && [.idle, .saved, .failed, .cancelled].contains(stage) }
    var canSave: Bool { work == nil && stage == .readyToSave && savings?.isSmaller == true }
    var canCancel: Bool { stage.canCancel && !cancelling }

    private func move(to next: PipelineStage) {
        guard stage.allows(next) else {
            log.error("Rejected invalid pipeline transition")
            return
        }
        stage = next
        progress = nil
        // Only fixed internal stage names, never paths, asset identifiers, or NSError descriptions.
        log.info("Pipeline stage: \(next.rawValue, privacy: .public)")
    }

    func chooseVideo() {
        guard canChoose else { return }
        source = nil; output = nil; message = nil; previewURL = nil
        outputURL = nil; identity = .unknown; retrievingFromCloud = false
        cancelling = false
        activeSettings = settings.transcode
        move(to: .waitingForPermission)
        work = Task {
            defer { work = nil }
            do {
                limitedAccess = try await photos.requestAccess()
                try Task.checkCancellation()
                move(to: .choosing)
                showingPicker = true
            } catch { fail(error, fallback: .permissionDenied) }
        }
    }

    func selected(identifier: String?) {
        guard stage == .choosing else { return }
        showingPicker = false
        guard let identifier else {
            message = PipelineError.assetUnavailable.localizedDescription
            move(to: .failed)
            return
        }
        move(to: .retrieving)
        work = Task {
            defer { work = nil; cancelling = false }
            do {
                try temporary.cleanup()
                try temporary.ensureWorkspace()
                // Unknown original size before retrieval: a floor, not a download-space guarantee.
                try temporary.requireCapacity(for: DiskHeadroom.reserve)
                let retrieved = try await photos.retrieve(identifier: identifier) { [weak self] value in
                    guard let self, self.stage == .retrieving, !self.cancelling else { return }
                    self.retrievingFromCloud = true
                    self.setProgress(value)
                }
                try Task.checkCancellation()
                identity = retrieved.identity
                move(to: .preparing)
                let original = try await verifier.inspect(retrieved.asset.url)
                try Task.checkCancellation()
                source = original
                // Heuristic headroom for an output plus scratch space. Never a storage reservation.
                try temporary.requireCapacity(for: DiskHeadroom.bytes(original.bytes, copies: 2))
                move(to: .transcoding)
                let written = try await transcoder.transcode(retrieved, metadata: original,
                                                             settings: activeSettings) { [weak self] value in
                    guard let self, self.stage == .transcoding, !self.cancelling else { return }
                    self.setProgress(value)
                }
                outputURL = written
                try Task.checkCancellation()
                move(to: .verifying)
                output = try await verifier.verify(written, source: original, expecting: activeSettings.codec)
                try Task.checkCancellation()
                previewURL = written
                move(to: .readyToSave)
                if savings?.isSmaller != true {
                    message = "This export is not smaller. Saving is disabled. Discard it and try another video."
                }
            } catch {
                fail(error, fallback: stage == .transcoding ? .export : (stage == .verifying ? .verification : .retrieval))
            }
        }
    }

    func pickerCancelled() {
        showingPicker = false
        if stage == .choosing { move(to: .cancelled) }
    }

    func save() {
        guard canSave, let url = outputURL, let original = source else { return }
        // Disable repeated taps before the first await. The Photos transaction is not cancellable.
        previewURL = nil
        move(to: .saving)
        work = Task {
            defer { work = nil }
            do {
                // Recheck immediately before save, in case iOS removed a temporary file.
                let checked = try await verifier.verify(url, source: original, expecting: activeSettings.codec)
                guard Savings(originalBytes: original.bytes, compressedBytes: checked.bytes).isSmaller
                else { throw PipelineError.verification }
                try temporary.requireCapacity(for: DiskHeadroom.bytes(checked.bytes, copies: 1))
                _ = try await photos.save(videoAt: url, identity: identity)
                output = checked
                move(to: .saved)
                message = "A separate copy was saved. Your original is unchanged. No iCloud storage has been reclaimed."
                cleanTemporaryFiles()
            } catch { fail(error, fallback: .save) }
        }
    }

    func cancel() {
        guard canCancel else { return }
        message = "Cancelling…"
        cancelling = true
        if let work {
            work.cancel()
            photos.cancelRetrieval()
            transcoder.cancel()
            // Cleanup happens only after export unwinds, never while it may still write.
        } else {
            previewURL = nil
            cleanTemporaryFiles()
            move(to: .cancelled)
            message = "Discarded. Your original is unchanged."
            cancelling = false
        }
    }

    func enteredBackground() {
        // There is no background execution entitlement. In-flight saves must be allowed to settle.
        if [.retrieving, .preparing, .transcoding, .verifying].contains(stage) { cancel() }
    }

    private func setProgress(_ value: Double) {
        guard value.isFinite else { return }
        progress = min(1, max(0, value))
    }

    private func fail(_ error: Error, fallback: PipelineError) {
        let normalized = Task.isCancelled ? PipelineError.cancelled : PipelineError.normalize(error, fallback: fallback)
        previewURL = nil
        cleanTemporaryFiles()
        move(to: normalized == .cancelled ? .cancelled : .failed)
        message = normalized.localizedDescription
        cancelling = false
    }

    private func cleanTemporaryFiles() {
        outputURL = nil
        do { try temporary.cleanup(); cleanupWarning = nil }
        catch {
            cleanupWarning = "Temporary cleanup could not finish. Restart BatchShrink to retry."
            log.error("Temporary cleanup failed")
        }
    }
}
