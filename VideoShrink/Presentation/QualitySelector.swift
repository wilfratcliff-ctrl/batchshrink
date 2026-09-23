import SwiftUI

/// The words both estimate cards use when their band predicts no saving at all.
///
/// Each card drew a pair of zeroes as the byte figure "Zero KB" in its largest type when nothing
/// in the selection was expected to shrink. Zero is true and it is not what the card is for: the
/// video's own row already says "Little saving expected", and the card exists to say what the
/// numbers mean. One rule in one place, so the two cards cannot say different things.
enum EstimateCopy {
    static let noSavingHeadline = "No saving expected"
    /// The sentence under it. It states the rule the run applies rather than a claim about bytes
    /// nothing has measured: a copy that does not come out smaller is not saved.
    static let noSavingNote = "BatchShrink only keeps a copy that comes out smaller than its original, so these videos are likely to be left as they are."
}

/// One row of pills where the highlight slides between the options.
struct QualityPillGroup<Option: Hashable & Identifiable>: View {
    let options: [Option]
    let selected: Option
    let title: (Option) -> String
    let caption: (Option) -> String
    let namespace: Namespace.ID
    let select: (Option) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 8)) : AnyLayout(HStackLayout(spacing: 8))
        layout {
            ForEach(options) { option in
                pill(option)
            }
        }
        // The highlight slides from pill to pill. Reduce Motion keeps the highlight and drops the
        // slide, so which option is chosen stays visible without any movement.
        .animation(reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.78), value: selected)
    }

    private func pill(_ option: Option) -> some View {
        let isSelected = option == selected
        return Button { select(option) } label: {
            VStack(spacing: 5) {
                Text(title(option))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(isSelected ? ShrinkStyle.canvas : Color.primary)
                Text(caption(option))
                    .font(.caption2)
                    .foregroundStyle(isSelected ? ShrinkStyle.canvas.opacity(0.75) : Color.secondary)
            }
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 62)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(ShrinkStyle.accent)
                        .matchedGeometryEffect(id: "pill", in: namespace)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(isSelected ? ShrinkStyle.accent.opacity(0.4) : Color.primary.opacity(0.07),
                                  lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityLabel("\(title(option)), \(caption(option))")
    }
}

/// The quality chooser: picture size, frame rate, and an estimate that animates as the choice
/// changes.
struct QualitySelector: View {
    @ObservedObject var settings: ShrinkSettings
    /// Estimated result of the current selection at any resolution.
    let estimate: (CopyResolution) -> SavingsEstimate?
    var placeholder: String = "Choose videos to see how much smaller they could get."

    @Namespace private var resolutionHighlight
    @Namespace private var frameRateHighlight
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 10) {
                sectionTitle("Picture size")
                QualityPillGroup(options: CopyResolution.allCases,
                                 selected: settings.resolution,
                                 title: { $0.title },
                                 caption: { $0.codec.displayName },
                                 namespace: resolutionHighlight) { settings.resolution = $0 }
                Text("Copies are never bigger than the original, so 4K only helps 4K videos.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            estimateBlock
            VStack(alignment: .leading, spacing: 10) {
                sectionTitle("Smoothness")
                QualityPillGroup(options: FrameRateOption.allCases,
                                 selected: settings.frameRate,
                                 title: { $0.shortTitle },
                                 caption: { $0.framesPerSecond == nil ? "Every frame" : "Fewer frames" },
                                 namespace: frameRateHighlight) { settings.frameRate = $0 }
                Text("Fewer frames, smaller file. Fast action looks best untouched.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .sensoryFeedback(.selection, trigger: settings.resolution)
        .sensoryFeedback(.selection, trigger: settings.frameRate)
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    @ViewBuilder private var estimateBlock: some View {
        let projected = estimate(settings.resolution)
        if let projected, projected.hasNumbers {
            // A selection whose band never dips below its originals has a zero at both ends. The
            // card says what it found instead of setting that zero in its largest type.
            let headline = projected.predictsNoSaving
                ? EstimateCopy.noSavingHeadline
                : ShrinkFormat.byteRange(low: projected.conservativeBytes,
                                         high: projected.optimisticBytes)
            let detail = projected.predictsNoSaving
                ? EstimateCopy.noSavingNote
                : "estimated saving · copies about \(ShrinkFormat.bytes(projected.estimatedCopyBytes))"
            VStack(alignment: .leading, spacing: 3) {
                Text(headline)
                    .font(.system(.title, design: .default, weight: .bold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .fixedSize(horizontal: false, vertical: true)
                Text(detail)
                    .font(.footnote).foregroundStyle(.secondary)
                    .contentTransition(.numericText())
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18).shrinkCard()
            // The figures cross-fade as the picture size changes. Reduce Motion swaps them outright.
            .animation(reduceMotion ? nil : .snappy(duration: 0.28), value: settings.resolution)
        } else {
            Text(placeholder)
                .font(.footnote).foregroundStyle(.secondary)
        }
    }
}

/// The sheet both flows present.
struct QualitySheet: View {
    @ObservedObject var settings: ShrinkSettings
    let estimate: (CopyResolution) -> SavingsEstimate?
    var placeholder: String = "Choose videos to see how much smaller they could get."

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Find your balance.").font(ShrinkStyle.headline).tracking(-1)
                        Text("A little smaller, or a little sharper. You decide.")
                            .font(.body).foregroundStyle(.secondary)
                    }
                    QualitySelector(settings: settings, estimate: estimate, placeholder: placeholder)
                    Text("These are estimates. Real sizes appear when it finishes.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .frame(maxWidth: 540)
                .padding(24)
                .frame(maxWidth: .infinity)
            }
            .background(ShrinkStyle.canvas)
            .navigationTitle("Quality")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(32)
        .tint(ShrinkStyle.accent)
    }
}

/// The compact card that shows the current choice and opens the chooser.
struct QualityRow: View {
    @ObservedObject var settings: ShrinkSettings
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 14) {
                Image(systemName: "camera.filters")
                    .font(.title3).foregroundStyle(ShrinkStyle.accent)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Quality").font(.subheadline.weight(.semibold))
                    Text(settings.summary).font(.footnote).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold)).foregroundStyle(.tertiary)
            }
            .padding(18)
            .shrinkCard()
            .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Quality. \(settings.resolution.title) \(settings.resolution.codec.displayName), \(settings.frameRate.title).")
        .accessibilityHint("Opens the picture size and frame rate choices.")
        .accessibilityIdentifier("qualityRow")
    }
}
