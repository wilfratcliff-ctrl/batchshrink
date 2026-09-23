# From one-video proof to a safe batch product

Start only after the physical acceptance test passes. Expand supported media and failure recovery before monetization or library-wide operations. Deletion is not future design work any more: an opt-in implementation has been in the source since build 7, and round 1 hardened its gate. The deletion section below is design intent for the product version, not a statement that nothing exists.

**Status.** Four states, kept apart throughout this document and never blurred into one another:
historical (a past build), implemented source (in the tree and compiled), observed (it ran, with
evidence named) and still-not-observed (the app's runtime behaviour).

- **Historical (build 5):** the library scan, the batch selection screen, the queue with a
  measured time estimate, quality options, thumbnails, the on-device history of completed videos
  and a durable queue file compiled into build 5 and described in
  [BATCH_PHASE.md](BATCH_PHASE.md). The durable queue is reconciled on launch: in-flight items
  wait again and mid-save items are flagged for the user rather than repeated.
- **Historical (build 7):** opt-in deletion with two modes, the `DeletionPolicy` gate, persisted
  deletion intent and the sampled verification path compiled into build 7.
- **Implemented source (rounds 1 to 5, in the tree at `5d72357`; compiled, and its tests pass):**
  deletion requires a stored original-to-copy receipt and revalidates both assets immediately
  before Photos is asked; a failed queue write stops a run before it touches Photos; verification
  requires every sample window to decode, decodes audio rather than trusting track duration, and
  compares the imported copy against the output the run measured; a Photos change monitor is
  constructed by `BatchViewModel` and reconciles the listing after an outside edit (N1, closed in
  round 2, with tests for the wiring added in round 3).
- **Observed (2026-09-23):** the 162 XCTest cases compile and pass in CI. Run `35852961091` at
  commit `5d72357` reported `** TEST BUILD SUCCEEDED **` and
  `Executed 162 tests, with 0 failures (0 unexpected)`. That covers the app's pure logic against
  injected fakes, and nothing beyond it.
- **Still not observed:** the app has never actually run. No screen has been rendered, no video
  has been exported, no original has been deleted and no queue file has been written on a device.
  `docs/PHYSICAL_DEVICE_TEST_PLAN.md` remains unexecuted, and build 10 is still the last build
  known to have reached testers.

Open: exactly-once save reconciliation, a richer job store, purchases and background processing.
The change monitor is wired now (rounds 2 and 3); what is unproven there is how the reconciliation
behaves against a real library.

The final product will use Expo. After the native proof, follow [EXPO_INTEGRATION.md](EXPO_INTEGRATION.md): retain the Swift media engine, wrap it in a local Expo module, and replace the SwiftUI harness with the product UI. Re-run the full safety matrix across that bridge.

## Library scanning and filtering

Use PhotoKit fetches for metadata and a `PHPhotoLibraryChangeObserver` for changes. Respect limited access as the actual accessible library; never label that subset “your entire library.” Paginate work, avoid downloading everything merely to scan, and handle revoked authorization or assets removed outside the app.

Round 1 (commit `559f693`) built `LibraryChangeMonitor` and the pure reconciliation rules but constructed the monitor nowhere, so a library edited outside the app still went stale. Round 2 wired it: `BatchViewModel` constructs and starts the monitor and applies a metadata-only reconciliation on each report, and round 3 added tests for that wiring. Both are closed (N1 and N8 in `AGENT_LOOP.md`) and the code compiles with those tests passing at `5d72357`; whether the reconciliation behaves as intended against a real library is still a device question.

Define eligibility explicitly: ordinary video versus adjusted, slow-motion, time-lapse, cinematic, HDR, ProRes, spatial/MV-HEVC, shared or otherwise restricted resources. Test each separately. Live Photos contain paired still/video resources and must not be treated as an ordinary movie replacement. Exclude them until there is a tested preservation design. Spatial and cinematic semantics may not survive a flat HEVC export.

## Savings estimates

PhotoKit metadata does not provide a supported universal original byte-size field. Do not use undocumented KVC properties. Distinguish measured bytes, bitrate-based estimates and unknown size. An AVAsset's estimated bitrate is not an exact container size. Sampling must state confidence/range and its download/energy cost. Already-HEVC footage may gain little or grow; skip ineffective results.

The actual cloud-space outcome includes Photos/iCloud behavior, retained originals and Recently Deleted retention, not just output file bytes. Present potential versus confirmed changes separately. Do not promise to lower an iCloud subscription tier from estimated media ratios.

## Persistent queue and recovery

Introduce a durable local store for job IDs, source identifiers/resource identity, policy version, expected metadata, output location, verification evidence and Photos creation receipts. No personal metadata in diagnostic logs. Persist transitions atomically around download, export, verification, save request and save confirmation. Protect files and exclude regenerable media from backup.

Start with one encoder at a time. Bound disk usage and reserve headroom; adapt to power and thermal state. AVFoundation export is not assumed resumable at an arbitrary frame—checkpoint between complete files and restart a partial export after cleanup. On relaunch reconcile partial files and jobs, permission changes, removed assets and Photos operations that may have committed before a crash. Exactly-once saving needs a deliberate idempotency/reconciliation strategy; merely retrying can create duplicates.

Round 1 (commit `559f693`; in the tree and compiled at `5d72357`) implements part of this: the queue records a versioned receipt naming the created copy and what both assets looked like when it was checked, and a queue write that fails now blocks the next Photos mutation instead of being ignored. Exactly-once save reconciliation is still open.

## Duplicate and identity handling

Record relationships between original and newly created Photos items. Avoid reprocessing app-created copies. A Photos local identifier is useful locally but is not a universal stable cross-device content hash. Any hashing of source/output data must stream bytes and consider battery/download costs. Handle separately imported duplicates, edited variants, multiple resource representations and shared-library permissions deliberately. Do not merge user memories based only on timestamps and dimensions.

Round 1 (commit `559f693`; in the tree and compiled at `5d72357`) records the original-to-copy relationship in the deletion receipt. Round 3 shipped the rest of N5: app-created copies are recorded in the history store and kept out of bulk selection, while individual rows can still be chosen deliberately. What remains of N5 is exactly-once save reconciliation.

## Verification records and quality

Store measured bytes, codec, duration, video/audio properties, display transform, verification algorithm/version, save result and created asset identifier. Strengthen Phase 0’s first-frame check with sampled or full decoding, end-of-file checks, audio decode/sync validation and playback of the asset returned by Photos after import. Compare color/HDR metadata, orientation/mirroring, frame rate and relevant descriptive metadata. Keep user-visible preview and explain intentional quality changes.

Round 1 (commit `559f693`; in the tree and compiled at `5d72357`) implements part of this: every applicable sample window must decode, audio is decoded rather than inferred from track duration, and the imported copy is compared against the output the run measured. Full-file decode, audio sync, orientation and HDR fidelity still need a device.

A successful local file export is not proof of Photos import durability or completed iCloud sync. Define what evidence is sufficient for each claim. Do not promise that an app can verify every aspect of iCloud replication from a PhotoKit success callback.

## User-confirmed deletion

**Status (build 7, historical):** a first implementation compiled. Deleting is off by default,
applies to batch runs only, and offers two modes: after each confirmed copy, or at the end after a
review. One gate, `DeletionPolicy`, requires a saved, smaller, verified copy that Photos handed
back; anything less keeps the original and says why. Intent is persisted before each delete, so an
interrupted one comes back `uncertain` rather than being retried. Photos' Recently Deleted window
is stated in the interface wherever the choice is offered.

**Status (implemented source, round 1; in the tree and compiled at `5d72357`, with the suite
green, but never run):** the gate is stricter now. A run records
a receipt naming the copy Photos created, and what both assets looked like when that copy was
checked. Immediately before Photos is asked, both assets are looked up again and the delete is
refused unless the fresh look matches the receipt. A receipt that is missing, stale or written by
an older algorithm can never authorise a delete, so a queue written before the change still
decodes and keeps every original. Deletion was briefly dead code while the stricter gate and its
caller were developed separately; an integration pass rewired the receipt from read-back through
the persisted queue into the gate, and the old unrevalidated call now has no caller. That rewiring
compiles and is covered by the passing suite, but it has never run against a real library.

Still open before this is a product feature rather than a prototype: comparing quality and
metadata differences in the review step, designing recovery for an interrupted delete beyond a
flag, and testing every interruption between save and removal on a device. There is no bulk
"delete everything" action and no permanent deletion, and the one-video flow never deletes.

## StoreKit and commercial release

Only after the core experience is trustworthy, define a purchase model and add StoreKit 2 with sandbox/StoreKit Configuration tests, verified transactions, restore/current entitlements, refunds/revocations and interrupted purchases. Keep privacy-sensitive processing independent of a marketing backend. No pricing, subscriptions or account system has been selected in this phase.

Before App Review: provide a truthful privacy policy and App Privacy answers, keep required-reason manifests aligned with actual APIs, justify Photos access, respect limited authorization, include clear compression-loss and storage claims, and document any implemented background mode. Test on all supported devices/OS versions. Accessibility, localization, energy use and failure recovery are release requirements. Confirm App Store requirements and any payment rules from current Apple sources when that phase begins.

## Suggested milestones

Written while the batch was still future work. Since then the durable queue has shipped (build 5) and opt-in deletion has shipped (build 7); the reliability rounds that followed are in the tree at `5d72357`, compiled and with the 162-case suite passing in CI. None of it is device-proven: crash-safe save reconciliation and the device acceptance run are still open. See the status block at the top of this document.

1. Compile, run tests and pass physical Phase 0 acceptance; retain sanitized evidence.
2. Establish a supported-format matrix, improve verification and measure compression/energy tradeoffs.
3. Build a persistent queue for a small user-selected batch, with crash-safe save reconciliation.
4. Run the background/overnight spike and expose only the behavior it proves.
5. Separately review safe deletion, purchases and commercial App Review readiness.
