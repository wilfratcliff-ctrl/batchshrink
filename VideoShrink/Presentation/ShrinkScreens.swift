import SwiftUI
import AVKit

struct ShrinkWelcome: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            ShrinkEyebrow(title: "One moment at a time", symbol: "play.rectangle")
            VStack(alignment: .leading, spacing: 12) {
                Text("Same moment.\nLighter footprint.")
                    .font(ShrinkStyle.headline).tracking(-1)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Text("Choose a video, set the quality, and preview your smaller copy before saving.")
                    .font(.body).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ShrinkIllustration()
            ShrinkNotice(symbol: "play.circle", title: "See it before you save it",
                         detail: "Check the picture and sound. Your original stays untouched.")
            Text("Keep the app open and your iPhone unlocked while it works.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

}

struct ShrinkIllustration: View {
    var body: some View {
        ShrinkHeroArtwork()
    }
}

struct ShrinkProgress: View {
    let stage: PipelineStage
    let progress: Double?
    let fromCloud: Bool
    let cancelling: Bool

    private var title: String {
        if cancelling { return "Stopping safely…" }
        switch stage {
        case .waitingForPermission: return "A little access first."
        case .choosing: return "Find your video."
        case .retrieving: return fromCloud ? "Bringing it from iCloud." : "Getting your original."
        case .preparing: return "Getting things ready."
        case .transcoding: return "A little lighter.\nMoment by moment."
        case .verifying: return "One last check."
        case .saving: return "Keeping your copy."
        default: return "Working on your video."
        }
    }

    private var detail: String {
        if cancelling { return "Finishing cleanup. Your original is safe." }
        switch stage {
        case .waitingForPermission: return "Allow access to the video you’d like to compress."
        case .choosing: return "Choose one video in the Photos picker."
        case .retrieving: return fromCloud ? "Downloading the full original before compression." : "Loading the original from your Photos library."
        case .preparing: return "Checking the video and available space."
        case .transcoding: return "Creating a smaller copy on your iPhone."
        case .verifying: return "Checking that the copy decodes, and its duration, orientation and audio tracks."
        case .saving: return "Adding a separate video to your Photos library."
        default: return "Your original stays untouched."
        }
    }

    private var currentStep: Int {
        switch stage {
        case .transcoding: return 1
        case .verifying, .saving: return 2
        default: return 0
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            ShrinkEyebrow(title: stage == .saving ? "Almost yours" : "Original protected", symbol: "checkmark.shield")
            Text(title).font(ShrinkStyle.headline).tracking(-1)
                .fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.isHeader)
            Text(detail).font(.body).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 24) {
                ShrinkProgressOrb(progress: cancelling ? nil : progress, label: title)
                if ![.waitingForPermission, .choosing, .saving].contains(stage) {
                    Divider()
                    VStack(alignment: .leading, spacing: 20) {
                        step(0, title: "Get the original")
                        step(1, title: "Make a smaller copy")
                        step(2, title: "Check the result")
                    }
                }
            }
            .padding(24).shrinkCard()
            if stage != .saving {
                ShrinkNotice(symbol: "iphone", title: "Stay here for a moment",
                             detail: "Keep this app open and your iPhone unlocked. Leaving or locking cancels processing.")
            }
        }
    }

    private func step(_ index: Int, title: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: index < currentStep ? "checkmark.circle.fill" : (index == currentStep ? "circle.inset.filled" : "circle"))
                .foregroundStyle(index <= currentStep ? ShrinkStyle.accent : Color.secondary)
                .accessibilityHidden(true)
            Text(title).font(.subheadline.weight(index == currentStep ? .semibold : .regular))
                .foregroundStyle(index <= currentStep ? Color.primary : Color.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(index < currentStep ? "complete" : (index == currentStep ? "in progress" : "up next"))")
    }
}

struct ShrinkResult: View {
    let source: VideoMetadata
    let output: VideoMetadata
    let saved: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var savings: Savings { Savings(originalBytes: source.bytes, compressedBytes: output.bytes) }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            ShrinkEyebrow(title: saved ? "Saved to Photos" : "Copy checked", symbol: saved ? "checkmark.circle.fill" : "checkmark.shield")
            VStack(alignment: .leading, spacing: 10) {
                Text(saved ? "All set.\nA lighter copy is yours." : (savings.isSmaller ? "Your video.\nA little lighter." : "This one didn’t get smaller."))
                    .font(ShrinkStyle.headline).tracking(-1)
                    .fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.isHeader)
                Text(saved ? "Your new copy is in Photos. Your original is right where you left it." : (savings.isSmaller ? "Your copy is ready. Give it a look before saving." : "This export didn’t get smaller, so saving is turned off. Try another video."))
                    .font(.body).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 24) {
                if savings.isSmaller, let percentage = savings.percentage {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(percentage / 100, format: .percent.precision(.fractionLength(1)))
                            .font(ShrinkStyle.headline).tracking(-1)
                            .foregroundStyle(ShrinkStyle.accent).monospacedDigit()
                        Text("smaller video file").font(.headline)
                        Text("\(ShrinkFormat.bytes(savings.bytesSaved)) less than the original")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                } else {
                    Label("No size reduction", systemImage: "equal.circle").font(.headline)
                }
                VStack(spacing: 18) {
                    comparisonRow("Original", bytes: source.bytes, accent: false)
                    comparisonRow("New copy", bytes: output.bytes, accent: true)
                }
            }
            .padding(24).shrinkCard()
            Text("Your original is still stored. Keeping both copies uses more space; no iCloud storage has been freed.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private func comparisonRow(_ title: String, bytes: Int64, accent: Bool) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
                : AnyLayout(HStackLayout(alignment: .firstTextBaseline))
            layout {
                Text(title).foregroundStyle(.secondary)
                if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 8) }
                Text(ShrinkFormat.bytes(bytes)).fontWeight(.semibold).monospacedDigit()
            }
            .font(.subheadline)
            GeometryReader { geometry in
                let fraction = Double(max(0, bytes)) / Double(max(1, max(source.bytes, output.bytes)))
                Capsule().fill((accent ? ShrinkStyle.accent : Color.secondary).opacity(accent ? 1 : 0.4))
                    .frame(width: geometry.size.width * fraction)
            }
            .frame(height: 8).accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
    }
}

struct ShrinkRecovery: View {
    let failed: Bool
    let message: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Image(systemName: failed ? "exclamationmark.circle" : "pause.circle")
                .font(.system(size: 48, weight: .light)).foregroundStyle(ShrinkStyle.accent)
                .accessibilityHidden(true)
            Text(failed ? "Let’s try that again." : "No rush.\nYour original is safe.")
                .font(ShrinkStyle.headline).tracking(-1)
                .fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.isHeader)
            Text(message ?? "Choose another video whenever you’re ready.")
                .font(.body).foregroundStyle(.secondary)
            ShrinkNotice(symbol: "checkmark.shield", title: "Original untouched",
                         detail: "This video wasn’t changed. Deleting only ever happens after a copy is saved and read back.")
        }
    }
}

/// The toolbar "?" used by both flows.
struct HelpButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.primary)
                .frame(minWidth: 44, minHeight: 44)
                .background(ShrinkStyle.surface, in: RoundedRectangle(cornerRadius: 15))
        }
        .accessibilityLabel("Help and settings")
    }
}

struct ShrinkHelp: View {
    @ObservedObject var settings: ShrinkSettings
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @AppStorage("completionHaptics") private var completionHaptics = true
    @State private var showIntroduction = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ShrinkBrand().padding(.vertical, 8)
                    Button("See the introduction") { showIntroduction = true }
                }
                Section("Fast answers") {
                    Label("Space comes back 30 days after a delete, when Photos clears Recently Deleted.", systemImage: "clock.arrow.circlepath")
                    Label("A copy is a second video, so storage goes up before it comes down.", systemImage: "arrow.up.arrow.down")
                    Label("Looking through your library never downloads your videos. Preview images may come from iCloud.", systemImage: "icloud.slash")
                    Label("Sizes here are estimates. The end of a run shows measured results.", systemImage: "ruler")
                }
                Section("Which videos it can work on") {
                    Text("BatchShrink compresses ordinary videos. A video it cannot compress carefully is left untouched, and the reason is shown.")
                    Text("Live Photos, time-lapse, spatial, slow-motion, edited, cinematic, and shared or restricted videos aren't supported yet. HDR and ProRes are read from the video itself: looking through your library reads the ones already on your iPhone, and every video you pick is read again before a run starts. A video still in iCloud, one the scan did not reach, or one whose read failed hasn't been read yet, so it can still turn out to be unsupported.")
                }
                Section("A smaller copy, safely") {
                    if settings.deletionMode.deletesOriginals {
                        Label("Originals are deleted only after a copy is saved and read back.",
                              systemImage: "trash")
                    } else {
                        Label("Your original is never changed or deleted.", systemImage: "checkmark.shield")
                    }
                    Label("Compression happens on your iPhone.", systemImage: "iphone")
                    Label("BatchShrink does not upload your videos. Photos may sync with iCloud.", systemImage: "lock")
                }
                Section("Originals") {
                    Text("Deleting applies to batch runs and is off unless you turn it on. The one-video flow never deletes anything.")
                    Text("Deleted originals wait in Recently Deleted for 30 days, which is also when the space comes back.")
                }
                Section("Quality") {
                    Text("1080p HEVC by default. 720p is smaller and uses H.264. 4K keeps more detail on 4K videos.")
                    Text("Fewer frames a second makes a smaller file. Fast action looks best at the original rate.")
                }
                Section("Several videos at once") {
                    Text("Copies are saved as they finish, so there’s no preview for each one.")
                    Text("Leaving the app pauses the batch. Keep it open and your iPhone unlocked.")
                }
                Section("Estimates") {
                    Text("Size and time estimates are ranges, not measurements. The finished screen reports measured sizes.")
                    Text("Photos doesn’t report an original size for every video, so those are counted but left out of the estimate.")
                }
                Section("Preferences") {
                    Toggle("Completion haptics", isOn: $completionHaptics)
                    Toggle("Keep screen awake while working", isOn: $settings.keepScreenAwake)
                    Text("Only while a batch is running. It uses more battery and the phone runs warmer.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Photos access") {
                    Text("With limited access, only the videos you’ve allowed can be listed or shrunk. You can change access in Settings.")
                    Button("Open Photos access settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(ShrinkStyle.canvas)
            .navigationTitle("Settings & help").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .tint(ShrinkStyle.accent)
        .sheet(isPresented: $showIntroduction) {
            ShrinkOnboarding { showIntroduction = false }
                .preferredColorScheme(.dark)
        }
    }
}

struct VideoPreview: View {
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer
    init(url: URL) { _player = State(initialValue: AVPlayer(url: url)) }

    var body: some View {
        NavigationStack {
            VideoPlayer(player: player)
                .background(.black)
                .navigationTitle("Your compressed copy").navigationBarTitleDisplayMode(.inline)
                .safeAreaInset(edge: .bottom) {
                    Text("Check picture, orientation and sound before saving.")
                        .font(.footnote).foregroundStyle(.secondary)
                        .padding().frame(maxWidth: .infinity).background(ShrinkStyle.surface)
                }
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
                .onDisappear { player.pause(); player.replaceCurrentItem(with: nil) }
        }
    }
}

#if DEBUG
private let previewSource = VideoMetadata(duration: 128, width: 3840, height: 2160, bytes: 420_000_000,
    fileType: "MOV", audioTrackCount: 1, isPlayable: true, codec: .h264, nominalFrameRate: 30)
private let previewOutput = VideoMetadata(duration: 128, width: 1920, height: 1080, bytes: 126_000_000,
    fileType: "MOV", audioTrackCount: 1, isPlayable: true, codec: .hevc, nominalFrameRate: 30)

#Preview("Welcome") {
    ScrollView { ShrinkWelcome().padding(24) }.background(ShrinkStyle.canvas).preferredColorScheme(.dark)
}
#Preview("Compressing · dark") {
    ScrollView { ShrinkProgress(stage: .transcoding, progress: 0.42, fromCloud: false, cancelling: false).padding(24) }
        .background(ShrinkStyle.canvas).preferredColorScheme(.dark)
}
#Preview("Result · large text") {
    ScrollView { ShrinkResult(source: previewSource, output: previewOutput, saved: false).padding(24) }
        .background(ShrinkStyle.canvas).preferredColorScheme(.dark).environment(\.dynamicTypeSize, .accessibility2)
}
#Preview("Saved") {
    ScrollView { ShrinkResult(source: previewSource, output: previewOutput, saved: true).padding(24) }
        .background(ShrinkStyle.canvas).preferredColorScheme(.dark)
}
#Preview("No reduction") {
    ScrollView { ShrinkResult(source: previewOutput, output: previewSource, saved: false).padding(24) }
        .background(ShrinkStyle.canvas).preferredColorScheme(.dark)
}
#Preview("Interrupted") {
    ScrollView { ShrinkRecovery(failed: true, message: "There isn’t enough free space. Free some space on your iPhone, then try again.").padding(24) }
        .background(ShrinkStyle.canvas).preferredColorScheme(.dark)
}
#endif
