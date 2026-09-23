import XCTest
@testable import VideoShrink

@MainActor final class BatchQueueTests: XCTestCase {

    func testRunningItemsWaitAgainAndMidSaveItemsAreFlagged() {
        let record = BatchQueueRecord(
            settings: .init(resolution: "hd1080", frameRate: "original"),
            items: [item("a", .pending), item("b", .running), item("c", .saving),
                    item("d", .saved(originalBytes: 1_000, copyBytes: 600)),
                    item("e", .skipped(reason: "Not smaller")),
                    item("f", .failed(code: .storage)), item("g", .needsCheck)])
        let reconciled = BatchQueueReconciliation.reconcile(record)
        XCTAssertEqual(reconciled.items.map(\.state),
                       [.pending, .pending, .needsCheck,
                        .saved(originalBytes: 1_000, copyBytes: 600),
                        .skipped(reason: "Not smaller"), .failed(code: .storage), .needsCheck])
    }

    func testLiveStatesRoundTripThroughTheStoredForm() {
        let cases: [(BatchItemState, BatchQueueRecord.State)] = [
            (.pending, .pending),
            (.retrieving(0.4), .running),
            (.preparing, .running),
            (.transcoding(0.9), .running),
            (.verifying, .running),
            (.saving, .saving),
            (.saved(Savings(originalBytes: 1_000, compressedBytes: 600)),
             .saved(originalBytes: 1_000, copyBytes: 600)),
            (.skipped("Not smaller"), .skipped(reason: "Not smaller")),
            (.failed(.insufficientStorage), .failed(code: .storage)),
            (.failed(.verification), .failed(code: .verification)),
            (.needsCheck, .needsCheck)
        ]
        for (live, stored) in cases {
            XCTAssertEqual(BatchQueueReconciliation.persisted(live), stored)
            XCTAssertEqual(BatchQueueReconciliation.live(stored), BatchQueueReconciliation.live(stored))
        }
        // The two coarse states both come back as something the run will not touch on its own.
        XCTAssertEqual(BatchQueueReconciliation.live(.running), .pending)
        XCTAssertEqual(BatchQueueReconciliation.live(.saving), .needsCheck)
        XCTAssertEqual(BatchQueueReconciliation.live(.needsCheck), .needsCheck)
    }

    func testFailureCodesStayUsefulAfterARestart() {
        XCTAssertEqual(BatchFailureCode(.permissionDenied), .permission)
        XCTAssertEqual(BatchFailureCode(.assetUnavailable), .unavailable)
        XCTAssertEqual(BatchFailureCode(.unsupported), .unsupported)
        XCTAssertEqual(BatchFailureCode(.retrieval), .retrieval)
        XCTAssertEqual(BatchFailureCode(.temporaryFiles), .storage)
        XCTAssertEqual(BatchFailureCode(.orientationMismatch), .verification)
        XCTAssertEqual(BatchFailureCode(.save), .save)
        XCTAssertEqual(BatchFailureCode(.export), .export)
        // Every restored code maps back to a real, readable error.
        for code in [BatchFailureCode.permission, .unavailable, .unsupported, .retrieval,
                     .storage, .verification, .export, .save] {
            XCTAssertFalse(code.error.localizedDescription.isEmpty)
        }
    }

    func testTheFileStoreRoundTripsAndClearsByWritingAnEmptyQueue() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("queue-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileBatchQueueStore(directory: directory)

        XCTAssertNil(store.load())
        let record = BatchQueueRecord(settings: .init(resolution: "hd720", frameRate: "fps24"),
                                      items: [item("a", .pending), item("b", .saving)])
        try store.save(record)
        XCTAssertEqual(store.load(), record)

        store.clear()
        XCTAssertNil(store.load())
    }

    func testAQueueFromANewerVersionIsIgnored() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("queue-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileBatchQueueStore(directory: directory)
        var record = BatchQueueRecord(settings: .init(resolution: "hd1080", frameRate: "original"),
                                      items: [item("a", .pending)])
        record.version = BatchQueueRecord.currentVersion + 1
        try store.save(record)
        XCTAssertNil(store.load())
    }

    func testAnEmptyStoredQueueReadsAsNoQueue() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("queue-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileBatchQueueStore(directory: directory)
        try store.save(BatchQueueRecord(settings: .init(resolution: "hd1080", frameRate: "original"),
                                        items: []))
        XCTAssertNil(store.load())
    }

    private func item(_ id: String, _ state: BatchQueueRecord.State) -> BatchQueueRecord.Item {
        BatchQueueRecord.Item(identifier: id, creationDate: nil, duration: 120,
                              pixelWidth: 3840, pixelHeight: 2160, bytes: 3_000_000_000, state: state)
    }
}
