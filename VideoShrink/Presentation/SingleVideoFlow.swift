import SwiftUI
import AVKit

/// The one-video path: choose, process, preview, then save.
///
/// Kept alongside the batch flow for anyone who wants to look at a copy before it reaches
/// Photos, and because it is the safest place to test the pipeline on a single clip.
struct SingleVideoFlow: View {
    @ObservedObject var model: CompressionViewModel
    let useBatch: () -> Void

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("completionHaptics") private var completionHaptics = true
    @State private var sheet: DetailSheet?
    @State private var confirmation: Confirmation?
    @State private var showQuality = false

    private enum DetailSheet: Identifiable {
        case help, preview(URL)
        var id: String {
            switch self {
            case .help: return "help"
            case .preview(let url): return url.absoluteString
            }
        }
    }

    private enum Confirmation {
        case save, discard
        var title: String {
            self == .save ? "Save a separate copy?" : "Discard this compressed copy?"
        }
        var message: String {
            self == .save
                ? "Your original stays in Photos. The new copy may sync with iCloud Photos. Keeping both uses more storage. Saving cannot be cancelled once it starts."
                : "Only the temporary compressed copy will be removed. Your original stays in Photos."
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                stageContent
                if model.stage == .idle {
                    QualityRow(settings: model.settings) { showQuality = true }
                }
                if model.limitedAccess && model.canChoose {
                    ShrinkNotice(symbol: "photo.badge.checkmark", title: "Limited Photos access",
                                 detail: "Choose a video you’ve allowed, or update Photos access in Help.")
                }
                if let warning = model.cleanupWarning {
                    ShrinkNotice(symbol: "exclamationmark.triangle", title: "Cleanup needs attention", detail: warning)
                }
                if let source = model.source, ![.failed, .cancelled].contains(model.stage) {
                    VideoDetails(source: source, output: model.output)
                }
            }
            .frame(maxWidth: 540)
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 28)
            .frame(maxWidth: .infinity)
        }
        .background(ShrinkStyle.canvas)
        .safeAreaInset(edge: .bottom, spacing: 0) { actionBar }
        .navigationTitle("One video")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Batch") { useBatch() }
                    .font(.subheadline.weight(.medium))
                    .frame(minHeight: 44)
                    .disabled(!model.canChoose)
                    .accessibilityHint("Go back to shrinking several videos at once.")
            }
            ToolbarItem(placement: .topBarTrailing) {
                HelpButton { sheet = .help }
            }
        }
        .sheet(isPresented: $model.showingPicker, onDismiss: model.pickerCancelled) {
            VideoPicker(selected: model.selected, cancelled: model.pickerCancelled)
        }
        .sheet(item: $sheet) { destination in
            switch destination {
            case .help: ShrinkHelp(settings: model.settings)
            case .preview(let url): VideoPreview(url: url)
            }
        }
        .sheet(isPresented: $showQuality) {
            QualitySheet(settings: model.settings,
                         estimate: { _ in nil },
                         placeholder: "Pick a video and BatchShrink measures the copy it makes.")
        }
        .confirmationDialog(confirmation?.title ?? "", isPresented: Binding(
            get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }
        ), titleVisibility: .visible, presenting: confirmation) { action in
            switch action {
            case .save: Button("Save copy to Photos") { model.save() }
            case .discard: Button("Discard temporary copy", role: .destructive) { model.cancel() }
            }
            Button("Keep reviewing", role: .cancel) {}
        } message: { action in
            Text(action.message)
        }
        .onChange(of: scenePhase) { _, value in
            if value == .background { model.enteredBackground() }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: model.stage)
        .sensoryFeedback(trigger: model.stage) { _, next in
            guard completionHaptics else { return nil }
            if next == .saved { return .success }
            if next == .failed { return .error }
            return nil
        }
    }

    @ViewBuilder private var stageContent: some View {
        switch model.stage {
        case .idle:
            ShrinkWelcome()
        case .readyToSave, .saved:
            if let source = model.source, let output = model.output {
                ShrinkResult(source: source, output: output, saved: model.stage == .saved)
                if model.stage == .readyToSave, let url = model.previewURL {
                    Button { sheet = .preview(url) } label: {
                        HStack(spacing: 16) {
                            Image(systemName: "play.circle.fill").font(.largeTitle)
                            VStack(alignment: .leading, spacing: 5) {
                                Text("Take a look").font(.headline)
                                Text("Check picture, orientation and sound.")
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right").font(.caption.weight(.bold))
                        }
                        .padding(20).shrinkCard()
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Preview compressed video")
                    .accessibilityHint("Check picture, orientation and sound before saving.")
                    .accessibilityIdentifier("previewVideo")
                    // An HDR original never reaches this state: reading its format refuses it before
                    // the export starts, so advice about previewing one would describe a video the
                    // screen cannot be showing.
                    Text("Compression can reduce quality. Preview the copy before saving.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        case .failed, .cancelled:
            ShrinkRecovery(failed: model.stage == .failed, message: model.message)
        default:
            ShrinkProgress(stage: model.stage, progress: model.progress,
                           fromCloud: model.retrievingFromCloud, cancelling: model.cancelling)
        }
    }

    private var actionBar: some View {
        ShrinkActionBar {
            if model.canChoose {
                ShrinkPrimaryButton(title: model.stage == .idle ? "Choose a video" : "Choose another video",
                                    symbol: "plus", action: model.chooseVideo)
                    .accessibilityIdentifier("chooseVideo")
                Label("Your original stays untouched", systemImage: "checkmark.shield")
                    .font(.footnote).foregroundStyle(.secondary)
                if model.stage == .idle {
                    Button("Shrink several videos instead", action: useBatch)
                        .font(.subheadline.weight(.medium))
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("useBatch")
                }
            } else if model.stage == .readyToSave {
                ShrinkPrimaryButton(title: "Save copy to Photos", symbol: "square.and.arrow.down") {
                    confirmation = .save
                }
                .disabled(!model.canSave)
                .accessibilityIdentifier("saveCopy")
                Button("Discard temporary copy", role: .destructive) { confirmation = .discard }
                    .font(.subheadline.weight(.medium)).frame(minHeight: 44)
                    .disabled(!model.canCancel)
            } else if model.stage == .saving {
                Label("Saving your copy…", systemImage: "photo")
                    .font(.headline).frame(maxWidth: .infinity, minHeight: 52)
                Text("Please wait for Photos to confirm.").font(.footnote).foregroundStyle(.secondary)
            } else if model.canCancel || model.cancelling {
                Button(model.cancelling ? "Cancelling…" : "Cancel processing", action: model.cancel)
                    .font(.headline).frame(maxWidth: .infinity, minHeight: 52)
                    .disabled(!model.canCancel)
            }
        }
    }
}

struct VideoDetails: View {
    let source: VideoMetadata
    let output: VideoMetadata?

    var body: some View {
        DisclosureGroup {
            VStack(spacing: 14) {
                LabeledContent("Duration", value: ShrinkFormat.duration(source.duration))
                LabeledContent("Original", value: ShrinkFormat.bytes(source.bytes))
                LabeledContent("Original resolution", value: "\(source.width) × \(source.height)")
                LabeledContent("Container", value: source.fileType)
                LabeledContent("Audio tracks", value: source.audioTrackCount.formatted())
                if let output {
                    LabeledContent("Copy", value: ShrinkFormat.bytes(output.bytes))
                    LabeledContent("Copy resolution", value: "\(output.width) × \(output.height)")
                    LabeledContent("Copy format", value: output.codec.displayName)
                    LabeledContent("Copy frame rate", value: ShrinkFormat.frameRate(output.nominalFrameRate))
                }
            }
            .font(.subheadline).padding(.top, 16)
        } label: {
            Label("Video details", systemImage: "slider.horizontal.3")
                .font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                .frame(minHeight: 44)
        }
        .padding(.horizontal, 20).padding(.vertical, 8).shrinkCard()
    }
}
