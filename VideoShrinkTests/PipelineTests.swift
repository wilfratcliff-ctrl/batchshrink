import XCTest
import AVFoundation
import Combine
@testable import VideoShrink

@MainActor final class PipelineTests: XCTestCase {
    func testSuccessRequiresExplicitSaveAndReverification() async {
        let fixture = Fixture()
        var stages: [PipelineStage] = []
        let observation = fixture.model.$stage.sink { stages.append($0) }
        await ready(fixture)
        XCTAssertEqual(fixture.photos.saveCount, 0)
        XCTAssertTrue(fixture.model.canSave)
        fixture.model.save()
        fixture.model.save() // repeated tap must be ignored
        await eventually { fixture.model.stage == .saved && fixture.model.canChoose }
        XCTAssertEqual(fixture.photos.saveCount, 1)
        XCTAssertEqual(fixture.verifier.verifications, 2)
        XCTAssertEqual(stages, [.idle, .waitingForPermission, .choosing, .retrieving, .preparing,
                                .transcoding, .verifying, .readyToSave, .saving, .saved])
        XCTAssertGreaterThanOrEqual(fixture.files.cleanups, 2)
        withExtendedLifetime(observation) {}
    }

    func testDeniedPermissionNeverRetrievesOrSaves() async {
        let fixture = Fixture()
        fixture.photos.accessError = .permissionDenied
        fixture.model.chooseVideo()
        await eventually { fixture.model.stage == .failed && fixture.model.canChoose }
        XCTAssertEqual(fixture.photos.retrieveCount, 0)
        XCTAssertEqual(fixture.photos.saveCount, 0)
        XCTAssertFalse(fixture.model.showingPicker)
    }

    func testLimitedPermissionCanCompleteForAllowedAsset() async {
        let fixture = Fixture()
        fixture.photos.limited = true
        await ready(fixture)
        XCTAssertTrue(fixture.model.limitedAccess)
        XCTAssertTrue(fixture.model.canSave)
    }

    func testMissingIdentifierFailsWithoutProviderFallback() async {
        let fixture = Fixture()
        await choose(fixture)
        fixture.model.selected(identifier: nil)
        XCTAssertEqual(fixture.model.stage, .failed)
        XCTAssertEqual(fixture.photos.retrieveCount, 0)
    }

    func testCloudFailureStopsBeforeExport() async {
        let fixture = Fixture()
        fixture.photos.retrievalError = .retrieval
        await choose(fixture)
        fixture.model.selected(identifier: "test")
        await eventually { fixture.model.stage == .failed && fixture.model.canChoose }
        XCTAssertEqual(fixture.transcoder.exports, 0)
        XCTAssertEqual(fixture.photos.saveCount, 0)
    }

    func testCancelRetrievalNeverStartsExport() async {
        let fixture = Fixture()
        fixture.photos.holdRetrieval = true
        await choose(fixture)
        fixture.model.selected(identifier: "test")
        await eventually { fixture.photos.retrieveGate != nil }
        fixture.model.cancel()
        await eventually { fixture.model.stage == .cancelled && fixture.model.canChoose }
        XCTAssertEqual(fixture.transcoder.exports, 0)
        XCTAssertEqual(fixture.photos.saveCount, 0)
    }

    func testReverificationFailurePreventsPhotosTransaction() async {
        let fixture = Fixture()
        await ready(fixture)
        fixture.verifier.error = .verification
        fixture.model.save()
        await eventually { fixture.model.stage == .failed && fixture.model.canChoose }
        XCTAssertEqual(fixture.photos.saveCount, 0)
        XCTAssertEqual(fixture.verifier.verifications, 2)
    }

    func testExportFailureNeverVerifiesOrSaves() async {
        let fixture = Fixture()
        fixture.transcoder.error = .export
        await choose(fixture)
        fixture.model.selected(identifier: "test")
        await eventually { fixture.model.stage == .failed && fixture.model.canChoose }
        XCTAssertEqual(fixture.verifier.verifications, 0)
        XCTAssertEqual(fixture.photos.saveCount, 0)
    }

    func testVerificationFailureCannotSave() async {
        let fixture = Fixture()
        fixture.verifier.error = .verification
        await choose(fixture)
        fixture.model.selected(identifier: "test")
        await eventually { fixture.model.stage == .failed && fixture.model.canChoose }
        fixture.model.save()
        XCTAssertEqual(fixture.photos.saveCount, 0)
        XCTAssertNil(fixture.model.previewURL)
    }

    func testLowStorageStopsBeforeRetrieval() async {
        let fixture = Fixture()
        fixture.files.capacityError = .insufficientStorage
        await choose(fixture)
        fixture.model.selected(identifier: "test")
        await eventually { fixture.model.stage == .failed && fixture.model.canChoose }
        XCTAssertEqual(fixture.photos.retrieveCount, 0)
        XCTAssertEqual(fixture.photos.saveCount, 0)
    }

    func testLargerOutputCannotSaveAndCanBeDiscarded() async {
        let fixture = Fixture()
        fixture.verifier.output = metadata(bytes: 2_000)
        await ready(fixture)
        XCTAssertFalse(fixture.model.canSave)
        fixture.model.save()
        XCTAssertEqual(fixture.photos.saveCount, 0)
        fixture.model.cancel()
        XCTAssertEqual(fixture.model.stage, .cancelled)
        XCTAssertNil(fixture.model.previewURL)
    }

    func testCancellationWaitsForWriterBeforeCleanup() async {
        let fixture = Fixture()
        fixture.transcoder.hold = true
        await choose(fixture)
        fixture.model.selected(identifier: "test")
        await eventually { fixture.transcoder.gate != nil }
        let cleanupsBeforeCancel = fixture.files.cleanups
        fixture.model.cancel()
        XCTAssertEqual(fixture.files.cleanups, cleanupsBeforeCancel)
        XCTAssertFalse(fixture.model.canChoose)
        fixture.transcoder.release()
        await eventually { fixture.model.stage == .cancelled && fixture.model.canChoose }
        XCTAssertGreaterThan(fixture.files.cleanups, cleanupsBeforeCancel)
        XCTAssertEqual(fixture.verifier.verifications, 0)
    }

    func testBackgroundCancelsActiveExport() async {
        let fixture = Fixture()
        fixture.transcoder.hold = true
        await choose(fixture)
        fixture.model.selected(identifier: "test")
        await eventually { fixture.transcoder.gate != nil }
        fixture.model.enteredBackground()
        XCTAssertTrue(fixture.transcoder.cancelCalled)
        fixture.transcoder.release()
        await eventually { fixture.model.stage == .cancelled && fixture.model.canChoose }
    }

    func testSaveFailureReportsFailureAndCleansUp() async {
        let fixture = Fixture()
        fixture.photos.saveError = .save
        await ready(fixture)
        fixture.model.save()
        await eventually { fixture.model.stage == .failed && fixture.model.canChoose }
        XCTAssertEqual(fixture.photos.saveCount, 1)
        XCTAssertFalse(fixture.model.canSave)
        XCTAssertNil(fixture.model.previewURL)
    }

    func testSaveIsNotCancelledOrCleanedWhileTransactionIsPending() async {
        let fixture = Fixture()
        fixture.photos.holdSave = true
        await ready(fixture)
        fixture.model.save()
        await eventually { fixture.photos.saveGate != nil }
        let cleanups = fixture.files.cleanups
        fixture.model.cancel()
        fixture.model.enteredBackground()
        XCTAssertEqual(fixture.model.stage, .saving)
        XCTAssertEqual(fixture.files.cleanups, cleanups)
        fixture.photos.releaseSave()
        await eventually { fixture.model.stage == .saved && fixture.model.canChoose }
    }

    func testCleanupFailureIsVisible() async {
        let fixture = Fixture()
        await ready(fixture)
        fixture.files.cleanupError = .temporaryFiles
        fixture.model.cancel()
        XCTAssertNotNil(fixture.model.cleanupWarning)
    }

    private func choose(_ fixture: Fixture) async {
        fixture.model.chooseVideo()
        await eventually { fixture.model.showingPicker }
    }

    private func ready(_ fixture: Fixture) async {
        await choose(fixture)
        fixture.model.selected(identifier: "test")
        await eventually { fixture.model.stage == .readyToSave && fixture.model.canCancel }
        // Let the task's defer clear its handle before assertions/actions.
        await Task.yield()
    }

    private func eventually(_ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<500 {
            if predicate() { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("Timed out waiting for pipeline", file: file, line: line)
    }
}

@MainActor private final class Fixture {
    let photos = MockPhotos()
    let transcoder = MockTranscoder()
    let verifier = MockVerifier()
    let files = MockFiles()
    let settings = ShrinkSettings(defaults: UserDefaults(suiteName: "videoshrink.tests.\(UUID().uuidString)")
                                  ?? .standard)
    lazy var model = CompressionViewModel(photos: photos, transcoder: transcoder, verifier: verifier,
                                          temporary: files, settings: settings)
}

@MainActor private final class MockPhotos: PhotoLibraryServing {
    var accessError: PipelineError?
    var retrievalError: PipelineError?
    var saveError: PipelineError?
    var limited = false
    var retrieveCount = 0
    var saveCount = 0
    var holdSave = false
    var holdRetrieval = false
    var retrieveGate: CheckedContinuation<Void, Error>?
    var saveGate: CheckedContinuation<Void, Never>?
    func requestAccess() async throws -> Bool {
        if let accessError { throw accessError }
        return limited
    }
    func retrieve(identifier: String, progress: @escaping @MainActor (Double) -> Void) async throws -> RetrievedVideo {
        retrieveCount += 1
        if let retrievalError { throw retrievalError }
        if holdRetrieval { try await withCheckedThrowingContinuation { retrieveGate = $0 } }
        try Task.checkCancellation()
        return RetrievedVideo(asset: AVURLAsset(url: URL(fileURLWithPath: "/mock-source.mov")),
                              identity: .unknown)
    }
    func cancelRetrieval() { retrieveGate?.resume(throwing: PipelineError.cancelled); retrieveGate = nil }
    func save(videoAt url: URL, identity: AssetIdentity) async throws -> String? {
        saveCount += 1
        if let saveError { throw saveError }
        if holdSave { await withCheckedContinuation { saveGate = $0 } }
        return "created-\(saveCount)"
    }
    func localFileURL(identifier: String) async -> URL? { nil }
    func playerItem(identifier: String) async throws -> AVPlayerItem { throw PipelineError.assetUnavailable }
    func deleteOriginals(identifiers: [String]) async throws -> [String] { [] }
    func releaseSave() { saveGate?.resume(); saveGate = nil }
}

@MainActor private final class MockTranscoder: VideoTranscoding {
    var error: PipelineError?
    var exports = 0
    var hold = false
    var cancelCalled = false
    var gate: CheckedContinuation<Void, Never>?
    var receivedSettings: [TranscodeSettings] = []
    var written = URL(fileURLWithPath: "/mock-output.mov")

    func transcode(_ source: RetrievedVideo, metadata: VideoMetadata, settings: TranscodeSettings,
                   progress: @escaping @MainActor (Double) -> Void) async throws -> URL {
        exports += 1
        receivedSettings.append(settings)
        if let error { throw error }
        if hold { await withCheckedContinuation { gate = $0 } }
        try Task.checkCancellation()
        return written
    }
    func cancel() { cancelCalled = true }
    func release() { gate?.resume(); gate = nil }
}

// Tests inspect this fake only after awaited operations finish; production uses an actor.
private final class MockVerifier: VideoVerifying {
    var error: PipelineError?
    var output = metadata(bytes: 600)
    var verifications = 0
    func inspect(_ url: URL) async throws -> VideoMetadata { metadata() }
    func verify(_ url: URL, source: VideoMetadata, expecting codec: VideoCodec?) async throws -> VideoMetadata {
        verifications += 1
        if let error { throw error }
        return output
    }
}

@MainActor private final class MockFiles: TemporaryFileManaging {
    var capacityError: PipelineError?
    var cleanupError: PipelineError?
    var cleanups = 0
    func ensureWorkspace() throws {}
    func outputURL() throws -> URL { URL(fileURLWithPath: "/mock-output.mov") }
    func remove(_ url: URL) throws {}
    func requireCapacity(for bytes: Int64) throws { if let capacityError { throw capacityError } }
    func cleanup() throws { cleanups += 1; if let cleanupError { throw cleanupError } }
}
