import Foundation

/// What VideoShrink does with originals once a copy has been confirmed.
enum DeletionMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case off
    case afterEachCopy
    case afterRun

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: return "Keep every original"
        case .afterEachCopy: return "Delete as it goes"
        case .afterRun: return "Delete at the end"
        }
    }

    var shortTitle: String {
        switch self {
        case .off: return "Off"
        case .afterEachCopy: return "After each copy"
        case .afterRun: return "After the run"
        }
    }

    var detail: String {
        switch self {
        case .off: return "Nothing is deleted. You keep both copies."
        case .afterEachCopy: return "Each original goes as soon as its copy is saved and checked."
        case .afterRun: return "Originals wait until the run finishes. You confirm once at the end."
        }
    }

    var deletesOriginals: Bool { self != .off }
}

enum DeletionDecision: Equatable, Sendable {
    case delete
    case skip(String)
}

/// What a fresh look at a copy and its original found, immediately before a delete is submitted.
///
/// A stored receipt is never enough on its own: Photos is asked again for both assets and the
/// answer is one of these.
enum CopyRevalidation: Equatable, Sendable {
    /// Both assets are still in Photos and still look like what the run recorded.
    case matches
    /// Read or write access to Photos was withdrawn between the run and the delete.
    case accessDenied
    /// The copy is no longer in Photos.
    case copyMissing
    /// The copy is there but no longer the one the run saved.
    case copyChanged
    /// The original is no longer in Photos.
    case sourceMissing
    /// The original changed after the copy was made from it.
    case sourceChanged
    /// Photos could not answer at all.
    case unavailable
}

/// What Photos reported about one asset at one moment.
///
/// Plain values, so the comparison against a fresh look is testable without Photos. Only
/// documented `PHAsset` properties are recorded, and nothing here identifies the media itself.
struct AssetSnapshot: Codable, Equatable, Sendable {
    var identifier: String
    var duration: Double
    var pixelWidth: Int
    var pixelHeight: Int
    var creationDate: Date?
    var modificationDate: Date?
    /// Photos reports a size only for a file that is on this iPhone, so this is often nil.
    var bytes: Int64? = nil

    /// Nothing recorded. Used when a receipt cannot be read, so it can never authorise anything.
    static let empty = AssetSnapshot(identifier: "", duration: 0, pixelWidth: 0, pixelHeight: 0,
                                     creationDate: nil, modificationDate: nil)

    /// Whether a fresh look still describes the asset this snapshot was taken for.
    ///
    /// A missing date or a missing size on the *fresh* side is never treated as a match with a
    /// recorded value: only identical values pass, so an asset Photos can no longer describe
    /// keeps its original.
    func stillMatches(_ expected: AssetSnapshot) -> Bool {
        guard !identifier.isEmpty, identifier == expected.identifier else { return false }
        guard pixelWidth == expected.pixelWidth, pixelHeight == expected.pixelHeight else { return false }
        guard abs(duration - expected.duration) <= DeletionEvidence.durationTolerance else { return false }
        guard creationDate == expected.creationDate,
              modificationDate == expected.modificationDate else { return false }
        // A size is only compared when both looks produced one. An asset that lives only in
        // iCloud reports no size, and that alone is not evidence that it changed.
        if let expectedBytes = expected.bytes, let bytes, bytes != expectedBytes { return false }
        return true
    }
}

/// What the run recorded when it checked a copy: which asset Photos created and what both
/// assets looked like at that moment.
///
/// This is a receipt, not proof. It is stored with the queue and is only ever read to compare
/// against a fresh look at both assets immediately before a delete is submitted, so a copy that
/// was edited or removed after the run cannot authorise removing the original. A queue written
/// before this existed carries no receipt at all, and then the original simply stays.
struct DeletionEvidence: Codable, Equatable, Sendable {
    /// Bumped whenever these checks change meaning. A receipt an older version wrote cannot
    /// authorise a delete, because it was not collected the way this version expects.
    static let currentVersion = 1
    /// Two durations this close count as the same duration; PhotoKit rounds what it reports.
    static let durationTolerance = 0.05

    enum CodingKeys: String, CodingKey { case version, copy, source }

    var version: Int
    /// The copy Photos created when this original was compressed.
    var copy: AssetSnapshot
    /// The original as it looked when that copy was checked.
    var source: AssetSnapshot

    init(version: Int = DeletionEvidence.currentVersion,
         copy: AssetSnapshot,
         source: AssetSnapshot) {
        self.version = version
        self.copy = copy
        self.source = source
    }

    /// The recorded copy, or nil when there is nothing here that may authorise a delete.
    var verifiedCopyIdentifier: String? {
        guard isCurrentAlgorithm, !copy.identifier.isEmpty else { return nil }
        return copy.identifier
    }

    var isCurrentAlgorithm: Bool { version == DeletionEvidence.currentVersion }
}

extension DeletionEvidence {
    /// Decoded leniently on purpose. A queue that cannot be decoded is thrown away, which would
    /// cost a user their run; a receipt that cannot be read is simply not evidence, and an
    /// unreadable receipt is recorded with no version so it can never authorise a delete.
    init(from decoder: Decoder) throws {
        guard let container = try? decoder.container(keyedBy: CodingKeys.self) else {
            version = 0
            copy = .empty
            source = .empty
            return
        }
        version = (try? container.decode(Int.self, forKey: .version)) ?? 0
        copy = (try? container.decode(AssetSnapshot.self, forKey: .copy)) ?? .empty
        source = (try? container.decode(AssetSnapshot.self, forKey: .source)) ?? .empty
    }
}

/// The single gate every deletion goes through.
///
/// It is deliberately hard to satisfy. A delete needs all of: a smaller saved copy, a read-back
/// Photos confirmed, a receipt naming the copy this run created, and a fresh look taken
/// immediately before the delete that says both assets are unchanged. Anything less keeps the
/// original and says why.
enum DeletionPolicy {
    static func decision(mode: DeletionMode,
                         saving: Savings?,
                         readBack: CopyReadBack?,
                         evidence: DeletionEvidence? = nil,
                         revalidation: CopyRevalidation? = nil,
                         alreadyDeleted: Bool) -> DeletionDecision {
        guard mode.deletesOriginals else { return .skip("Deleting originals is turned off.") }
        guard !alreadyDeleted else { return .skip("This original has already been dealt with.") }
        guard let saving, saving.isSmaller else {
            return .skip("No smaller copy was saved, so the original stays.")
        }
        switch readBack {
        case .confirmed:
            // Necessary, but no longer sufficient: the copy and the original are looked at again
            // below, and the receipt has to be there for that look to mean anything.
            break
        case .unavailable:
            return .skip("The copy couldn’t be read back from Photos, so the original stays.")
        case nil:
            return .skip("The copy hasn’t been checked yet, so the original stays.")
        }
        // A queue restored from before copy identity was recorded, or a run that stopped before
        // the copy was recorded, has no receipt. It never authorises a delete.
        guard let evidence, evidence.verifiedCopyIdentifier != nil else {
            return .skip("The copy this run made isn't recorded, so the original stays.")
        }
        guard let revalidation else {
            return .skip("The copy and the original haven't been checked again, so the original stays.")
        }
        switch revalidation {
        case .matches:
            return .delete
        case .copyMissing:
            return .skip("The copy is no longer in Photos, so the original stays.")
        case .copyChanged:
            return .skip("The copy changed after it was checked, so the original stays.")
        case .sourceMissing:
            return .skip("Photos can no longer find the original.")
        case .sourceChanged:
            return .skip("The original changed after the copy was made, so it stays.")
        case .accessDenied:
            return .skip("Photos access was withdrawn, so the original stays.")
        case .unavailable:
            return .skip("The copy couldn't be looked up again, so the original stays.")
        }
    }

    /// Splits a group of deletion candidates using looks taken right now, at the moment the group
    /// is about to be handed to Photos.
    ///
    /// This is deliberately separate from the decision the interface shows earlier: a candidate
    /// that was checked when it joined the group is checked again here, so a copy edited or
    /// removed while the group waited cannot ride along on an earlier answer. Identifiers come
    /// back sorted, so one confirmation always covers the same originals in the same order, and a
    /// candidate whose receipt or look is missing is kept rather than approved.
    static func split(_ candidates: [String: DeletionEvidence],
                      outcomes: [String: CopyRevalidation])
        -> (approved: [String], rejected: [String: CopyRevalidation]) {
        var approved: [String] = []
        var rejected: [String: CopyRevalidation] = [:]
        for identifier in candidates.keys.sorted() {
            guard let receipt = candidates[identifier] else { continue }
            guard receipt.verifiedCopyIdentifier != nil, let outcome = outcomes[identifier] else {
                rejected[identifier] = .unavailable
                continue
            }
            if outcome == .matches {
                approved.append(identifier)
            } else {
                rejected[identifier] = outcome
            }
        }
        return (approved, rejected)
    }
}

/// What happened to one original. Persisted with the queue so a stop mid-delete is visible.
enum DeletionOutcome: Equatable, Sendable, Codable {
    /// Written *before* Photos is asked, so an interrupted delete is recognisable afterwards.
    case deleting
    case deleted
    case skipped(String)
    case failed(BatchFailureCode)
    case uncertain
}

struct DeletionReport: Equatable, Sendable {
    var deleted = 0
    var skipped = 0
    var failed = 0
    var uncertain = 0

    var handled: Int { deleted + skipped + failed + uncertain }
}
