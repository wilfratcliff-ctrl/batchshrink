import SwiftUI

/// The choice of what happens to originals, with everything it means written next to it.
struct DeletionSheet: View {
    @ObservedObject var settings: ShrinkSettings

    @Environment(\.dismiss) private var dismiss
    @State private var pendingMode: DeletionMode?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    warning
                    VStack(spacing: 0) {
                        ForEach(DeletionMode.allCases) { mode in
                            row(mode)
                            if mode != DeletionMode.allCases.last {
                                Divider().padding(.leading, 16)
                            }
                        }
                    }
                    // The three choices are one card, and it was the only card in the app without a
                    // border - so the list a user has to read before turning deletion on was also
                    // the one thing at Increase Contrast that kept a flat eight-percent fill.
                    .shrinkCard()
                    Text("A copy has to be saved, smaller and confirmed in Photos before an original is touched. Anything else is kept, and the run tells you why.")
                        .font(.footnote).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("This applies to batch runs. The one-video flow never deletes.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .frame(maxWidth: 540)
                .padding(24)
                .frame(maxWidth: .infinity)
            }
            .background(ShrinkStyle.canvas)
            .navigationTitle("Originals")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .confirmationDialog("Delete originals?",
                                isPresented: Binding(get: { pendingMode != nil },
                                                     set: { if !$0 { pendingMode = nil } }),
                                titleVisibility: .visible,
                                presenting: pendingMode) { mode in
                Button("Turn on “\(mode.shortTitle)”", role: .destructive) {
                    settings.deletionMode = mode
                    pendingMode = nil
                }
                Button("Cancel", role: .cancel) { pendingMode = nil }
            } message: { _ in
                Text("Deleted originals wait in Recently Deleted for 30 days before the space comes back. Nothing is deleted unless its copy is saved, smaller and confirmed.")
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(ShrinkStyle.radiusSheet)
        .tint(ShrinkStyle.accent)
    }

    private var warning: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text("Deleting is permanent after 30 days")
                    .font(.subheadline.weight(.semibold))
                Text("Deleted items sit in Recently Deleted for 30 days. That’s when the space comes back, once your devices have synced.")
                    .font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Photos asks you to confirm each batch of deletions, and no app can pre-authorise that. Deleting at the end means one confirmation for the whole run.")
                    .font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(ShrinkStyle.cardPadding).shrinkCard()
        .accessibilityElement(children: .combine)
    }

    private func row(_ mode: DeletionMode) -> some View {
        let isSelected = settings.deletionMode == mode
        return Button {
            // Every mode that deletes goes through one more hard confirmation.
            if mode.deletesOriginals && !isSelected {
                pendingMode = mode
            } else {
                settings.deletionMode = mode
            }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isSelected ? ShrinkStyle.accent : Color.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(mode.title).font(.subheadline.weight(.semibold))
                    Text(mode.detail).font(.footnote).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityIdentifier("deletion-\(mode.rawValue)")
    }
}

/// Shows the current choice and opens the sheet.
struct DeletionRow: View {
    @ObservedObject var settings: ShrinkSettings
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 14) {
                Image(systemName: settings.deletionMode.deletesOriginals ? "trash" : "checkmark.shield")
                    .font(.title3)
                    .foregroundStyle(settings.deletionMode.deletesOriginals ? Color.orange : ShrinkStyle.accent)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Originals").font(.subheadline.weight(.semibold))
                    Text(settings.deletionMode.shortTitle).font(.footnote).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold)).foregroundStyle(.tertiary)
            }
            .padding(ShrinkStyle.cardPadding).shrinkCard()
            .contentShape(RoundedRectangle(cornerRadius: ShrinkStyle.radiusCard, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Originals. \(settings.deletionMode.title).")
        .accessibilityHint("Opens the choice of what happens to originals.")
        .accessibilityIdentifier("deletionRow")
    }
}
