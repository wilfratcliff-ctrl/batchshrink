import SwiftUI
import AVKit

/// A quick look at one original before it is chosen or deleted: press play, drag the scrubber,
/// close. The system player brings the scrubber, so this stays small on purpose.
struct VideoScrubSheet: View {
    let asset: LibraryAsset
    let load: @MainActor () async throws -> AVPlayerItem

    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var problem: String?
    @State private var loading = true

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    playerArea
                    facts
                    Text("If this video lives in iCloud, Photos fetches what it needs to play, so the first few seconds can take a moment.")
                        .font(.footnote).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Press play, or drag the bar, to check you’ve got the right video.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .frame(maxWidth: 540)
                .padding(20)
                .frame(maxWidth: .infinity)
            }
            .background(ShrinkStyle.canvas)
            .navigationTitle("Check this video")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .task { await start() }
        .onDisappear {
            player?.pause()
            player?.replaceCurrentItem(with: nil)
        }
    }

    private var playerArea: some View {
        ZStack {
            Color.black
            if let player {
                VideoPlayer(player: player)
                    // The loading and failure branches each carry a line of text, and this one
                    // carried nothing: VoiceOver arrived at a bare area on the one branch that
                    // actually has something to play. `children: .contain` labels it without
                    // making it a single element, so the system transport controls stay in the
                    // accessibility tree exactly as they were.
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Video player")
            } else if loading {
                VStack(spacing: 10) {
                    ProgressView().tint(.white)
                    Text("Opening…").font(.footnote).foregroundStyle(.white.opacity(0.8))
                }
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "video.slash").font(.largeTitle)
                    Text(problem ?? "This video couldn’t be opened.").multilineTextAlignment(.center)
                }
                .foregroundStyle(.white)
                .padding(20)
            }
        }
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var facts: some View {
        VStack(alignment: .leading, spacing: 12) {
            LabeledContent("Recorded", value: ShrinkFormat.date(asset.creationDate))
            LabeledContent("Length", value: ShrinkFormat.duration(asset.duration))
            if asset.longEdge > 0 {
                LabeledContent("Size on screen", value: "\(asset.pixelWidth) × \(asset.pixelHeight)")
            }
            LabeledContent("Original file", value: asset.bytes.map(ShrinkFormat.bytes) ?? "Not reported by Photos")
        }
        .font(.subheadline)
        .padding(18).shrinkCard()
    }

    private func start() async {
        do {
            let item = try await load()
            // Ready to scrub, deliberately not playing: a preview should never open with sound.
            player = AVPlayer(playerItem: item)
            loading = false
        } catch {
            loading = false
            problem = error.localizedDescription
        }
    }
}
