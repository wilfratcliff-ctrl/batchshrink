import SwiftUI

@main
struct VideoShrinkApp: App {
    @StateObject private var settings: ShrinkSettings
    @StateObject private var model: CompressionViewModel
    @StateObject private var batch: BatchViewModel

    init() {
        // One settings object and one temporary workspace are shared by both flows.
        let settings = ShrinkSettings()
        let temporary = TemporaryFileManager()
        _settings = StateObject(wrappedValue: settings)
        _model = StateObject(wrappedValue: CompressionViewModel(
            photos: PhotoLibraryService(),
            transcoder: VideoTranscodingService(temporary: temporary),
            verifier: VideoVerificationService(),
            temporary: temporary,
            settings: settings
        ))
        _batch = StateObject(wrappedValue: BatchViewModel(
            photos: PhotoLibraryService(),
            scanner: PhotoLibraryScanService(),
            transcoder: VideoTranscodingService(temporary: temporary),
            verifier: VideoVerificationService(),
            temporary: temporary,
            history: UserDefaultsShrinkHistoryStore(),
            queueStore: FileBatchQueueStore(),
            screenAwake: ScreenAwakeController(),
            settings: settings
        ))
    }

    var body: some Scene {
        WindowGroup { ContentView(model: model, batch: batch) }
    }
}
