import ExpoModulesCore
import SwiftUI
import UIKit

// One native session survives React reloads. Creating two view models would let
// one model's startup cleanup remove the other's active output.
@MainActor enum VideoShrinkNativeSession {
  static let settings = ShrinkSettings()
  static let temporary = TemporaryFileManager()

  static let model = CompressionViewModel(
    photos: PhotoLibraryService(),
    transcoder: VideoTranscodingService(temporary: temporary),
    verifier: VideoVerificationService(),
    temporary: temporary,
    settings: settings
  )

  static let batch = BatchViewModel(
    photos: PhotoLibraryService(),
    scanner: PhotoLibraryScanService(),
    transcoder: VideoTranscodingService(temporary: temporary),
    verifier: VideoVerificationService(),
    temporary: temporary,
    history: UserDefaultsShrinkHistoryStore(),
    queueStore: FileBatchQueueStore(),
    screenAwake: ScreenAwakeController(),
    settings: settings
  )

  static func presentationRemoved() {
    model.pickerCancelled()
    model.cancel()
    batch.enteredBackground()
  }
}

final class VideoShrinkNativeView: ExpoView {
  private var host: UIHostingController<ContentView>?

  required init(appContext: AppContext? = nil) {
    super.init(appContext: appContext)
    clipsToBounds = true
    backgroundColor = UIColor(red: 0.025, green: 0.035, blue: 0.065, alpha: 1)
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    if window == nil {
      detachHost()
    } else {
      attachHostIfNeeded()
      DispatchQueue.main.async { [weak self] in self?.attachHostIfNeeded() }
    }
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    attachHostIfNeeded()
    host?.view.frame = bounds
  }

  private func attachHostIfNeeded() {
    guard window != nil, host == nil, let parent = containingController else { return }
    let controller = UIHostingController(rootView: ContentView(model: VideoShrinkNativeSession.model,
                                                              batch: VideoShrinkNativeSession.batch))
    host = controller
    controller.view.backgroundColor = UIColor(red: 0.025, green: 0.035, blue: 0.065, alpha: 1)
    parent.addChild(controller)
    controller.view.frame = bounds
    controller.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    addSubview(controller.view)
    controller.didMove(toParent: parent)
  }

  private var containingController: UIViewController? {
    var responder: UIResponder? = next
    while let current = responder {
      if let controller = current as? UIViewController { return controller }
      responder = current.next
    }
    return nil
  }

  private func detachHost() {
    guard let controller = host else { return }
    // Cancellation preserves the existing rule: an accepted Photos save settles.
    VideoShrinkNativeSession.presentationRemoved()
    controller.willMove(toParent: nil)
    controller.view.removeFromSuperview()
    controller.removeFromParent()
    host = nil
  }
}
