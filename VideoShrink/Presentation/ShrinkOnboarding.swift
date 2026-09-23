import SwiftUI

/// Introduces the actual compression flow before asking Photos for access.
/// Completion is persistent; a recovered run always takes precedence at the root.
struct ShrinkOnboarding: View {
    let complete: () -> Void
    @State private var page = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let titles = ["Keep the moment.\nLose the weight.",
                          "Small files.\nBig possibilities.",
                          "Your memories.\nYour call."]
    private let details = ["Give your favourite videos a lighter footprint. Right here on your iPhone.",
                           "Choose a few videos or a whole batch. Set the quality, then let BatchShrink work.",
                           "Smaller copies are saved as separate videos in your Photos library. Originals stay unless you choose to delete them."]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                ShrinkBrand()
                Spacer()
                Button("Skip", action: complete)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 44, minHeight: 44)
            }
            .padding(.horizontal, 24)
            HStack(spacing: 6) {
                ForEach(0..<3) { index in
                    Capsule().fill(index <= page ? ShrinkStyle.accent : ShrinkStyle.elevated)
                        .frame(height: 3)
                }
            }
            .padding(.horizontal, 24).padding(.top, 18).padding(.bottom, 12)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Introduction, step \(page + 1) of 3")

            ScrollView {
                VStack(spacing: 24) {
                    VStack(spacing: 14) {
                        Text(titles[page])
                            .font(ShrinkStyle.headline).tracking(-1.2)
                            .foregroundStyle(.primary)
                            .accessibilityAddTraits(.isHeader)
                        Text(details[page])
                            .font(.body).foregroundStyle(.secondary)
                            .lineSpacing(3)
                    }
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    ShrinkHeroArtwork(mode: page)
                    Label(footnote, systemImage: page == 2 ? "checkmark.shield" : "iphone")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(ShrinkStyle.accent)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: 480)
                .padding(.horizontal, 28).padding(.vertical, 24)
                .frame(maxWidth: .infinity)
                .id(page)
                .transition(.opacity)
            }
            // Moving to another page fades the old one out. Reduce Motion swaps the page with no
            // fade at all; the step indicator already carries the same information with no motion.
            ShrinkActionBar {
                ShrinkPrimaryButton(title: page == 2 ? "Get started" : "Continue",
                                    symbol: "arrow.right") {
                    if page == 2 { complete() }
                    else { withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) { page += 1 } }
                }
                if page > 0 {
                    Button("Back") {
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) { page -= 1 }
                    }
                    .font(.subheadline).foregroundStyle(.secondary)
                    .frame(minWidth: 44, minHeight: 44)
                } else {
                    Text("Less storage. More life.")
                        .font(.footnote).foregroundStyle(.secondary).padding(.vertical, 8)
                }
            }
        }
        .background(ShrinkStyle.canvas)
    }

    private var footnote: String {
        switch page {
        case 0: return "Compressed on your iPhone"
        case 1: return "You choose the balance of size and quality"
        default: return "Photos access is requested when you scan"
        }
    }
}

/// Original vector artwork: layered video frames converging into a lighter copy.
/// Scales without external images, personal photos, or illustrative storage claims.
struct ShrinkHeroArtwork: View {
    var mode = 0

    var body: some View {
        GeometryReader { geometry in
            let width = min(geometry.size.width, 380)
            ZStack {
                Circle()
                    .fill(RadialGradient(colors: [ShrinkStyle.accent.opacity(0.12), .clear],
                                         center: .center, startRadius: 15, endRadius: width * 0.5))
                    .frame(width: width, height: width)
                Circle().stroke(ShrinkStyle.hairline, lineWidth: 1)
                    .frame(width: width * 0.87, height: width * 0.87)
                Circle().stroke(ShrinkStyle.hairline, lineWidth: 1)
                    .frame(width: width * 0.65, height: width * 0.65)
                if mode == 1 {
                    filmFrame(width: width * 0.50, tint: ShrinkStyle.lilac, isFront: false)
                        .rotationEffect(.degrees(17)).offset(x: width * 0.16, y: -44)
                }
                filmFrame(width: width * 0.57, tint: ShrinkStyle.lilac, isFront: false)
                    .rotationEffect(.degrees(-12)).offset(x: -width * 0.12, y: -25)
                filmFrame(width: width * 0.49, tint: ShrinkStyle.accent, isFront: true)
                    .rotationEffect(.degrees(9)).offset(x: width * 0.14, y: 35)
                Image(systemName: mode == 2 ? "checkmark.shield.fill"
                      : mode == 1 ? "square.stack.3d.up.fill" : "arrow.down.right.and.arrow.up.left")
                    .font(.system(size: 23, weight: .semibold))
                    .foregroundStyle(ShrinkStyle.canvas)
                    .frame(width: 60, height: 60)
                    .background(ShrinkStyle.accent, in: RoundedRectangle(cornerRadius: 20))
                    .rotationEffect(.degrees(-6))
                    .offset(x: width * 0.29, y: -80)
                Image(systemName: "sparkle")
                    .font(.system(size: 25, weight: .light))
                    .foregroundStyle(ShrinkStyle.lilac)
                    .offset(x: -width * 0.34, y: 90)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .frame(height: 300)
        .accessibilityHidden(true)
    }

    private func filmFrame(width: CGFloat, tint: Color, isFront: Bool) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 4) {
                ForEach(0..<3) { _ in Circle().fill(tint.opacity(0.45)).frame(width: 4, height: 4) }
                Spacer()
                Image(systemName: "video.fill").font(.system(size: 11))
            }
            ZStack {
                RoundedRectangle(cornerRadius: 15)
                    .fill(LinearGradient(colors: [tint.opacity(0.5), tint.opacity(0.06)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: "play.fill").font(.system(size: 30, weight: .medium))
                    .foregroundStyle(tint)
            }
            .frame(height: width * 0.62)
            HStack {
                Capsule().fill(tint.opacity(0.5)).frame(width: width * (isFront ? 0.26 : 0.55), height: 5)
                Spacer()
                if isFront { Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)) }
            }
        }
        .foregroundStyle(tint)
        .padding(16).frame(width: width)
        .background(ShrinkStyle.surface, in: RoundedRectangle(cornerRadius: 24))
        .overlay { RoundedRectangle(cornerRadius: 24).strokeBorder(tint.opacity(0.35), lineWidth: 1) }
        .shadow(color: .black.opacity(0.25), radius: 20, y: 14)
    }
}

#if DEBUG
#Preview("Introduction") {
    ShrinkOnboarding(complete: {}).preferredColorScheme(.dark)
}
#Preview("Introduction · accessible") {
    ShrinkOnboarding(complete: {}).preferredColorScheme(.dark)
        .environment(\.dynamicTypeSize, .accessibility2)
}
#endif
