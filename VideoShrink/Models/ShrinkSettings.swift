import Foundation
import Combine

/// The quality choices both flows share. Stored on this device only; no account, no sync.
@MainActor final class ShrinkSettings: ObservableObject {
    @Published var resolution: CopyResolution {
        didSet { persist() }
    }
    @Published var frameRate: FrameRateOption {
        didSet { persist() }
    }
    @Published var deletionMode: DeletionMode {
        didSet { persist() }
    }
    /// Off by default: keeping the display awake costs battery and runs the phone warmer.
    @Published var keepScreenAwake: Bool {
        didSet { persist() }
    }

    private let defaults: UserDefaults
    private let resolutionKey = "shrink.resolution"
    private let frameRateKey = "shrink.frameRate"
    private let deletionKey = "shrink.deletionMode"
    private let screenAwakeKey = "shrink.keepScreenAwake"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        resolution = defaults.string(forKey: resolutionKey)
            .flatMap(CopyResolution.init(rawValue:)) ?? .hd1080
        frameRate = defaults.string(forKey: frameRateKey)
            .flatMap(FrameRateOption.init(rawValue:)) ?? .original
        deletionMode = defaults.string(forKey: deletionKey)
            .flatMap(DeletionMode.init(rawValue:)) ?? .off
        keepScreenAwake = defaults.bool(forKey: screenAwakeKey)
    }

    var transcode: TranscodeSettings {
        TranscodeSettings(resolution: resolution, frameRate: frameRate)
    }

    /// A short line for cards that show the current choice.
    var summary: String {
        "\(resolution.title) · \(resolution.codec.displayName) · \(frameRate.shortTitle)"
    }

    /// The shortest true name for the current choice, for the one place it has to fit a pill.
    ///
    /// `summary` names all three choices, which is right for the card and for the sheet's own row
    /// and too long for the selection screen's header, where this sits beside the sort control on
    /// a phone. The frame rate is the part that goes: its default *is* the original rate, so
    /// leaving it out says nothing untrue, and naming it only when it has been lowered is exactly
    /// when it became a fact worth the room.
    var pillSummary: String {
        frameRate.framesPerSecond == nil
            ? "\(resolution.title) · \(resolution.codec.displayName)"
            : "\(resolution.title) · \(resolution.codec.displayName) · \(frameRate.shortTitle)"
    }

    private func persist() {
        defaults.set(resolution.rawValue, forKey: resolutionKey)
        defaults.set(frameRate.rawValue, forKey: frameRateKey)
        defaults.set(deletionMode.rawValue, forKey: deletionKey)
        defaults.set(keepScreenAwake, forKey: screenAwakeKey)
    }
}
