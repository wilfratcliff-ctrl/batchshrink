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

/// The single gate every deletion goes through.
///
/// It is deliberately hard to satisfy: a saved copy that is smaller, verified, and handed back by
/// Photos. Anything less keeps the original and says why.
enum DeletionPolicy {
    static func decision(mode: DeletionMode,
                         saving: Savings?,
                         readBack: CopyReadBack?,
                         alreadyDeleted: Bool) -> DeletionDecision {
        guard mode.deletesOriginals else { return .skip("Deleting originals is turned off.") }
        guard !alreadyDeleted else { return .skip("This original has already been dealt with.") }
        guard let saving, saving.isSmaller else {
            return .skip("No smaller copy was saved, so the original stays.")
        }
        switch readBack {
        case .confirmed:
            return .delete
        case .unavailable:
            return .skip("The copy couldn’t be read back from Photos, so the original stays.")
        case nil:
            return .skip("The copy hasn’t been checked yet, so the original stays.")
        }
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
