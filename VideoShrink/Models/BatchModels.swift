import Foundation

/// Why a run stopped. The paused screen says which one happened.
enum BatchPauseReason: Equatable, Sendable {
    case asked
    case leftApp
    case tooWarm
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
    static let reserve: Int64 = 256 * 1_024 * 1_024

    static func bytes(_ bytes: Int64, copies: Int64) -> Int64 {
        let (product, overflow) = bytes.multipliedReportingOverflow(by: copies)
        let (total, addOverflow) = product.addingReportingOverflow(reserve)
        return overflow || addOverflow ? Int64.max : total
    }
}
