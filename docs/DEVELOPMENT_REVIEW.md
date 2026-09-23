# Development decision — 21 September 2026

The next milestone is a reliability release focused on safe saves, deletion and recovery. Keep the current SwiftUI interface inside the Expo wrapper. Finish this milestone before purchases, broader media support or background processing.

## Evidence and current state

- `RELEASE_10.md` records a successful production EAS build and a submission reference for 0.1.0 (10). This review did not independently check App Store Connect processing or tester availability.
- Earlier project conversation includes the user's report that an earlier build was sent to family, and feedback about repeated deletion prompts. This is real usage feedback, but not a completed device acceptance matrix.
- Implemented: library scan, selection/previews, quality options, sequential processing, durable queue, save read-back, opt-in grouped deletion, screen-awake control, and the mint/lilac redesign with onboarding.
- Re-run in this review: repository guardrails PASS (36 application Swift files, 102 XCTest cases present); TypeScript PASS; native synchronization PASS (35 shared Swift files plus privacy manifest).
- These checks do not execute Swift. No XCTest execution or comprehensive build-10 device results were found in the reviewed evidence.
- Git has no commits or configured remote. The current source cannot be tied to a release through a commit SHA.
- README, NEXT_PHASE, VALIDATION and the physical test plan contain historical statements that conflict with implemented behavior and the build-10 release record. Examples include no deletion, no builds, no idle-timer override, and metadata copying limited to creation date.

Findings below are source-review findings, not device reproductions.

## Priority 0: durable evidence before Photos mutations

`BatchViewModel.persistQueue()` catches write failures and only displays a warning. `flushDeletions()` calls it and proceeds to `photos.deleteOriginals()` even if deletion intent was not saved. Saving a new copy likewise proceeds after a failed transition write. A crash can therefore leave a stale queue that does not describe a Photos operation that was already attempted.

Make persistence failure explicit at save/delete boundaries. Pause before submitting a new Photos mutation when the required checkpoint cannot be written; retain recoverable evidence when Photos has already accepted a transaction. Handle queue clearing failures visibly too.

Acceptance: inject write failures before save, before deletion and after transaction completion; ensure no unjournaled operation is newly submitted, no ambiguous operation is automatically repeated, and relaunch preserves an actionable recovery state.

## Priority 0: retain copy identity and revalidate deletion

The created asset identifier is returned by `PhotoLibraryService.save`, used for an immediate read-back, then discarded. `BatchQueueRecord.Item` stores the original identifier and a read-back enum, but no copy identifier or expected metadata. `restoreQueue()` restores the historical confirmation, and `deleteOriginalsNow()` can use it without looking up the copy again.

Persist an original-to-copy relationship, verification evidence/version and sufficient source identity to detect changes. Immediately before submitting deletion, fetch the copy and original again, verify the expected copy and reject changed, missing or inaccessible assets. A cached confirmation is insufficient. Recheck queued deletion candidates at flush time, not only when they enter the group. Preserve ambiguous crash windows for explicit reconciliation; a receipt alone does not guarantee exactly-once saving.

Apple documents that the [creation placeholder has the new asset's local identifier](https://developer.apple.com/documentation/photos/phobjectplaceholder), which can be used to fetch that asset after creation completes.

Acceptance: remove or edit a copy in Photos after a run, change an original after compression, revoke access, and restore an old queue. Each case must keep the original when evidence is missing or stale. Migrate existing queues conservatively: old records without copy identity must not authorize deletion.

## Priority 0: make verification match its stated guarantee

`VideoVerificationService.decodeSamples` tries three positions but accepts `decoded > 0`; two failed sample windows can still pass. `confirmReadBack` calls `inspect`, which checks container/track metadata but does not compare with the expected output or decode samples. Audio verification checks track duration, not decoded audio or sync.

Require every applicable sample window to succeed, with an explicit policy for very short clips. Verify the imported copy against persisted expectations and sample its media. Keep audio/HDR claims limited to the evidence actually collected.

Acceptance: fixtures with failed middle/end samples, mismatched imported properties, missing audio and short valid clips. Device playback must additionally cover audio sync, orientation and HDR appearance.

## Priority 1: execution and device evidence

Run the existing XCTest suite on a Mac using `scripts/validate-mac.sh` with a simulator UDID. Fix failures and add regressions for the cases above. Preserve the xcresult and toolchain version. A signed EAS archive is not an XCTest run.

Create a sanitized `DEVICE_RESULTS.md` when tests actually run. Exercise build 10 as the UI baseline with originals retained; validate the corrected build separately with expendable clips before enabling deletion in wider testing. Record:

1. Local SDR, portrait, silent and already-compressed clips.
2. Confirmed iCloud retrieval, loss of connectivity, limited/denied access.
3. HDR appearance, audio sync and playback near the end of the imported copy.
4. Pause/lock/force quit during export, save, read-back and deletion.
5. Grouped deletion counts (including five and seven items), cancellation of the system prompt, and both deletion modes.
6. Backgrounding during an accepted save: its completion must not trigger a new deletion while paused/backgrounded. The current `queueDeletion` threshold path needs a regression for this boundary.
7. Onboarding/relaunch, large text, VoiceOver, Reduce Motion, small screens and landscape.

Any next upload must use build 11 or later. No new build or submission was initiated by this review.

## Priority 1: library freshness and duplicate prevention

Add a [Photos change observer](https://developer.apple.com/documentation/photos/phphotolibrarychangeobserver) and foreground authorization refresh. Apple specifies that observer notifications can arrive on an arbitrary queue; update UI state on the main actor. Reconcile selection and thumbnails without silently changing an active job's identity.

History currently records original identifiers only. Use persisted copy relationships to keep app-created copies out of automatic bulk selection while supporting deliberate reprocessing. Test external edits/deletions, changed limited access and new copies appearing during a run.

## Development hygiene and later milestones

- Establish the first local source-control checkpoint after reviewing ignored files/secrets; separately configure a private remote when its destination is chosen. Do not label current files as an exact build-10 snapshot without comparing the uploaded source.
- Bring the status documents and device plan up to date. Distinguish historical entries, implemented behavior, compiled builds and observed test results.
- Keep SwiftUI for the present product. The older proposal to replace it with a React Native interface needs a concrete product benefit before spending time on that migration.
- After reliability acceptance, finish icon/store assets, privacy/support pages and truthful storage/quality copy. Then select and implement the purchase model, including entitlement restoration and interrupted transactions.
- Keep photo/RAW compression, broad special-format support and background/overnight processing as separate later milestones. The existing foreground screen-awake option already addresses part of the user's unattended-batch request.

The first implementation task should be persistence-gated Photos operations, followed by durable copy receipts and fresh deletion verification. Device testing can begin on the current UI while these fixes are developed.
