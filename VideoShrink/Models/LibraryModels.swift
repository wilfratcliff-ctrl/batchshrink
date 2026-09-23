import Foundation
import Photos

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

    /// The same video, refused for a reason this app read from the media itself.
    ///
    /// The scan can decide most reasons from library metadata, but a codec subtype and a colour
    /// transfer function appear in no PhotoKit listing. When the on-device pass reads them from an
    /// original that is already on this iPhone, this is how the video is refused while the library
    /// is being listed instead of part-way through a run. The reason is always `AssetRules`' own
    /// sentence, so the video reads the same wherever it is refused.
    func refusing(_ reason: String) -> LibraryAsset {
        LibraryAsset(id: id, creationDate: creationDate, duration: duration,
                     pixelWidth: pixelWidth, pixelHeight: pixelHeight,
                     bytes: bytes, unsupportedReason: reason)
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
    /// The band the estimate came from, named with the frame rate that scaled it.
    ///
    /// The frame rate travels inside the basis rather than beside it so the caption cannot claim
    /// a scaling the arithmetic did not apply: `make(for:frameRate:measured:)` puts the same
    /// choice it scaled the band with into the basis it hands back, and everything that describes
    /// the numbers reads it from here.
    enum Basis: Equatable, Sendable {
        case planning(resolution: CopyResolution, frameRate: FrameRateOption)
        case measured(samples: Int, frameRate: FrameRateOption)

        var frameRate: FrameRateOption {
            switch self {
            case .planning(_, let frameRate), .measured(_, let frameRate): return frameRate
            }
        }

        /// How the caption names the frame-rate scaling, or nil when there was none to name.
        ///
        /// This is read off the same `frameRateScale(_:)` the band was scaled with, so a caption
        /// cannot name a scaling that did not happen. The band is documented as a 30 fps band, so
        /// 30 fps is a no-op here and stays an implementation detail of this file, exactly as the
        /// comment on `frameRateScale` says it should.
        var frameRateScaling: String? {
            guard CopySizeModel.frameRateScales(frameRate) else { return nil }
            return "scaled for \(frameRate.shortTitle)"
        }
    }

    let lowBitsPerSecond: Double
    let highBitsPerSecond: Double
    let basis: Basis

    static func make(for resolution: CopyResolution,
                     frameRate: FrameRateOption,
                     measured: [CopyMeasurement]) -> CopySizeModel {
        let matching = measured.filter { $0.isValid && matches($0.longEdge, resolution: resolution) }
        let band: ClosedRange<Double>
        let basis: Basis
        if matching.count >= 3,
           let lowest = matching.map(\.bitsPerSecond).min(),
           let highest = matching.map(\.bitsPerSecond).max() {
            band = max(250_000, lowest * 0.9)...min(80_000_000, highest * 1.1)
            basis = .measured(samples: matching.count, frameRate: frameRate)
        } else {
            band = resolution.planningBand
            basis = .planning(resolution: resolution, frameRate: frameRate)
        }
        // The scale is taken from the basis the caption is built from rather than from the
        // parameter beside it, so the two cannot be told different things.
        let scale = frameRateScale(basis.frameRate)
        let low = band.lowerBound * scale
        return CopySizeModel(lowBitsPerSecond: low,
                             highBitsPerSecond: max(band.upperBound * scale, low * 1.05),
                             basis: basis)
    }

    /// Measured copies only refine the band for the size they were made at.
    static func matches(_ measuredLongEdge: Int, resolution: CopyResolution) -> Bool {
        abs(measuredLongEdge - resolution.longEdge) <= max(8, resolution.longEdge / 20)
    }

    /// Fewer frames means fewer bits at the same picture size. The planning band is a 30 fps
    /// band and this is what a lower target scales it down from. The interface names the scaling
    /// beside the estimate ("scaled for 24 fps") and never the band's own baseline, so 30 fps
    /// stays an implementation detail of this file.
    static func frameRateScale(_ frameRate: FrameRateOption) -> Double {
        guard let wanted = frameRate.framesPerSecond else { return 1 }
        return min(1, max(0.4, wanted / 30))
    }

    /// True when a frame-rate choice actually moves this band.
    ///
    /// A choice that leaves the band where it was must not be named in the caption beside the
    /// estimate: the interface names the scaling, and "scaled for 30 fps" claimed a scaling that
    /// never happened because 30 fps is this band's own baseline.
    static func frameRateScales(_ frameRate: FrameRateOption) -> Bool {
        frameRateScale(frameRate) < 1
    }

    /// Copy size range for a video of this duration, in bytes.
    ///
    /// Returns nil rather than trapping when the duration is unusable or the byte figure cannot
    /// be held in an `Int64`. Guarding the duration alone is not enough: a duration read out of a
    /// queue file this app did not write can be finite and positive and still large enough to put
    /// the product below out of range, and `Int64(_: Double)` traps on that instead of failing.
    /// `Double(Int64.max)` rounds up to 2^63, the first value an `Int64` cannot hold, so the
    /// upper comparison is strict.
    func copyBytes(forDuration duration: Double) -> ClosedRange<Int64>? {
        guard duration.isFinite, duration > 0 else { return nil }
        let lowest = (lowBitsPerSecond * duration / 8).rounded()
        let highest = (highBitsPerSecond * duration / 8).rounded()
        guard Self.canBeAnInt64(lowest), Self.canBeAnInt64(highest) else { return nil }
        let low = Int64(lowest)
        let high = Int64(highest)
        return low...max(high, low)
    }

    /// True when a computed byte figure is a value an `Int64` can actually hold, which is what
    /// makes the conversion above safe rather than a trap.
    private static func canBeAnInt64(_ bytes: Double) -> Bool {
        bytes.isFinite && bytes >= Double(Int64.min) && bytes < Double(Int64.max)
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
}

/// What one scan or selection could say about savings. Never a promise: it covers only the
/// videos whose original size Photos or the device could actually report.
struct SavingsEstimate: Equatable, Sendable {
    let sizedCount: Int
    let sizedBytes: Int64
    /// Original bytes of the videos the band expects a copy of: the ones whose copy is smaller
    /// than its original even at the bottom of the band.
    ///
    /// A video whose band never dips below its own size is one the run is expected to skip rather
    /// than copy, so its original is part of `sizedBytes` and deliberately not part of this.
    /// Without the split, a video the run will leave alone was counted in the "copies about"
    /// figure at its full size.
    let copiedBytes: Int64
    let conservativeBytes: Int64
    let optimisticBytes: Int64
    let likelyNoReductionCount: Int
    let basis: CopySizeModel.Basis

    var hasNumbers: Bool { sizedCount > 0 }

    /// How many of the sized videos the conservative end of the band still shrinks: the ones the
    /// summary can name as able to get lighter.
    var likelyShrinkCount: Int { sizedCount - likelyNoReductionCount }

    /// True when the band predicts no saving at all, even at its bottom, so a run is expected to
    /// skip every video in the estimate.
    ///
    /// The two cards that draw the band say what they found rather than setting a zero in their
    /// largest type: `ShrinkFormat.byteRange(low: 0, high: 0)` renders "Zero KB", which is true
    /// and tells the user nothing.
    var predictsNoSaving: Bool { hasNumbers && optimisticBytes == 0 }

    /// Bytes the copies are expected to take, from the same band.
    ///
    /// The midpoint of the band is what the "copies about" line shows, over the videos a copy is
    /// expected for, and never above any one original: a copy is never larger than what it copies.
    var estimatedCopyBytes: Int64 {
        max(0, copiedBytes - (conservativeBytes + optimisticBytes) / 2)
    }

    static func make(assets: [LibraryAsset],
                     settings: TranscodeSettings,
                     measured: [CopyMeasurement]) -> SavingsEstimate {
        var sized = 0
        var sizedBytes: Int64 = 0
        var copiedBytes: Int64 = 0
        var conservative: Int64 = 0
        var optimistic: Int64 = 0
        var noReduction = 0
        // The caption drawn from `basis` describes the numbers above, which are byte totals, so
        // each band is credited with the original bytes of the videos that used it and the band
        // holding most of those bytes is the one named. Counting videos instead would let a crowd
        // of small originals speak for one large one. Ties are broken by a canonical order below,
        // so reversing the selection cannot change what the caption claims.
        var bands: [(basis: CopySizeModel.Basis, bytes: Int64)] = []
        for asset in assets {
            guard let bytes = asset.bytes, asset.isEligible, asset.duration > 0 else { continue }
            let effective = settings.effectiveResolution(sourceLongEdge: asset.longEdge)
            // One model per video: this is the band the video's own figures come from and the band
            // the caption may end up naming, so the two read the same numbers.
            let model = CopySizeModel.make(for: effective, frameRate: settings.frameRate,
                                           measured: measured)
            guard let saving = model.savings(sourceBytes: bytes, duration: asset.duration) else {
                continue
            }
            if let index = bands.firstIndex(where: { $0.basis == model.basis }) {
                bands[index] = (basis: bands[index].basis, bytes: bands[index].bytes + bytes)
            } else {
                bands.append((basis: model.basis, bytes: bytes))
            }
            sized += 1
            sizedBytes += bytes
            conservative += saving.conservativeBytes
            optimistic += saving.optimisticBytes
            if !saving.likelyShrinks { noReduction += 1 }
            // A video the band predicts no saving for at all is one the estimate expects the run
            // to skip, so it is not one of the originals the copy figure describes.
            if saving.optimisticBytes > 0 { copiedBytes += bytes }
        }
        return SavingsEstimate(sizedCount: sized, sizedBytes: sizedBytes,
                               copiedBytes: copiedBytes,
                               conservativeBytes: conservative, optimisticBytes: optimistic,
                               likelyNoReductionCount: noReduction,
                               basis: dominantBand(bands)
                                   ?? .planning(resolution: settings.resolution,
                                                frameRate: settings.frameRate))
    }

    /// The band that carries most of the sized original bytes, or nil when nothing was sized.
    ///
    /// A selection with mixed sizes can use more than one band, and only one of them can be named.
    /// The one holding the largest share of the bytes is chosen because the totals the caption
    /// explains are byte totals. An exact tie is settled by `outranks` rather than by whichever
    /// video happened to come first, so the same selection always gets the same caption.
    private static func dominantBand(_ bands: [(basis: CopySizeModel.Basis, bytes: Int64)])
        -> CopySizeModel.Basis? {
        var best: (basis: CopySizeModel.Basis, bytes: Int64)?
        for band in bands {
            guard let current = best else { best = band; continue }
            if band.bytes > current.bytes
                || (band.bytes == current.bytes && outranks(band.basis, current.basis)) {
                best = band
            }
        }
        return best?.basis
    }

    /// A total order over bands, so a tie in bytes cannot be decided by the selection's order.
    /// A band measured on this iPhone outranks a planning band, because it is the stronger
    /// evidence, and a larger band outranks a smaller one.
    private static func outranks(_ band: CopySizeModel.Basis, _ other: CopySizeModel.Basis) -> Bool {
        rank(band) > rank(other)
    }

    private static func rank(_ band: CopySizeModel.Basis) -> (kind: Int, size: Int) {
        switch band {
        case .planning(let resolution, _): return (kind: 0, size: resolution.longEdge)
        case .measured(let samples, _): return (kind: 1, size: samples)
        }
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
        /// Reading library metadata. Nothing here asks for media, so nothing here can download.
        case listing
        /// Measuring the originals already on this iPhone, on a system that reports no size.
        case measuring
        /// Reading the codec and colour tags of the originals already on this iPhone, on a system
        /// that does report sizes. Nothing is measured here, so calling it measuring would be a
        /// claim this pass cannot make.
        case inspectingFormats
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
    /// Videos this scan read and refused on its own, with the reason, newest first.
    ///
    /// They are deliberately not in `assets`: everything in `assets` can be chosen and run, and a
    /// video this app has read and refused cannot be. They are carried here rather than only
    /// counted so the library screen can name them, because a row that says why is better than a
    /// video that quietly disappears. They are counted in `unsupportedCount`, so the summary's
    /// totals still add up.
    ///
    /// Only the on-device pass fills this: a metadata-only refresh cannot read a format, so a
    /// refresh carries the ones already read instead of claiming to know them again.
    var refusedAssets: [LibraryAsset] = []

    func estimate(settings: TranscodeSettings, measured: [CopyMeasurement]) -> SavingsEstimate {
        SavingsEstimate.make(assets: assets, settings: settings, measured: measured)
    }
}

/// Photos access in the app's own terms, so the rest of the app does not have to read a
/// PhotoKit status to know whether it may look at the library.
enum LibraryAccess: Equatable, Sendable {
    /// The app may read the whole library.
    case full
    /// The app may read only the videos the user picked. The user can narrow or widen this in
    /// Settings while the app is in the background, which is why it is re-read on the way in.
    case limited
    /// Photos access was refused or is restricted.
    case denied
    /// The user has not been asked yet.
    case notDetermined

    init(_ status: PHAuthorizationStatus) {
        switch status {
        case .authorized: self = .full
        case .limited: self = .limited
        case .notDetermined: self = .notDetermined
        case .denied, .restricted: self = .denied
        @unknown default: self = .denied
        }
    }

    /// True when the app may list the library at all.
    ///
    /// This answers "may the app read?", which is not the same question as "has access been
    /// lost?". It is false both for a refusal and for a user who has never been asked, so a
    /// caller working out whether to report access as gone has to read `self` rather than this.
    var canRead: Bool { self == .full || self == .limited }
    /// True when the app can see only part of the library.
    var isLimited: Bool { self == .limited }
}

/// Why the app is looking at the library again.
enum LibraryChangeReason: Equatable, Sendable {
    /// Photos reported a change made outside the app, such as an edit or a new video.
    case libraryChanged
    /// The app came back to the front, so the library is worth re-listing even without a
    /// notification, because Photos does not report an access change while it is suspended.
    case enteredForeground
    /// Photos access itself changed since the last look: limited, revoked or restored.
    case accessChanged
}

/// What a fresh look at Photos means for the library the app already has in hand.
///
/// Photos changes underneath the app: a video is edited or deleted, access narrows, or an
/// app-created copy appears. Reconciling drops what is gone and reports what moved, but it
/// never re-points a job that is already running. The identity such a job is working on stays
/// exactly as it was, even if Photos has stopped listing that original.
struct LibraryReconciliation: Equatable, Sendable {
    /// The refreshed library, newest first, with a running job's entry kept in place.
    let result: LibraryScanResult
    /// The selection to keep. A selected video Photos no longer lists drops out, unless a job
    /// is already running on it.
    let selection: Set<String>
    /// Videos that left the library since the previous look.
    let removedIdentifiers: [String]
    /// Videos whose Photos metadata changed, so a preview or thumbnail drawn from the older
    /// version is out of date.
    let changedIdentifiers: [String]
    /// Running jobs whose original Photos no longer lists. Their identity is kept on purpose.
    let vanishedRunningIdentifiers: [String]

    /// True when the library the app was holding no longer describes what Photos has.
    var changedSomething: Bool {
        !removedIdentifiers.isEmpty
            || !changedIdentifiers.isEmpty
            || !vanishedRunningIdentifiers.isEmpty
    }
}

extension LibraryScanResult {
    /// The identifiers a run is still working on, whose identity must not change underneath it.
    static func runningIdentifiers(in items: [BatchItem]) -> Set<String> {
        Set(items.filter { !$0.state.isFinished }.map(\.id))
    }

    /// Lines a fresh listing up with the library the app already has in hand.
    ///
    /// `previous` is the library the app was looking at, when it had one. `running` comes from
    /// `runningIdentifiers(in:)` and names the jobs that must keep their identity.
    ///
    /// A video Photos no longer lists is dropped, along with any selection that pointed at it.
    /// Two things are deliberately kept. A running job keeps its entry even when its original
    /// has gone, because a run is never re-pointed at a different video. And a size the device
    /// already measured is kept for a video whose Photos metadata is otherwise unchanged,
    /// because a metadata-only refresh cannot measure anything and that measurement is still
    /// the best answer for this original.
    static func reconcile(previous: LibraryScanResult?,
                          fresh: LibraryScanResult,
                          selection: Set<String>,
                          running: Set<String>) -> LibraryReconciliation {
        let previousAssets = previous?.assets ?? []
        let previousByID = Dictionary(previousAssets.map { ($0.id, $0) },
                                     uniquingKeysWith: { first, _ in first })
        // A format this app read on the device is part of what it knows about a video, so a video
        // refused for one is a video whose Photos metadata this refresh still has to compare.
        let previouslyRefused = Dictionary((previous?.refusedAssets ?? []).map { ($0.id, $0) },
                                           uniquingKeysWith: { first, _ in first })
        let knownByID = previousByID.merging(previouslyRefused) { first, _ in first }
        let listedIDs = Set(fresh.assets.map(\.id))

        // A job already running keeps its identity even when Photos stops listing the original.
        let carried = previousAssets.filter { running.contains($0.id) && !listedIDs.contains($0.id) }

        // Change is judged on Photos metadata, never on the measured size: that size lives only
        // in this app, and a refresh never takes a new one.
        let changed = Set(fresh.assets.compactMap { asset -> String? in
            guard let old = knownByID[asset.id] else { return nil }
            return Self.differsInPhotosMetadata(asset, old) ? asset.id : nil
        })

        // A format this app read on the device is still this app's best answer for this original,
        // and a metadata-only refresh cannot read it again. The refusal is carried for a video
        // Photos still lists and whose Photos metadata has not changed underneath it. A video whose
        // metadata did change is treated as a video this app has not read: it goes back in the
        // list as an ordinary candidate rather than being refused on a reading that no longer
        // describes it.
        let stillRefused = fresh.assets.compactMap { asset -> LibraryAsset? in
            guard let refusal = previouslyRefused[asset.id], !changed.contains(asset.id) else {
                return nil
            }
            return refusal.withBytes(refusal.bytes ?? asset.bytes)
        }
        let refusedIDs = Set(stillRefused.map(\.id))

        let assets = fresh.assets.filter { !refusedIDs.contains($0.id) }.map { asset -> LibraryAsset in
            guard asset.bytes == nil, !changed.contains(asset.id),
                  let measured = previousByID[asset.id]?.bytes else { return asset }
            return asset.withBytes(measured)
        } + carried

        // A refused video Photos still lists has not left the library, so it is present even though
        // it is not one of the videos a run can pick.
        let present = Set(assets.map(\.id)).union(refusedIDs)
        // A video this app had refused and Photos no longer lists has still left the library, and
        // saying so is what keeps this app's idea of the library honest about it.
        let removed = Set(previousAssets.map(\.id)).union(previouslyRefused.keys)
            .union(selection).subtracting(present)
        // A refresh cannot measure on device, so a size source the app already earned stands.
        let keepsMeasuredSizes = previous?.sizeSource == .measuredOnDevice

        return LibraryReconciliation(
            result: LibraryScanResult(assets: assets,
                                      videoCount: fresh.videoCount,
                                      unsupportedCount: fresh.unsupportedCount + stillRefused.count,
                                      unknownSizeCount: assets.filter { $0.bytes == nil }.count,
                                      sizeSource: keepsMeasuredSizes ? .measuredOnDevice : fresh.sizeSource,
                                      measuredOnDeviceCount: keepsMeasuredSizes
                                          ? (previous?.measuredOnDeviceCount ?? 0)
                                          : fresh.measuredOnDeviceCount,
                                      refusedAssets: stillRefused),
            selection: selection.intersection(present),
            removedIdentifiers: removed.sorted(),
            changedIdentifiers: changed.sorted(),
            vanishedRunningIdentifiers: carried.map(\.id).sorted())
    }

    /// True when two entries describe different things in Photos.
    ///
    /// Only what Photos itself reports is compared. The measured size is not part of this: only
    /// this app knows it, and losing it is not a change in Photos. Neither is the refusal reason:
    /// HDR and ProRes are read from the media rather than reported by any listing, so the same
    /// video listed plainly and the same video listed with a reason this app read are the same
    /// video, and comparing the reason would make every refused video look changed to itself.
    private static func differsInPhotosMetadata(_ asset: LibraryAsset, _ other: LibraryAsset) -> Bool {
        asset.creationDate != other.creationDate
            || asset.duration != other.duration
            || asset.pixelWidth != other.pixelWidth
            || asset.pixelHeight != other.pixelHeight
    }
}
