import UIKit

@MainActor protocol ScreenAwakeControlling {
    func hold(_ hold: Bool)
}

/// Keeps the display awake while a batch is working, and only then.
///
/// iOS ignores the flag once the app is not frontmost, and it never survives the process, so the
/// worst case is a screen that stays on a little longer than intended. Every path that stops work
/// releases it.
@MainActor final class ScreenAwakeController: ScreenAwakeControlling {
    private(set) var isHolding = false

    func hold(_ hold: Bool) {
        guard hold != isHolding else { return }
        isHolding = hold
        UIApplication.shared.isIdleTimerDisabled = hold
    }
}
