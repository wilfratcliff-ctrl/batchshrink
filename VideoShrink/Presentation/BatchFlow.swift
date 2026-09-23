import SwiftUI

/// The batch flow: look through the library, choose videos and quality, work through them,
/// then read an honest summary.
struct BatchFlow: View {
    @ObservedObject var batch: BatchViewModel
    let useSingleVideo: () -> Void

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(ShrinkHaptics.storageKey) private var haptics = true
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
            .confirmationDialog("Shrink \(selectionCount) \(selectionNoun)?", isPresented: $confirmStart,
                                titleVisibility: .visible) {
                Button("Shrink \(selectionCount) \(selectionNoun)") { batch.start() }
                Button("Not yet", role: .cancel) {}
            } message: {
                Text(Self.confirmationMessage(settings: batch.settings.transcode,
                                              deletion: batch.effectiveDeletionMode))
            }
            .onChange(of: scenePhase) { _, value in
                if value == .background { batch.enteredBackground() }
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: batch.phase)
            // The end of a run obeys the same switch as the quality pills, through the one place
            // that decides what each haptic moment plays.
            .sensoryFeedback(trigger: batch.phase) { _, next in
                if next == .finished { return ShrinkHaptics.feedback(.finished, enabled: haptics) }
                if next == .failed { return ShrinkHaptics.feedback(.failed, enabled: haptics) }
                return nil
            }
            .onChange(of: batch.phase) { _, value in
                if value != .selecting { confirmStart = false }
            }
    }

    private var selectionCount: Int { batch.selection.count }
    private var selectionNoun: String { selectionCount == 1 ? "video" : "videos" }

    /// The last thing read before work starts, so it has to be true under the mode that applies
    /// right now rather than under the default one.
    ///
    /// `effectiveDeletionMode` is the run's own choice while a run is going and the user's current
    /// choice once it has stopped, and this dialog only ever appears before a run starts, so it is
    /// the choice the Originals sheet is showing. The two deleting modes borrow that sheet's own
    /// wording instead of restating it, so the confirmation and the choice cannot drift apart.
    /// Deleting is off unless the user turned it on.
    ///
    /// The picture size is named as a ceiling because `TranscodeSettings.effectiveResolution` never
    /// upscales: a 720p original in a run set to 4K is copied at 720p, which is the rule
    /// `QualitySelector` states and the export obeys. The sentence used to promise a copy "at 4K"
    /// for videos that would be copied smaller. The frame rate is named too, in the model's own
    /// terms - the target a lowering works towards, and one that is never raised - because this is
    /// the last screen before a run and it used to mention neither choice's effect.
    ///
    /// Static and internal so a case can read the sentence, which is the product here.
    static func confirmationMessage(settings: TranscodeSettings, deletion: DeletionMode) -> String {
        let copies = "Each smaller copy is saved to Photos as it finishes, at up to \(settings.resolution.title)\(frameRateClause(settings.frameRate))."
        guard deletion.deletesOriginals else {
            return "\(copies) Your originals stay exactly where they are."
        }
        return "\(copies) \(deletion.detail) Deleted originals sit in Recently Deleted for 30 days."
    }

    /// The frame-rate half of the confirmation, in the words the model uses for it: a target the
    /// export lowers towards, or every frame when nothing is asked of it.
    private static func frameRateClause(_ frameRate: FrameRateOption) -> String {
        guard let target = frameRate.framesPerSecond else { return ", keeping every frame" }
        return ", targeting \(Int(target)) fps"
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
