import SwiftUI

enum ShrinkStyle {
    static let canvas = Color(red: 0.025, green: 0.035, blue: 0.065)
    static let surface = Color(red: 0.065, green: 0.080, blue: 0.120)
    static let elevated = Color(red: 0.10, green: 0.12, blue: 0.17)
    static let accent = Color(red: 0.66, green: 0.96, blue: 0.82)
    static let lilac = Color(red: 0.73, green: 0.69, blue: 1.0)
    static let button = accent
    /// The colour for the two things this app warns about: an original that is about to be deleted,
    /// and a video the run could not account for.
    ///
    /// It was `Color.orange` written out at three separate sites, which made the app's warning
    /// colour the one part of the palette nobody could find: every other colour here is named, so
    /// the ones that carry a warning should be too, and a tint that means "look at this" is not a
    /// thing to leave to whoever is editing a screen at the time.
    static let danger = Color.orange
    static let thumbnailBackground = elevated
    static let hairline = ShrinkHairline()
    static let headline = Font.system(.largeTitle, design: .default, weight: .bold)

    /// The rhythm every screen shares.
    ///
    /// The screens had grown a mix of numbers for the same three roles - card padding written as 14,
    /// 18, 20, 22 and 24 in different places, and the gap between blocks as 18, 20, 22 and 24. On a
    /// phone that reads as noise: the eye notices two cards that do not line up before it notices
    /// either card on its own. These are named rather than copied about, so the next screen added
    /// lands on the same grid without anyone having to remember what it was.
    static let gutter: CGFloat = 24
    static let sectionSpacing: CGFloat = 20
    static let cardPadding: CGFloat = 20

    /// How tall the layered artwork is drawn.
    ///
    /// It was a fixed 300 points everywhere, which on the two screens that open a flow pushed the
    /// only control that matters - Find my videos, Choose a video - below the fold on an ordinary
    /// phone. The picture is a mood, not the content, so it takes a smaller share of a screen that
    /// has something to say and less of one that does not.
    static let heroHeight: CGFloat = 200

    /// The radii every rounded corner in the app shares.
    ///
    /// There were eight of them for four jobs: video tiles at 22, cards at 24, the help button at
    /// 15, quality pills at 14, thumbnails at 12, a 16:9 preview at 18, and both sheets' own
    /// corners at 32. A tile and a card of the same kind were drawn two points apart on different
    /// screens - close enough to look like a mistake rather than a decision. These are named rather
    /// than copied about for the same reason the spacing above is: the eye notices two cards that
    /// do not line up before it notices either card on its own, and the next screen added should
    /// land on the scale without anyone having to remember what it was.
    ///
    /// The order is deliberate - each is a little rounder than the one before, and each is used for
    /// a shape a little larger than the one before.
    static let radiusSheet: CGFloat = 32
    static let radiusCard: CGFloat = 24
    static let radiusTile: CGFloat = 20
    static let radiusChip: CGFloat = 14
    static let radiusThumb: CGFloat = 12

    /// The brand mark's own rounding, as a fraction of its side.
    ///
    /// The mark is drawn at three sizes - 28 points in a toolbar, 60 in the hero artwork, and 216
    /// in the app icon - and a fixed radius would make the same badge a different shape at each.
    /// `scripts/make-app-icon.mjs` uses this same fraction, so the icon is the toolbar logo
    /// enlarged rather than a second drawing of it.
    static func markRadius(for side: CGFloat) -> CGFloat { side * 0.32 }
}

/// Every haptic the app plays, and the one switch in Settings that covers them.
///
/// The switch was named for the end of a run and only the end of a run read it, so someone who had
/// turned it off still felt a buzz on every quality pill - the controls this app taps most. The row
/// is now named for what it covers and every trigger asks here, so the name in Settings and the
/// moments that obey it cannot drift apart. Reduce Motion is deliberately not involved: haptics
/// are not motion, and the system's own Haptics switch remains the way to silence the whole phone.
enum ShrinkHaptics {
    /// The stored preference.
    ///
    /// The key keeps the row's original name rather than following the row's new one, because a
    /// renamed key is a different preference: everyone who had turned haptics off would have found
    /// them on again.
    static let storageKey = "completionHaptics"

    /// One of the app's haptic moments.
    enum Moment: CaseIterable {
        /// Choosing a picture size or a smoothness option.
        case qualityChoice
        /// A batch run or a one-video compress finishing.
        case finished
        /// A batch run or a one-video compress failing.
        case failed
    }

    /// The feedback to play at `moment`, or none at all when the switch is off.
    ///
    /// Main-actor isolated because it builds SwiftUI's own feedback values, and every caller is a
    /// view body or a `@MainActor` case. The key above deliberately is not: it is read in an
    /// `@AppStorage` initialiser, where a default value has to stay usable outside the actor.
    @MainActor
    static func feedback(_ moment: Moment, enabled: Bool) -> SensoryFeedback? {
        guard enabled else { return nil }
        switch moment {
        case .qualityChoice: return .selection
        case .finished: return .success
        case .failed: return .error
        }
    }
}

/// The one-pixel line around a card and along the action bar.
///
/// A flat `Color.white.opacity(0.08)` is a whisper on this dark canvas, and for anyone who has
/// asked for Increase Contrast it is a whisper they asked not to have: the border is often the
/// only thing separating a card from the canvas behind it, and at eight percent it reads as
/// nothing. The stroke resolves itself against the environment instead, so the line stays quiet
/// at the standard contrast setting and becomes a real line when the setting is increased.
struct ShrinkHairline: ShapeStyle {
    func resolve(in environment: EnvironmentValues) -> Color {
        environment.colorSchemeContrast == .increased
            ? Color.white.opacity(0.45)
            : Color.white.opacity(0.08)
    }
}

extension View {
    func shrinkCard() -> some View {
        background(ShrinkStyle.surface, in: RoundedRectangle(cornerRadius: ShrinkStyle.radiusCard,
                                                              style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: ShrinkStyle.radiusCard, style: .continuous)
                    .strokeBorder(ShrinkStyle.hairline, lineWidth: 1)
                    .allowsHitTesting(false)
            }
    }

    /// The inset every page's content sits inside.
    ///
    /// Nine screens wrote the same three paddings out by hand and two more wrote a shape of their
    /// own, which is exactly how the two flows came to be four points apart on the gap between
    /// blocks for a whole round without anyone choosing it. One modifier, so a page cannot be inset
    /// like no other page. It goes between the content's own max width and the frame that fills the
    /// screen - see any screen's body - because that is the order these three paddings have always
    /// been applied in.
    func shrinkPageInsets() -> some View {
        padding(.horizontal, ShrinkStyle.gutter).padding(.top, 20).padding(.bottom, 28)
    }
}

enum ShrinkFormat {
    /// A count with the words that follow it, singular where the count is one.
    ///
    /// Several screens wrote "1 videos to explore", "1 videos left" and "Delete 1 originals": the
    /// count was right and the sentence was wrong, on exactly the screens somebody with a single
    /// video in their library sees first. One helper rather than a ternary at every site, because
    /// these strings are what drift apart when they multiply - and what follows the count is passed
    /// in, so the caller still owns its own words and can put a verb there where the sentence needs
    /// one ("1 video isn't" / "2 videos aren't"). The number is grouped as the rest of the app groups
    /// numbers, so a four-figure library reads "1,024 videos" wherever it appears.
    static func counted(_ count: Int, _ singular: String, _ plural: String) -> String {
        "\(count.formatted()) \(count == 1 ? singular : plural)"
    }

    static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    /// Compact form for tables of results: "1.4 GB", "820 MB", "12 MB".
    static func compactBytes(_ value: Int64) -> String {
        bytes(value)
    }

    /// "1.2–2.4 GB" for a range, collapsing a shared unit.
    static func byteRange(low: Int64, high: Int64) -> String {
        guard low > 0 || high > 0 else { return bytes(0) }
        let lowText = bytes(low)
        let highText = bytes(high)
        if low <= 0 { return "up to \(highText)" }
        if lowText == highText { return lowText }
        let lowParts = lowText.split(separator: " ")
        let highParts = highText.split(separator: " ")
        if lowParts.count == 2, highParts.count == 2, lowParts[1] == highParts[1] {
            let (from, to) = samePrecision(lowParts[0], highParts[0])
            return "\(from)–\(to) \(lowParts[1])"
        }
        return "\(lowText) to \(highText)"
    }

    /// Two figures from one range, written with the same precision.
    ///
    /// `ByteCountFormatter` decides each end on its own, and the summary card drew the pair as
    /// **"409–552.5 MB"**: the lower end a whole number, the upper carrying a decimal, in the
    /// app's largest type. Two ends of one estimate are one number's worth of idea, and writing
    /// them at two precisions reads as two different kinds of figure rather than as a range.
    ///
    /// When either end is whole, both are written whole: the lower rounded down and the upper up,
    /// so the band is never narrower than the figures it was built from. A band whose ends both
    /// carry decimals is left exactly as the formatter wrote it.
    ///
    /// The two figures are parsed back out of the formatted strings, so the decimal and grouping
    /// separators are read from the current locale rather than assumed to be "." and "," - the
    /// alternative was to rebuild the range from bytes and quietly stop agreeing with every other
    /// byte figure the app prints.
    static func samePrecision(_ low: Substring, _ high: Substring) -> (String, String) {
        guard !low.contains(".") || !high.contains("."),
              let lowValue = decimal(low), let highValue = decimal(high) else {
            return (String(low), String(high))
        }
        return (Int(lowValue.rounded(.down)).formatted(),
                Int(highValue.rounded(.up)).formatted())
    }

    /// One figure from a formatted byte string, as a number, whatever separators the locale uses.
    private static func decimal(_ text: Substring) -> Double? {
        var cleaned = String(text)
        if let grouping = Locale.current.groupingSeparator, !grouping.isEmpty {
            cleaned = cleaned.replacingOccurrences(of: grouping, with: "")
        }
        if let point = Locale.current.decimalSeparator, point != "." {
            cleaned = cleaned.replacingOccurrences(of: point, with: ".")
        }
        return Double(cleaned)
    }

    /// "about 40 minutes" is too strong a claim; this stays deliberately rough.
    static func roughDuration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "a moment" }
        if seconds < 45 { return "under a minute" }
        let minutes = (seconds / 60).rounded()
        if minutes < 60 { return "about \(Int(minutes)) min" }
        let hours = seconds / 3_600
        if hours < 10 {
            return "about \(String(format: "%.1f", hours)) hr"
        }
        return "about \(Int(hours.rounded())) hr"
    }

    /// "3–11 min" for an estimated band.
    static func durationRange(_ range: ClosedRange<Double>) -> String {
        let low = roundedMinutes(range.lowerBound)
        let high = roundedMinutes(range.upperBound)
        if low == high { return low }
        let lowParts = low.split(separator: " ")
        let highParts = high.split(separator: " ")
        if lowParts.count == 2, highParts.count == 2, lowParts[1] == highParts[1] {
            return "\(lowParts[0])–\(high)"
        }
        return "\(low) to \(high)"
    }

    private static func roundedMinutes(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "under a minute" }
        if seconds < 60 { return "under a minute" }
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return "\(minutes) min" }
        let hours = Double(minutes) / 60
        return hours < 10 ? String(format: "%.1f hr", hours) : "\(Int(hours.rounded())) hr"
    }

    static func date(_ value: Date?) -> String {
        guard let value else { return "Undated video" }
        return value.formatted(date: .abbreviated, time: .shortened)
    }
    static func duration(_ value: Double) -> String {
        guard value.isFinite, value > 0 else { return "—" }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = value >= 3_600 ? [.hour, .minute, .second] : [.minute, .second]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: value) ?? "—"
    }

    static func frameRate(_ value: Double) -> String {
        guard value.isFinite, value > 0.5 else { return "—" }
        return "\(Int(value.rounded())) fps"
    }
}

/// A large measured number with a short explanation. Used for scan totals and run totals.
struct ShrinkStat: View {
    let value: String
    let label: String
    var detail: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(.system(.title, design: .default, weight: .semibold))
                .tracking(-0.8)
                .foregroundStyle(ShrinkStyle.accent)
                .monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
            Text(label).font(.subheadline.weight(.medium))
            if let detail {
                Text(detail).font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// The surface every bottom action bar sits on, so both flows share one shape.
struct ShrinkActionBar<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 10) { content }
            .frame(maxWidth: 540)
            .padding(.horizontal, ShrinkStyle.gutter).padding(.top, 18).padding(.bottom, 12)
            .frame(maxWidth: .infinity)
            // Opaque, and it was 0.97. The background is one flat colour, so three percent of
            // transparency bought nothing except a ghost of whatever was scrolling underneath: the
            // summary screen drew its Quality card half-visible through the bar, which reads as a
            // clipped card rather than as a bar. A bar that hides what passes under it is the
            // ordinary arrangement; a bar that nearly hides it is the one that looks wrong.
            .background(ShrinkStyle.canvas)
            .overlay(alignment: .top) { Rectangle().fill(ShrinkStyle.hairline).frame(height: 1) }
    }
}

struct ShrinkPrimaryButton: View {
    let title: String
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 58)
                .padding(.horizontal, 16)
        }
        .buttonStyle(ShrinkPrimaryButtonStyle())
    }
}

private struct ShrinkPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isEnabled ? ShrinkStyle.canvas : Color.white.opacity(0.4))
            .background(isEnabled ? ShrinkStyle.accent : ShrinkStyle.elevated,
                        in: RoundedRectangle(cornerRadius: ShrinkStyle.radiusTile, style: .continuous))
            .opacity(configuration.isPressed ? 0.85 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: configuration.isPressed)
    }
}

struct ShrinkBrand: View {
    private let markSide: CGFloat = 28

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "arrow.down.right.and.arrow.up.left")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(ShrinkStyle.canvas)
                .frame(width: markSide, height: markSide)
                .background(ShrinkStyle.accent,
                            in: RoundedRectangle(cornerRadius: ShrinkStyle.markRadius(for: markSide)))
            // "BatchShrink" is one unbreakable word, and at the largest text sizes it is wider than
            // the room left beside Skip on the introduction and inside a navigation-bar item on the
            // start screen. Scaling it down costs nothing: the label below is what VoiceOver reads,
            // so the name is never the thing that is lost. Whether 0.6 is enough at the very largest
            // size is a reading of the source; a render at AX5 would settle it.
            Text("BatchShrink")
                .font(.headline)
                .tracking(-0.5)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("BatchShrink")
    }
}

/// Uses measured progress only. Unknown progress remains a native activity indicator.
struct ShrinkProgressOrb: View {
    let progress: Double?
    let label: String

    var body: some View {
        ZStack {
            Circle().stroke(ShrinkStyle.elevated, lineWidth: 8)
            if let progress {
                Circle().trim(from: 0, to: min(1, max(0, progress)))
                    .stroke(ShrinkStyle.accent, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text(min(1, max(0, progress)), format: .percent.precision(.fractionLength(0)))
                    .font(.system(.largeTitle, design: .default, weight: .semibold))
                    .tracking(-1.5).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.4).padding(16)
            } else {
                ProgressView().controlSize(.large).tint(ShrinkStyle.accent)
            }
        }
        .frame(width: 144, height: 144)
        .padding(12)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(progress.map { "\(Int(min(1, max(0, $0)) * 100)) percent" } ?? "In progress")
    }
}

/// The two bars that put an original and its copy side by side.
///
/// Every screen that reports a saving draws this: the summary's estimate, the end of a batch run,
/// and the one-video result. The one-video screen used to draw its own version of it, in its own
/// colour, with no track behind the bars - so the same fact looked like two different components
/// depending on which flow produced it, and the copy's bar in that version simply stopped in
/// mid-air with nothing to compare it against. One component, so the two cannot drift again.
struct ShrinkSizeComparison: View {
    let original: Int64
    let copy: Int64
    /// What the two rows are called.
    ///
    /// The summary is talking about a library - "Originals", "Estimated copies" - and the one-video
    /// result is talking about the file it just wrote - "Original", "New copy". Neither screen's
    /// words are right on the other, so the caller owns them and these are the summary's.
    var originalTitle = "Originals"
    var copyTitle = "Smaller copies"

    var body: some View {
        VStack(spacing: 18) {
            sizeRow(originalTitle, bytes: original, color: ShrinkStyle.lilac)
            sizeRow(copyTitle, bytes: copy, color: ShrinkStyle.accent)
        }
    }

    private func sizeRow(_ title: String, bytes: Int64, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            ViewThatFits(in: .horizontal) {
                HStack {
                    Text(title).foregroundStyle(.secondary)
                    Spacer()
                    Text(ShrinkFormat.bytes(bytes)).fontWeight(.semibold).monospacedDigit()
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).foregroundStyle(.secondary)
                    Text(ShrinkFormat.bytes(bytes)).fontWeight(.semibold).monospacedDigit()
                }
            }
            .font(.subheadline)
            GeometryReader { geometry in
                Capsule().fill(ShrinkStyle.elevated)
                Capsule().fill(color)
                    .frame(width: geometry.size.width * Self.fraction(bytes, of: largest))
            }
            .frame(height: 8).accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
    }

    /// The longer of the two files, which is what both bars are scaled against.
    ///
    /// Scaling against the original alone draws a copy that came out *bigger* as the same length as
    /// the video it came from, which is the one comparison this view exists to make and the one the
    /// one-video screen can actually reach: a copy that did not get smaller is shown on it.
    private var largest: Int64 { max(1, max(original, copy)) }

    /// A bar's share of the track, clamped so a negative or absurd size cannot draw outside it.
    static func fraction(_ bytes: Int64, of largest: Int64) -> Double {
        min(1, max(0, Double(bytes) / Double(max(1, largest))))
    }
}

struct ShrinkNotice: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.title3).foregroundStyle(ShrinkStyle.accent)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(ShrinkStyle.cardPadding).shrinkCard()
        .accessibilityElement(children: .combine)
    }
}

struct ShrinkEyebrow: View {
    let title: String
    let symbol: String
    var body: some View {
        Label(title, systemImage: symbol)
            .font(.caption.weight(.semibold))
            .foregroundStyle(ShrinkStyle.accent)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(ShrinkStyle.accent.opacity(0.09), in: Capsule())
    }
}
