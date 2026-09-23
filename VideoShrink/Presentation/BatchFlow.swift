import SwiftUI

/// The batch flow: look through the library, choose videos and quality, work through them,
/// then read an honest summary.
struct BatchFlow: View {
    @ObservedObject var batch: BatchViewModel
    let useSingleVideo: () -> Void

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("completionHaptics") private var completionHaptics = true
    @State private var showHelp = false
    @State private var showQuality = false
    @State private var showDeletion = false
    @State private var confirmStart = false

    var body: some View {
        screen
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    HelpButton { showHelp = true }
                }
            }
            .sheet(isPresented: $showHelp) { ShrinkHelp(settings: batch.settings) }
            .sheet(isPresented: $showQuality) {
                QualitySheet(settings: batch.settings) { batch.estimate(for: $0) }
            }
            .sheet(isPresented: $showDeletion) { DeletionSheet(settings: batch.settings) }
            .confirmationDialog("Shrink \(batch.selection.count) videos?", isPresented: $confirmStart,
                                titleVisibility: .visible) {
                Button("Shrink \(batch.selection.count) videos") { batch.start() }
                Button("Not yet", role: .cancel) {}
            } message: {
                Text("Each smaller copy is saved to Photos as it finishes, at \(batch.settings.resolution.title). Your originals stay exactly where they are.")
            }
            .onChange(of: scenePhase) { _, value in
                if value == .background { batch.enteredBackground() }
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: batch.phase)
            .sensoryFeedback(trigger: batch.phase) { _, next in
                guard completionHaptics else { return nil }
                if next == .finished { return .success }
                if next == .failed { return .error }
                return nil
            }
            .onChange(of: batch.phase) { _, value in
                if value != .selecting { confirmStart = false }
            }
    }

    @ViewBuilder private var screen: some View {
        switch batch.phase {
        case .start:
            BatchStartScreen(batch: batch, useSingleVideo: useSingleVideo,
                             openDeletion: { showDeletion = true })
        case .scanning:
            BatchScanningScreen(batch: batch)
        case .scanned:
            BatchSummaryScreen(batch: batch, openQuality: { showQuality = true })
        case .selecting:
            BatchSelectionScreen(batch: batch, confirmStart: $confirmStart,
                                 openQuality: { showQuality = true })
        case .processing:
            BatchProcessingScreen(batch: batch)
        case .paused:
            BatchPausedScreen(batch: batch)
        case .finished:
            BatchFinishedScreen(batch: batch)
        case .failed:
            BatchRecoveryScreen(batch: batch, useSingleVideo: useSingleVideo)
        }
    }
}
