import XCTest
@testable import VideoShrink

final class DeletionPolicyTests: XCTestCase {
    private let saving = Savings(originalBytes: 1_000, compressedBytes: 600)
    private let larger = Savings(originalBytes: 1_000, compressedBytes: 1_200)

    // MARK: - Fixtures

    /// A look at one asset, as Photos would describe it.
    private func snapshot(_ identifier: String,
                          duration: Double = 12,
                          pixelWidth: Int = 1920,
                          pixelHeight: Int = 1080,
                          created: Date? = Date(timeIntervalSinceReferenceDate: 1_000),
                          modified: Date? = Date(timeIntervalSinceReferenceDate: 2_000),
                          bytes: Int64? = 400) -> AssetSnapshot {
        AssetSnapshot(identifier: identifier, duration: duration, pixelWidth: pixelWidth,
                      pixelHeight: pixelHeight, creationDate: created,
                      modificationDate: modified, bytes: bytes)
    }

    /// The receipt a run records for one original: the copy Photos made, and the original it was
    /// made from, both as they looked when the copy was checked.
    private func receipt(version: Int = DeletionEvidence.currentVersion,
                         copyIdentifier: String = "copy-of-a",
                         originalIdentifier: String = "a") -> DeletionEvidence {
        DeletionEvidence(version: version,
                         copy: snapshot(copyIdentifier, bytes: 400),
                         source: snapshot(originalIdentifier, bytes: 1_000))
    }

    /// The gate, with the common case filled in. Pass `saving: nil` to ask for the standard
    /// smaller copy; the "no copy at all" case is exercised directly below.
    private func decide(_ mode: DeletionMode = .afterRun,
                        saving saved: Savings? = nil,
                        readBack: CopyReadBack? = .confirmed,
                        evidence: DeletionEvidence? = nil,
                        revalidation: CopyRevalidation? = .matches,
                        alreadyDeleted: Bool = false) -> DeletionDecision {
        DeletionPolicy.decision(mode: mode,
                                saving: saved ?? saving,
                                readBack: readBack,
                                evidence: evidence,
                                revalidation: revalidation,
                                alreadyDeleted: alreadyDeleted)
    }

    /// A stored queue with one finished item, and a receipt when one is given.
    private func savedRecord(_ evidence: DeletionEvidence?) -> BatchQueueRecord {
        BatchQueueRecord(
            settings: .init(resolution: "hd1080", frameRate: "original",
                            deletion: DeletionMode.afterRun.rawValue),
            items: [BatchQueueRecord.Item(identifier: "a", creationDate: nil, duration: 12,
                                          pixelWidth: 1920, pixelHeight: 1080, bytes: 1_000,
                                          state: .saved(originalBytes: 1_000, copyBytes: 600),
                                          readBack: .confirmed, deletion: nil,
                                          copyEvidence: evidence)])
    }

    // MARK: - The gate itself

    func testDeletingStaysOffUnlessItIsTurnedOn() {
        XCTAssertEqual(decide(.off, evidence: receipt(), revalidation: .matches),
                       .skip("Deleting originals is turned off."))
    }

    func testEveryDeletingModeNeedsAConfirmedReadBack() {
        for mode in [DeletionMode.afterEachCopy, .afterRun] {
            XCTAssertEqual(decide(mode, evidence: receipt(), revalidation: .matches), .delete)
            XCTAssertNotEqual(decide(mode, readBack: .unavailable, evidence: receipt(),
                                     revalidation: .matches),
                              .delete)
            XCTAssertNotEqual(decide(mode, readBack: nil, evidence: receipt(),
                                     revalidation: .matches),
                              .delete)
        }
    }

    func testEveryDeletingModeNeedsTheCopyAndTheOriginalCheckedAgain() {
        for mode in [DeletionMode.afterEachCopy, .afterRun] {
            // A receipt on its own is a record of an earlier check, so it is not enough.
            XCTAssertNotEqual(decide(mode, evidence: receipt(), revalidation: nil), .delete)
            // A fresh look with nothing recorded to compare it against is not enough either.
            XCTAssertNotEqual(decide(mode, evidence: nil, revalidation: .matches), .delete)
        }
    }

    func testACopyThatIsNotSmallerKeepsTheOriginal() {
        XCTAssertNotEqual(decide(.afterRun, saving: larger, evidence: receipt(),
                                 revalidation: .matches),
                          .delete)
        XCTAssertNotEqual(DeletionPolicy.decision(mode: .afterRun,
                                                 saving: nil,
                                                 readBack: .confirmed,
                                                 evidence: receipt(),
                                                 revalidation: .matches,
                                                 alreadyDeleted: false),
                          .delete)
    }

    func testAnOriginalThatWasAlreadyHandledIsNotDeletedTwice() {
        XCTAssertNotEqual(decide(.afterRun, evidence: receipt(), revalidation: .matches,
                                 alreadyDeleted: true),
                          .delete)
    }

    // MARK: - Acceptance: a copy that changed, went missing or cannot be looked up

    func testACopyEditedInPhotosAfterTheRunKeepsTheOriginal() {
        // Photos still has the copy, but it is no longer the one this run saved, so the original
        // stays whatever the interface showed earlier in the run.
        let decision = decide(evidence: receipt(), revalidation: .copyChanged)
        XCTAssertNotEqual(decision, .delete)
        XCTAssertEqual(decision, .skip("The copy changed after it was checked, so the original stays."))
    }

    func testACopyRemovedFromPhotosAfterTheRunKeepsTheOriginal() {
        XCTAssertEqual(decide(evidence: receipt(), revalidation: .copyMissing),
                       .skip("The copy is no longer in Photos, so the original stays."))
    }

    func testAWithdrawnOrNarrowedPhotosAccessKeepsTheOriginal() {
        // Revoked access, and limited access that no longer covers the assets, both arrive here as
        // a fresh look that did not match.
        XCTAssertEqual(decide(evidence: receipt(), revalidation: .accessDenied),
                       .skip("Photos access was withdrawn, so the original stays."))
        XCTAssertNotEqual(decide(evidence: receipt(), revalidation: .copyMissing), .delete)
        XCTAssertNotEqual(decide(evidence: receipt(), revalidation: .sourceMissing), .delete)
    }

    func testAPhotosLookUpThatFailsKeepsTheOriginal() {
        XCTAssertEqual(decide(evidence: receipt(), revalidation: .unavailable),
                       .skip("The copy couldn't be looked up again, so the original stays."))
    }

    func testAnOriginalChangedAfterCompressionIsKept() {
        XCTAssertEqual(decide(evidence: receipt(), revalidation: .sourceChanged),
                       .skip("The original changed after the copy was made, so it stays."))
    }

    func testAnOriginalPhotosCannotFindIsKept() {
        XCTAssertEqual(decide(evidence: receipt(), revalidation: .sourceMissing),
                       .skip("Photos can no longer find the original."))
    }

    // MARK: - Acceptance: receipts that must never authorise anything

    func testAQueueWrittenBeforeCopyIdentityExistedNeverAuthorisesDeletion() throws {
        // The exact file shape from before copy identity was recorded: the same fields, the same
        // encoder, no receipt key. This is the shape a user's stored queue is in right now.
        let legacy = LegacyQueue(
            settings: .init(resolution: "hd1080", frameRate: "original",
                            deletion: DeletionMode.afterRun.rawValue),
            items: [LegacyQueue.Item(identifier: "a", creationDate: nil, duration: 12,
                                     pixelWidth: 1920, pixelHeight: 1080, bytes: 1_000,
                                     state: .saved(originalBytes: 1_000, copyBytes: 600),
                                     readBack: .confirmed, deletion: nil)])
        let data = try JSONEncoder().encode(legacy)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("copyEvidence"),
                       "The fixture must not carry the field this change adds")

        // It still decodes, so an in-progress run on a user's phone is not thrown away.
        let record = try JSONDecoder().decode(BatchQueueRecord.self, from: data)
        XCTAssertEqual(record.version, BatchQueueRecord.currentVersion)
        XCTAssertEqual(record.items.count, 1)
        XCTAssertEqual(record.items[0].identifier, "a")
        XCTAssertEqual(record.items[0].readBack, .confirmed)
        XCTAssertNil(record.items[0].copyEvidence)
        XCTAssertNil(record.items[0].copyEvidence?.verifiedCopyIdentifier)

        // Even if something claimed the copy had just been checked, there is nothing recorded for
        // that check to be about, so the original stays.
        XCTAssertEqual(decide(evidence: record.items[0].copyEvidence, revalidation: .matches),
                       .skip("The copy this run made isn't recorded, so the original stays."))
    }

    func testAReceiptFromAnOlderAlgorithmKeepsTheOriginal() {
        let older = receipt(version: DeletionEvidence.currentVersion - 1)
        XCTAssertFalse(older.isCurrentAlgorithm)
        XCTAssertNil(older.verifiedCopyIdentifier)
        XCTAssertNotEqual(decide(evidence: older, revalidation: .matches), .delete)
    }

    func testAReceiptWithNoCopyIdentifierKeepsTheOriginal() {
        let blank = DeletionEvidence(copy: .empty, source: snapshot("a"))
        XCTAssertNil(blank.verifiedCopyIdentifier)
        XCTAssertNotEqual(decide(evidence: blank, revalidation: .matches), .delete)
    }

    func testACopyThatMayHaveBeenWrittenWhileTheAppDiedKeepsTheOriginal() {
        // The app stopped while Photos was accepting the copy. A receipt is not proof that the
        // rest of that save completed, so the window stays a question for the user.
        let item = BatchQueueRecord.Item(identifier: "a", creationDate: nil, duration: 12,
                                         pixelWidth: 1920, pixelHeight: 1080, bytes: 1_000,
                                         state: .saving, readBack: .confirmed, deletion: nil,
                                         copyEvidence: receipt())
        let record = BatchQueueRecord(
            settings: .init(resolution: "hd1080", frameRate: "original",
                            deletion: DeletionMode.afterRun.rawValue),
            items: [item])

        let restored = BatchQueueReconciliation.reconcile(record)
        XCTAssertEqual(restored.items[0].state, .needsCheck)

        var savings: Savings?
        if case .saved(let value) = BatchQueueReconciliation.live(restored.items[0].state) {
            savings = value
        }
        XCTAssertNotEqual(DeletionPolicy.decision(mode: .afterRun,
                                                 saving: savings,
                                                 readBack: restored.items[0].readBack,
                                                 evidence: restored.items[0].copyEvidence,
                                                 revalidation: .matches,
                                                 alreadyDeleted: false),
                          .delete)
        XCTAssertNil(restored.items[0].deletion)
    }

    // MARK: - The group is checked again when it is flushed

    func testTheGroupIsCheckedAgainWhenItIsFlushed() {
        // Both originals entered the group having been checked, and by flush time one copy has been
        // edited in Photos. Only the one that still holds up is handed to Photos; the other keeps
        // its original, with the reason recorded.
        let candidates = ["a": receipt(copyIdentifier: "copy-of-a", originalIdentifier: "a"),
                          "b": receipt(copyIdentifier: "copy-of-b", originalIdentifier: "b")]
        let split = DeletionPolicy.split(candidates,
                                        outcomes: ["a": .copyChanged, "b": .matches])
        XCTAssertEqual(split.approved, ["b"])
        XCTAssertEqual(split.rejected, ["a": .copyChanged])
    }

    func testACandidateWithoutAUsableReceiptIsNeverApproved() {
        let candidates = ["a": receipt(version: DeletionEvidence.currentVersion - 1),
                          "b": receipt(copyIdentifier: ""),
                          "c": receipt(copyIdentifier: "copy-of-c", originalIdentifier: "c")]
        // Every fresh look says the assets are fine; the receipts are what disqualify a and b.
        let split = DeletionPolicy.split(candidates,
                                        outcomes: ["a": .matches, "b": .matches, "c": .matches])
        XCTAssertEqual(split.approved, ["c"])
        XCTAssertEqual(split.rejected, ["a": .unavailable, "b": .unavailable])
    }

    func testACandidateWithNoLookTakenIsNotApproved() {
        let split = DeletionPolicy.split(["a": receipt()], outcomes: [:])
        XCTAssertTrue(split.approved.isEmpty)
        XCTAssertEqual(split.rejected, ["a": .unavailable])
    }

    // MARK: - Comparing one look with another

    func testTheComparisonDetectsEveryChangePhotosCanReport() {
        let expected = snapshot("copy-of-a")
        XCTAssertTrue(snapshot("copy-of-a").stillMatches(expected))
        XCTAssertFalse(snapshot("copy-of-b").stillMatches(expected))
        XCTAssertFalse(snapshot("copy-of-a", duration: 11.5).stillMatches(expected))
        XCTAssertFalse(snapshot("copy-of-a", pixelWidth: 1280).stillMatches(expected))
        XCTAssertFalse(snapshot("copy-of-a", pixelHeight: 720).stillMatches(expected))
        XCTAssertFalse(snapshot("copy-of-a", created: Date(timeIntervalSinceReferenceDate: 3_000))
            .stillMatches(expected))
        XCTAssertFalse(snapshot("copy-of-a", modified: Date(timeIntervalSinceReferenceDate: 9_000))
            .stillMatches(expected))
        XCTAssertFalse(snapshot("copy-of-a", bytes: 999).stillMatches(expected))
        // Nothing recorded is never a match, so an unreadable receipt cannot authorise a delete.
        XCTAssertFalse(snapshot("copy-of-a").stillMatches(.empty))
        XCTAssertFalse(AssetSnapshot.empty.stillMatches(expected))
    }

    func testAnAssetPhotosReportsNoSizeForCanStillMatch() {
        // An original that lives only in iCloud reports no size. That is not a change, so the dates
        // and the dimensions decide, and a copy whose size Photos does report still has to agree
        // with what was recorded.
        let expected = snapshot("a", bytes: nil)
        XCTAssertTrue(snapshot("a", bytes: nil).stillMatches(expected))
        XCTAssertTrue(snapshot("a", bytes: 1_000).stillMatches(expected))
        XCTAssertFalse(snapshot("a", duration: 9).stillMatches(expected))
    }

    // MARK: - The receipt on disk

    func testAReceiptSurvivesAQueueRoundTrip() throws {
        let record = savedRecord(receipt())
        let data = try JSONEncoder().encode(record)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("copyEvidence"))
        let decoded = try JSONDecoder().decode(BatchQueueRecord.self, from: data)
        XCTAssertEqual(decoded, record)
        XCTAssertEqual(decoded.items[0].copyEvidence?.verifiedCopyIdentifier, "copy-of-a")
    }

    func testAQueueWhoseReceiptIsNonsenseStillDecodes() throws {
        // A receipt the app cannot read must not cost the user the whole queue, and it must not be
        // read as evidence either.
        let data = try JSONEncoder().encode(savedRecord(receipt()))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var items = try XCTUnwrap(object["items"] as? [[String: Any]])
        items[0]["copyEvidence"] = "not a receipt"
        var rewritten = object
        rewritten["items"] = items
        let changed = try JSONSerialization.data(withJSONObject: rewritten)

        let decoded = try JSONDecoder().decode(BatchQueueRecord.self, from: changed)
        XCTAssertEqual(decoded.items.count, 1)
        XCTAssertEqual(decoded.items[0].state, .saved(originalBytes: 1_000, copyBytes: 600))
        XCTAssertNil(decoded.items[0].copyEvidence?.verifiedCopyIdentifier)
        XCTAssertEqual(decide(evidence: decoded.items[0].copyEvidence, revalidation: .matches),
                       .skip("The copy this run made isn't recorded, so the original stays."))
    }

    func testAReceiptWithAFieldFromANewerVersionStillDecodes() throws {
        // A field this version does not know about must not cost the user their queue, and must not
        // be mistaken for evidence either.
        let data = try JSONEncoder().encode(receipt())
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var extended = object
        extended["checkedByAFutureVersion"] = ["note": "ignore me"]
        let changed = try JSONSerialization.data(withJSONObject: extended)

        let decoded = try JSONDecoder().decode(DeletionEvidence.self, from: changed)
        XCTAssertEqual(decoded, receipt())
        XCTAssertEqual(decoded.verifiedCopyIdentifier, "copy-of-a")
    }

    func testAReceiptThatCannotBeReadIsNotEvidence() throws {
        // A damaged receipt decodes rather than throwing, because a throw would take the whole
        // queue with it. What comes back carries no version and no copy, so it authorises nothing.
        let damaged = Data(#"{"copy":{"identifier":"copy-of-a"}}"#.utf8)
        let decoded = try JSONDecoder().decode(DeletionEvidence.self, from: damaged)
        XCTAssertFalse(decoded.isCurrentAlgorithm)
        XCTAssertNil(decoded.verifiedCopyIdentifier)
        XCTAssertNotEqual(decide(evidence: decoded, revalidation: .matches), .delete)
    }

    // MARK: - Existing interface checks

    func testTheModeTitlesAndDetailsAreUsable() {
        for mode in DeletionMode.allCases {
            XCTAssertFalse(mode.title.isEmpty)
            XCTAssertFalse(mode.detail.isEmpty)
            XCTAssertFalse(mode.shortTitle.isEmpty)
        }
        XCTAssertFalse(DeletionMode.off.deletesOriginals)
        XCTAssertTrue(DeletionMode.afterEachCopy.deletesOriginals)
        XCTAssertTrue(DeletionMode.afterRun.deletesOriginals)
    }

    func testCoordinatesAreCheckedBeforeTheyAreUsed() {
        XCTAssertTrue(AssetIdentity.Coordinate(latitude: 51.5, longitude: -0.1).isValid)
        XCTAssertFalse(AssetIdentity.Coordinate(latitude: 91, longitude: 0).isValid)
        XCTAssertFalse(AssetIdentity.Coordinate(latitude: 0, longitude: 181).isValid)
        XCTAssertFalse(AssetIdentity.Coordinate(latitude: .nan, longitude: 0).isValid)
    }
}

/// The queue file shape from before copy identity was recorded. Encoding this with the project's
/// own encoder produces a file exactly like one an older build left on a user's phone, which is
/// what the migration test decodes.
private struct LegacyQueue: Encodable {
    struct Settings: Encodable {
        var resolution: String
        var frameRate: String
        var deletion: String?
    }

    struct Item: Encodable {
        var identifier: String
        var creationDate: Date?
        var duration: Double
        var pixelWidth: Int
        var pixelHeight: Int
        var bytes: Int64?
        var state: BatchQueueRecord.State
        var readBack: CopyReadBack?
        var deletion: DeletionOutcome?
    }

    var version = 1
    var settings: Settings
    var items: [Item]
}
