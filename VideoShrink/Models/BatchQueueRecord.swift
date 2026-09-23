import Foundation

/// The queue as it is written to disk, so a run can survive the app being closed.
///
/// It holds identifiers, the sizes Photos reported, the settings the run used and what
/// happened to each item, including the copy each item produced and what both assets looked
/// like when that copy was checked. No media, filename, location or thumbnail is stored.
struct BatchQueueRecord: Codable, Equatable, Sendable {
    /// Deliberately still 1. A stored queue is dropped when its version is not this one, and
    /// discarding a user's in-progress queue is worse than any bug this file fixes. Every field
    /// added since then is optional, so a queue written before it existed still decodes.
    static let currentVersion = 1

    var version: Int = BatchQueueRecord.currentVersion
    var settings: Settings
    var items: [Item]

    struct Settings: Codable, Equatable, Sendable {
        var resolution: String
        var frameRate: String
        var deletion: String?
    }

    struct Item: Codable, Equatable, Sendable {
        var identifier: String
        var creationDate: Date?
        var duration: Double
        var pixelWidth: Int
        var pixelHeight: Int
        var bytes: Int64?
        var state: State
        /// Recorded for saved items so a restored run can still say how many copies were read back.
        var readBack: CopyReadBack? = nil
        /// Recorded for every original the run touched, including ones it decided to keep.
        var deletion: DeletionOutcome? = nil
        /// Which asset Photos created for this original, and what both looked like when that copy
        /// was checked. Written only from a real read-back, and looked up again in full before any
        /// delete is submitted. A queue written before this existed carries none, which is exactly
        /// why its originals are never deleted.
        var copyEvidence: DeletionEvidence? = nil

        var asset: LibraryAsset {
            LibraryAsset(id: identifier, creationDate: creationDate, duration: duration,
                         pixelWidth: pixelWidth, pixelHeight: pixelHeight, bytes: bytes,
                         unsupportedReason: nil)
        }
    }

    /// The persisted states are deliberately coarser than the live ones: everything that was
    /// in flight is one state, because a queue is only written between steps.
    enum State: Codable, Equatable, Sendable {
        case pending
        case running
        case saving
        case saved(originalBytes: Int64, copyBytes: Int64)
        case skipped(reason: String)
        case failed(code: BatchFailureCode)
        case needsCheck
    }
}

/// A stable, small set of failure kinds. The exact error is not stored, so this file's format
/// never has to change when an error case is added or renamed.
enum BatchFailureCode: String, Codable, Equatable, Sendable {
    case permission, unavailable, unsupported, retrieval, storage, verification, export, save

    init(_ error: PipelineError) {
        switch error {
        case .permissionDenied: self = .permission
        case .assetUnavailable: self = .unavailable
        case .unsupported: self = .unsupported
        case .retrieval: self = .retrieval
        case .insufficientStorage, .temporaryFiles: self = .storage
        case .verification, .durationMismatch, .audioMismatch, .orientationMismatch,
             .codecMismatch, .resolutionMismatch, .frameRateMismatch:
            self = .verification
        case .save: self = .save
        case .export, .libraryScan, .cancelled: self = .export
        }
    }

    var error: PipelineError {
        switch self {
        case .permission: return .permissionDenied
        case .unavailable: return .assetUnavailable
        case .unsupported: return .unsupported
        case .retrieval: return .retrieval
        case .storage: return .insufficientStorage
        case .verification: return .verification
        case .export: return .export
        case .save: return .save
        }
    }
}

enum BatchQueueReconciliation {
    /// Decides what a stored queue means now.
    ///
    /// Anything that was in flight had not been saved, so it goes back to waiting. An item
    /// that was *mid-save* is different: Photos may have committed that copy after the app
    /// stopped, so it is flagged for a look rather than run again, which is how the queue
    /// avoids quietly making a second copy.
    static func reconcile(_ record: BatchQueueRecord) -> BatchQueueRecord {
        var reconciled = record
        reconciled.version = BatchQueueRecord.currentVersion
        for index in reconciled.items.indices {
            switch reconciled.items[index].state {
            case .pending, .running:
                reconciled.items[index].state = .pending
            case .saving:
                // A copy that may have been written while the app died stays a question for the
                // user. A receipt is a record of an earlier check, not proof that this save
                // completed, so this state never authorises a delete on its own.
                reconciled.items[index].state = .needsCheck
            case .saved, .skipped, .failed, .needsCheck:
                break
            }
            // A delete that was in flight when the app stopped may or may not have committed.
            if reconciled.items[index].deletion == DeletionOutcome.deleting {
                reconciled.items[index].deletion = .uncertain
            }
        }
        return reconciled
    }

    static func persisted(_ state: BatchItemState) -> BatchQueueRecord.State {
        switch state {
        case .pending: return .pending
        case .retrieving, .preparing, .transcoding, .verifying: return .running
        case .saving: return .saving
        case .saved(let saving):
            return .saved(originalBytes: saving.originalBytes, copyBytes: saving.compressedBytes)
        case .skipped(let reason): return .skipped(reason: reason)
        case .failed(let error): return .failed(code: BatchFailureCode(error))
        case .needsCheck: return .needsCheck
        }
    }

    static func live(_ state: BatchQueueRecord.State) -> BatchItemState {
        switch state {
        case .pending: return .pending
        case .running: return .pending
        case .saving, .needsCheck: return .needsCheck
        case .saved(let original, let copy):
            return .saved(Savings(originalBytes: original, compressedBytes: copy))
        case .skipped(let reason): return .skipped(reason)
        case .failed(let code): return .failed(code.error)
        }
    }
}
