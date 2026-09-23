# Optional overnight processing: feasibility spike

**Research only. The app implements no overnight mode or background scheduler.** It cancels active retrieval/export/verification when its scene enters the background, and an already submitted Photos save is allowed to settle because it cannot be rolled back or cancelled by this app.

One related piece is implemented source, not research: from build 9 the foreground batch has an opt-in "keep screen awake while working" setting, which holds the idle timer only while a run is active and releases it when work stops or the app leaves the foreground. That is not background processing and it is not the spike described below; it only stops the display sleeping during a foreground run. It has never been measured on a device.

## What iOS offers

| Approach | Useful behavior | Limits and experiment |
| --- | --- | --- |
| Foreground processing | User starts an operation and sees actual progress. This is the Phase 0 baseline. | Auto-lock, app switching, incoming calls, thermal/resource pressure and process termination can interrupt work. Measure long clips and cleanup after interruption. |
| Foreground with `UIApplication.isIdleTimerDisabled` | Implemented in source from build 9: an opt-in "keep screen awake while working" setting prevents automatic idle sleep while work is active. | It does not stop the user manually locking the phone, create a background entitlement or guarantee runtime. The setting is released on every exit. Power, brightness and accessibility still need device measurement rather than assumption. |
| `BGProcessingTask` | System-scheduled maintenance-style processing can request external power and network connectivity. | iOS chooses whether/when it runs; an earliest start is not an appointment. Tasks can expire or be interrupted. Work must be cancellable, checkpointed between videos and resubmitted responsibly. Do not promise a full-library overnight finish. |
| `BGContinuedProcessingTask` (iOS 26+) | A user-initiated task can start in foreground and continue with system-visible progress after backgrounding. Apple identifies media export as a use case. | Investigate availability, resource support, queued-versus-immediate submission, system UI, cancellation and expiration. It is not a general recurring overnight scheduler or proof of unlimited locked-screen encoding. Keep an iOS 18 fallback. |
| Short `beginBackgroundTask` allowance | May help finish a small critical handoff or cleanup. | Finite allowance with expiration; not a design for encoding hours of video. No fake audio/location session to keep the process alive. |

References: Apple’s [BGProcessingTask](https://developer.apple.com/documentation/backgroundtasks/bgprocessingtask), [long-running user-initiated tasks](https://developer.apple.com/documentation/backgroundtasks/performing-long-running-tasks-on-ios-and-ipados), [idle timer](https://developer.apple.com/documentation/uikit/uiapplication/isidletimerdisabled) and [background task allowance](https://developer.apple.com/documentation/uikit/uiapplication/beginbackgroundtask(withname:expirationhandler:)). These describe mechanisms, not a performance guarantee for VideoShrink.

## An honest product experience

After batch reliability exists, offer “Process while charging” with two plainly described options:

- **Keep VideoShrink open:** ask the user to connect power and choose whether to keep the display awake. Show remaining items and observed progress. Estimate completion only from measured throughput, with uncertainty. Let the user stop immediately.
- **Let iOS continue when available:** make scheduling explicit: “iPhone decides when background work can run. Some videos may wait until you reopen VideoShrink.” On iOS 26+, separately evaluate continuing an active user-started job using the newer API.

Never display “will finish by morning” merely because a task request was accepted. Show completed, waiting, interrupted and failed items truthfully on return. Keep originals through all interruption paths. A notification of completion should follow persisted verification and save receipts, not an export progress value.

## Spike design and physical tests

Before implementation, establish a foreground baseline for short/long SDR and HDR videos on the iPhone 15 Pro Max. Record duration, output bytes, energy and heat. Then build a separate experimental branch that performs one cancellable job at a time and persists checkpoints around output verification and Photos save.

Test on power/off power, low-power mode, Wi-Fi/cellular/offline, automatic/manual lock, freshly rebooted and unlocked versus later locked, low storage, natural thermal pressure, calls, user cancellation, app termination and system expiration. Observe whether protected source/output files remain accessible and whether AVFoundation’s hardware encoder can run in each execution mode. Do not weaken file protection solely to make a background experiment appear successful.

For `BGProcessingTask`, test real scheduling over multiple nights; debugger-triggered execution proves handler wiring only. For `BGContinuedProcessingTask`, test both submission strategies, progress reporting, user cancellation via system UI, expiration cleanup and completion after background/lock. Record OS/device versions because runtime behavior may differ.

Acceptance requires repeatable measurements, bounded temporary storage, recoverable state and honest UI. If locked-screen export fails, keep the supported foreground option and explain that limit. **Unlimited locked-screen processing remains unproven and is not a product claim.**
