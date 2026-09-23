import XCTest
import AVFoundation
@testable import VideoShrink

final class RulesTests: XCTestCase {
    func testMeasuredSavings() {
        let result = Savings(originalBytes: 1_000, compressedBytes: 600)
        XCTAssertEqual(result.bytesSaved, 400)
        XCTAssertEqual(result.percentage, 40)
        XCTAssertTrue(result.isSmaller)
    }

    func testLargerAndEqualOutputsAreNotSavings() {
        let larger = Savings(originalBytes: 1_000, compressedBytes: 1_200)
        XCTAssertEqual(larger.bytesSaved, -200)
        XCTAssertEqual(larger.percentage, -20)
        XCTAssertFalse(larger.isSmaller)
        XCTAssertFalse(Savings(originalBytes: 500, compressedBytes: 500).isSmaller)
        XCTAssertFalse(Savings(originalBytes: 500, compressedBytes: 0).isSmaller)
    }

    func testZeroSourceDoesNotDivideByZero() {
        XCTAssertNil(Savings(originalBytes: 0, compressedBytes: 100).percentage)
    }

    func testDurationRoundingAndPortraitDownscaleAreAccepted() throws {
        try VerificationRules.validate(source: metadata(duration: 60, width: 2160, height: 3840),
                                       output: metadata(duration: 60.1, width: 1080, height: 1920),
                                       expecting: nil)
    }

    func testTruncatedDurationRejected() {
        XCTAssertThrowsError(try VerificationRules.validate(source: metadata(), output: metadata(duration: 10),
                                                            expecting: nil)) {
            XCTAssertEqual($0 as? PipelineError, .durationMismatch)
        }
    }

    func testInvalidDurationsRejected() {
        for duration in [Double.nan, Double.infinity, 0, -1] {
            XCTAssertThrowsError(try VerificationRules.validate(source: metadata(),
                                                               output: metadata(duration: duration),
                                                               expecting: nil))
        }
    }

    func testEmptyUnplayableAndUnknownCodecRejected() {
        for output in [metadata(bytes: 0), metadata(playable: false), metadata(codec: .other)] {
            XCTAssertThrowsError(try VerificationRules.validate(source: metadata(), output: output, expecting: nil))
        }
    }

    func testMissingAudioRejectedAndSilentVideoAccepted() throws {
        XCTAssertThrowsError(try VerificationRules.validate(source: metadata(audio: 1), output: metadata(audio: 0),
                                                            expecting: nil)) {
            XCTAssertEqual($0 as? PipelineError, .audioMismatch)
        }
        try VerificationRules.validate(source: metadata(audio: 0), output: metadata(audio: 0), expecting: nil)
    }

    func testPortraitToLandscapeShapeChangeRejected() {
        XCTAssertThrowsError(try VerificationRules.validate(source: metadata(width: 1080, height: 1920),
                                                            output: metadata(width: 1920, height: 1080),
                                                            expecting: nil)) {
            XCTAssertEqual($0 as? PipelineError, .orientationMismatch)
        }
    }

    func testACopyMayNotBeLargerThanItsOriginal() {
        XCTAssertThrowsError(try VerificationRules.validate(source: metadata(width: 1920, height: 1080),
                                                            output: metadata(width: 3840, height: 2160),
                                                            expecting: nil)) {
            XCTAssertEqual($0 as? PipelineError, .resolutionMismatch)
        }
        XCTAssertNoThrow(try VerificationRules.validate(source: metadata(width: 3840, height: 2160),
                                                        output: metadata(width: 1280, height: 720),
                                                        expecting: nil))
    }

    func testACopyMayDropFramesButMayNotInventThem() {
        XCTAssertNoThrow(try VerificationRules.validate(source: metadata(frameRate: 60),
                                                        output: metadata(frameRate: 24),
                                                        expecting: nil))
        XCTAssertThrowsError(try VerificationRules.validate(source: metadata(frameRate: 30),
                                                            output: metadata(frameRate: 60),
                                                            expecting: nil)) {
            XCTAssertEqual($0 as? PipelineError, .frameRateMismatch)
        }
    }

    func testTheRequestedCodecIsCheckedAndABetterOneIsAccepted() {
        XCTAssertThrowsError(try VerificationRules.validate(source: metadata(),
                                                            output: metadata(codec: .h264),
                                                            expecting: .hevc)) {
            XCTAssertEqual($0 as? PipelineError, .codecMismatch)
        }
        XCTAssertNoThrow(try VerificationRules.validate(source: metadata(),
                                                        output: metadata(codec: .h264),
                                                        expecting: .h264))
        // Asking for the smaller H.264 copy and receiving HEVC is a better result, not a failure.
        XCTAssertNoThrow(try VerificationRules.validate(source: metadata(),
                                                        output: metadata(codec: .hevc),
                                                        expecting: .h264))
    }

    func testCannotSkipVerificationOrCancelAcceptedSave() {
        XCTAssertFalse(PipelineStage.transcoding.allows(.readyToSave))
        XCTAssertFalse(PipelineStage.verifying.allows(.saving))
        XCTAssertTrue(PipelineStage.verifying.allows(.readyToSave))
        XCTAssertFalse(PipelineStage.saving.allows(.cancelled))
        XCTAssertTrue(PipelineStage.saving.allows(.failed))
        XCTAssertTrue(PipelineStage.saving.allows(.saved))
    }

    func testNestedDiskFullErrorsGetActionableMessage() {
        let nested = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)
        let outer = NSError(domain: "Wrapped", code: 1, userInfo: [NSUnderlyingErrorKey: nested])
        XCTAssertEqual(PipelineError.normalize(outer, fallback: .export), .insufficientStorage)
        XCTAssertEqual(PipelineError.normalize(NSError(domain: AVFoundationErrorDomain,
                                                       code: AVError.diskFull.rawValue),
                                               fallback: .export), .insufficientStorage)
        XCTAssertEqual(PipelineError.normalize(CancellationError(), fallback: .export), .cancelled)
    }

    func testMissingFileFailsRealVerification() async {
        do {
            _ = try await VideoVerificationService().verify(
                FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
                source: metadata(), expecting: nil)
            XCTFail("A missing file must never pass verification")
        } catch { XCTAssertEqual(error as? PipelineError, .verification) }
    }

    func testEmptyFileFailsRealVerification() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data().write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            _ = try await VideoVerificationService().verify(url, source: metadata(), expecting: nil)
            XCTFail("An empty file must never pass verification")
        } catch { XCTAssertEqual(error as? PipelineError, .verification) }
    }

    func testCorruptContainerFailsRealVerification() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mov")
        try Data("Not a movie".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            _ = try await VideoVerificationService().verify(url, source: metadata(), expecting: nil)
            XCTFail("A nonempty corrupt container must never pass verification")
        } catch {
            // Different OS releases may reject during property loading or track inspection.
            XCTAssertFalse(error is CancellationError)
        }
    }
}

func metadata(duration: Double = 60, width: Int = 1920, height: Int = 1080,
              bytes: Int64 = 1_000, audio: Int = 1, playable: Bool = true,
              codec: VideoCodec = .hevc, frameRate: Double = 30) -> VideoMetadata {
    VideoMetadata(duration: duration, width: width, height: height, bytes: bytes,
                  fileType: "MOV", audioTrackCount: audio, isPlayable: playable,
                  codec: codec, nominalFrameRate: frameRate)
}
