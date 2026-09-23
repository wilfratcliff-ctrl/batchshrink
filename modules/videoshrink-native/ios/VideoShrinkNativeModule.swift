import ExpoModulesCore

public class VideoShrinkNativeModule: Module {
  public func definition() -> ModuleDefinition {
    Name("VideoShrinkNative")

    View(VideoShrinkNativeView.self) {
    }

    // UIHostingController does not own the application's SwiftUI scene.
    // Forward lifecycle events explicitly so the foreground-only rule still holds.
    OnAppEntersBackground {
      Task { @MainActor in
        VideoShrinkNativeSession.model.enteredBackground()
        VideoShrinkNativeSession.batch.enteredBackground()
      }
    }

    OnDestroy {
      Task { @MainActor in VideoShrinkNativeSession.presentationRemoved() }
    }
  }
}
