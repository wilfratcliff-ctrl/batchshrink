import ExpoModulesCore
import OSLog
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
  /// How many times the attach has been retried before this view says so out loud.
  private var attachAttempts = 0
  /// True while a retry is already waiting to run, so a burst of layout passes cannot spend the
  /// budget faster than the clock does: `layoutSubviews` can fire many times in the first frame or
  /// two, and one retry per layout pass would burn twenty attempts in milliseconds and tell a user
  /// the app could not start moments before it does.
  private var retryScheduled = false
  /// Twenty tries at 50ms apart is one second, which is far longer than the hop that finds the
  /// controller in an ordinary hierarchy and short enough that a user who is stuck is told soon.
  private static let attachAttemptLimit = 20
  private let log = Logger(subsystem: "VideoShrink", category: "Launch")

  /// Words for the moment before this view's SwiftUI has drawn anything.
  ///
  /// The view is created by React Native, so it exists before the SwiftUI host can attach - and
  /// attaching needs a parent view controller, which is not there on the first layout passes. Until
  /// then the shell draws nothing of its own and the app is a flat dark rectangle with no words on
  /// it. This label fills that, and it is also what a user sees if the controller is never found at
  /// all: it says the app could not start rather than leaving a blank screen behind.
  private lazy var placeholder: UILabel = {
    let label = UILabel()
    label.text = "Starting…"
    label.font = .preferredFont(forTextStyle: .headline)
    label.textColor = UIColor(white: 1, alpha: 0.72)
    label.textAlignment = .center
    label.numberOfLines = 0
    label.isUserInteractionEnabled = false
    label.backgroundColor = .clear
    return label
  }()

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
    placeholder.frame = bounds
  }

  private func attachHostIfNeeded() {
    guard window != nil, host == nil else { return }
    guard let parent = containingController else {
      // Nothing else in this view can draw, so say something rather than nothing - and keep trying,
      // because the controller appears a hop or two after the first layout in every hierarchy this
      // has been seen in.
      showPlaceholder()
      retryAttach()
      return
    }
    // A later detach and re-attach starts its own count: the retries are for finding the controller
    // the first time, not a budget the view spends once for the life of the process.
    attachAttempts = 0
    let controller = UIHostingController(rootView: ContentView(model: VideoShrinkNativeSession.model,
                                                              batch: VideoShrinkNativeSession.batch))
    host = controller
    controller.view.backgroundColor = UIColor(red: 0.025, green: 0.035, blue: 0.065, alpha: 1)
    parent.addChild(controller)
    controller.view.frame = bounds
    controller.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    addSubview(controller.view)
    controller.didMove(toParent: parent)
    // The label goes *after* the host's view is in the hierarchy, not before it is built: building
    // the root view is the first touch of the session's statics, and their initialisers are where the
    // main-actor work runs - the workspace sweep, the adopted save notes, the queue restore with one
    // Photos revalidation per saved item. Removing the words before that would leave the screen blank
    // for exactly the slow part this label exists to cover.
    placeholder.removeFromSuperview()
  }

  /// Looks again shortly, and gives up out loud rather than silently.
  ///
  /// The failures this exists for are the ones a screen cannot explain on its own: this view draws
  /// nothing until the host attaches, so a hierarchy this app cannot walk to a controller leaves a
  /// user looking at a rectangle with no way to tell a slow start from a broken one.
  private func retryAttach() {
    guard attachAttempts < Self.attachAttemptLimit else {
      if placeholder.text != Self.couldNotStart {
        placeholder.text = Self.couldNotStart
        // The observation, not a verdict: a controller arriving later still attaches, and this view
        // is reachable again from the next layout pass. The sentence on screen is the one a user
        // needs; this line is what a log should say.
        log.error("No parent view controller was found for the SwiftUI host after 20 looks over about a second")
        UIAccessibility.post(notification: .announcement, argument: Self.couldNotStart)
      }
      return
    }
    guard !retryScheduled else { return }
    retryScheduled = true
    attachAttempts += 1
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
      self?.retryScheduled = false
      self?.attachHostIfNeeded()
    }
  }

  private func showPlaceholder() {
    guard placeholder.superview == nil else { return }
    placeholder.frame = bounds
    addSubview(placeholder)
  }

  private static let couldNotStart = "BatchShrink could not start. Close the app and open it again."

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
