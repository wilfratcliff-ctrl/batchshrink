import ExpoModulesCore
import SwiftUI
import UIKit

// One native session survives React reloads. Creating two view models would let
// one model's startup cleanup remove the other's active output - and the session is
// the thing a reload has to leave standing: the settings, the history, the batch's
// queue and its paused phase, a save Photos has accepted, and a finished
// single-video copy that was waiting to be saved.
@MainActor enum VideoShrinkNativeSession {
  static let settings = ShrinkSettings()
  // Two workspaces, not one, exactly as the app target has: the batch sweeps its own
  // directory at the start and end of every run, and a one-video copy the user has not
  // saved yet must not be in it. See `TemporaryWorkspace`.
  static let oneVideoWorkspace = TemporaryFileManager(workspace: .oneVideo)
  static let batchWorkspace = TemporaryFileManager(workspace: .batch)
  // The same store for both flows, exactly as the app target shares one: a copy saved in the
  // one-video flow is this app's own output, and the batch flow's "Select all" can only leave it
  // alone if both flows read and write the same device-local memory.
  static let history = UserDefaultsShrinkHistoryStore()

  static let model = CompressionViewModel(
    photos: PhotoLibraryService(),
    transcoder: VideoTranscodingService(temporary: oneVideoWorkspace),
    verifier: VideoVerificationService(),
    temporary: oneVideoWorkspace,
    history: history,
    settings: settings
  )

  static let batch = BatchViewModel(
    photos: PhotoLibraryService(),
    scanner: PhotoLibraryScanService(),
    transcoder: VideoTranscodingService(temporary: batchWorkspace),
    verifier: VideoVerificationService(),
    temporary: batchWorkspace,
    history: history,
    queueStore: FileBatchQueueStore(),
    screenAwake: ScreenAwakeController(),
    settings: settings
  )

  /// The host has taken the presentation away: a React reload, or the module being destroyed.
  ///
  /// This is not the user's choice, and it is not backgrounding, whose screen comes back. It
  /// therefore applies the backgrounding rule and nothing stricter:
  ///
  /// - work in flight is cancelled, because there is no background execution entitlement and no
  ///   screen left to wait on it;
  /// - a save Photos has accepted is left alone, because `cancel()` refuses `.saving`: it settles
  ///   into `.saved`, and the copy Photos made is written to the shared history;
  /// - a *finished*, unsaved single-video export is kept. It cost the user a whole export, and a
  ///   view being removed is not the user asking to lose it, so the model stays on `.readyToSave`
  ///   and the copy stays in the one-video flow's own temporary workspace. That workspace is the
  ///   app's own and is cleared at the next launch, so the copy can still be lost - by the app's
  ///   own startup cleanup, never by this call and never by a batch run, which sweeps only its own
  ///   directory. Whether the flow offers that screen again is the flow's own concern; this
  ///   file's rule is only that teardown must not be the thing that deletes the copy;
  /// - the picker sheet is the one thing that cannot survive, because a sheet has no life without
  ///   the view that presents it. Its stage (`.choosing`) is closed rather than reopened, which
  ///   loses nothing: no video has been chosen yet.
  static func presentationRemoved() {
    model.pickerCancelled()
    // `.readyToSave` is deliberately not cancelled - see above. Every other stage this can reach
    // is either work in flight or one that `cancel()` already refuses.
    if model.stage != .readyToSave { model.cancel() }
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
    // Teardown keeps the backgrounding rule: work in flight is cancelled, an accepted save
    // settles, and a finished copy is kept rather than deleted.
    VideoShrinkNativeSession.presentationRemoved()
    controller.willMove(toParent: nil)
    controller.view.removeFromSuperview()
    controller.removeFromParent()
    host = nil
  }
}
