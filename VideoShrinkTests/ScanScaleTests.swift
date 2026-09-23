import XCTest
import AVFoundation
import Photos
@testable import VideoShrink

/// The library scan against a library far larger than a test can build, and against one that
/// changes while the scan is reading it.
///
/// Nothing here touches PhotoKit. The part of the pass that decides what to do when the library
/// moves under it is driven through the seam that exists for exactly that reason, and the rest
/// through the view model's own protocols, because a simulator has no photo library to change and
/// a Photos fetch result cannot be built by hand. What these tests cannot prove - and what still
/// needs a device - is what PhotoKit itself does mid-pass.
@MainActor final class ScanScaleTests: XCTestCase {

    // MARK: - The listing walk, against a library that moves

    func testTheWalkEndsAtTheEndOfAListingThatShrankUnderIt() async throws {
        // Photos can shorten a fetch result while it is being read, and asking such a listing for
        // an index it no longer has raises rather than returning nothing. Reading the count first
        // is what lets a shortened listing end.
        let service = PhotoLibraryScanService()
        var liveCount = 8
        var read: [Int] = []

        let outcome = try await service.walkListing(
            liveCount: { liveCount },
            assetAt: { (index: Int) -> Int in
                read.append(index)
                // Photos loses the last three videos while the pass is running.
                if index == 4 { liveCount = 5 }
                return index
            },
            describe: { (index: Int) -> LibraryAsset in scanScaleAsset("video-\(index)") },
            scanOwned: false,
            progress: { _ in })

        XCTAssertEqual(read, [0, 1, 2, 3, 4])
        XCTAssertEqual(outcome.assets.map(\.id),
                       ["video-0", "video-1", "video-2", "video-3", "video-4"])
        XCTAssertEqual(outcome.videoCount, 5)
    }

    func testTheWalkPicksUpAVideoAddedWhileItIsRunning() async throws {
        // The other direction: a video recorded or synced down mid-pass used to be missed because
        // the pass had already decided how many videos it was going to read.
        let service = PhotoLibraryScanService()
        var liveCount = 3

        let outcome = try await service.walkListing(
            liveCount: { liveCount },
            assetAt: { (index: Int) -> Int in
                if index == 1 { liveCount = 5 }
                return index
            },
            describe: { (index: Int) -> LibraryAsset in scanScaleAsset("video-\(index)") },
            scanOwned: false,
            progress: { _ in })

        XCTAssertEqual(outcome.assets.map(\.id),
                       ["video-0", "video-1", "video-2", "video-3", "video-4"])
        XCTAssertEqual(outcome.videoCount, 5)
    }

    func testTheWalkListsEachVideoOnceWhenAnAdditionShiftsTheListing() async throws {
        // A video arriving at the top of a newest-first listing pushes every video below it along
        // by one, so the next step arrives at a video the pass has already described. Naming it
        // twice would put it on the summary twice and offer it twice in a run.
        let service = PhotoLibraryScanService()
        var liveCount = 3
        var names = ["a", "b", "c"]
        var arrived = false

        let outcome = try await service.walkListing(
            liveCount: { liveCount },
            assetAt: { (index: Int) -> String in
                let name = names[index]
                if index == 0 && !arrived {
                    arrived = true
                    names = ["new", "a", "b", "c"]
                    liveCount = 4
                }
                return name
            },
            describe: { (id: String) -> LibraryAsset in scanScaleAsset(id) },
            scanOwned: false,
            progress: { _ in })

        XCTAssertEqual(outcome.assets.map(\.id), ["a", "b", "c"])
        // "new" arrived after the pass began, so the pass cannot report it: that is what the
        // reconciliation after a scan is for.
        XCTAssertEqual(outcome.videoCount, 3)
    }

    func testTheWalkNeverReportsMoreCheckedThanItsTotal() async throws {
        // The count under the progress bar is the user's only evidence that a long scan is moving,
        // so it must never read "45 of 30 checked" when the library loses videos part-way.
        let service = PhotoLibraryScanService()
        var updates: [LibraryScanProgress] = []
        var liveCount = 70

        let outcome = try await service.walkListing(
            liveCount: { liveCount },
            assetAt: { (index: Int) -> Int in
                if index == 40 { liveCount = 45 }
                return index
            },
            describe: { (index: Int) -> LibraryAsset in scanScaleAsset("video-\(index)") },
            scanOwned: false,
            progress: { updates.append($0) })

        XCTAssertEqual(updates.first, LibraryScanProgress(phase: .listing, scanned: 0, total: 70))
        XCTAssertEqual(updates.last, LibraryScanProgress(phase: .listing, scanned: 45, total: 45))
        XCTAssertTrue(updates.allSatisfy { $0.scanned <= $0.total })
        XCTAssertTrue(updates.allSatisfy { $0.phase == .listing })
        XCTAssertEqual(outcome.videoCount, 45)
    }

    func testUnsupportedVideosAreCountedAndTheTotalsStillAddUp() async throws {
        // `videoCount` is what the pass read, so the summary's own numbers add up whatever the
        // library did while it was being read.
        let service = PhotoLibraryScanService()

        let outcome = try await service.walkListing(
            liveCount: { 4 },
            assetAt: { (index: Int) -> Int in index },
            describe: { (index: Int) -> LibraryAsset in
                index.isMultiple(of: 2)
                    ? scanScaleAsset("video-\(index)")
                    : scanScaleAsset("video-\(index)", unsupported: "Cinematic videos are not supported yet.")
            },
            scanOwned: false,
            progress: { _ in })

        XCTAssertEqual(outcome.assets.map(\.id), ["video-0", "video-2"])
        XCTAssertEqual(outcome.skipped, 2)
        XCTAssertEqual(outcome.videoCount, 4)
    }

    func testTheWalkStopsWithinOneVideoOfTheStopButton() async {
        // Cancellability is a constraint, not a nicety: the pass reads one video at a time and
        // checks the stop switch before each one, so stopping never waits for the rest of a large
        // library to be read.
        let service = PhotoLibraryScanService()
        var read = 0

        do {
            _ = try await service.walkListing(
                liveCount: { 10_000 },
                assetAt: { (index: Int) -> Int in
                    read += 1
                    return index
                },
                describe: { (index: Int) -> LibraryAsset in scanScaleAsset("video-\(index)") },
                scanOwned: true,
                progress: { update in
                    // The user taps Stop on the scanning screen.
                    if update.scanned == 32 { service.cancel() }
                })
            XCTFail("A stopped scan must not report a library")
        } catch {
            XCTAssertEqual(PipelineError.normalize(error, fallback: .libraryScan), .cancelled)
        }

        // The next video is never read: the stop is seen before it, not after the library.
        XCTAssertEqual(read, 32)
    }

    // MARK: - A library that changes while the scan is reading it

    func testAChangeReportedWhileScanningIsReconciledOnceTheScanLands() async {
        let monitor = LibraryChangeMonitor(authorizationStatus: { .authorized })
        let fixture = ScanScaleFixture(assets: [scanScaleAsset("a"), scanScaleAsset("b")], monitor: monitor)
        fixture.scanner.hold = true
        fixture.batch.scan()
        await scanScaleEventually { fixture.scanner.gate != nil }

        // Photos changes while the pass is reading. The pass began before the change, so its
        // listing cannot be trusted to describe one moment of the library - and the report must
        // not be dropped just because a scan was in flight.
        fixture.scanner.refreshResult = scanScaleListing([scanScaleAsset("a")])
        monitor.enteredForeground()
        XCTAssertEqual(fixture.scanner.reconcileCount, 0)

        fixture.scanner.hold = false
        fixture.scanner.release()

        await scanScaleEventually { fixture.scanner.reconcileCount == 1 }
        await scanScaleEventually { fixture.batch.scanResult?.assets.map(\.id) == ["a"] }
        XCTAssertEqual(fixture.batch.phase, .scanned)
    }

    func testAChangeReportedWhileScanningSurvivesTheScanBeingStopped() async {
        let monitor = LibraryChangeMonitor(authorizationStatus: { .authorized })
        let fixture = ScanScaleFixture(assets: [scanScaleAsset("a")], monitor: monitor)
        fixture.batch.scan()
        await scanScaleEventually { fixture.batch.phase == .scanned }

        // A second pass, stopped by the user, with a change reported under it.
        fixture.scanner.hold = true
        fixture.batch.scan()
        await scanScaleEventually { fixture.scanner.gate != nil }
        fixture.scanner.refreshResult = scanScaleListing([scanScaleAsset("b")])
        monitor.enteredForeground()
        fixture.batch.cancelScan()

        await scanScaleEventually { fixture.scanner.reconcileCount == 1 }
        await scanScaleEventually { fixture.batch.scanResult?.assets.map(\.id) == ["b"] }
        XCTAssertEqual(fixture.batch.phase, .scanned)
    }

    func testAScanWithNoChangeReportedLeavesTheLibraryAlone() async {
        // The reconcile after a scan costs a full listing, so it must only ever run when Photos
        // actually said something while the pass was reading.
        let fixture = ScanScaleFixture(assets: [scanScaleAsset("a"), scanScaleAsset("b")])
        fixture.batch.scan()
        await scanScaleEventually { fixture.batch.phase == .scanned }

        XCTAssertEqual(fixture.scanner.reconcileCount, 0)
        XCTAssertEqual(fixture.batch.scanResult?.assets.map(\.id), ["a", "b"])
    }

    func testAccessWithdrawnWhileScanningStopsThePassAndSaysWhy() async {
        let status = ScanScaleAccessBox(.authorized)
        let monitor = LibraryChangeMonitor(authorizationStatus: { status.value })
        let fixture = ScanScaleFixture(assets: [scanScaleAsset("a")], monitor: monitor)
        fixture.scanner.hold = true
        fixture.batch.scan()
        await scanScaleEventually { fixture.scanner.gate != nil }

        // The user leaves the app, revokes Photos access in Settings and comes back.
        status.value = .denied
        monitor.enteredForeground()

        XCTAssertEqual(fixture.scanner.cancelCount, 1)
        await scanScaleEventually { fixture.batch.phase == .failed }
        XCTAssertEqual(fixture.batch.message, PipelineError.permissionDenied.localizedDescription)
        // The cancellation that follows lands after the decision to fail, and must not put the
        // flow back on the scanning screen with a library the app may no longer read.
        await scanScaleEventually { !fixture.batch.isRunning }
        XCTAssertEqual(fixture.batch.phase, .failed)
    }
}

// MARK: - Helpers

private func scanScaleAsset(_ id: String, unsupported: String? = nil) -> LibraryAsset {
    LibraryAsset(id: id, creationDate: Date(timeIntervalSince1970: 1_700_000_000), duration: 120,
                 pixelWidth: 3840, pixelHeight: 2160, bytes: 3_000_000_000,
                 unsupportedReason: unsupported)
}

private func scanScaleListing(_ assets: [LibraryAsset]) -> LibraryScanResult {
    LibraryScanResult(assets: assets,
                      videoCount: assets.count,
                      unsupportedCount: 0,
                      unknownSizeCount: assets.filter { $0.bytes == nil }.count,
                      sizeSource: .reportedByPhotos,
                      measuredOnDeviceCount: 0)
}

private func scanScaleEventually(_ predicate: () -> Bool, file: StaticString = #filePath,
                                 line: UInt = #line) async {
    for _ in 0..<500 {
        if predicate() { return }
        try? await Task.sleep(for: .milliseconds(2))
    }
    XCTFail("Timed out waiting for the scan", file: file, line: line)
}

/// A Photos authorization status a test can change between reads.
private final class ScanScaleAccessBox {
    var value: PHAuthorizationStatus
    init(_ value: PHAuthorizationStatus) { self.value = value }
}

@MainActor private final class ScanScaleFixture {
    let photos = ScanScaleMockPhotos()
    let scanner: ScanScaleMockScanner
    let transcoder = ScanScaleMockTranscoder()
    let verifier = ScanScaleMockVerifier()
    let files = ScanScaleMockFiles()
    let history = ScanScaleMockHistory()
    let queue = ScanScaleMockQueue()
    let screenAwake = ScanScaleMockScreenAwake()
    let monitor: LibraryChangeMonitor
    let settings = ShrinkSettings(defaults: UserDefaults(suiteName: "videoshrink.scan.\(UUID().uuidString)")
                                  ?? .standard)
    lazy var batch = BatchViewModel(photos: photos, scanner: scanner, transcoder: transcoder,
                                    verifier: verifier, temporary: files, history: history,
                                    queueStore: queue, screenAwake: screenAwake,
                                    libraryChanges: monitor, settings: settings)

    /// The scanner starts holding exactly the library this fixture was given, so a test says what
    /// the library is once rather than twice.
    init(assets: [LibraryAsset], monitor: LibraryChangeMonitor? = nil) {
        let mockScanner = ScanScaleMockScanner()
        mockScanner.result = scanScaleListing(assets)
        self.scanner = mockScanner
        self.monitor = monitor ?? LibraryChangeMonitor(authorizationStatus: { .authorized })
    }
}

@MainActor private final class ScanScaleMockScanner: LibraryScanning {
    var result = LibraryScanResult(assets: [], videoCount: 0, unsupportedCount: 0, unknownSizeCount: 0,
                                   sizeSource: .reportedByPhotos, measuredOnDeviceCount: 0)
    /// The library as Photos now has it, for a refresh. Left nil, a refresh repeats the last pass.
    var refreshResult: LibraryScanResult?
    /// Holds the pass open so a test can change the library while it is being read.
    var hold = false
    var gate: CheckedContinuation<Void, Error>?
    var cancelCount = 0
    var reconcileCount = 0
    private var cancelled = false

    func scan(progress: @escaping @MainActor (LibraryScanProgress) -> Void) async throws -> LibraryScanResult {
        cancelled = false
        progress(LibraryScanProgress(phase: .listing, scanned: 0, total: result.assets.count))
        if hold { try await withCheckedThrowingContinuation { gate = $0 } }
        if cancelled { throw PipelineError.cancelled }
        return result
    }

    func refreshListing() async throws -> LibraryScanResult { refreshResult ?? result }

    func reconcile(previous: LibraryScanResult?,
                   selection: Set<String>,
                   running: Set<String>) async throws -> LibraryReconciliation {
        reconcileCount += 1
        let fresh = try await refreshListing()
        return LibraryScanResult.reconcile(previous: previous, fresh: fresh,
                                           selection: selection, running: running)
    }

    func cancel() {
        cancelCount += 1
        cancelled = true
        gate?.resume(throwing: PipelineError.cancelled)
        gate = nil
    }

    /// Lets a held pass finish, so a test can drive what the model does when it lands.
    func release() {
        gate?.resume(returning: ())
        gate = nil
    }
}

@MainActor private final class ScanScaleMockPhotos: PhotoLibraryServing {
    func requestAccess() async throws -> Bool { false }

    func retrieve(identifier: String, progress: @escaping @MainActor (Double) -> Void) async throws -> RetrievedVideo {
        throw PipelineError.assetUnavailable
    }

    func cancelRetrieval() {}
    func save(videoAt url: URL, identity: AssetIdentity) async throws -> String? { nil }
    func localFileURL(identifier: String) async -> URL? { nil }

    func playerItem(identifier: String) async throws -> AVPlayerItem {
        throw PipelineError.assetUnavailable
    }

    func deleteOriginals(identifiers: [String]) async throws -> [String] { [] }
    func deletionEvidence(originalIdentifier: String, copyIdentifier: String) -> DeletionEvidence? { nil }
    func revalidateForDeletion(_ evidence: DeletionEvidence) -> CopyRevalidation { .unavailable }

    func deleteOriginals(afterRevalidating evidence: [String: DeletionEvidence]) async throws -> DeletionResult {
        DeletionResult()
    }
}

@MainActor private final class ScanScaleMockTranscoder: VideoTranscoding {
    func transcode(_ source: RetrievedVideo, metadata: VideoMetadata, settings: TranscodeSettings,
                   progress: @escaping @MainActor (Double) -> Void) async throws -> URL {
        throw PipelineError.assetUnavailable
    }

    func cancel() {}
}

private final class ScanScaleMockVerifier: VideoVerifying {
    func inspect(_ url: URL) async throws -> VideoMetadata { throw PipelineError.assetUnavailable }

    func verify(_ url: URL, source: VideoMetadata, expecting codec: VideoCodec?) async throws -> VideoMetadata {
        throw PipelineError.assetUnavailable
    }

    func verifyImportedCopy(_ url: URL, matching expected: VideoMetadata) async throws -> VideoMetadata {
        throw PipelineError.assetUnavailable
    }
}

@MainActor private final class ScanScaleMockFiles: TemporaryFileManaging {
    func ensureWorkspace() throws {}
    func outputURL() throws -> URL { URL(fileURLWithPath: "/scan-scale-root/output.mov") }
    func remove(_ url: URL) throws {}
    func requireCapacity(for bytes: Int64) throws {}
    func cleanup() throws {}
}

@MainActor private final class ScanScaleMockHistory: ShrinkHistoryStoring {
    func completedIdentifiers() -> Set<String> { [] }
    func createdCopyIdentifiers() -> Set<String> { [] }
    func copyMeasurements() -> [CopyMeasurement] { [] }
    func record(identifier: String, measurement: CopyMeasurement?) {}
    func recordCreatedCopy(identifier: String) {}
}

@MainActor private final class ScanScaleMockQueue: BatchQueueStoring {
    func load() -> BatchQueueRecord? { nil }
    func save(_ record: BatchQueueRecord) throws {}
    func clear() {}
}

@MainActor private final class ScanScaleMockScreenAwake: ScreenAwakeControlling {
    func hold(_ hold: Bool) {}
}
