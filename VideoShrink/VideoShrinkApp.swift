import SwiftUI

@main
struct VideoShrinkApp: App {
    @StateObject private var settings: ShrinkSettings
    @StateObject private var model: CompressionViewModel
    @StateObject private var batch: BatchViewModel

    init() {
        // One settings object, one temporary workspace and one history store are shared by both
        // flows.
        let settings = ShrinkSettings()
        let temporary = TemporaryFileManager()
        // The same store for both, rather than one each. A copy saved in the one-video flow is this
        // app's own output, and the batch flow's "Select all" can only leave it alone if the two
        // flows write to and read from the same device-local memory. Both would still see the other
        // writing, because the store is backed by the same defaults, but one instance makes that
        // sharing the arrangement rather than a coincidence.
        let history = UserDefaultsShrinkHistoryStore()
        _settings = StateObject(wrappedValue: settings)
        _model = StateObject(wrappedValue: CompressionViewModel(
            photos: PhotoLibraryService(),
            transcoder: VideoTranscodingService(temporary: temporary),
            verifier: VideoVerificationService(),
            temporary: temporary,
            history: history,
            settings: settings
        ))
        _batch = StateObject(wrappedValue: BatchViewModel(
            photos: PhotoLibraryService(),
            scanner: PhotoLibraryScanService(),
            transcoder: VideoTranscodingService(temporary: temporary),
            verifier: VideoVerificationService(),
            temporary: temporary,
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
