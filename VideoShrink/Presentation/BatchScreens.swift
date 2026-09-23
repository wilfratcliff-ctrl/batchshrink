import SwiftUI

// MARK: - Start

struct BatchStartScreen: View {
    @ObservedObject var batch: BatchViewModel
    let useSingleVideo: () -> Void
    let openDeletion: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                ShrinkEyebrow(title: "A little room for more", symbol: "sparkle")
                VStack(alignment: .leading, spacing: 12) {
                    Text("Less weight.\nMore memories.")
                        .font(ShrinkStyle.headline).tracking(-1.2)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    Text("Find the videos taking up space. Make room for whatever comes next.")
                        .font(.body).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ShrinkIllustration()
                HStack(alignment: .top, spacing: 16) {
                    // Decorative: the heading beside it already names the card.
                    Image(systemName: "square.stack.3d.up.fill")
                        .font(.title2).foregroundStyle(ShrinkStyle.lilac)
                        .frame(width: 44, height: 44)
                        .background(ShrinkStyle.lilac.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Start with your video library").font(.headline)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("See sizes and potential savings before you choose what to shrink.")
                            .font(.subheadline).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(22).frame(maxWidth: .infinity, alignment: .leading).shrinkCard()
                DeletionRow(settings: batch.settings, open: openDeletion)
                Text(batch.settings.deletionMode.deletesOriginals
                     ? "Deleting is on. A copy is saved and checked first, then the original goes."
                     : "Nothing is deleted. You keep the original and the copy.")
                    .font(.footnote).foregroundStyle(.secondary)
                QueueWarningNotice(warning: batch.queueWarning)
            }
            .frame(maxWidth: 540)
            .padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 28)
            .frame(maxWidth: .infinity)
        }
        .background(ShrinkStyle.canvas)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarLeading) { ShrinkBrand() } }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ShrinkActionBar {
                ShrinkPrimaryButton(title: "Find my videos", symbol: "arrow.right") {
                    batch.scan()
                }
                .accessibilityIdentifier("scanLibrary")
                Button("Just one video", action: useSingleVideo)
                    .font(.subheadline.weight(.medium))
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("useSingleVideo")
            }
        }
    }
}

// MARK: - Scanning

struct BatchScanningScreen: View {
    @ObservedObject var batch: BatchViewModel

    private var measuring: Bool { batch.scanProgress?.phase == .measuring }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                ShrinkEyebrow(title: "No originals download", symbol: "icloud.slash")
                VStack(alignment: .leading, spacing: 10) {
                    Text(measuring ? "Measuring what’s\nalready here." : "Looking through\nyour videos.")
                        .font(ShrinkStyle.headline).tracking(-1)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    Text(measuring
                         ? "This iOS version doesn’t report original sizes, so BatchShrink is measuring the videos already on your iPhone."
                         : "Checking sizes and lengths. Nothing downloads.")
                        .font(.body).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: 16) {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .accessibilityLabel(measuring ? "Measuring on-device videos" : "Listing videos")
                    Text(countText)
                        .font(.subheadline.weight(.medium))
                        .monospacedDigit()
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(24).shrinkCard()
                Text("Keep this open while it reads.").font(.footnote).foregroundStyle(.secondary)
            }
            .frame(maxWidth: 540)
            .padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 28)
            .frame(maxWidth: .infinity)
        }
        .background(ShrinkStyle.canvas)
        .navigationTitle("Your library")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ShrinkActionBar {
                Button("Stop looking") { batch.cancelScan() }
                    .font(.headline).frame(maxWidth: .infinity, minHeight: 52)
            }
        }
    }

    private var countText: String {
        guard let progress = batch.scanProgress, progress.total > 0 else {
            return measuring ? "Measuring…" : "Looking…"
        }
        let noun = progress.total == 1 ? "video" : "videos"
        return measuring
            ? "\(progress.scanned.formatted()) of \(progress.total.formatted()) \(noun) measured"
            : "\(progress.scanned.formatted()) of \(progress.total.formatted()) \(noun) checked"
    }
}

// MARK: - Summary

struct BatchSummaryScreen: View {
    @ObservedObject var batch: BatchViewModel
    let openQuality: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                ShrinkEyebrow(title: "Library summary", symbol: "list.bullet.rectangle")
                VStack(alignment: .leading, spacing: 10) {
                    Text(headline)
                        .font(ShrinkStyle.headline).tracking(-1)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    Text(subhead)
                        .font(.body).foregroundStyle(.secondary)
                }
                if let result = batch.scanResult, let estimate = batch.scanEstimate {
                    if result.assets.isEmpty {
                        ShrinkNotice(symbol: "video.slash", title: "Nothing to shrink yet",
                                     detail: "Every video BatchShrink can see is unsupported or outside your Photos access.")
                    } else {
                        statsCard(result: result, estimate: estimate)
                        QualityRow(settings: batch.settings, open: openQuality)
                        notices(result: result)
                    }
                }
                if batch.limitedAccess {
                    Text("Limited Photos access: these totals cover only the videos you’ve allowed.")
                        .font(.footnote).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                QueueWarningNotice(warning: batch.queueWarning)
            }
            .frame(maxWidth: 540)
            .padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 28)
            .frame(maxWidth: .infinity)
        }
        .background(ShrinkStyle.canvas)
        .navigationTitle("Your library")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ShrinkActionBar {
                if let result = batch.scanResult, !result.assets.isEmpty {
                    ShrinkPrimaryButton(title: "Choose videos", symbol: "checklist") {
                        batch.beginSelecting()
                    }
                    .accessibilityIdentifier("chooseBatchVideos")
                    Button("Select the \(batch.selectableCount) worth shrinking") {
                        batch.beginSelecting()
                        batch.selectAll()
                    }
                    .font(.subheadline.weight(.medium))
                    .frame(minHeight: 44)
                }
                Button("Look again") { batch.scan() }
                    .font(.subheadline.weight(.medium))
                    .frame(minHeight: 44)
            }
        }
    }

    private var headline: String {
        guard let result = batch.scanResult else { return "Your library" }
        if result.assets.isEmpty { return "Nothing to shrink yet." }
        return result.assets.count == 1 ? "One video can get lighter."
                                        : "\(result.assets.count) videos can get lighter."
    }

    private var subhead: String {
        guard let result = batch.scanResult else { return "" }
        return result.videoCount == 1 ? "1 video in your Photos library."
                                      : "\(result.videoCount) videos in your Photos library."
    }

    private func statsCard(result: LibraryScanResult, estimate: SavingsEstimate) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            if estimate.hasNumbers {
                Label("ROOM TO RECLAIM", systemImage: "arrow.down.right.and.arrow.up.left")
                    .font(.caption.weight(.semibold)).tracking(1.5)
                    .foregroundStyle(ShrinkStyle.accent)
                ShrinkStat(value: ShrinkFormat.byteRange(low: estimate.conservativeBytes,
                                                         high: estimate.optimisticBytes),
                           label: "potentially smaller",
                           detail: "Estimated for \(estimate.sizedCount.formatted()) of \(result.assets.count.formatted()) videos")
                Divider()
                ShrinkSizeComparison(original: estimate.sizedBytes, copy: estimate.estimatedCopyBytes, estimated: true)
                Text("Storage is reclaimed after originals are deleted and cleared from Recently Deleted.")
                    .font(.footnote).foregroundStyle(.secondary)
                DisclosureGroup("About this estimate") {
                    Text(basisText(estimate)).font(.footnote).foregroundStyle(.secondary)
                        .padding(.top, 8)
                }
                .font(.footnote)
            } else {
                ShrinkStat(value: "No sizes yet", label: "savings can’t be estimated",
                           detail: "Photos reported no original size for these videos.")
            }
        }
        .padding(24).shrinkCard()
        // The estimate restates itself when the size changes. Reduce Motion swaps the figures
        // outright, which is the whole of what this animation carries.
        .animation(reduceMotion ? nil : .snappy(duration: 0.28), value: batch.settings.resolution)
    }

    @ViewBuilder private func notices(result: LibraryScanResult) -> some View {
        if result.unknownSizeCount > 0 {
            Text("\(result.unknownSizeCount) aren’t measured yet, so they’re not in the estimate.")
                .font(.footnote).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        if result.unsupportedCount > 0 {
            Text("\(result.unsupportedCount) aren’t supported yet: edited, slow-motion, time-lapse, spatial and Live Photos.")
                .font(.footnote).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func basisText(_ estimate: SavingsEstimate) -> String {
        switch estimate.basis {
        case .planning(let resolution):
            let band = resolution.planningBand
            let detail = String(format: "%.0f–%.0f Mbps", band.lowerBound / 1_000_000, band.upperBound / 1_000_000)
            if estimate.frameRate == .original {
                return "Planning band \(detail), until this iPhone has measured some."
            }
            return "Planning band \(detail), scaled for \(estimate.frameRate.shortTitle)."
        case .measured(let samples):
            return "From \(samples) copies measured on this iPhone."
        }
    }
}

// MARK: - Choosing

struct BatchSelectionScreen: View {
    enum Sort: String, CaseIterable, Identifiable {
        case newest = "Newest"
        case largest = "Largest"
        var id: String { rawValue }
    }

    @ObservedObject var batch: BatchViewModel
    @Binding var confirmStart: Bool
    let openQuality: () -> Void
    @State private var sort: Sort = .largest
    @State private var previewing: LibraryAsset?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 12),
              count: dynamicTypeSize.isAccessibilitySize ? 1 : 2)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Make room.").font(ShrinkStyle.headline).tracking(-1)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityAddTraits(.isHeader)
                        Text("\(batch.eligibleAssets.count) videos to explore")
                            .font(.subheadline).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Menu {
                        Picker("Order", selection: $sort) {
                            ForEach(Sort.allCases) { Text($0.rawValue).tag($0) }
                        }
                    } label: {
                        Label(sort.rawValue, systemImage: "line.3.horizontal.decrease")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 12).frame(minHeight: 44)
                            .background(ShrinkStyle.surface, in: Capsule())
                    }
                    .accessibilityLabel("Sort videos, \(sort.rawValue)")
                    .accessibilityHint("Chooses the order the videos appear in.")
                }
                QualityRow(settings: batch.settings, open: openQuality)
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(assets) { asset in row(asset) }
                }
                Text(footer).font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                QueueWarningNotice(warning: batch.queueWarning)
            }
            .frame(maxWidth: 700)
            .padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 24)
            .frame(maxWidth: .infinity)
        }
        .background(ShrinkStyle.canvas)
        .navigationTitle("Choose videos")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Summary") { batch.backToSummary() }
                    .font(.subheadline.weight(.medium)).frame(minHeight: 44)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Select all \(batch.selectableCount)") { batch.selectAll() }
                    Button("Select likely to shrink") { batch.selectLikelyToShrink() }
                    Button("Clear selection", role: .destructive) { batch.clearSelection() }
                } label: {
                    Image(systemName: "checklist").frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel("Selection options")
                .accessibilityHint("Select all, select likely to shrink, or clear the selection.")
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { actionBar }
        .sheet(item: $previewing) { asset in
            VideoScrubSheet(asset: asset) { try await batch.previewItem(for: asset.id) }
        }
    }

    private var assets: [LibraryAsset] {
        switch sort {
        case .newest:
            return batch.eligibleAssets
        case .largest:
            return batch.eligibleAssets.sorted { ($0.bytes ?? -1) > ($1.bytes ?? -1) }
        }
    }

    private var footer: String {
        var lines = ["Anything that doesn’t get smaller is skipped, so you never get a bigger copy."]
        let unknown = batch.eligibleAssets.filter { $0.bytes == nil }.count
        if unknown > 0 {
            lines.append("\(unknown) aren’t measured yet, so they’re not in the estimate.")
        }
        return lines.joined(separator: " ")
    }

    private var actionBar: some View {
        ShrinkActionBar {
            Group {
                if let estimate = batch.selectionEstimate, estimate.hasNumbers {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(batch.selection.count) selected · \(ShrinkFormat.bytes(estimate.sizedBytes)) of originals")
                            .font(.subheadline.weight(.semibold))
                        Text("Estimated \(ShrinkFormat.byteRange(low: estimate.conservativeBytes, high: estimate.optimisticBytes)) smaller")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    .contentTransition(.numericText())
                } else {
                    Text(batch.selection.isEmpty ? "Nothing selected yet" : "\(batch.selection.count) selected")
                        .font(.subheadline.weight(.semibold))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            ShrinkPrimaryButton(title: batch.selection.count == 1 ? "Shrink 1 video" : "Shrink \(batch.selection.count) videos",
                                symbol: "wand.and.sparkles") {
                confirmStart = true
            }
            .disabled(!batch.canStart)
            .accessibilityIdentifier("startBatch")
        }
    }

    private func row(_ asset: LibraryAsset) -> some View {
        let isSelected = batch.selection.contains(asset.id)
        let alreadyShrunk = batch.completedIdentifiers.contains(asset.id)
        // A copy this app made is left out of an automatic selection, so the row has to say why
        // it is the one thing "Select all" did not tick. It wins over the shrunk label: a copy
        // that was deliberately run through again is in both sets, and "made by" is the fact
        // that explains the row.
        let madeByApp = batch.createdCopyIdentifiers.contains(asset.id)
        let estimate = batch.savings(for: asset)
        // VoiceOver cannot see the lilac captions below, so the row's label repeats every fact
        // the card shows in words, choosing between the three in the same order the card does.
        var spoken = [rowLabel(asset)]
        if madeByApp {
            spoken.append("made by BatchShrink")
        } else if alreadyShrunk {
            spoken.append("previously shrunk")
        } else if let estimate {
            spoken.append(estimate.likelyShrinks
                          ? "estimated \(ShrinkFormat.bytes(estimate.conservativeBytes)) smaller"
                          : "little saving expected")
        }
        spoken.append(isSelected ? "selected" : "not selected")
        return VStack(alignment: .leading, spacing: 0) {
            Button { previewing = asset } label: {
                GeometryReader { geometry in
                    AssetThumbnail(identifier: asset.id,
                                   size: CGSize(width: geometry.size.width, height: geometry.size.height),
                                   badge: ShrinkFormat.duration(asset.duration),
                                   showsPlayBadge: true,
                                   revision: batch.thumbnailRevision)
                }
                .aspectRatio(0.92, contentMode: .fit)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Preview \(rowLabel(asset))")
            .accessibilityHint("Opens the original video player.")
            .accessibilityIdentifier("preview-\(asset.id)")

            Button { batch.toggle(asset.id) } label: {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: 6) {
                        Text(asset.bytes.map(ShrinkFormat.bytes) ?? "Unmeasured")
                            .font(.subheadline.weight(.semibold)).monospacedDigit()
                            .foregroundStyle(.primary)
                        Spacer(minLength: 0)
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .foregroundStyle(isSelected ? ShrinkStyle.accent : Color.secondary)
                    }
                    Text(asset.creationDate?.formatted(date: .abbreviated, time: .omitted) ?? "Undated video")
                        .font(.caption).foregroundStyle(.secondary)
                    if madeByApp {
                        Text("Made by BatchShrink").font(.caption).foregroundStyle(ShrinkStyle.lilac)
                    } else if alreadyShrunk {
                        Text("Previously shrunk").font(.caption).foregroundStyle(ShrinkStyle.lilac)
                    } else if let estimate {
                        Text(estimate.likelyShrinks
                             ? "Est. \(ShrinkFormat.bytes(estimate.conservativeBytes)) smaller"
                             : "Little saving expected")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(estimate.likelyShrinks ? ShrinkStyle.accent : Color.secondary)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(14)
                .frame(maxWidth: .infinity, minHeight: 100, alignment: .topLeading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(spoken.joined(separator: ", "))
            .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            .accessibilityHint(isSelected ? "Remove from this batch." : "Add to this batch.")
        }
        .background(ShrinkStyle.surface)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(isSelected ? AnyShapeStyle(ShrinkStyle.accent) : AnyShapeStyle(ShrinkStyle.hairline),
                              lineWidth: isSelected ? 2 : 1)
                .allowsHitTesting(false)
        }
    }
    /// What VoiceOver reads for a row, shortest useful version of the three facts.
    private func rowLabel(_ asset: LibraryAsset) -> String {
        let size = asset.bytes.map(ShrinkFormat.bytes) ?? "size not reported"
        return "\(ShrinkFormat.date(asset.creationDate)), \(ShrinkFormat.duration(asset.duration)), \(size)"
    }
}

// MARK: - Working

struct BatchProcessingScreen: View {
    @ObservedObject var batch: BatchViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { _ in
            content
        }
        .background(ShrinkStyle.canvas)
        .navigationTitle("Working")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ShrinkActionBar {
                Button(batch.isStopping ? "Pausing…" : "Pause") { batch.pause() }
                    .font(.headline).frame(maxWidth: .infinity, minHeight: 52)
                    .disabled(batch.isStopping)
                Button("Finish with what’s done") { batch.finishNow() }
                    .font(.subheadline.weight(.medium)).frame(minHeight: 44)
                    .disabled(batch.isStopping && !batch.currentIsSaving)
            }
        }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                ShrinkEyebrow(title: batch.isStopping ? "Pausing safely" : "Original protected",
                              symbol: "checkmark.shield")
                VStack(alignment: .leading, spacing: 8) {
                    Text(headline)
                        .font(ShrinkStyle.headline).tracking(-1)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    Text(subhead).font(.body).foregroundStyle(.secondary)
                }
                currentCard
                estimateCard
                if let savings = batch.summary.measuredSavings, savings.isSmaller {
                    savedSoFarCard(savings)
                }
                finishedList
                if let warning = batch.cleanupWarning {
                    ShrinkNotice(symbol: "exclamationmark.triangle", title: "Cleanup needs attention", detail: warning)
                }
                QueueWarningNotice(warning: batch.queueWarning)
                Text(processingFootnote)
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .frame(maxWidth: 540)
            .padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 28)
            .frame(maxWidth: .infinity)
        }
    }

    private var headline: String {
        let remaining = batch.remainingCount
        if remaining == 0 { return "Finishing up." }
        return remaining == 1 ? "One video left." : "\(remaining) videos left."
    }

    /// What the person should know about leaving the app alone with it.
    private var processingFootnote: String {
        if batch.isLowPowerMode {
            return "Keep BatchShrink open. Low Power Mode is on, so this takes longer."
        }
        if batch.settings.keepScreenAwake {
            return "Keeping your screen awake while this runs. Leaving still pauses the batch."
        }
        return "Keep BatchShrink open. Leaving pauses the batch."
    }

    private var subhead: String {
        if batch.isStopping { return "Stopping after this step. Saved copies are safe." }
        return "\(batch.finishedCount) of \(batch.items.count) finished."
    }

    private var estimateCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let estimate = batch.remainingEstimate {
                let midpoint = (estimate.lowerBound + estimate.upperBound) / 2
                Text("\(ShrinkFormat.roughDuration(midpoint)) remaining")
                    .font(.system(.title, design: .default, weight: .bold))
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.numericText())
                Text("\(ShrinkFormat.durationRange(estimate)) · from \(batch.estimator.sampleCount) finished \(batch.estimator.sampleCount == 1 ? "video" : "videos")")
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                Text("Time estimate after the first video")
                    .font(.system(.title, design: .default, weight: .bold))
                    .fixedSize(horizontal: false, vertical: true)
                Text("BatchShrink waits until one video has finished before predicting the rest.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(24).shrinkCard()
    }

    private var currentCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            ShrinkProgressOrb(progress: batch.currentProgress,
                              label: batch.currentStage?.title ?? "Preparing next video")
            if let asset = batch.currentAsset, let number = batch.currentNumber {
                HStack(alignment: .center, spacing: 14) {
                    AssetThumbnail(identifier: asset.id, size: CGSize(width: 96, height: 60),
                                   revision: batch.thumbnailRevision)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Video \(number) of \(batch.items.count)")
                            .font(.subheadline.weight(.semibold))
                        Text(batch.currentStage?.title ?? "Working").font(.headline)
                        Text(detail(asset))
                            .font(.footnote).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if let progress = batch.currentProgress {
                    ProgressView(value: progress)
                        .accessibilityLabel(batch.currentStage?.title ?? "Progress")
                    Text(progress, format: .percent.precision(.fractionLength(0)))
                        .font(.footnote).foregroundStyle(.secondary).monospacedDigit()
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 44)
                Text("Starting the next video…").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(24).shrinkCard()
    }

    private func detail(_ asset: LibraryAsset) -> String {
        let length = ShrinkFormat.duration(asset.duration)
        let stage = batch.currentStage
        if stage == .retrieving { return "\(length) · downloading if it’s in iCloud" }
        if stage == .transcoding {
            return "\(length) · \(batch.settings.resolution.title) \(batch.settings.resolution.codec.displayName)"
        }
        if stage == .verifying { return "\(length) · checking the copy" }
        if stage == .saving { return "\(length) · adding it to Photos" }
        return length
    }

    private func savedSoFarCard(_ savings: Savings) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(ShrinkFormat.bytes(savings.bytesSaved))
                .font(.system(.title, design: .default, weight: .bold))
                .monospacedDigit().accessibilityHidden(true)
                .contentTransition(.numericText())
            Text("smaller so far").font(.subheadline.weight(.medium))
            Text("\(batch.summary.savedCount) \(batch.summary.savedCount == 1 ? "copy" : "copies") saved")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(24).shrinkCard()
        .accessibilityElement(children: .combine)
        // The running total counts up as copies finish. Reduce Motion shows each new figure with
        // no count, and the combined element reads the value either way.
        .animation(reduceMotion ? nil : .snappy(duration: 0.3), value: batch.summary.copyBytes)
    }

    @ViewBuilder private var finishedList: some View {
        let finished = Array(batch.items.filter { $0.state.isFinished }.suffix(10).reversed())
        if !finished.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                Text("Just finished").font(.subheadline.weight(.semibold))
                ForEach(finished) { item in
                    BatchFinishedRow(item: item, readBack: batch.readBackOutcomes[item.id],
                                     deletion: batch.deletionOutcomes[item.id],
                                     revision: batch.thumbnailRevision,
                                     finding: batch.midSaveFindings[item.id])
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24).shrinkCard()
        }
    }
}

struct BatchFinishedRow: View {
    let item: BatchItem
    var readBack: CopyReadBack? = nil
    var deletion: DeletionOutcome? = nil
    var revision: Int = 0
    /// What a restored run worked out about this video, when it stopped while Photos was taking
    /// the copy. `BatchViewModel.midSaveFindings` holds one of these per flagged video, and it is
    /// the only thing that can say whether the app answered the question or the user still has it.
    var finding: MidSaveFinding? = nil

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            AssetThumbnail(identifier: item.asset.id, size: CGSize(width: 44, height: 44),
                           revision: revision)
            VStack(alignment: .leading, spacing: 3) {
                Text(ShrinkFormat.date(item.asset.creationDate))
                    .font(.subheadline.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                Text(detail).font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            if let saving {
                Text("-\(ShrinkFormat.bytes(saving.bytesSaved))")
                    .font(.footnote.weight(.semibold)).monospacedDigit()
                    .foregroundStyle(ShrinkStyle.accent)
                    // Spoken, "-1.4 GB" reads as a subtraction. The label names the saving.
                    .accessibilityLabel("\(ShrinkFormat.bytes(saving.bytesSaved)) saved")
            } else {
                // The symbol only repeats the state `detail` already spells out in words.
                Image(systemName: symbol).foregroundStyle(tint).accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var saving: Savings? {
        if case .saved(let saving) = item.state { return saving }
        return nil
    }

    private var symbol: String {
        switch item.state {
        case .saved: return "checkmark.circle.fill"
        case .skipped: return "equal.circle"
        case .failed: return "exclamationmark.circle"
        case .needsCheck: return "questionmark.circle"
        default: return "circle.dashed"
        }
    }

    private var tint: Color {
        switch item.state {
        case .saved: return ShrinkStyle.accent
        case .failed, .needsCheck: return .orange
        default: return .secondary
        }
    }

    private var detail: String {
        switch item.state {
        case .saved:
            var text = "Saved a smaller copy"
            switch readBack {
            case .confirmed: text = "Saved · read back from Photos"
            case .unavailable: text = "Saved · Photos hasn’t handed it back yet"
            case nil: break
            }
            switch deletion {
            case .deleted: text += " · original deleted"
            case .skipped: text += " · original kept"
            case .failed, .uncertain: text += " · original is still here"
            default: break
            }
            return text
        case .skipped(let reason): return reason
        case .failed(let error): return error.localizedDescription
        case .needsCheck:
            // The app looks at Photos before this row is drawn, so a flagged video usually has an
            // answer by now: either the copy it made is in the library, or - with the whole
            // library in view - there is no copy at all. Only what neither the stored record nor
            // Photos could settle stays the user's question, and then the row shows that question.
            guard let finding else {
                return "Closed while saving. Check Photos before running it again."
            }
            switch finding {
            case .copyInPhotos:
                return "Photos has the copy BatchShrink made, so it is not run again and cannot be copied twice."
            case .noCopyInPhotos:
                return "Photos has no copy BatchShrink made, so running this one again cannot make a second copy."
            case .unresolved(let question):
                return question
            }
        default: return item.state.title
        }
    }
}

/// What a restored run worked out about the videos it stopped mid-save on, split the one way the
/// paused and finished screens care about: answered by the app, and still the user's to answer.
///
/// This is `BatchViewModel.requeueUncertain()`'s own filter read the other way around. That
/// function requeues exactly the flagged videos that do not `forbidsAnotherSave`, so a screen that
/// counts them the same way can offer the requeue control only where the app would act on it, and
/// can say what it found everywhere else.
@MainActor private struct MidSaveReport {
    /// Videos whose copy the app can see. Running one again would make a second copy.
    var foundCopy = 0
    /// Videos the app could not answer for, so looking in Photos is still the user's job.
    var awaitingUser = 0

    init(_ batch: BatchViewModel) {
        for item in batch.items where item.state == .needsCheck {
            if batch.midSaveFindings[item.id]?.forbidsAnotherSave == true {
                foundCopy += 1
            } else {
                awaitingUser += 1
            }
        }
    }

    /// The heading for the flagged videos. It names what is left to do rather than what stopped:
    /// a question the app answered is not something for the user to check.
    var title: String {
        guard awaitingUser > 0 else {
            return foundCopy == 1 ? "1 copy found in Photos" : "\(foundCopy) copies found in Photos"
        }
        return "\(awaitingUser) to check in Photos"
    }

    /// The same, in a sentence, including the part the app settled for itself.
    var detail: String {
        if awaitingUser == 0 {
            return foundCopy == 1
                ? "The copy BatchShrink made is in Photos, so it is not run again. Nothing is left to check."
                : "The copies BatchShrink made are in Photos, so none of them are run again. Nothing is left to check."
        }
        guard foundCopy > 0 else {
            return "BatchShrink stopped while Photos was taking a copy. Look in Photos before running those again."
        }
        let found = foundCopy == 1 ? "one of them" : "\(foundCopy) of them"
        let verdict = foundCopy == 1 ? "so that one is not run again." : "so those are not run again."
        let rest = awaitingUser == 1
            ? "The other one still needs a look in Photos."
            : "The other \(awaitingUser) still need a look in Photos."
        return "BatchShrink stopped while Photos was taking a copy, and found the copy it made for \(found), \(verdict) \(rest)"
    }
}

// MARK: - Paused and finished

struct BatchPausedScreen: View {
    @ObservedObject var batch: BatchViewModel

    private var midSave: MidSaveReport { MidSaveReport(batch) }

    /// Only the reasons worth putting on screen. A pause the user asked for needs no explanation.
    private var pauseReasonText: String? {
        switch batch.pauseReason {
        case .tooWarm: return "Your iPhone got warm, so BatchShrink stopped. Let it cool, then continue."
        case .leftApp: return "BatchShrink paused when the app left the foreground."
        default: return nil
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                ShrinkEyebrow(title: "Paused", symbol: "pause.circle")
                VStack(alignment: .leading, spacing: 10) {
                    Text("Paused.\nNothing was lost.")
                        .font(ShrinkStyle.headline).tracking(-1)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    Text("\(batch.finishedCount) of \(batch.items.count) finished. Copies already saved are in Photos.")
                        .font(.body).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(batch.remainingCount) videos left")
                        .font(.system(.title, design: .default, weight: .bold))
                        .fixedSize(horizontal: false, vertical: true)
                    if let estimate = batch.remainingEstimate {
                        Text("Roughly \(ShrinkFormat.durationRange(estimate)) when you continue.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24).shrinkCard()
                if batch.restoredRun {
                    Text("Picked up where you left off.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let reason = pauseReasonText {
                    Text(reason)
                        .font(.footnote).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if batch.summary.needsCheckCount > 0 {
                    ShrinkNotice(symbol: midSave.awaitingUser > 0 ? "questionmark.circle" : "checkmark.circle",
                                 title: midSave.title, detail: midSave.detail)
                }
                if let warning = batch.queueWarning {
                    ShrinkNotice(symbol: "exclamationmark.triangle",
                                 title: "This run can’t be resumed", detail: warning)
                }
                if let savings = batch.summary.measuredSavings, savings.isSmaller {
                    Text("\(ShrinkFormat.bytes(savings.bytesSaved)) smaller so far · \(batch.summary.savedCount) saved.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: 540)
            .padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 28)
            .frame(maxWidth: .infinity)
        }
        .background(ShrinkStyle.canvas)
        .navigationTitle("Paused")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ShrinkActionBar {
                ShrinkPrimaryButton(title: "Continue", symbol: "play.fill") { batch.resume() }
                if midSave.awaitingUser > 0 {
                    Button("I checked Photos — run them again") { batch.requeueUncertain() }
                        .font(.subheadline.weight(.medium)).frame(minHeight: 44)
                }
                Button("Finish with what’s done") { batch.finishNow() }
                    .font(.subheadline.weight(.medium)).frame(minHeight: 44)
            }
        }
    }
}

struct BatchFinishedScreen: View {
    @ObservedObject var batch: BatchViewModel
    @State private var confirmDeletion = false

    private var midSave: MidSaveReport { MidSaveReport(batch) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                ShrinkEyebrow(title: "Finished", symbol: "checkmark.seal")
                VStack(alignment: .leading, spacing: 10) {
                    Text(headline)
                        .font(ShrinkStyle.headline).tracking(-1)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    Text(subhead)
                        .font(.body).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                totalsCard
                if batch.readBackReport.total > 0 {
                    Text(readBackLine)
                        .font(.footnote).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                failures
                if let note = deletionNote {
                    Text(note)
                        .font(.footnote).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let warning = batch.cleanupWarning {
                    ShrinkNotice(symbol: "exclamationmark.triangle", title: "Cleanup needs attention", detail: warning)
                }
                if let warning = batch.queueWarning {
                    ShrinkNotice(symbol: "exclamationmark.triangle",
                                 title: "Something wasn't written down", detail: warning)
                }
            }
            .frame(maxWidth: 540)
            .padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 28)
            .frame(maxWidth: .infinity)
        }
        .background(ShrinkStyle.canvas)
        .navigationTitle("Finished")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Delete \(batch.deletableItemIDs.count) originals?",
                            isPresented: $confirmDeletion, titleVisibility: .visible) {
            Button("Delete \(batch.deletableItemIDs.count) originals", role: .destructive) {
                batch.deleteOriginalsNow()
            }
            Button("Keep them", role: .cancel) {}
        } message: {
            Text("Each one has a smaller copy that Photos handed back. Deleted originals go to Recently Deleted and stay there for 30 days.")
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ShrinkActionBar {
                ShrinkPrimaryButton(title: "Shrink more videos", symbol: "checklist") {
                    batch.beginSelecting()
                }
                if !batch.deletableItemIDs.isEmpty {
                    Button(batch.deletionInProgress ? "Deleting…" : "Delete \(batch.deletableItemIDs.count) originals") {
                        confirmDeletion = true
                    }
                    .font(.subheadline.weight(.semibold)).foregroundStyle(.orange)
                    .frame(minHeight: 44)
                    .disabled(batch.deletionInProgress)
                    .accessibilityIdentifier("deleteOriginals")
                }
                if batch.summary.failedCount > 0 {
                    Button("Try the failed ones again") { batch.retryFailed() }
                        .font(.subheadline.weight(.medium)).frame(minHeight: 44)
                }
                if midSave.awaitingUser > 0 {
                    Button("I checked Photos — run them again") { batch.requeueUncertain() }
                        .font(.subheadline.weight(.medium)).frame(minHeight: 44)
                }
                Button("Done") { batch.reset() }
                    .font(.subheadline.weight(.medium)).frame(minHeight: 44)
                    .accessibilityIdentifier("finishBatch")
            }
        }
    }

    private var headline: String {
        let saved = batch.summary.savedCount
        if saved == 0 { return "No copies were saved." }
        return saved == 1 ? "One video,\nlighter." : "\(saved) videos,\nlighter."
    }

    private var subhead: String {
        let summary = batch.summary
        var parts: [String] = []
        if summary.savedCount > 0 {
            parts.append("\(summary.savedCount) smaller \(summary.savedCount == 1 ? "copy" : "copies") in Photos.")
        }
        if summary.skippedCount > 0 {
            parts.append("\(summary.skippedCount) didn’t get smaller.")
        }
        if summary.failedCount > 0 {
            parts.append("\(summary.failedCount) couldn’t finish.")
        }
        if summary.pendingCount > 0 {
            parts.append("\(summary.pendingCount) not attempted.")
        }
        if midSave.awaitingUser > 0 {
            parts.append("\(midSave.awaitingUser) to check in Photos.")
        }
        if midSave.foundCopy > 0 {
            let copies = midSave.foundCopy == 1 ? "copy" : "copies"
            parts.append("\(midSave.foundCopy) \(copies) found in Photos and not run again.")
        }
        return parts.isEmpty ? "Nothing was processed." : parts.joined(separator: " ")
    }

    /// What the finished screen can say about copies Photos handed back for a check.
    private var readBackLine: String {
        let report = batch.readBackReport
        let saved = batch.summary.savedCount
        if report.unavailable == 0 {
            return saved == report.confirmed
                ? "All \(saved) copies confirmed in Photos."
                : "\(report.confirmed) of \(saved) confirmed so far."
        }
        return "\(report.confirmed) confirmed · \(report.unavailable) not readable yet."
    }

    /// What the run did with originals, in one honest line.
    private var deletionNote: String? {
        let report = batch.deletionReport
        let mode = batch.effectiveDeletionMode
        if report.deleted > 0 {
            return report.deleted == 1
                ? "1 original deleted. It sits in Recently Deleted for 30 days."
                : "\(report.deleted) originals deleted. They sit in Recently Deleted for 30 days."
        }
        if report.uncertain > 0 {
            return "\(report.uncertain) originals may already have been deleted. Check Photos before running those again."
        }
        if mode.deletesOriginals {
            return batch.deletableItemIDs.isEmpty
                ? "No original qualified to be deleted, so all of them are still there."
                : nil
        }
        return "Nothing was deleted. Keeping both copies uses more space."
    }

    private var totalsCard: some View {
        VStack(alignment: .leading, spacing: 22) {
            if let savings = batch.summary.measuredSavings, savings.isSmaller {
                Label("A LITTLE LIGHTER", systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.semibold)).tracking(1.5)
                    .foregroundStyle(ShrinkStyle.accent)
                ShrinkStat(value: ShrinkFormat.bytes(savings.bytesSaved), label: "less video data",
                           detail: "across \(batch.summary.savedCount) saved \(batch.summary.savedCount == 1 ? "copy" : "copies")")
                Divider()
                ShrinkSizeComparison(original: savings.originalBytes, copy: savings.compressedBytes)
            } else {
                ShrinkStat(value: "Nothing measured", label: "no smaller copies",
                           detail: "originals were left as they were")
            }
        }
        .padding(24).shrinkCard()
    }

    @ViewBuilder private var failures: some View {
        let needing = batch.items.filter { item in
            if item.state.isFailed || item.state == .needsCheck { return true }
            switch batch.deletionOutcomes[item.id] {
            case .uncertain, .failed: return true
            default: return false
            }
        }
        if !needing.isEmpty {
            VStack(alignment: .leading, spacing: 16) {
                Text("Needs attention").font(.subheadline.weight(.semibold))
                ForEach(needing) { item in
                    BatchFinishedRow(item: item, readBack: batch.readBackOutcomes[item.id],
                                     deletion: batch.deletionOutcomes[item.id],
                                     revision: batch.thumbnailRevision,
                                     finding: batch.midSaveFindings[item.id])
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24).shrinkCard()
        }
    }
}

// MARK: - Recovery

struct BatchRecoveryScreen: View {
    @ObservedObject var batch: BatchViewModel
    let useSingleVideo: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Image(systemName: "exclamationmark.circle")
                    .font(.system(size: 48, weight: .light))
                    .foregroundStyle(ShrinkStyle.accent)
                    .accessibilityHidden(true)
                Text("Let’s try that again.")
                    .font(ShrinkStyle.headline).tracking(-1)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Text(batch.message ?? "BatchShrink couldn’t look through your library just now.")
                    .font(.body).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Nothing was changed. Looking through your library only reads dates, durations and sizes.")
                    .font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                QueueWarningNotice(warning: batch.queueWarning)
            }
            .frame(maxWidth: 540)
            .padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 28)
            .frame(maxWidth: .infinity)
        }
        .background(ShrinkStyle.canvas)
        .navigationTitle("Your library")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ShrinkActionBar {
                ShrinkPrimaryButton(title: "Try again", symbol: "arrow.clockwise") { batch.scan() }
                Button("Shrink one video instead", action: useSingleVideo)
                    .font(.subheadline.weight(.medium)).frame(minHeight: 44)
            }
        }
    }
}

// MARK: - Queue notices

/// A queue that could not be written down, or a stored queue that could not be cleared.
///
/// The view model sets this from more than one place, and the run can come to rest on several
/// screens afterwards, so every one of them draws it. `BatchPausedScreen` and
/// `BatchFinishedScreen` keep their own wording because they explain it in their own terms.
struct QueueWarningNotice: View {
    let warning: String?

    var body: some View {
        if let warning {
            ShrinkNotice(symbol: "exclamationmark.triangle",
                         title: "Something wasn't written down", detail: warning)
        }
    }
}

#if DEBUG
// Previews here use plain values only: no Photos access, no files, no view model.
private let previewAsset = LibraryAsset(id: "preview", creationDate: nil, duration: 128,
                                        pixelWidth: 3840, pixelHeight: 2160, bytes: 420_000_000,
                                        unsupportedReason: nil)

#Preview("Finished rows") {
    VStack(alignment: .leading, spacing: 18) {
        BatchFinishedRow(item: BatchItem(asset: previewAsset, state: .saved(
            Savings(originalBytes: 420_000_000, compressedBytes: 126_000_000))))
        BatchFinishedRow(item: BatchItem(asset: previewAsset, state: .skipped(
            "This copy wasn’t smaller than the original, so it wasn’t saved.")))
        BatchFinishedRow(item: BatchItem(asset: previewAsset, state: .failed(.insufficientStorage)))
        BatchFinishedRow(item: BatchItem(asset: previewAsset, state: .needsCheck),
                         finding: .copyInPhotos)
        BatchFinishedRow(item: BatchItem(asset: previewAsset, state: .needsCheck),
                         finding: .unresolved(question: MidSaveFinding.limitedAccessQuestion))
    }
    .padding(24)
    .background(ShrinkStyle.canvas).preferredColorScheme(.dark)
}
#endif
