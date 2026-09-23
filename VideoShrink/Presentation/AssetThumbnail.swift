import SwiftUI
import UIKit

/// A video preview for lists. It shows a placeholder until Photos hands one over, then fades
/// the picture in. Purely decorative, so VoiceOver skips it.
struct AssetThumbnail: View {
    let identifier: String
    var size: CGSize = CGSize(width: 54, height: 54)
    /// A corner label, usually the video's length.
    var badge: String? = nil
    /// Shown when tapping the thumbnail opens a player rather than selecting it.
    var showsPlayBadge = false
    /// Bumped by the view model when Photos reports a change to this video. The request below
    /// keys on it, so an edited video is fetched again instead of showing the cached picture.
    var revision: Int = 0

    @State private var image: UIImage?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var requestID: String {
        "\(identifier)-\(revision)-\(Int(size.width.rounded()))-\(Int(size.height.rounded()))"
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: ShrinkStyle.radiusThumb, style: .continuous)
                .fill(ShrinkStyle.thumbnailBackground)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .transition(.opacity)
            } else {
                Image(systemName: "video")
                    .font(.system(size: max(12, size.height * 0.26)))
                    .foregroundStyle(.secondary)
            }
            if showsPlayBadge {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: max(18, size.height * 0.3)))
                    .foregroundStyle(.white, .black.opacity(0.45))
                    .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
            }
            if let badge {
                Text(badge)
                    .font(.caption2.weight(.semibold)).monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(.black.opacity(0.55), in: Capsule())
                    .padding(4)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: ShrinkStyle.radiusThumb, style: .continuous))
        .task(id: requestID) {
            let loaded = await ThumbnailService.shared.image(identifier: identifier, size: size)
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { image = loaded }
        }
        .accessibilityHidden(true)
    }
}
