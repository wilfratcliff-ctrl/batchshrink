# Physical-device acceptance plan

All cases are **NOT RUN** at creation. Use expendable or separately backed-up test clips, starting on the iPhone 15 Pro Max. No test instructs you to remove your original media. An installed internal build and a passing simulator test suite are prerequisites, not proof of the media pipeline.

These cases describe the source at commit `07526c4`. Build 10 (`0.1.0`) is the last build known to have run anywhere, and it predates the round 1 queue, deletion and verification changes and every round after them, so a pass against build 10 covers none of this. The first build to carry that work is `0.1.0` (build 11), and nothing since build 10 has been installed on a device, so the first run of this plan is the first evidence about any of it.

Record: app version/build, Git revision once available, iOS/Xcode versions, device, permission mode, codec/resolution/HDR/frame rate, duration, audio, network/power/thermal conditions, source/output byte counts, observed outcome and pass/fail. Do not put private filenames, library identifiers, locations or personal footage in the repository.

## First five tests

1. **Local landscape video with audio:** choose a short, unedited, high-bitrate SDR clip already downloaded. Verify sensible measured metadata, export progress and ready-to-save state. Preview beginning/middle/end and listen. Confirm exactly one new Photos item appears only after Save; original duration, quality and edit state remain unchanged.
2. **iCloud-only original:** use a known offloaded, expendable clip with Optimize iPhone Storage enabled. There is no reliable public “evict just this original” action in this app; do not assume an asset is cloud-only just because optimization is enabled. Record how offloaded status was established. Look for PhotoKit download progress, complete the pipeline and save. Repeat with connectivity unavailable to observe a clear retrieval failure. A cached original can still succeed offline, so that is not proof of an iCloud path.
3. **Portrait video with audio:** compare orientation and aspect in preview and in Photos after import, including rotation/fullscreen playback. Check audio synchronization near both ends and confirm the measured size reduction is positive.
4. **Cancel while transcoding:** use a sufficiently long 4K clip, cancel after real progress begins, and confirm no new Photos item, cancelled status and a usable fresh selection. Repeat selection/export to expose stale callbacks or leftover output.
5. **Long 4K HDR video:** remain in foreground on power, preview and save only if verified and smaller. Compare brightness, highlights, color, orientation, sound and end playback with the original. Any washed-out image, unexpected SDR conversion or lost HDR behavior is a recorded feasibility issue, even if automated checks passed.

## Full matrix

| Case | Action and expected result |
| --- | --- |
| Permission not determined | Tap Choose; permission state appears, native prompt appears. Cancel processing while prompt is pending; resolve the prompt. The app must not continue processing afterward. The app cannot dismiss Apple’s prompt. |
| Denied/restricted | Deny access or use a restriction. Show readable guidance, no picker/export/save. Settings recovery works when allowed. |
| Limited, allowed item | Allow only one test video; select it. Full pipeline works without requiring access to the entire library. |
| Limited, disallowed item | System picker may display items outside the grant. Selecting one must show the accessible-asset error and no output. Update access in Settings, return and retry. |
| Picker cancel/swipe dismissal | Both cancellation paths end cleanly, with a usable Choose button. |
| iCloud interruption | During confirmed download, toggle connectivity off. Observe error/cancellation behavior and retry. Record if the OS continues from cache. Never label a local retrieval as a proven download. |
| Cloud cancel and retry | Cancel while download percentage updates, immediately start a new attempt when allowed. Old callbacks must not affect the new attempt or continue the pipeline. Photos may retain downloaded cache bytes. |
| Local 4K, long duration | Monitor UI responsiveness and Instruments memory on a locally attachable device if available. Memory must not scale linearly with file size. Record export time and failures without assuming the cloud Mac can attach to the phone. |
| Low resolution/already HEVC | Some files may grow or stay equal. Exact negative/zero savings must display and Save must be disabled. Discard removes only the temporary copy. |
| Orientation/mirroring | Portrait, landscape left/right and front-camera samples. Aspect check alone cannot detect every rotation or mirror mistake; visually compare. |
| Audio | Stereo, mono and silent clips. Verify audio count and listen throughout. Multiple audio-track files are explicitly unsupported. Spatial audio/channel-layout fidelity is not automatically certified. |
| Unsupported media | Edited/trimmed, slow-motion, time-lapse, spatial and compositions should reject safely. Test cinematic and imported special formats for gaps in detection; do not assume all unsupported metadata is identifiable from PhotoKit subtypes. |
| Output verification failure | Mock tests cover this deterministically. On a development build, use synthetic invalid fixtures to test actual corrupt containers; never alter a personal original. A missing/empty/truncated/wrong-codec output must not be saved. |
| Cancellation by stage | Permission, cloud download, preparation, export, verification and ready-to-save discard. Confirm cancelled state, no save and eventual cleanup. Preparation/verification may finish quickly; exercise these with mocks as well. |
| Save transaction | Double tap Save; only one request. Cancellation is unavailable during save. Confirm no cleanup before Photos finishes. Revoke permission before Save to confirm readable failure. |
| Low storage | On a controlled test device, reduce available space using expendable test data. Test preflight rejection, download failure, mid-export disk-full, and save requiring another copy. No success claim from a preflight alone. Space can change at any time. |
| Incoming call/interruption | Receive a call during export. Record whether iOS only makes the scene inactive or backgrounds it. Inactive alone need not cancel; background must request cancellation. No automatic save or false success. |
| Lock/Home/app switch | Lock or background during cloud/export/verification. App requests cancellation, possibly completes cleanup only after resuming. It must not claim processing continues overnight. Background while ready-to-save may retain the temporary output until discard/save or restart. |
| Process termination | Force quit during export, reopen and check startup cleanup. Repeat during save: Photos may have committed despite no completion UI. A stored queue flags a mid-save item for a look rather than repeating it, but automatic exactly-once reconciliation is not implemented; inspect Photos before manually retrying. |
| Thermal pressure | Observe a naturally warm device during long processing; never deliberately overheat it. Record slowdowns, OS interruptions, failures and battery impact. No thermal throughput promise. |
| Playback after import | Play in Photos from beginning through end, seek around, listen, inspect HDR and rotation. Preview success is not proof that the imported representation plays correctly. |
| Metadata | Compare creation date, duration, codec, resolution, frame rate, location, HDR/color tags, audio channels, favorites, album membership, captions and edit history. Creation date, filename, location and favourite/hidden flags are deliberately copied at Photos level, and the file's own descriptive metadata is written into the copy; album membership, captions, keywords and ratings are not. Record all differences. |
| Copy changed after a run | With deleting on, edit or remove a copy in Photos after its run, then confirm the original is kept and the reason is shown, because the fresh look no longer matches the stored receipt. |
| Failed queue write | Make the queue file unwritable during a run. Confirm the run stops before it saves a copy or asks Photos to delete anything, and that a committed save is never repeated after its follow-up record cannot be written. |
| Original safety | Before/after compare original item, dimensions, duration, visual quality and edit state. With separate trusted export tooling, compare original resource hashes where practical. Check no item was moved to Recently Deleted and no original content changed. |
| Accessibility | Largest Dynamic Type, VoiceOver, landscape and increased contrast. Read all controls, sizes and errors; ensure text is not clipped and progress announces the current operation clearly. |
| Cleanup/privacy | After cancel/failure/save and next launch, inspect the app sandbox where development tooling permits. Only app-owned output is removed. Inspect console for absence of media paths, identifiers and content. Inspect the archive’s privacy manifest. |

## Evidence and pass criteria

Use a results sheet outside this repository if it contains personal information. For each case record observed facts, not “looks okay.” Store sanitized failures and exact reproduction steps in an issue or a future `docs/DEVICE_RESULTS.md`.

Phase 0 passes only when the iCloud retrieval → **smaller HEVC output** → verification → separate Photos save path works on the physical iPhone and the original is unchanged. HDR, special formats and background behavior each need their own result; passing SDR does not certify them. Pause expansion into batching until safety failures are understood and corrected.
