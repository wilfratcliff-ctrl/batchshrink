import Foundation

/// The queue as it is written to disk, so a run can survive the app being closed.
///
/// It holds identifiers, the sizes Photos reported, the settings the run used and what
/// happened to each item, including the copy each item produced and what both assets looked
/// like when that copy was checked. It also holds the videos the run began without, so a run
/// picked up again can still account for them. No media, filename, location or thumbnail is
/// stored.
struct BatchQueueRecord: Codable, Equatable, Sendable {
    /// Deliberately still 1. A stored queue is dropped when its version is not this one, and
    /// discarding a user's in-progress queue is worse than any bug this file fixes. Every field
    /// added since then is optional, so a queue written before it existed still decodes.
    static let currentVersion = 1

    var version: Int = BatchQueueRecord.currentVersion
    var settings: Settings
    var items: [Item]
    /// The videos the chosen-video read took out of this run before its first export.
    ///
    /// They are deliberately not `items`: an entry there is a video the run has a state for, and
    /// nothing here was ever run. Keeping them beside the run is what lets a restored queue answer
    /// the question the finished screen exists to answer - what happened to the videos the user
    /// picked - long after the process that refused them is gone. A queue written before this
    /// existed carries no list, and a restored run simply names none, exactly as it did before.
    var refusals: [Refusal]? = nil

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
        /// The sizes the run measured for the copy it was handing to Photos. Written with the
        /// `.saving` state, because that is the moment the run knows them and Photos may already
        /// hold the copy. It is what lets a later launch that finds that copy say what was saved
        /// instead of leaving the user a question, and it is never read for an item that settled.
        /// A queue written before this existed carries none, and its question simply stays open.
        var attemptedSave: AttemptedSave? = nil

        var asset: LibraryAsset {
            LibraryAsset(id: identifier, creationDate: creationDate, duration: duration,
                         pixelWidth: pixelWidth, pixelHeight: pixelHeight, bytes: bytes,
                         unsupportedReason: nil)
        }
    }

    /// One video the chosen-video read refused, and the one thing about its reason a file may hold.
    ///
    /// The row a screen draws from one of these carries a date, a duration and a size beside the
    /// reason, so the identity the run's own items keep travels here too. Without it a restored run
    /// would draw a different row from the one the run itself drew, and that row could not be
    /// recognised as the video the user picked.
    ///
    /// The sentence itself is deliberately absent. It belongs to `AssetRules`, which owns both of
    /// the refusals this read can produce, so the record keeps the small stable distinction between
    /// them and the words are asked for again on restore. That is the same trade `BatchFailureCode`
    /// makes: a stored code changes when the set of kinds changes, and a stored sentence would
    /// freeze one build's wording into every later one.
    struct Refusal: Codable, Equatable, Sendable {
        var identifier: String
        var creationDate: Date?
        var duration: Double
        var pixelWidth: Int
        var pixelHeight: Int
        var bytes: Int64?
        var kind: Kind

        var asset: LibraryAsset {
            LibraryAsset(id: identifier, creationDate: creationDate, duration: duration,
                         pixelWidth: pixelWidth, pixelHeight: pixelHeight, bytes: bytes,
                         unsupportedReason: kind.reason)
        }

        /// The refusal to write down for a video the chosen-video read just refused, or nil when
        /// its reason is not one of the two this file can name again.
        ///
        /// A reason this file cannot name is not written down at all. That leaves a restored run
        /// saying exactly what it said before this field existed, rather than putting a sentence of
        /// this file's own into the record.
        init?(asset: LibraryAsset) {
            guard let reason = asset.unsupportedReason, let kind = Kind(reason: reason) else {
                return nil
            }
            self.identifier = asset.id
            self.creationDate = asset.creationDate
            self.duration = asset.duration
            self.pixelWidth = asset.pixelWidth
            self.pixelHeight = asset.pixelHeight
            self.bytes = asset.bytes
            self.kind = kind
        }

        /// The refusals the media itself can earn, kept as a small stable set rather than a
        /// sentence.
        ///
        /// Both are `AssetRules`' own question about an original - is it HDR, is it ProRes - and a
        /// video that is both reads as ProRes, because that is the reason `AssetRules` gives it.
        /// Asking that owner in the same order here keeps the two ends of the round trip saying the
        /// same thing.
        enum Kind: String, Codable, Equatable, Sendable {
            case hdr
            case proRes

            /// The sentence `AssetRules` gives this refusal, asked for rather than written down, so
            /// a wording change moves the writing and the reading together.
            var reason: String {
                switch self {
                case .hdr:
                    return AssetRules.unsupportedFormatReason(isHDR: true, isProRes: false)
                        ?? Kind.unnamedReason
                case .proRes:
                    return AssetRules.unsupportedFormatReason(isHDR: false, isProRes: true)
                        ?? Kind.unnamedReason
                }
            }

            /// The kind a sentence is, or nil when it is not one this file can name again.
            init?(reason: String) {
                if let proRes = AssetRules.unsupportedFormatReason(isHDR: false, isProRes: true),
                   proRes == reason {
                    self = .proRes
                } else if let hdr = AssetRules.unsupportedFormatReason(isHDR: true, isProRes: false),
                          hdr == reason {
                    self = .hdr
                } else {
                    return nil
                }
            }

            /// The sentence the refused-video rows already fall back to for a refusal carrying no
            /// reason of its own, so this file never holds a wording that is its own.
            static let unnamedReason = "This video is not supported yet."
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

/// The sizes a run measured for the copy it was about to hand to Photos.
///
/// `Savings` is deliberately not storable, so this is the smallest shape that carries the two
/// numbers a restored run needs to describe a copy it later finds in Photos.
struct AttemptedSave: Codable, Equatable, Sendable {
    var originalBytes: Int64
    var copyBytes: Int64

    init(_ savings: Savings) {
        originalBytes = savings.originalBytes
        copyBytes = savings.compressedBytes
    }

    var savings: Savings { Savings(originalBytes: originalBytes, compressedBytes: copyBytes) }
}

/// What a restored run worked out about a video that was mid-save when the app stopped.
///
/// This is the whole of the reconciliation. "Photos may have taken that copy" becomes an answer
/// wherever the stored record and PhotoKit can give one, and stays a question wherever they
/// cannot. Only a receipt naming the copy this app created can answer anything, and even then the
/// answer is read from how Photos looks now: a receipt describes an earlier moment, which is
/// exactly why it is evidence rather than proof.
enum MidSaveFinding: Equatable, Sendable {
    /// Photos still has the copy this run created. Nothing may save this video again.
    case copyInPhotos
    /// Photos has no copy this run created and the app could see the whole library, so this video
    /// may wait again: running it cannot make a second copy.
    case noCopyInPhotos
    /// Neither the record nor Photos can answer the question, so it stays the user's. The text is
    /// what to look for in Photos, in the words the interface shows.
    case unresolved(question: String)

    /// The question left open when neither the record nor Photos can narrow it, or when the app
    /// can see only part of the library for reasons of its own.
    static let unknownQuestion = "BatchShrink stopped while Photos was taking a copy of this video. Look in Photos: if there are two copies, that copy was made; if there is one, it wasn't."
    /// The same question when access covers part of the library, which makes a copy the app cannot
    /// see no evidence at all that it was never written.
    static let limitedAccessQuestion = "Photos access covers only some of your library, so BatchShrink cannot tell whether this video was copied. Look in Photos before running it again."

    /// Whether this finding rules out running the video again.
    var forbidsAnotherSave: Bool {
        switch self {
        case .copyInPhotos: return true
        case .noCopyInPhotos, .unresolved: return false
        }
    }

    /// Whether this finding is still the user's to answer, rather than an answer the app reached.
    ///
    /// Only the unresolved case is a question. `copyInPhotos` is a conclusion - the app found the
    /// copy, recorded it as its own output and settled the video - and `noCopyInPhotos` is the
    /// other, where the app looked at the whole library and found nothing, so the video may wait
    /// again. A question is a different thing from either, and it is what keeps a video out of a
    /// bulk selection until the user answers it.
    var isOpenQuestion: Bool {
        if case .unresolved = self { return true }
        return false
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
        // An original the app deliberately refuses - HDR or ProRes - is stored as the ordinary
        // "not supported" code rather than a code of its own. A stored code is a stable, coarse
        // kind and the queue file deliberately holds no sentence, so the exact words live only
        // in the run that raised them; what a restored queue can honestly say is that this video
        // is one the app does not support, which is what `.unsupported` says.
        case .unsupportedOriginal: self = .unsupported
        // An export Apple would not build is stored the same way, and for the same reason: what a
        // restored queue can honestly say about that video is that this app cannot process it. The
        // finding itself - no session at that quality, or a session that cannot write the
        // container - is not storable, so it lives only in the run that raised it.
        case .exportUnavailable: self = .unsupported
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

    /// Turns the copy identity a record kept, plus a fresh look at Photos, into an answer.
    ///
    /// The three answers are deliberately not symmetrical. Anything that shows the recorded copy
    /// is in the library means a copy exists, and a video that may already have been copied must
    /// never be copied again. "No copy" is only given with the whole library in view: under
    /// limited access an asset can be invisible rather than gone, and reading that as absence is
    /// the one answer that could lead to a second copy. Everything else stays a question.
    static func midSaveFinding(receipt: DeletionEvidence?,
                               lookup: CopyRevalidation?,
                               wholeLibraryVisible: Bool) -> MidSaveFinding {
        // A receipt from an older algorithm, or one with no copy in it, names nothing that can be
        // looked up. What Photos says about it cannot be trusted either: the service reports an
        // unusable receipt exactly as it reports a missing copy.
        guard let receipt, receipt.verifiedCopyIdentifier != nil else {
            return .unresolved(question: MidSaveFinding.unknownQuestion)
        }
        guard let lookup else {
            return .unresolved(question: MidSaveFinding.unknownQuestion)
        }
        switch lookup {
        // The copy is there. `.copyChanged` still means an asset with that identifier exists, and
        // the two source cases can only be reached once the copy itself has matched.
        case .matches, .copyChanged, .sourceMissing, .sourceChanged:
            return .copyInPhotos
        case .copyMissing:
            guard wholeLibraryVisible else {
                return .unresolved(question: MidSaveFinding.limitedAccessQuestion)
            }
            return .noCopyInPhotos
        case .accessDenied, .unavailable:
            return .unresolved(question: MidSaveFinding.unknownQuestion)
        }
    }
}
