import XCTest
import AVFoundation
import CoreMedia
import CoreVideo
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

    // MARK: - Copy verification policy (P0-3)

    func testVerificationRequiresEverySampleWindowNotJustOne() {
        XCTAssertTrue(VideoVerificationService.allWindowsDecoded([true, true, true]))
        XCTAssertFalse(VideoVerificationService.allWindowsDecoded([true, true, false]),
                       "A tail that will not decode must not pass")
        XCTAssertFalse(VideoVerificationService.allWindowsDecoded([true, false, false]),
                       "A middle and an end that will not decode must not pass")
        XCTAssertFalse(VideoVerificationService.allWindowsDecoded([false, true, true]))
        XCTAssertFalse(VideoVerificationService.allWindowsDecoded([]),
                       "Decoding nothing is not a pass")
    }

    func testSampleWindowsCoverStartMiddleAndEndOfANormalClip() {
        let windows = VideoVerificationService.sampleWindows(start: 0, length: 60)
        XCTAssertEqual(windows.count, 3, "A 60 s clip can host all three windows")
        XCTAssertEqual(windows.first?.offset ?? -1, 6, accuracy: 0.0001)
        XCTAssertEqual(windows.dropFirst().first?.offset ?? -1, 30, accuracy: 0.0001)
        XCTAssertEqual(windows.last?.offset ?? -1, 54, accuracy: 0.0001)
        for window in windows { XCTAssertEqual(window.window, 0.5, accuracy: 0.0001) }
    }

    func testSampleWindowsFollowATrackThatDoesNotStartAtZero() {
        let windows = VideoVerificationService.sampleWindows(start: 4, length: 60)
        XCTAssertEqual(windows.count, 3)
        XCTAssertEqual(windows.first?.offset ?? -1, 10, accuracy: 0.0001)
        XCTAssertEqual(windows.last?.offset ?? -1, 58, accuracy: 0.0001)
    }

    func testShortValidClipIsSampledWholeInsteadOfSkipped() {
        // 0.04 s cannot host even the earliest window, so the clip is sampled as one window
        // covering all of it. It passes only because that window decoded.
        XCTAssertEqual(VideoVerificationService.minimumSampleWindow, 0.05, accuracy: 0.0001)
        let windows = VideoVerificationService.sampleWindows(start: 0, length: 0.04)
        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows.first?.offset ?? -1, 0, accuracy: 0.0001)
        XCTAssertEqual(windows.first?.window ?? -1, 0.04, accuracy: 0.0001)
        XCTAssertTrue(VideoVerificationService.allWindowsDecoded([true]))
        XCTAssertFalse(VideoVerificationService.allWindowsDecoded([false]))
    }

    func testTailWindowIsDroppedOnlyWhenItCannotHoldAFrame() {
        // 0.2 s leaves 0.02 s after the 0.9 position, less than the documented floor, so only
        // the two windows that fit are required.
        XCTAssertEqual(VideoVerificationService.sampleWindows(start: 0, length: 0.2).count, 2)
        XCTAssertEqual(VideoVerificationService.sampleWindows(start: 0, length: 1).count, 3)
        // An unusable range yields no window at all, which the check above turns into a failure.
        XCTAssertEqual(VideoVerificationService.sampleWindows(start: 0, length: 0).count, 0)
    }

    func testImportedCopyIsComparedWithTheExpectedOutput() throws {
        let expected = metadata(duration: 30, width: 1920, height: 1080, audio: 1)
        XCTAssertNoThrow(try VideoVerificationService.validate(expected: expected, observed: expected,
                                                               expecting: expected.codec))
        XCTAssertThrowsError(try VideoVerificationService.validate(
            expected: expected, observed: metadata(duration: 29, width: 1920, height: 1080, audio: 1),
            expecting: expected.codec)) { XCTAssertEqual($0 as? PipelineError, .durationMismatch) }
        XCTAssertThrowsError(try VideoVerificationService.validate(
            expected: expected, observed: metadata(duration: 30, width: 1920, height: 1080, audio: 0),
            expecting: expected.codec)) { XCTAssertEqual($0 as? PipelineError, .audioMismatch) }
        XCTAssertThrowsError(try VideoVerificationService.validate(
            expected: expected, observed: metadata(duration: 30, width: 1080, height: 1920, audio: 1),
            expecting: expected.codec)) { XCTAssertEqual($0 as? PipelineError, .orientationMismatch) }
        XCTAssertThrowsError(try VideoVerificationService.validate(
            expected: expected, observed: metadata(duration: 30, width: 3840, height: 2160, audio: 1),
            expecting: expected.codec)) { XCTAssertEqual($0 as? PipelineError, .resolutionMismatch) }
        XCTAssertThrowsError(try VideoVerificationService.validate(
            expected: expected, observed: metadata(duration: 30, width: 1920, height: 1080, bytes: 0),
            expecting: expected.codec)) { XCTAssertEqual($0 as? PipelineError, .verification) }
    }

    func testImportedCopyReadBackRejectsAFileItCannotRead() async {
        do {
            _ = try await VideoVerificationService().verifyImportedCopy(
                FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
                matching: metadata())
            XCTFail("A copy that cannot be read must never pass read-back verification")
        } catch { XCTAssertEqual(error as? PipelineError, .verification) }
    }

    // MARK: - Formats only the media itself can decide (N12)

    // A ProRes subtype and an HDR transfer function appear in no PhotoKit listing, so both are
    // decided once the original can be read. The first three cases below drive that decision; the
    // fourth drives it through a real `CMFormatDescription`, which is as close to an original as
    // a machine with no media file can get.

    /// Failures before this change: every one of them, because nothing could set either trait.
    /// `AssetRules` refusal is read out of the rules table rather than restated, so an HDR
    /// original reads the same here as it does on the screening screen.
    func testAHDRTransferFunctionIsRefusedInTheRulesOwnWords() {
        XCTAssertEqual(VideoVerificationService.transferFunction(
            declaredBy: kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String), .hlg)
        XCTAssertEqual(VideoVerificationService.transferFunction(
            declaredBy: kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String), .pq)
        XCTAssertEqual(VideoVerificationService.transferFunction(
            declaredBy: kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String), .pq,
                       "The image-buffer attachment and the format description carry one value")
        XCTAssertTrue(TransferFunction.hlg.isHDR)
        XCTAssertTrue(TransferFunction.pq.isHDR)

        let wording = AssetRules.unsupportedReason(AssetRules.Traits(isHDR: true))
        let refusal = VideoVerificationService.unsupportedFormatRefusal(isHDR: true, isProRes: false)
        XCTAssertNotNil(wording)
        XCTAssertEqual(refusal?.reason, wording)
        XCTAssertEqual(refusal?.errorDescription, wording,
                       "An HDR original must be refused in the words the library already shows")
    }

    func testAProResSubtypeIsRefusedInTheRulesOwnWords() {
        for subtype in [kCMVideoCodecType_AppleProRes422, kCMVideoCodecType_AppleProRes422HQ,
                        kCMVideoCodecType_AppleProRes422LT, kCMVideoCodecType_AppleProRes422Proxy,
                        kCMVideoCodecType_AppleProRes4444, kCMVideoCodecType_AppleProRes4444XQ,
                        kCMVideoCodecType_AppleProResRAW, kCMVideoCodecType_AppleProResRAWHQ] {
            XCTAssertTrue(VideoVerificationService.isProRes(subtype: subtype),
                          "Every ProRes subtype Apple declares must be refused")
        }

        let refusal = VideoVerificationService.unsupportedFormatRefusal(isHDR: false, isProRes: true)
        XCTAssertEqual(refusal?.errorDescription,
                       AssetRules.unsupportedReason(AssetRules.Traits(isProRes: true)),
                       "A ProRes original must be refused in the words the library already shows")
    }

    func testAnOrdinarySDRVideoIsNotRefused() {
        XCTAssertNil(VideoVerificationService.unsupportedFormatRefusal(isHDR: false, isProRes: false))
        XCTAssertEqual(VideoVerificationService.transferFunction(declaredBy: nil), .unknown)
        XCTAssertEqual(VideoVerificationService.transferFunction(declaredBy: "not a transfer function"),
                       .unknown,
                       "A value this app has never seen is not a reason to refuse the whole library")
        XCTAssertEqual(VideoVerificationService.transferFunction(
            declaredBy: kCMFormatDescriptionTransferFunction_ITU_R_709_2 as String), .sdr)
        XCTAssertFalse(TransferFunction.sdr.isHDR)
        XCTAssertFalse(TransferFunction.unknown.isHDR)
        for subtype in [kCMVideoCodecType_H264, kCMVideoCodecType_HEVC] {
            XCTAssertFalse(VideoVerificationService.isProRes(subtype: subtype))
        }

        let ordinary = metadata()
        XCTAssertFalse(ordinary.isHDR)
        XCTAssertFalse(ordinary.isProRes)
        XCTAssertEqual(ordinary.transferFunction, .unknown)
    }

    /// The two facts as a real format description carries them. Building a description is not
    /// building a media file, so this proves the symbols and the documented extension key line up
    /// with Apple's, and nothing about what a device reports.
    func testTheFormatFactsAreReadFromARealFormatDescription() throws {
        let hdr = try formatDescription(codecType: kCMVideoCodecType_HEVC,
                                        declaring: kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String)
        XCTAssertEqual(VideoVerificationService.transferFunction(of: [hdr]), .hlg,
                       "The reader must find the transfer function through Apple's documented key")
        XCTAssertEqual(VideoVerificationService.unsupportedFormatRefusal(
            isHDR: VideoVerificationService.transferFunction(of: [hdr]).isHDR, isProRes: false)?.reason,
                       AssetRules.unsupportedReason(AssetRules.Traits(isHDR: true)))

        let proRes = try formatDescription(codecType: kCMVideoCodecType_AppleProRes4444)
        XCTAssertTrue(VideoVerificationService.isProRes(
            subtype: CMFormatDescriptionGetMediaSubType(proRes)))
        XCTAssertFalse(VideoVerificationService.isProRes(
            subtype: CMFormatDescriptionGetMediaSubType(hdr)),
                       "An HDR HEVC original is not ProRes")

        let ordinary = try formatDescription(codecType: kCMVideoCodecType_H264,
                                             declaring: kCMFormatDescriptionTransferFunction_ITU_R_709_2 as String)
        XCTAssertEqual(VideoVerificationService.transferFunction(of: [ordinary]), .sdr)
        XCTAssertNil(VideoVerificationService.unsupportedFormatRefusal(
            isHDR: VideoVerificationService.transferFunction(of: [ordinary]).isHDR,
            isProRes: VideoVerificationService.isProRes(
                subtype: CMFormatDescriptionGetMediaSubType(ordinary))))
    }

    /// A real `CMFormatDescription`, made with the API CoreMedia itself uses, so the subtype and
    /// the colour tag are read off a genuine description rather than off a dictionary this test
    /// wrote. `declaring` is the value of the documented transfer-function extension.
    private func formatDescription(codecType: CMVideoCodecType,
                                   declaring transferFunction: String? = nil) throws -> CMFormatDescription {
        var extensions: [String: Any] = [:]
        if let transferFunction {
            extensions[kCMFormatDescriptionExtension_TransferFunction as String] = transferFunction
        }
        var created: CMFormatDescription?
        // Argument order is CoreMedia's: allocator, codecType, width, height, extensions, out.
        let status = CMVideoFormatDescriptionCreate(allocator: nil, codecType: codecType,
                                                   width: 1920, height: 1080,
                                                   extensions: extensions as CFDictionary,
                                                   formatDescriptionOut: &created)
        return try XCTUnwrap(created, "CMVideoFormatDescriptionCreate returned status \(status)")
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
    // The single-video flow has no deletion path at all, so this fake never writes a receipt and
    // never approves a delete.
    func deletionEvidence(originalIdentifier: String, copyIdentifier: String) -> DeletionEvidence? { nil }
    func revalidateForDeletion(_ evidence: DeletionEvidence) -> CopyRevalidation { .unavailable }
    func deleteOriginals(afterRevalidating evidence: [String: DeletionEvidence]) async throws -> DeletionResult {
        DeletionResult(deleted: [], rejected: evidence.mapValues { _ in CopyRevalidation.unavailable })
    }
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
    func verifyImportedCopy(_ url: URL, matching expected: VideoMetadata) async throws -> VideoMetadata {
        output
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
