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
    /// True once the item the system player was handed says it can play. `loading` cannot carry this:
    /// it means "Photos answered the fetch", and an item that arrives and stays undecided would then
    /// read as ready - which is the state this whole wait exists for.
    @State private var playable = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    playerArea
                    problemLine
                    // Both notes describe a look that is happening. They used to be drawn whatever
                    // state the area above was in, so the sheet could tell a user to press play on a
                    // control that was not there - while the fetch was still running, or after it had
                    // failed - and explain an iCloud fetch under a line saying nothing could be
                    // opened. Each is now drawn only where it is true.
                    if playable {
                        Text("Press play, or drag the bar, to check you’ve got the right video.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    facts
                    if problem == nil {
                        Text("If this video lives in iCloud, Photos fetches what it needs to play, so the first few seconds can take a moment.")
                            .font(.footnote).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
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
            if playable, let player {
                VideoPlayer(player: player)
                    // The loading and failure branches each carry a line of text, and this one
                    // carried nothing - the failure state's is now drawn under the box by
                    // `problemLine`, the loading one inside it: VoiceOver arrived at a bare area on
                    // the one branch that actually has something to play. `children: .contain` labels it without
                    // making it a single element, so the system transport controls stay in the
                    // accessibility tree exactly as they were.
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Video player")
            } else if problem == nil {
                // The spinner covers both waits: PhotoKit answering, and then the item it answered
                // with saying it can play. Either way there is nothing to press yet, which is what
                // the note below the box used to imply there was.
                VStack(spacing: 10) {
                    ProgressView().tint(.white)
                    Text("Opening…").font(.footnote).foregroundStyle(.white.opacity(0.8))
                }
            } else {
                // The symbol stays in the box and the sentence is drawn under it by `problemLine`:
                // the box is a fixed 16:9 shape, so a failure sentence inside it is clipped at
                // accessibility text sizes, which is exactly when a user needs to read it. The symbol
                // is decoration - the sentence is the element - so it says nothing of its own.
                Image(systemName: "video.slash")
                    .font(.largeTitle)
                    .foregroundStyle(.white)
                    .padding(20)
                    .accessibilityHidden(true)
            }
        }
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    /// The failure's words, drawn under the box rather than inside it.
    @ViewBuilder private var problemLine: some View {
        if let problem {
            Text(problem)
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private var facts: some View {
        VStack(alignment: .leading, spacing: 12) {
            LabeledContent("Recorded", value: ShrinkFormat.date(asset.creationDate))
            LabeledContent("Length", value: ShrinkFormat.duration(asset.duration))
            if asset.longEdge > 0 {
                LabeledContent("Size on screen", value: "\(asset.pixelWidth) × \(asset.pixelHeight)")
            }
            // Not "Original file": this row can be looking at a copy this app made, which stays in the
            // library, is labelled `Made by BatchShrink` in the grid and can still be ticked by hand.
            // What the row knows is the size of the file behind it, whoever made it.
            LabeledContent("File size", value: asset.bytes.map(ShrinkFormat.bytes) ?? "Not reported by Photos")
        }
        .font(.subheadline)
        .padding(18).shrinkCard()
    }

    private func start() async {
        do {
            let item = try await load()
            // The sheet may have gone while Photos was answering: building a player for a view that
            // has already disappeared is the one thing `onDisappear` cannot undo - it has run, and it
            // will not run again to pause a player created after it.
            guard !Task.isCancelled else { return }
            // Ready to scrub, deliberately not playing: a preview should never open with sound.
            player = AVPlayer(playerItem: item)
            loading = false
            await waitUntilPlayable(item)
        } catch {
            // A cancelled task means the sheet is going: there is nobody left to read a sentence.
            guard !Task.isCancelled else { return }
            loading = false
            problem = Self.failureSentence(for: error)
        }
    }

    /// Waits for the item the system player was handed to become something that plays.
    ///
    /// Having an item is not having a video. PhotoKit can answer with a player item that never becomes
    /// ready - an original it cannot fetch is the obvious way - and until round 27 the sheet took the
    /// item's existence as success, so it would sit on a black rectangle under a footnote telling the
    /// user to press play, with nothing said and no bound left running. The item's own status answers
    /// it, under a bound of this sheet's own, because the fetch above has already answered by the time
    /// this runs: the two waits are one after the other, so the look's worst case is the fetch's bound
    /// plus this one.
    private func waitUntilPlayable(_ item: AVPlayerItem) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(Self.playableWaitSeconds))
        while item.status == .unknown, !Task.isCancelled, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(150))
        }
        guard !Task.isCancelled else { return }
        guard item.status != .readyToPlay else {
            playable = true
            return
        }
        problem = "Photos handed over a file that would not play. Nothing was changed."
        player = nil
    }

    /// How long the item may stay undecided after Photos has handed one over.
    private static let playableWaitSeconds: Double = 10

    /// What to say when the look fails, in this sheet's own terms.
    ///
    /// Deliberately not `error.localizedDescription`. Those sentences are written for a run that is
    /// about to change something: the one a failed fetch produces tells the user to add the video to
    /// the app's allowed videos in Settings, which is right for a video outside a limited grant and
    /// wrong for one Photos no longer has - and the sheet cannot tell those apart, so it says both.
    /// Nothing here mentions a copy, because nothing here makes one.
    static func failureSentence(for error: Error) -> String {
        guard let pipeline = error as? PipelineError else {
            return "Photos could not hand this video over to play."
        }
        switch pipeline {
        case .assetUnavailable:
            return "This video is no longer in your Photos library, or it is outside the access BatchShrink has. Nothing was changed."
        case .retrieval:
            return "Photos could not fetch this video to play. If its original is in iCloud, check your connection, then open this look again."
        default:
            // Every other case is a pipeline sentence about a step this sheet does not take.
            return "Photos could not hand this video over to play."
        }
    }
}
