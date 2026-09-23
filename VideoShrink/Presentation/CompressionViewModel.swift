import Foundation
import Combine
import OSLog
import Photos

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
    /// The device-local memory of what this app has made.
    ///
    /// The one-video flow has no library and no deletion, so it reads nothing from this store. It
    /// writes to it, and that is the whole point: a copy Photos hands back here is a new asset with
    /// an identifier of its own, and if the identifier is not written down, the batch flow's
    /// "Select all" cannot tell the copy from an untouched original and will shrink this app's own
    /// output all over again. It is the same store the batch flow reads, so the two flows agree
    /// about what this app created.
    private let history: any ShrinkHistoryStoring
    /// Photos' own authorization status, read for the one question a permission failure cannot
    /// answer from the message alone: whether access is missing because the user refused it or
    /// because something outside the app restricts it.
    ///
    /// The batch flow reads the same status for the same reason, and the two readings need
    /// different words: a refusal is answered with Settings, where the user can allow it again,
    /// while a restriction taken by Screen Time or a device management profile cannot be lifted
    /// there at all - Photos is not on this app's Settings page while it is on, so naming Settings
    /// would send the user to a switch that does not exist.
    ///
    /// It is a parameter, with the real reading as its default, so a test can drive the state a
    /// simulator cannot be put in.
    private let authorizationStatus: () -> PHAuthorizationStatus
    @Published private var work: Task<Void, Never>?
    private var outputURL: URL?
    private var identity = AssetIdentity.unknown
    private let log = Logger(subsystem: "VideoShrink", category: "Pipeline")
    /// Snapshot taken when a run starts, so changing quality never affects work in flight.
    private var activeSettings = TranscodeSettings.standard

    init(photos: any PhotoLibraryServing, transcoder: any VideoTranscoding,
         verifier: any VideoVerifying, temporary: any TemporaryFileManaging,
         history: any ShrinkHistoryStoring = UserDefaultsShrinkHistoryStore(),
         settings: ShrinkSettings,
         authorizationStatus: @escaping () -> PHAuthorizationStatus = {
             PHPhotoLibrary.authorizationStatus(for: .readWrite)
         }) {
        self.photos = photos
        self.transcoder = transcoder
        self.verifier = verifier
        self.temporary = temporary
        self.history = history
        self.settings = settings
        self.authorizationStatus = authorizationStatus
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
            // The figure the step in hand asked the workspace for, kept beside the call so a space
            // refusal can state what it wanted. It is dropped the moment the check lets the step
            // through, so a later failure is never described in terms of a check that already
            // passed.
            var demanded: Int64?
            do {
                try temporary.cleanup()
                try temporary.ensureWorkspace()
                // Unknown original size before retrieval: a floor, not a download-space guarantee.
                let floor = DiskHeadroom.neededToWrite(nil)
                demanded = floor
                try temporary.requireCapacity(for: floor)
                demanded = nil
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
                // One file is about to be written, not two; see the batch flow's note.
                let copyRoom = DiskHeadroom.neededToWrite(original.bytes)
                demanded = copyRoom
                try temporary.requireCapacity(for: copyRoom)
                demanded = nil
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
                fail(error, fallback: stage == .transcoding ? .export : (stage == .verifying ? .verification : .retrieval),
                     demanded: demanded)
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
            var demanded: Int64?
            do {
                // Recheck immediately before save, in case iOS removed a temporary file.
                let checked = try await verifier.verify(url, source: original, expecting: activeSettings.codec)
                guard Savings(originalBytes: original.bytes, compressedBytes: checked.bytes).isSmaller
                else { throw PipelineError.verification }
                let saveRoom = DiskHeadroom.neededToWrite(checked.bytes)
                demanded = saveRoom
                try temporary.requireCapacity(for: saveRoom)
                demanded = nil
                let created = try await photos.save(videoAt: url, identity: identity)
                // Written down at the moment the identifier exists, in the same store the batch
                // flow reads, so a later bulk selection leaves this app's own copy alone. The
                // copy never enters `completedIdentifiers`: that set means "this original was
                // shrunk", and the copy is not an original. It stays visible in the library and
                // can still be chosen by hand.
                if let created { history.recordCreatedCopy(identifier: created) }
                output = checked
                move(to: .saved)
                message = "A separate copy was saved. Your original is unchanged. No iCloud storage has been reclaimed."
                cleanTemporaryFiles()
            } catch { fail(error, fallback: .save, demanded: demanded) }
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

    private func fail(_ error: Error, fallback: PipelineError, demanded: Int64? = nil) {
        let normalized = Task.isCancelled ? PipelineError.cancelled : PipelineError.normalize(error, fallback: fallback)
        previewURL = nil
        cleanTemporaryFiles()
        // `.saving` is the one stage with no move to `.cancelled`: Photos holds the save and there
        // is no supported way to take it back, so the run waits for Photos to answer. A
        // cancellation surfacing from there is reported as a save that did not confirm, because
        // `move` would otherwise refuse `.cancelled` and leave the screen resting on "Saving to
        // Photos" with a message and nothing to press.
        if normalized == .cancelled, !stage.allows(.cancelled) {
            move(to: .failed)
            message = PipelineError.save.localizedDescription
        } else {
            move(to: normalized == .cancelled ? .cancelled : .failed)
            // Two failures wear words this flow can write better than the case's own sentence:
            // access something outside the app switched off, which is not a refusal the user can
            // undo in Settings, and a space refusal whose figure this step asked for and still
            // holds.
            if normalized == .permissionDenied {
                message = PipelineError.accessSentence(restricted: authorizationStatus() == .restricted)
            } else if normalized == .insufficientStorage, let demanded {
                message = PipelineError.insufficientStorageSentence(needed: demanded)
            } else {
                message = normalized.localizedDescription
            }
        }
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
