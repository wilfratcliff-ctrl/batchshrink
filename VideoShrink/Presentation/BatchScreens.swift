import SwiftUI
import UIKit

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

    /// What the scan is doing, in the words this screen draws.
    ///
    /// The scan has three phases now. The listing wording describes neither of the on-device ones,
    /// and "measuring" describes only the size pass, so reading a video's format gets its own
    /// heading and body rather than borrowing the listing's.
    ///
    /// `chosen` is not a scan at all: it is the moment between the user's tap on Shrink and the
    /// first export, when the videos they picked are read for the formats BatchShrink cannot
    /// shrink. It says so in its own words, because a person watching a bar move after tapping
    /// Shrink is owed the reason they are waiting.
    private enum Wording: Equatable { case listing, measuring, inspectingFormats, chosen }

    private var wording: Wording {
        if batch.preflight != nil { return .chosen }
        guard let phase = batch.scanProgress?.phase else { return .listing }
        switch phase {
        case .listing: return .listing
        case .measuring: return .measuring
        case .inspectingFormats: return .inspectingFormats
        }
    }

    /// The count the screen draws, whichever pass is reporting it. The pre-flight and a scan never
    /// run at once: one happens before a run and the other before a choice.
    private var progress: LibraryScanProgress? { batch.preflight ?? batch.scanProgress }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                ShrinkEyebrow(title: "No originals download", symbol: "icloud.slash")
                VStack(alignment: .leading, spacing: 10) {
                    Text(heading)
                        .font(ShrinkStyle.headline).tracking(-1)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    Text(detail)
                        .font(.body).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: 16) {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .accessibilityLabel(progressLabel)
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
        // The same bar carries the chosen-video read, which is not a library being looked through.
        .navigationTitle(batch.preflight == nil ? "Your library" : "Checking")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ShrinkActionBar {
                // The same stop, named for what it is stopping: reading the library is looking,
                // and reading the videos just chosen is not.
                Button(batch.preflight == nil ? "Stop looking" : "Stop") { batch.cancelScan() }
                    .font(.headline).frame(maxWidth: .infinity, minHeight: 52)
            }
        }
    }

    private var heading: String {
        switch wording {
        case .listing: return "Looking through\nyour videos."
        case .measuring: return "Measuring what’s\nalready here."
        case .inspectingFormats: return "Reading formats."
        case .chosen: return "Checking the videos\nyou picked."
        }
    }

    /// What the phase is doing, and what it is not. The format pass reads videos already on this
    /// iPhone, so a video still in iCloud stays unknown instead of being fetched to say otherwise.
    private var detail: String {
        switch wording {
        case .listing:
            return "Checking sizes and lengths. No videos are downloaded."
        case .measuring:
            return "This iOS version doesn’t report original sizes, so BatchShrink is measuring the videos already on your iPhone."
        case .inspectingFormats:
            return "Reading the codec and colour information of videos already on your iPhone. Nothing is downloaded, and a video that is still in iCloud stays unknown."
        case .chosen:
            return "Reading the codec and colour information of the videos you chose, before the first copy is made. Nothing is downloaded, so a video whose original is still in iCloud is read when the run opens it."
        }
    }

    private var progressLabel: String {
        switch wording {
        case .listing: return "Listing videos"
        case .measuring: return "Measuring on-device videos"
        case .inspectingFormats: return "Reading video formats"
        case .chosen: return "Checking chosen videos"
        }
    }

    /// The count line the scan has always published. The same "n of m" is true in every phase, so
    /// only the two labels around it change.
    private var countText: String {
        guard let progress = progress, progress.total > 0 else {
            switch wording {
            case .listing, .inspectingFormats: return "Looking…"
            case .measuring: return "Measuring…"
            case .chosen: return "Checking…"
            }
        }
        let noun = progress.total == 1 ? "video" : "videos"
        return wording == .measuring
            ? "\(progress.scanned.formatted()) of \(progress.total.formatted()) \(noun) measured"
            : "\(progress.scanned.formatted()) of \(progress.total.formatted()) \(noun) checked"
    }
}

// MARK: - Summary

/// What the summary says when the scan found nothing it can work on.
///
/// The two cases are different findings and used to read as one. A library with videos the app
/// cannot use is a refusal of each of them; a library with no videos at all was told the same
/// thing, which cannot be true of nothing. The empty case says there were none, and says it about
/// Photos as this app is allowed to see it, because limited access can make that a different
/// statement about the same library.
struct BatchEmptyNotice: View {
    let result: LibraryScanResult
    /// True when Photos lets the app see part of the library only, so "no videos" means none of
    /// the ones it is allowed rather than none at all.
    let limitedAccess: Bool

    var title: String { "Nothing to shrink yet" }

    var detail: String {
        guard result.videoCount == 0 else {
            return "Every video BatchShrink can see is unsupported or outside your Photos access."
        }
        return limitedAccess
            ? "BatchShrink is allowed to see only some of your Photos library, and there are no videos in that part of it."
            : "There are no videos in your Photos library yet."
    }

    var body: some View {
        ShrinkNotice(symbol: "video.slash", title: title, detail: detail)
    }
}

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
                        BatchEmptyNotice(result: result, limitedAccess: batch.limitedAccess)
                        // Nothing here can be chosen, so the selection screen is not reachable. This
                        // is the one place the refused videos can still be named.
                        RefusedVideoList(assets: result.refusedAssets)
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
                    // What this does is pick every video that may be chosen, so it says that. It used
                    // to read "Select the \(count) worth shrinking" while selecting whatever was
                    // selectable, which is the over-claim the headline above it was just corrected
                    // for - and the selection screen already offers the narrower action by name,
                    // "Select likely to shrink", for anyone who wants it.
                    Button("Select all \(batch.selectableCount)") {
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
        return Self.summaryHeadline(eligibleCount: result.assets.count, estimate: batch.scanEstimate)
    }

    /// What the summary claims about the scan, read off the same estimate the card below it shows.
    ///
    /// The headline used to count every eligible video: it promised "\(count) videos can get
    /// lighter" including the videos the estimate beside it says will not shrink, and it promised
    /// it even when nothing had been measured at all, while the card below read "No sizes yet".
    ///
    /// It now reads the same end of the band the card does - the optimistic one, which is what
    /// decides whether the card has a figure to show at all. Reading the conservative end here
    /// produced its own contradiction: one video whose band straddles its original is "no
    /// reduction" at the bottom and a copy at the top, so the headline announced nothing to get
    /// lighter over a card reading "up to 10 MB". Where the two ends disagree the sentence says
    /// "might" or "up to" rather than "can", which is the same qualification the card's range
    /// carries. Static and internal so a case can state the sentence rather than re-derive it.
    static func summaryHeadline(eligibleCount: Int, estimate: SavingsEstimate?) -> String {
        guard eligibleCount > 0 else { return "Nothing to shrink yet." }
        guard let estimate, estimate.hasNumbers else { return "No sizes to estimate from yet." }
        let possible = estimate.mayShrinkCount
        if possible == 0 { return "Nothing here is likely to get lighter." }
        // Some of them may not shrink after all: the conservative end of the band is zero for at
        // least one video. That is the estimate's own uncertainty, so the sentence carries it.
        let uncertain = estimate.likelyNoReductionCount > 0
        if possible == 1 {
            return uncertain ? "One video might get lighter." : "One video can get lighter."
        }
        return uncertain ? "Up to \(possible) videos can get lighter."
                         : "\(possible) videos can get lighter."
    }

    private var subhead: String {
        guard let result = batch.scanResult else { return "" }
        return result.videoCount == 1 ? "1 video in your Photos library."
                                      : "\(result.videoCount) videos in your Photos library."
    }

    private func statsCard(result: LibraryScanResult, estimate: SavingsEstimate) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            if !estimate.hasNumbers {
                ShrinkStat(value: "No sizes yet", label: "savings can’t be estimated",
                           detail: "Photos reported no original size for these videos.")
            } else if estimate.predictsNoSaving {
                // The band's zero used to be drawn as the bold figure "Zero KB" under the heading
                // "ROOM TO RECLAIM". Zero is true and it is not what the card is for, so the card
                // says what it found instead.
                Label("NOTHING TO RECLAIM", systemImage: "equal.circle")
                    .font(.caption.weight(.semibold)).tracking(1.5)
                    .foregroundStyle(ShrinkStyle.accent)
                ShrinkStat(value: EstimateCopy.noSavingHeadline,
                           label: "at this quality",
                           detail: "Estimated for \(estimate.sizedCount.formatted()) of \(result.assets.count.formatted()) videos")
                Divider()
                Text(EstimateCopy.noSavingNote)
                    .font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                DisclosureGroup("About this estimate") {
                    Text(Self.basisText(estimate)).font(.footnote).foregroundStyle(.secondary)
                        .padding(.top, 8)
                }
                .font(.footnote)
            } else {
                Label("ROOM TO RECLAIM", systemImage: "arrow.down.right.and.arrow.up.left")
                    .font(.caption.weight(.semibold)).tracking(1.5)
                    .foregroundStyle(ShrinkStyle.accent)
                ShrinkStat(value: ShrinkFormat.byteRange(low: estimate.conservativeBytes,
                                                         high: estimate.optimisticBytes),
                           label: "potentially smaller",
                           detail: "Estimated for \(estimate.sizedCount.formatted()) of \(result.assets.count.formatted()) videos")
                Divider()
                // Both rows describe the same videos: the originals a copy is expected for, and the
                // copies. A video the estimate expects to skip has no copy, and pairing its original
                // with the copies was a before-and-after of two different sets.
                ShrinkSizeComparison(original: estimate.copiedBytes, copy: estimate.estimatedCopyBytes,
                                     estimated: true)
                Text("Saving copies uses more space. Storage is reclaimed after originals are deleted and cleared from Recently Deleted.")
                    .font(.footnote).foregroundStyle(.secondary)
                DisclosureGroup("About this estimate") {
                    Text(Self.basisText(estimate)).font(.footnote).foregroundStyle(.secondary)
                        .padding(.top, 8)
                }
                .font(.footnote)
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
            Text("\(result.unsupportedCount) aren't supported yet: Live Photos, time-lapse, spatial, slow-motion, edited, cinematic, shared or restricted, HDR and ProRes videos. HDR and ProRes are read from the video itself: the scan reads the ones already on your iPhone, and the videos you pick are read again before a run starts. A video still in iCloud is only read once the run opens it, so one of those can still turn out to be unsupported.")
                .font(.footnote).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The caption under the estimate, naming where the band came from.
    ///
    /// The frame rate is read from the basis, which is where `CopySizeModel.make` put the choice it
    /// scaled the numbers with, and it is named only when the scaling moved them. The caption used
    /// to name 30 fps - this band's own baseline, a scaling of 1.0 - while saying nothing about the
    /// 0.8x a measured band at 24 fps got, so it named a scaling that did not happen and hid the
    /// one that did. Static and internal so a case can read the sentence.
    static func basisText(_ estimate: SavingsEstimate) -> String {
        let scaling = estimate.basis.frameRateScaling
        switch estimate.basis {
        case .planning(let resolution, _):
            let band = resolution.planningBand
            let detail = String(format: "%.0f–%.0f Mbps", band.lowerBound / 1_000_000, band.upperBound / 1_000_000)
            guard let scaling else {
                return "Planning band \(detail), until this iPhone has measured some."
            }
            return "Planning band \(detail), \(scaling)."
        case .measured(let samples, _):
            guard let scaling else { return "From \(samples) copies measured on this iPhone." }
            return "From \(samples) copies measured on this iPhone, \(scaling)."
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 12),
              count: dynamicTypeSize.isAccessibilitySize ? 1 : 2)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                QualityRow(settings: batch.settings, open: openQuality)
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(assets) { asset in row(asset) }
                }
                // The one case where nothing started at all: every video the user picked was read
                // and refused before the run could begin. The list below names them and says why,
                // and this says that no export was attempted.
                if batch.preflightLeftNothingToRun {
                    ShrinkNotice(symbol: "nosign", title: "Nothing was exported.",
                                 detail: "Every video you picked is one BatchShrink read and cannot shrink, so no run started. They are listed below with the reason, and they are untouched in Photos.")
                }
                // A check that stopped because the app went to the background. The user is back on
                // the screen they tapped from, so without this the tap reads as one that did
                // nothing at all. The Stop button needs no line of its own: that was their tap.
                if let notice = batch.preflightNotice {
                    ShrinkNotice(symbol: "pause.circle", title: "That check stopped.", detail: notice)
                }
                RefusedVideoList(assets: batch.refusedAssets)
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

    /// The headline and the way the grid is ordered.
    ///
    /// They shared one row against about 327pt of usable width. The headline can wrap and the
    /// pill's single word cannot, so at accessibility text sizes the one thing that truncated was
    /// the order the user has no other way to read. The decision is `sortSitsBesideHeadline` on its
    /// own so a case can state it; whether the stacked pill then fits is what a render would say.
    @ViewBuilder private var header: some View {
        if Self.sortSitsBesideHeadline(at: dynamicTypeSize) {
            HStack(alignment: .top) {
                titleBlock
                Spacer(minLength: 8)
                sortMenu
            }
        } else {
            VStack(alignment: .leading, spacing: 12) {
                titleBlock
                sortMenu
            }
        }
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Make room.").font(ShrinkStyle.headline).tracking(-1)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text("\(batch.eligibleAssets.count) videos to explore")
                .font(.subheadline).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var sortMenu: some View {
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

    /// Whether the sort pill shares the headline's line, or sits under it.
    ///
    /// These are the sizes the rest of the app already reshapes itself for: a grid that becomes one
    /// column, and figures that stop sharing a row with their labels. Static and internal so a case
    /// can state the boundary rather than re-derive it.
    static func sortSitsBesideHeadline(at size: DynamicTypeSize) -> Bool {
        !size.isAccessibilitySize
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
                        Text(Self.selectionSummary(selectedCount: batch.selection.count,
                                                   estimate: estimate))
                            .font(.subheadline.weight(.semibold))
                        Text(Self.selectionSaving(estimate))
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
            // The figures count up as videos are ticked. Reduce Motion swaps them outright. Without
            // an animation the numeric transition above it was inert, which reads as a live
            // modifier until someone looks for the animation it needs.
            .animation(reduceMotion ? nil : .snappy(duration: 0.28), value: batch.selection.count)
            ShrinkPrimaryButton(title: batch.selection.count == 1 ? "Shrink 1 video" : "Shrink \(batch.selection.count) videos",
                                symbol: "wand.and.sparkles") {
                confirmStart = true
            }
            .disabled(!batch.canStart)
            .accessibilityIdentifier("startBatch")
        }
    }

    /// The first line of the action bar.
    ///
    /// It read "5 selected · 2.1 GB of originals" where one of the five had no reported size. The
    /// count was the whole selection and the figure was the subtotal of the videos Photos or the
    /// device could measure, so the line claimed a total it did not have. The qualifier the footer
    /// already carried is now in the line itself. Static and internal so a case can read it.
    static func selectionSummary(selectedCount: Int, estimate: SavingsEstimate) -> String {
        "\(selectedCount) selected · \(ShrinkFormat.bytes(estimate.sizedBytes)) of \(estimate.sizedCount) measured"
    }

    /// The action bar's second line, which is the third place a band's zero used to be set as the
    /// claim "Zero KB": the bar read "Estimated Zero KB smaller" over a selection the estimate
    /// expected the run to skip. It says what the estimate found instead, in the words the two
    /// estimate cards already use. Static and internal so a case can read it.
    static func selectionSaving(_ estimate: SavingsEstimate) -> String {
        estimate.predictsNoSaving
            ? EstimateCopy.noSavingHeadline
            : "Estimated \(ShrinkFormat.byteRange(low: estimate.conservativeBytes, high: estimate.optimisticBytes)) smaller"
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
}

/// What VoiceOver reads for one video's row, shortest useful version of the three facts. The rows
/// that can be chosen and the rows the scan refused both use it, so one video reads the same way
/// wherever it is named.
private func rowLabel(_ asset: LibraryAsset) -> String {
    let size = asset.bytes.map(ShrinkFormat.bytes) ?? "size not reported"
    return "\(ShrinkFormat.date(asset.creationDate)), \(ShrinkFormat.duration(asset.duration)), \(size)"
}

/// The videos a scan read and refused, named with the reason it read from the media.
///
/// A refused video is not one this app can run, so it is named rather than offered: nothing here is
/// a button and nothing can be ticked. The selection screen draws this after the rows that can be
/// chosen, and the summary draws it when there is nothing eligible at all, which is the one case
/// where the selection screen cannot be reached. Both exist because a count never says which video
/// was refused or why.
struct RefusedVideoList: View {
    let assets: [LibraryAsset]
    /// A sentence for the screen this list is drawn on, when the screen has something to add about
    /// why these videos are here. The run screens say they came out before the first export; the
    /// library screens have nothing to add and pass nothing.
    var context: String? = nil

    var body: some View {
        if !assets.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                // Every other title on these screens is a VoiceOver header, so this card's heading
                // and the two below it were the only ones the rotor could not reach.
                Text("Not supported")
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Text(spoken)
                    .font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(assets) { asset in row(asset) }
            }
            .padding(.top, 4)
        }
    }

    /// What this list says above its rows: whatever the screen that drew it had to add, then the
    /// account of what the list itself is.
    private var spoken: String {
        guard let context = context else { return summary }
        return "\(context) \(summary)"
    }

    private var summary: String {
        assets.count == 1
            ? "BatchShrink read this video and cannot shrink it. It stays in Photos untouched."
            : "BatchShrink read these videos and cannot shrink them. They stay in Photos untouched."
    }

    private func row(_ asset: LibraryAsset) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "nosign")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(rowLabel(asset))
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(asset.unsupportedReason ?? "This video is not supported yet.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ShrinkStyle.surface)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(ShrinkStyle.hairline, lineWidth: 1)
                .allowsHitTesting(false)
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint("This video cannot be chosen for a batch.")
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
                // The videos the chosen-video read refused, named with the reason the media itself
                // gave. They are here rather than in the run, so the count under this heading is
                // the count the user was promised minus exactly these.
                RefusedVideoList(assets: batch.preflightRefusals,
                                 context: "Taken out of this run before it started.")
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
                    // The estimate is remade as videos finish, and the figure counts to its new
                    // value when it moves. Reduce Motion swaps it outright; the numeric transition
                    // above was inert without an animation to drive it.
                    .animation(reduceMotion ? nil : .snappy(duration: 0.28), value: batch.remainingEstimate)
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
                    // The bar speaks its own percentage and the orb speaks the stage and the
                    // percentage again; this figure is the same number a third time. It stays on
                    // screen and leaves the accessibility tree.
                    Text(progress, format: .percent.precision(.fractionLength(0)))
                        .font(.footnote).foregroundStyle(.secondary).monospacedDigit()
                        .accessibilityHidden(true)
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
            // The figure is the only thing on this screen that says anything is being saved, and it
            // was hidden inside a container that combines its children: VoiceOver read "smaller so
            // far, 3 copies saved" and never the number. `BatchFinishedRow` gives its figure the same
            // spoken label one screen away, so the phrase lives in one place.
            Text(ShrinkFormat.bytes(savings.bytesSaved))
                .font(.system(.title, design: .default, weight: .bold))
                .monospacedDigit()
                .accessibilityLabel(BatchFinishedRow.SavingDisplay(bytesSaved: savings.bytesSaved).spokenLabel)
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
                    .accessibilityAddTraits(.isHeader)
                ForEach(finished) { item in
                    BatchFinishedRow(item: item, readBack: batch.readBackOutcomes[item.id],
                                     deletion: batch.deletionOutcomes[item.id],
                                     revision: batch.thumbnailRevision,
                                     finding: batch.midSaveFindings[item.id],
                                     storageDemand: batch.storageDemands[item.id])
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
    /// The room a space check asked for when it refused this video, from
    /// `BatchViewModel.storageDemands`. A refusal taken at a measured size is a fact about this
    /// video, so the row names the figure the check held instead of the general sentence.
    var storageDemand: Int64? = nil

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
            if let display = savingDisplay {
                Text(display.figure)
                    .font(.footnote.weight(.semibold)).monospacedDigit()
                    .foregroundStyle(ShrinkStyle.accent)
                    .accessibilityLabel(display.spokenLabel)
            } else {
                // The symbol only repeats the state `detail` already spells out in words.
                Image(systemName: symbol).foregroundStyle(tint).accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// The saving this row may show, or nil when there is none it could honestly show.
    ///
    /// A stored `.saved` whose copy is not smaller than its original comes only from a queue file
    /// this app did not write: every path that writes `.saved` is gated on `isSmaller`. It used to
    /// be rendered as a figure all the same, and a negative saving reads there as "--1.2 GB".
    var savingDisplay: SavingDisplay? {
        guard case .saved(let saving) = item.state, saving.isSmaller else { return nil }
        return SavingDisplay(bytesSaved: saving.bytesSaved)
    }

    /// One saving in the two forms a figure needs, built from the same number so the figure and the
    /// phrase VoiceOver reads cannot disagree. The working screen's running total is the other
    /// figure nothing else can explain, and it borrows this phrase rather than writing its own.
    struct SavingDisplay: Equatable {
        let bytesSaved: Int64
        var figure: String { "-\(ShrinkFormat.bytes(bytesSaved))" }
        /// Spoken, "-1.4 GB" reads as a subtraction. The label names the saving.
        var spokenLabel: String { "\(ShrinkFormat.bytes(bytesSaved)) saved" }
    }

    private var symbol: String {
        switch item.state {
        case .saved: return savingDisplay == nil ? "equal.circle" : "checkmark.circle.fill"
        case .skipped: return "equal.circle"
        case .failed: return "exclamationmark.circle"
        case .needsCheck: return "questionmark.circle"
        default: return "circle.dashed"
        }
    }

    private var tint: Color {
        switch item.state {
        case .saved: return savingDisplay == nil ? .secondary : ShrinkStyle.accent
        case .failed, .needsCheck: return .orange
        default: return .secondary
        }
    }

    /// What the row says happened to this video. Internal so a case can read the sentence, which is
    /// the product here.
    var detail: String {
        switch item.state {
        case .saved(let saving):
            var text = saving.isSmaller ? "Saved a smaller copy" : "Saved a copy"
            switch readBack {
            case .confirmed: text = "Saved · read back from Photos"
            case .unavailable: text = "Saved · Photos hasn’t handed it back yet"
            case nil: break
            }
            // The saved state and a copy that is not smaller can only meet in a queue file this
            // app did not write, and the row must say so rather than leave a checkmark and no
            // figure unexplained.
            if !saving.isSmaller {
                text += " · its recorded size is not smaller than the original"
            }
            switch deletion {
            case .deleted: text += " · original deleted"
            case .skipped: text += " · original kept"
            case .failed: text += " · original is still here"
            case .uncertain: text += " · original may already be deleted"
            default: break
            }
            return text
        case .skipped(let reason): return reason
        case .failed(let error):
            // A refusal taken at a size this run measured is a fact about this video, and the check
            // held the figure when it refused. The sentence is `PipelineError`'s own, so it reads
            // here exactly as the paused screen's and the one-video flow's do.
            if let storageDemand, error == .insufficientStorage {
                return PipelineError.insufficientStorageSentence(needed: storageDemand)
            }
            return error.localizedDescription
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
            // Said of the copy rather than of the run: a save Photos did not confirm flags its
            // video while the run itself carries on to the next one.
            return awaitingUser == 1
                ? "Photos may still have been taking the copy of this video. Look in Photos before running it again."
                : "Photos may still have been taking the copies of these videos. Look in Photos before running them again."
        }
        let found = foundCopy == 1 ? "one of them" : "\(foundCopy) of them"
        let verdict = foundCopy == 1 ? "so that one is not run again." : "so those are not run again."
        let rest = awaitingUser == 1
            ? "The other one still needs a look in Photos."
            : "The other \(awaitingUser) still need a look in Photos."
        return "Photos kept the copy it made for \(found), \(verdict) \(rest)"
    }
}

// MARK: - Paused and finished

struct BatchPausedScreen: View {
    @ObservedObject var batch: BatchViewModel

    private var midSave: MidSaveReport { MidSaveReport(batch) }

    /// Only the reasons worth putting on screen. A pause the user asked for needs no explanation,
    /// and every reason the user did not ask for brings its own wording with it.
    private var pauseReasonText: String? { batch.pauseReason?.explanation }

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
                    // The same notice, under the same title, that the start, summary, selection,
                    // processing, recovery and finished screens draw. What this screen has to add
                    // is the button: Continue still works, and it is a relaunch that may not find
                    // this run again, because the record the relaunch reads may be older than it.
                    ShrinkNotice(symbol: "exclamationmark.triangle",
                                 title: "Something wasn't written down", detail: warning)
                    Text("Continue still works. Part of this run's record may be missing, so a relaunch may not pick it up again.")
                        .font(.footnote).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let savings = batch.summary.measuredSavings, savings.isSmaller {
                    Text("\(ShrinkFormat.bytes(savings.bytesSaved)) smaller so far · \(batch.summary.savedCount) saved.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                // The same list the working screen carries: a run that was stopped still has to
                // account for the videos it never took.
                RefusedVideoList(assets: batch.preflightRefusals,
                                 context: "Taken out of this run before it started.")
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
                // The same list the working and paused screens carry, in the same sentence: the
                // videos the chosen-video read took out before the run began. They are not in
                // `items`, so without this the counts above cannot be reconciled with what was
                // picked, and they are named as unsupported rather than as anything that failed.
                RefusedVideoList(assets: batch.preflightRefusals,
                                 context: "Taken out of this run before it started.")
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
                HStack(spacing: 12) {
                    Button("Done") { batch.reset() }
                        .font(.subheadline.weight(.medium)).frame(maxWidth: .infinity, minHeight: 44)
                        .accessibilityIdentifier("finishBatch")
                    // Drawn only when there is something behind it: a menu trigger over an empty menu
                    // is a control that does nothing at all.
                    if !extras.isEmpty {
                        overflowMenu
                    }
                }
            }
        }
    }

    /// The one control that keeps this bar two rows high however many extra actions apply.
    ///
    /// The bar could stack five controls - roughly 304pt, and roughly 450pt at accessibility text
    /// sizes - against a landscape viewport of about 330pt, which left the totals card, the read-back
    /// line and the failure list a sliver. Those figures are the audit's arithmetic: a render in both
    /// landscape orientations would settle what the bar actually costs.
    private var overflowMenu: some View {
        Menu {
            ForEach(extras) { extra in
                switch extra {
                case .deleteOriginals:
                    // The destructive role is what the menu has instead of the bar's orange text.
                    Button(batch.deletionInProgress ? "Deleting…" : "Delete \(batch.deletableItemIDs.count) originals",
                           role: .destructive) {
                        confirmDeletion = true
                    }
                    .disabled(batch.deletionInProgress)
                    .accessibilityIdentifier("deleteOriginals")
                case .retryFailed:
                    Button("Try the failed ones again") { batch.retryFailed() }
                case .requeueUncertain:
                    Button("I checked Photos — run them again") { batch.requeueUncertain() }
                }
            }
        } label: {
            Label("More actions", systemImage: "ellipsis.circle")
                .font(.subheadline.weight(.medium))
                .frame(minWidth: 44, minHeight: 44)
        }
        .accessibilityHint("Delete originals, try the failed ones again, or run the ones you checked.")
    }

    /// What the finished screen can still do beyond the two controls on its bar, in the order they
    /// appear. One list decides both whether the overflow control is drawn and what is inside it, so
    /// the two cannot disagree.
    private var extras: [Extra] {
        Extra.available(deletableCount: batch.deletableItemIDs.count,
                        failedCount: batch.summary.failedCount,
                        awaitingUser: midSave.awaitingUser)
    }

    /// The screen's third, fourth and fifth controls, as values rather than as a second copy of the
    /// conditions that decide them. Internal so a case can read the list.
    enum Extra: Hashable, Identifiable {
        case deleteOriginals
        case retryFailed
        case requeueUncertain

        var id: Self { self }

        static func available(deletableCount: Int, failedCount: Int, awaitingUser: Int) -> [Extra] {
            var extras: [Extra] = []
            if deletableCount > 0 { extras.append(.deleteOriginals) }
            if failedCount > 0 { extras.append(.retryFailed) }
            if awaitingUser > 0 { extras.append(.requeueUncertain) }
            return extras
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
                    .accessibilityAddTraits(.isHeader)
                ForEach(needing) { item in
                    BatchFinishedRow(item: item, readBack: batch.readBackOutcomes[item.id],
                                     deletion: batch.deletionOutcomes[item.id],
                                     revision: batch.thumbnailRevision,
                                     finding: batch.midSaveFindings[item.id],
                                     storageDemand: batch.storageDemands[item.id])
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
    @Environment(\.openURL) private var openURL

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
                // Only for access the user themselves refused. Naming Settings here would be the
                // wrong route for a restriction, where Photos is not on this app's Settings page
                // at all - that case carries its own sentence above and no way out but the truth.
                if batch.accessBlock == .refused {
                    Text("Photos access is allowed outside BatchShrink. Allow it there and come back: BatchShrink looks at your library again by itself.")
                        .font(.footnote).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("Nothing was changed. Looking through your library reads details and sizes; your videos are left alone.")
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
                if batch.accessBlock == .refused {
                    Button("Open Photos access settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }
                    .font(.subheadline.weight(.medium)).frame(minHeight: 44)
                }
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
/// screens afterwards, so every one of them draws it, under this one title. `BatchPausedScreen`
/// and `BatchFinishedScreen` draw it directly instead of through this view, because each has one
/// thing of its own to say about a run that has stopped or ended.
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
