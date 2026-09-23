import SwiftUI

@main
struct VideoShrinkApp: App {
    @StateObject private var settings: ShrinkSettings
    @StateObject private var model: CompressionViewModel
    @StateObject private var batch: BatchViewModel

    init() {
        // One settings object and one history store are shared by both flows. The temporary
        // workspace is deliberately not: a finished, unsaved one-video copy has to survive a
        // batch run, and the batch sweeps its own directory at the start and end of every run.
        // See `TemporaryWorkspace` for what went wrong while the two shared one.
        let settings = ShrinkSettings()
        let oneVideoWorkspace = TemporaryFileManager(workspace: .oneVideo)
        let batchWorkspace = TemporaryFileManager(workspace: .batch)
        // The same store for both, rather than one each. A copy saved in the one-video flow is this
        // app's own output, and the batch flow's "Select all" can only leave it alone if the two
        // flows write to and read from the same device-local memory. Both would still see the other
        // writing, because the store is backed by the same defaults, but one instance makes that
        // sharing the arrangement rather than a coincidence.
        let history = UserDefaultsShrinkHistoryStore()
        _settings = StateObject(wrappedValue: settings)
        _model = StateObject(wrappedValue: CompressionViewModel(
            photos: PhotoLibraryService(),
            transcoder: VideoTranscodingService(temporary: oneVideoWorkspace),
            verifier: VideoVerificationService(),
            temporary: oneVideoWorkspace,
            history: history,
            settings: settings
        ))
        _batch = StateObject(wrappedValue: BatchViewModel(
            photos: PhotoLibraryService(),
            scanner: PhotoLibraryScanService(),
            transcoder: VideoTranscodingService(temporary: batchWorkspace),
            verifier: VideoVerificationService(),
            temporary: batchWorkspace,
            history: history,
            queueStore: FileBatchQueueStore(),
            screenAwake: ScreenAwakeController(),
            settings: settings
        ))
    }

    var body: some Scene {
        WindowGroup { ContentView(model: model, batch: batch) }
    }
}
