import Foundation

/// One video as Photos describes it during a scan. Building this downloads nothing: it is
/// library metadata plus, when the platform reports one, an original byte size.
struct LibraryAsset: Identifiable, Equatable, Sendable {
    let id: String
    let creationDate: Date?
    let duration: Double
    let pixelWidth: Int
    let pixelHeight: Int
    /// Original bytes as reported by Photos. `nil` means Photos did not report a size.
    let bytes: Int64?
    /// Non-nil when the pipeline cannot process this video yet.
    let unsupportedReason: String?

    var isEligible: Bool { unsupportedReason == nil }
    var longEdge: Int { max(pixelWidth, pixelHeight) }

    /// Photos reports sizes for a resource, not for a whole asset; a Live Photo or an edited
    /// asset has more than one. Only the ordinary video resource is used.
    func withBytes(_ bytes: Int64?) -> LibraryAsset {
        LibraryAsset(id: id, creationDate: creationDate, duration: duration,
                     pixelWidth: pixelWidth, pixelHeight: pixelHeight,
                     bytes: bytes, unsupportedReason: unsupportedReason)
    }

    func savings(settings: TranscodeSettings, measured: [CopyMeasurement]) -> AssetSavings? {
        guard let bytes, isEligible, duration > 0 else { return nil }
        let effective = settings.effectiveResolution(sourceLongEdge: longEdge)
        let model = CopySizeModel.make(for: effective, frameRate: settings.frameRate, measured: measured)
        return model.savings(sourceBytes: bytes, duration: duration)
    }
}

/// A planning band for the size of a copy, in bits per second.
///
/// Apple does not publish the bitrate of its export presets, so this starts as a planning
/// band per resolution and is replaced by copy sizes measured on this iPhone once enough
/// of them exist.
struct CopySizeModel: Equatable, Sendable {
    enum Basis: Equatable, Sendable {
        case planning(resolution: CopyResolution)
        case measured(samples: Int)
    }

    let lowBitsPerSecond: Double
    let highBitsPerSecond: Double
    let basis: Basis

    static func make(for resolution: CopyResolution,
                     frameRate: FrameRateOption,
                     measured: [CopyMeasurement]) -> CopySizeModel {
        let matching = measured.filter { $0.isValid && matches($0.longEdge, resolution: resolution) }
        let scale = frameRateScale(frameRate)
        let band: ClosedRange<Double>
        let basis: Basis
        if matching.count >= 3,
           let lowest = matching.map(\.bitsPerSecond).min(),
           let highest = matching.map(\.bitsPerSecond).max() {
            band = max(250_000, lowest * 0.9)...min(80_000_000, highest * 1.1)
            basis = .measured(samples: matching.count)
        } else {
            band = resolution.planningBand
            basis = .planning(resolution: resolution)
        }
        let low = band.lowerBound * scale
        return CopySizeModel(lowBitsPerSecond: low,
                             highBitsPerSecond: max(band.upperBound * scale, low * 1.05),
                             basis: basis)
    }

    /// Measured copies only refine the band for the size they were made at.
    static func matches(_ measuredLongEdge: Int, resolution: CopyResolution) -> Bool {
        abs(measuredLongEdge - resolution.longEdge) <= max(8, resolution.longEdge / 20)
    }

    /// Fewer frames means fewer bits at the same picture size. The planning band assumes a
    /// 30 fps original, which the interface states next to the estimate.
    static func frameRateScale(_ frameRate: FrameRateOption) -> Double {
        guard let wanted = frameRate.framesPerSecond else { return 1 }
        return min(1, max(0.4, wanted / 30))
    }

    /// Copy size range for a video of this duration, in bytes.
    func copyBytes(forDuration duration: Double) -> ClosedRange<Int64>? {
        guard duration.isFinite, duration > 0 else { return nil }
        let low = Int64((lowBitsPerSecond * duration / 8).rounded())
        let high = Int64((highBitsPerSecond * duration / 8).rounded())
        return low...max(high, low)
    }

    /// Estimated saving for one video: the conservative figure assumes the copy lands at the
    /// top of the band, the optimistic one at the bottom.
    func savings(sourceBytes: Int64, duration: Double) -> AssetSavings? {
        guard sourceBytes > 0, let copy = copyBytes(forDuration: duration) else { return nil }
        return AssetSavings(conservativeBytes: max(0, sourceBytes - copy.upperBound),
                            optimisticBytes: max(0, sourceBytes - copy.lowerBound))
    }
}

struct AssetSavings: Equatable, Sendable {
    let conservativeBytes: Int64
    let optimisticBytes: Int64

    /// Only true when the copy is smaller even at the top of the band.
    var likelyShrinks: Bool { conservativeBytes > 0 }

    static func + (lhs: AssetSavings, rhs: AssetSavings) -> AssetSavings {
        AssetSavings(conservativeBytes: lhs.conservativeBytes + rhs.conservativeBytes,
                     optimisticBytes: lhs.optimisticBytes + rhs.optimisticBytes)
    }
}

/// What one scan or selection could say about savings. Never a promise: it covers only the
/// videos whose original size Photos or the device could actually report.
struct SavingsEstimate: Equatable, Sendable {
    let sizedCount: Int
    let sizedBytes: Int64
    let conservativeBytes: Int64
    let optimisticBytes: Int64
    let likelyNoReductionCount: Int
    let basis: CopySizeModel.Basis
    let frameRate: FrameRateOption

    var hasNumbers: Bool { sizedCount > 0 }

    /// Bytes a copy of the selection is expected to take, from the same band.
    var estimatedCopyBytes: Int64 {
        max(0, sizedBytes - (conservativeBytes + optimisticBytes) / 2)
    }

    static func make(assets: [LibraryAsset],
                     settings: TranscodeSettings,
                     measured: [CopyMeasurement]) -> SavingsEstimate {
        var sized = 0
        var sizedBytes: Int64 = 0
        var conservative: Int64 = 0
        var optimistic: Int64 = 0
        var noReduction = 0
        var basis: CopySizeModel.Basis = .planning(resolution: settings.resolution)
        for asset in assets {
            guard let saving = asset.savings(settings: settings, measured: measured),
                  let bytes = asset.bytes else { continue }
            let effective = settings.effectiveResolution(sourceLongEdge: asset.longEdge)
            basis = CopySizeModel.make(for: effective, frameRate: settings.frameRate, measured: measured).basis
            sized += 1
            sizedBytes += bytes
            conservative += saving.conservativeBytes
            optimistic += saving.optimisticBytes
            if !saving.likelyShrinks { noReduction += 1 }
        }
        return SavingsEstimate(sizedCount: sized, sizedBytes: sizedBytes,
                               conservativeBytes: conservative, optimisticBytes: optimistic,
                               likelyNoReductionCount: noReduction, basis: basis,
                               frameRate: settings.frameRate)
    }
}

enum LibrarySizeSource: Equatable, Sendable {
    /// Photos reported the original size for at least one video.
    case reportedByPhotos
    /// Photos reports no size on this iOS version, so originals already on the iPhone were measured.
    case measuredOnDevice
    /// No size was available from either route.
    case unavailable
}

struct LibraryScanProgress: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case listing
        case measuring
    }

    let phase: Phase
    let scanned: Int
    let total: Int
}

struct LibraryScanResult: Equatable, Sendable {
    /// Eligible videos, newest first.
    let assets: [LibraryAsset]
    let videoCount: Int
    let unsupportedCount: Int
    let unknownSizeCount: Int
    let sizeSource: LibrarySizeSource
    let measuredOnDeviceCount: Int

    func estimate(settings: TranscodeSettings, measured: [CopyMeasurement]) -> SavingsEstimate {
        SavingsEstimate.make(assets: assets, settings: settings, measured: measured)
    }
}
