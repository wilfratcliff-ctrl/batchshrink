# From one-video proof to a safe batch product

Start only after the physical acceptance test passes. Expand supported media and failure recovery before monetization or library-wide operations. The prototype contains no deletion code; deletion below is future design work only.

**Status (build 5):** the library scan, the batch selection screen, the queue with a measured
time estimate, quality options, thumbnails, the on-device history of completed videos and a
durable queue file are implemented and described in [BATCH_PHASE.md](BATCH_PHASE.md). The
durable queue is reconciled on launch: in-flight items wait again and mid-save items are
flagged for the user rather than repeated. Exactly-once save reconciliation, observable
library changes and a richer job store (expected metadata, verification evidence, receipts)
remain open. Verification now samples three points in each copy, checks that audio is present
when the original had sound, and reads every saved copy back from Photos; the batch also stops
itself when iOS reports a critical thermal state. Deletion, purchases and background processing
are untouched.

The final product will use Expo. After the native proof, follow [EXPO_INTEGRATION.md](EXPO_INTEGRATION.md): retain the Swift media engine, wrap it in a local Expo module, and replace the SwiftUI harness with the product UI. Re-run the full safety matrix across that bridge.

## Library scanning and filtering

Use PhotoKit fetches for metadata and a `PHPhotoLibraryChangeObserver` for changes. Respect limited access as the actual accessible library; never label that subset “your entire library.” Paginate work, avoid downloading everything merely to scan, and handle revoked authorization or assets removed outside the app.

Define eligibility explicitly: ordinary video versus adjusted, slow-motion, time-lapse, cinematic, HDR, ProRes, spatial/MV-HEVC, shared or otherwise restricted resources. Test each separately. Live Photos contain paired still/video resources and must not be treated as an ordinary movie replacement. Exclude them until there is a tested preservation design. Spatial and cinematic semantics may not survive a flat HEVC export.

## Savings estimates

PhotoKit metadata does not provide a supported universal original byte-size field. Do not use undocumented KVC properties. Distinguish measured bytes, bitrate-based estimates and unknown size. An AVAsset's estimated bitrate is not an exact container size. Sampling must state confidence/range and its download/energy cost. Already-HEVC footage may gain little or grow; skip ineffective results.

The actual cloud-space outcome includes Photos/iCloud behavior, retained originals and Recently Deleted retention, not just output file bytes. Present potential versus confirmed changes separately. Do not promise to lower an iCloud subscription tier from estimated media ratios.

## Persistent queue and recovery

Introduce a durable local store for job IDs, source identifiers/resource identity, policy version, expected metadata, output location, verification evidence and Photos creation receipts. No personal metadata in diagnostic logs. Persist transitions atomically around download, export, verification, save request and save confirmation. Protect files and exclude regenerable media from backup.

Start with one encoder at a time. Bound disk usage and reserve headroom; adapt to power and thermal state. AVFoundation export is not assumed resumable at an arbitrary frame—checkpoint between complete files and restart a partial export after cleanup. On relaunch reconcile partial files and jobs, permission changes, removed assets and Photos operations that may have committed before a crash. Exactly-once saving needs a deliberate idempotency/reconciliation strategy; merely retrying can create duplicates.

## Duplicate and identity handling

Record relationships between original and newly created Photos items. Avoid reprocessing app-created copies. A Photos local identifier is useful locally but is not a universal stable cross-device content hash. Any hashing of source/output data must stream bytes and consider battery/download costs. Handle separately imported duplicates, edited variants, multiple resource representations and shared-library permissions deliberately. Do not merge user memories based only on timestamps and dimensions.

## Verification records and quality

Store measured bytes, codec, duration, video/audio properties, display transform, verification algorithm/version, save result and created asset identifier. Strengthen Phase 0’s first-frame check with sampled or full decoding, end-of-file checks, audio decode/sync validation and playback of the asset returned by Photos after import. Compare color/HDR metadata, orientation/mirroring, frame rate and relevant descriptive metadata. Keep user-visible preview and explain intentional quality changes.

A successful local file export is not proof of Photos import durability or completed iCloud sync. Define what evidence is sufficient for each claim. Do not promise that an app can verify every aspect of iCloud replication from a PhotoKit success callback.

## User-confirmed deletion

**Status (build 7):** a first implementation exists. Deleting is off by default, applies to batch
runs only, and offers two modes: after each confirmed copy, or at the end after a review. One gate,
`DeletionPolicy`, requires a saved, smaller, verified copy that Photos handed back; anything less
keeps the original and says why. Intent is persisted before each delete, so an interrupted one
comes back `uncertain` rather than being retried. Photos' Recently Deleted window is stated in the
interface wherever the choice is offered.

Still open before this is a product feature rather than a prototype: verifying that the source has
not changed since verification, comparing quality and metadata differences in the review step,
designing recovery for an interrupted delete beyond a flag, and testing every interruption between
save and removal on a device. There is no bulk "delete everything" action and no permanent
deletion, and the one-video flow never deletes.

## StoreKit and commercial release

Only after the core experience is trustworthy, define a purchase model and add StoreKit 2 with sandbox/StoreKit Configuration tests, verified transactions, restore/current entitlements, refunds/revocations and interrupted purchases. Keep privacy-sensitive processing independent of a marketing backend. No pricing, subscriptions or account system has been selected in this phase.

Before App Review: provide a truthful privacy policy and App Privacy answers, keep required-reason manifests aligned with actual APIs, justify Photos access, respect limited authorization, include clear compression-loss and storage claims, and document any implemented background mode. Test on all supported devices/OS versions. Accessibility, localization, energy use and failure recovery are release requirements. Confirm App Store requirements and any payment rules from current Apple sources when that phase begins.

## Suggested milestones

1. Compile, run tests and pass physical Phase 0 acceptance; retain sanitized evidence.
2. Establish a supported-format matrix, improve verification and measure compression/energy tradeoffs.
3. Build a persistent queue for a small user-selected batch, with crash-safe save reconciliation.
4. Run the background/overnight spike and expose only the behavior it proves.
5. Separately review safe deletion, purchases and commercial App Review readiness.
