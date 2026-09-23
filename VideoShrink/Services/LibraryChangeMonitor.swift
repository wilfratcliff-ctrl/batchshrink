import Photos
import UIKit
import Combine

/// Watches Photos for changes made outside the app, and watches the app coming back to the
/// front so a change to limited or revoked access is noticed too.
///
/// Apple delivers `PHPhotoLibraryChangeObserver` notifications on an arbitrary queue, so
/// nothing here touches app state off the main actor: the observer is a plain proxy that hops
/// to the main actor and reports there. This class only says that something changed. Deciding
/// what to do about it stays with the caller, and `LibraryScanResult.reconcile` keeps a running
/// job's identity through the change.
@MainActor final class LibraryChangeMonitor: ObservableObject {
    /// One more than the number of changes reported so far, so a view can refresh on any of them.
    @Published private(set) var revision = 0
    /// Photos access as of the last check.
    @Published private(set) var access: LibraryAccess
    /// Called on the main actor after each reported change.
    var onChange: (@MainActor (LibraryChangeReason) -> Void)?

    private let library: PHPhotoLibrary?
    private let notificationCenter: NotificationCenter
    private let authorizationStatus: () -> PHAuthorizationStatus
    private var foregroundToken: NSObjectProtocol?
    private var isWatching = false
    private lazy var changes = LibraryChangeObserverProxy { [weak self] in
        guard let self else { return }
        self.report(.libraryChanged)
    }

    /// Pass `library` only to watch something other than `PHPhotoLibrary.shared()`. The shared
    /// library is resolved when `start()` is called, so building a monitor reads no Photos
    /// state beyond the authorization status.
    init(library: PHPhotoLibrary? = nil,
         notificationCenter: NotificationCenter = .default,
         authorizationStatus: @escaping () -> PHAuthorizationStatus = {
             PHPhotoLibrary.authorizationStatus(for: .readWrite)
         }) {
        self.library = library
        self.notificationCenter = notificationCenter
        self.authorizationStatus = authorizationStatus
        self.access = LibraryAccess(authorizationStatus())
    }

    /// True while the app may list at least part of the library.
    var canReadLibrary: Bool { access.canRead }
    /// True while access covers only the videos the user chose.
    var isLimited: Bool { access.isLimited }

    /// Starts watching Photos and the app returning to the front. Safe to call more than once.
    /// The owner calls `stop()` when it is done watching.
    func start() {
        guard !isWatching else { return }
        isWatching = true
        (library ?? PHPhotoLibrary.shared()).register(changes)
        foregroundToken = notificationCenter.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: nil) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.enteredForeground()
                }
            }
    }

    /// Stops watching and releases both registrations.
    func stop() {
        guard isWatching else { return }
        isWatching = false
        (library ?? PHPhotoLibrary.shared()).unregisterChangeObserver(changes)
        if let foregroundToken {
            notificationCenter.removeObserver(foregroundToken)
            self.foregroundToken = nil
        }
    }

    /// A fresh authorization check for the way back in. Access can change in Settings while the
    /// app is suspended, and Photos does not deliver a change notification for that, so the
    /// status is re-read every time the app becomes active.
    func enteredForeground() {
        let updated = LibraryAccess(authorizationStatus())
        guard updated == access else {
            access = updated
            report(.accessChanged)
            return
        }
        report(.enteredForeground)
    }

    private func report(_ reason: LibraryChangeReason) {
        revision += 1
        onChange?(reason)
    }
}

/// Bridges PhotoKit's arbitrary-queue notifications onto the main actor.
///
/// It deliberately reads nothing out of the `PHChange`: that object describes a library this
/// app is not holding, and the useful next step is a fresh listing, which is the caller's call.
/// Holding no library state here also means the proxy stays harmless if it outlives the monitor
/// it reports to, because the reference back is weak.
private final class LibraryChangeObserverProxy: NSObject, PHPhotoLibraryChangeObserver {
    private let notify: @MainActor () -> Void

    init(notify: @escaping @MainActor () -> Void) {
        self.notify = notify
        super.init()
    }

    func photoLibraryDidChange(_ changeInstance: PHChange) {
        let notify = self.notify
        Task { @MainActor in notify() }
    }
}
