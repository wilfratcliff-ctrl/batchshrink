import Foundation

/// Why a run stopped. The paused screen says which one happened.
enum BatchPauseReason: Equatable, Sendable, CaseIterable {
    case asked
    case leftApp
    case tooWarm
    /// A refusal taken before anything about this video was measured.
    ///
    /// The run asks for one working reserve before it starts on a video at all, and that figure is
    /// the same for every video in the run. Nothing the run does to one video changes it, so
    /// failing each remaining item with the same sentence, once per item, says one thing many
    /// times and answers nothing. It stops the run instead, and the paused screen names the figure
    /// the check asked for.
    ///
    /// A refusal taken at a size the run *did* measure - the room for one video's copy - is not
    /// this: a later video may be small enough, so that one still fails only its own video.
    case storage

    /// What the paused screen says about a stop the user did not ask for, or nil for the one they
    /// did.
    ///
    /// The switch is exhaustive on purpose, with no `default`: a reason added later cannot come to
    /// rest on a paused screen that explains nothing, because it will not compile without its
    /// wording here.
    var explanation: String? {
        switch self {
        case .asked: return nil
        case .leftApp: return "BatchShrink paused when the app left the foreground."
        case .tooWarm: return "Your iPhone got warm, so BatchShrink stopped. Let it cool, then continue."
        case .storage:
            // The check that stops the run asks for the working reserve and for no measured file,
            // so the sentence names that figure rather than a copy nothing has measured yet.
            return PipelineError.insufficientStorageSentence(needed: DiskHeadroom.neededToWrite(nil))
        }
    }
}

enum BatchItemState: Equatable, Sendable {
    case pending
    case retrieving(Double?)
    case preparing
    case transcoding(Double?)
    case verifying
    case saving
    case saved(Savings)
    case skipped(String)
    case failed(PipelineError)
    /// The app stopped while Photos was accepting this copy. It is not run again on its own.
    case needsCheck

    var isFinished: Bool {
        switch self {
        case .saved, .skipped, .failed, .needsCheck: return true
        default: return false
        }
    }

    var isSaving: Bool {
        if case .saving = self { return true }
        return false
    }

    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }

    var title: String {
        switch self {
        case .pending: return "Waiting"
        case .retrieving: return "Getting the original"
        case .preparing: return "Getting ready"
        case .transcoding: return "Shrinking"
        case .verifying: return "Checking the copy"
        case .saving: return "Keeping the copy"
        case .saved: return "Saved"
        case .skipped: return "Not saved"
        case .failed: return "Couldn’t finish"
        case .needsCheck: return "Check Photos"
        }
    }
}

struct BatchItem: Identifiable, Equatable, Sendable {
    let asset: LibraryAsset
    var state: BatchItemState
    var id: String { asset.id }
}

/// Whether the copy Photos accepted could be read back afterwards.
///
/// A failed read-back is not a failed save: Photos already confirmed the write. It means the
/// copy could not be checked yet, and the summary says exactly that.
enum CopyReadBack: String, Codable, Equatable, Sendable {
    case confirmed
    case unavailable
}

struct ReadBackReport: Equatable, Sendable {
    var confirmed = 0
    var unavailable = 0
    var total: Int { confirmed + unavailable }
}

struct BatchSummary: Equatable, Sendable {
    var savedCount = 0
    var skippedCount = 0
    var failedCount = 0
    var needsCheckCount = 0
    var pendingCount = 0
    var originalBytes: Int64 = 0
    var copyBytes: Int64 = 0

    var measuredSavings: Savings? {
        guard originalBytes > 0, copyBytes > 0 else { return nil }
        return Savings(originalBytes: originalBytes, compressedBytes: copyBytes)
    }
}

/// Estimates how long the rest of a batch will take from the work already finished.
///
/// It reports nothing until this device has finished at least one video, and it always
/// reports a range: compression speed varies with content, temperature and power state.
struct ProcessingEstimator: Equatable, Sendable {
    struct Sample: Equatable, Sendable {
        let processingSeconds: Double
        let contentSeconds: Double?
    }

    private(set) var samples: [Sample] = []

    mutating func record(processingSeconds: Double, contentSeconds: Double?) {
        guard processingSeconds.isFinite, processingSeconds >= 0 else { return }
        let duration = contentSeconds ?? 0
        let content = duration.isFinite && duration > 0.5 ? duration : nil
        samples.append(Sample(processingSeconds: processingSeconds, contentSeconds: content))
        if samples.count > 40 { samples.removeFirst(samples.count - 40) }
    }

    var sampleCount: Int { samples.count }
    var hasEstimate: Bool { !samples.isEmpty }

    private var ratios: [Double] {
        samples.compactMap { sample in
            guard let content = sample.contentSeconds, content > 0 else { return nil }
            return sample.processingSeconds / content
        }
    }

    private var meanRatio: Double? {
        let values = ratios
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    private var meanFixedSeconds: Double {
        guard let ratio = meanRatio else { return 0 }
        let fixed = samples.compactMap { sample -> Double? in
            guard let content = sample.contentSeconds else { return nil }
            return max(0, sample.processingSeconds - ratio * content)
        }
        guard !fixed.isEmpty else { return 0 }
        return fixed.reduce(0, +) / Double(fixed.count)
    }

    private var meanItemSeconds: Double {
        guard !samples.isEmpty else { return 0 }
        return samples.map(\.processingSeconds).reduce(0, +) / Double(samples.count)
    }

    /// Multipliers applied to the point estimate to produce the reported band.
    private var spread: (low: Double, high: Double) {
        let values = ratios
        guard values.count >= 2, let lowest = values.min(), let highest = values.max(),
              let mean = meanRatio, mean > 0 else {
            return (0.6, 1.8)
        }
        return (max(0.45, (lowest / mean) * 0.85), min(2.6, (highest / mean) * 1.25))
    }

    func remainingSeconds(pendingContentSeconds: [Double?],
                          activeContentSeconds: Double?,
                          activeElapsedSeconds: Double) -> ClosedRange<Double>? {
        guard hasEstimate else { return nil }
        var total = pendingContentSeconds.reduce(0.0) { $0 + predict(contentSeconds: $1) }
        if let activeContentSeconds {
            total += max(0, predict(contentSeconds: activeContentSeconds) - max(0, activeElapsedSeconds))
        }
        let factors = spread
        let low = max(0, total * factors.low)
        return low...max(low, total * factors.high)
    }

    private func predict(contentSeconds: Double?) -> Double {
        guard let ratio = meanRatio, let duration = contentSeconds, duration > 0 else {
            return max(1, meanItemSeconds)
        }
        return max(1, meanFixedSeconds + ratio * duration)
    }
}

/// The single place where the disk-space heuristics live. These are heuristics, not
/// reservations: PhotoKit and the encoder still report their own failures.
enum DiskHeadroom {
    /// Kept free on top of whatever a step is about to write, and never counted as one of the
    /// files themselves.
    ///
    /// It covers the scratch an export session uses for its own work, the queue write, and the
    /// headroom iOS wants before it will keep handing out space quickly. It is a round number
    /// that nothing has measured on a device, and it is deliberately not scaled to the file: the
    /// file is counted separately, below. `docs/PHYSICAL_DEVICE_TEST_PLAN.md` carries the case
    /// that is meant to settle it.
    static let reserve: Int64 = 256 * 1_024 * 1_024

    /// What a step needs free before it starts writing one more file of this size: that file,
    /// plus the reserve.
    ///
    /// This is the question a space check should be asking, and it is deliberately *not* a
    /// function of how many files exist. A step that is about to write a copy is already holding
    /// the file it is copying from, and that file is already reflected in the free space a check
    /// reads. Counting it a second time demands space the step will never need, which is how a
    /// phone with room to finish an export gets refused before that export starts.
    ///
    /// Pass the size of the file the step is about to write, or nil when that size is not known
    /// yet - before a retrieval whose original may still be in iCloud, for instance - which asks
    /// only for the reserve. A video whose size is unknown is never refused over a figure the
    /// app invented, and the write itself still reports a real failure.
    ///
    /// What it does not promise: a copy that comes out larger in bytes than the file it came
    /// from can still run the device out of room inside the encoder. That is a real, reported
    /// failure that loses nothing - no copy is saved and the original is untouched - and the only
    /// alternative would be to demand space for a copy size that nothing can predict.
    static func neededToWrite(_ bytes: Int64?) -> Int64 {
        guard let bytes, bytes > 0 else { return reserve }
        let (total, overflow) = bytes.addingReportingOverflow(reserve)
        return overflow ? Int64.max : total
    }

    /// The size of `copies` files this size, plus the reserve.
    ///
    /// This answers "how much space will these files take", which is deliberately not the same
    /// question as "how much space does this step still need free": the file a step is copying
    /// from is part of this total but none of what it still needs. Every call site sizes its step
    /// with `neededToWrite(_:)` instead, so this arithmetic has no production caller left: it
    /// survives only because its arithmetic is pinned by test. See the free-space case in
    /// `docs/PHYSICAL_DEVICE_TEST_PLAN.md`.
    static func bytes(_ bytes: Int64, copies: Int64) -> Int64 {
        let (product, overflow) = bytes.multipliedReportingOverflow(by: copies)
        let (total, addOverflow) = product.addingReportingOverflow(reserve)
        return overflow || addOverflow ? Int64.max : total
    }
}
