# Agent improvement loop

This file is the loop's memory. A round of automated agents reads it first and updates it
last, so the work survives a context reset, a restart or a compaction.

## Gates that actually run on Windows

There is no Swift compiler, Xcode or XCTest runner on this machine. Three checks do run here:

```
npm run typecheck
npm run validate:native
node scripts/sync-native-sources.mjs --check
```

`npm run validate:native` is a source-pattern guardrail, not a compiler. It scans all
application Swift for forbidden patterns (`try!`, `as!`, `URLSession`, `value(forKey:)`,
`Data(contentsOf:)`, `WKWebView`, `PHAssetCollectionChangeRequest`) and asserts that Photos
deletion and change requests appear only in `PhotoLibraryService.swift`.

`sync-native-sources.mjs` mirrors Swift under `VideoShrink/{Models,Services,Presentation}`
into the Expo pod. Any Swift edit in those folders requires `npm run sync:native` or the
check fails and EAS builds break. The mirrored copies are git-ignored, so they never appear
in a commit, but the check still has to pass.

Everything Swift is unverified until `scripts/validate-mac.sh` runs on a Mac. Treat every
Swift change here as plausible, not proven.

## Ownership rule

Each agent owns a fixed file list for the round and edits nothing else. When a change is
needed outside the list, the agent reports it instead of making it. This is what stops four
agents from tearing each other's work apart in a codebase no one can compile.

## Backlog

Sourced from `docs/DEVELOPMENT_REVIEW.md`, which is the project's own review of record.

| ID | Priority | Item | Status |
|----|----------|------|--------|
| P0-1 | 0 | Persistence failure must block new Photos mutations; no unjournaled save or delete | done, round 1 |
| P0-2 | 0 | Persist copy identity, revalidate copy and original immediately before deletion, migrate old queues conservatively | done, round 1 |
| P0-3 | 0 | Verification must match its claim: all sample windows, decoded audio, imported copy compared to expectations | done, round 1 |
| P1-1 | 1 | Run XCTest on a Mac via `scripts/validate-mac.sh`; produce `DEVICE_RESULTS.md` | blocked, needs macOS |
| P1-2 | 1 | Photos change observer plus foreground authorization refresh | done, round 2 |
| P1-3 | 1 | Establish source-control checkpoints | done, commit `10ab65f` |
| P1-4 | 1 | Status documents conflict with implemented behaviour | done, round 2 |
| N1 | 0 | `LibraryChangeMonitor` is built and tested but nothing constructs it, so the library never actually reconciles | done, round 2 |
| N2 | 1 | Thumbnail cache never invalidated, so an edit in Photos shows the old picture | done, round 2 |
| N3 | 1 | `queueWarning` invisible on the screens a failed write can leave the run resting on | done, round 2 |
| N4 | 2 | A deletion candidate could be offered before its copy changed | done, round 2 |
| N5 | 1 | App-created copies excluded from bulk selection while staying re-processable by hand | half done, round 3: exclusion shipped, exactly-once save reconciliation still open |
| N6 | 0 | None of the round 1 Swift has ever been compiled; the first Mac run is the real test of all of it | blocked, needs macOS |
| N7 | 2 | `LibraryReconciling` workaround folded into `LibraryScanning` and the workaround deleted | done, round 3 |
| N8 | 1 | No test covered the reconciliation wiring | done, round 3 |
| N9 | 2 | `ThumbnailService` key index grew unbounded | done, round 3 |
| N10 | 2 | `LibraryChangeMonitor.stop()` is never called | documented as deliberate, round 3 |
| N11 | 1 | No test has ever run: 162 XCTest cases exist and zero have executed | blocked, needs macOS |
| N12 | 1 | `AssetRules` refuses HDR and ProRes but nothing can ever set either trait, so both rules are dead and an HDR original is still processed. `NEXT_PHASE.md` requires HDR exclusion. Needs codec/colour-tag detection where the media is readable, applied to both `Traits` call sites in the same round | open |
| N13 | 2 | `PhotoLibraryScanService.cancelled` is shared between `scan()` and `refreshListing()`, so a refresh can clear a cancel that just landed. Not user-visible today because the scan task is cancelled too | open |
| N14 | 3 | `BatchSelectionScreen.detail(_:)` has no caller. Pre-existing dead code | open |
| N15 | 3 | `withTaskCancellationHandler(operation:onCancel:)` is the pre-`isolation:` overload, deprecated in the iOS 18 SDK | open |
| N16 | 1 | Exactly-once save reconciliation (NEXT_PHASE): a save receipt is evidence, not proof the copy completed | open |

## Round log

| Round | Commit | Focus | Gates | Notes |
|-------|--------|-------|-------|-------|
| 0 | `10ab65f` | Baseline checkpoint before any agent work | all three PASS | 81 files, clean tree |
| 1 | see below | P0-1, P0-2, P0-3 and the P1-2 mechanism, by four parallel agents on disjoint file lists | all three PASS | 13 files, ~1890 insertions, 102 -> 145 XCTest cases |
| 2 | see below | N1, N2, N3, N4 and P1-4, by four parallel agents on disjoint file lists | all three PASS | 17 files, ~390 insertions |
| 3 | see below | N5, N7-N10, eligibility rules, a compile-risk audit and the Mac handoff | all three PASS | 13 files, 145 -> 162 XCTest cases |

### Round 1 detail

- `verification_integrity` rewrote `VideoVerificationService.swift`: every applicable sample
  window must decode rather than "at least one", short clips follow a stated policy instead of
  being skipped, audio is decoded rather than assumed from track duration, and the imported copy
  is compared against the output this run measured.
- `queue_durability` hardened `BatchViewModel.swift`: `persistQueue()` and `setState(_:for:)`
  return whether the record reached disk, and the save and delete boundaries refuse to touch
  Photos when it did not. A committed save is never re-run after a failed follow-up write.
- `copy_identity` added `DeletionEvidence` and `AssetSnapshot`, revalidation of both the copy and
  the original immediately before deletion, and a conservative migration: a queue written before
  this change carries no receipt and can never authorise a delete.
- `library_freshness` added `LibraryChangeMonitor.swift` plus pure reconciliation rules. The
  mechanism is built and tested but not yet constructed anywhere, which is N1.
- A fifth agent, `integration_round1`, then wired the four together. This mattered: `copy_identity`
  made the deletion gate stricter while nobody passed the new evidence in, so deletion had become
  silently dead code. The receipt now flows from read-back through the persisted queue into the
  gate, the flush re-checks before submitting, and the old unrevalidated delete call has no caller.

### Round 1 integration decisions

- `PhotoLibraryDeletionRevalidating` was folded into `PhotoLibraryServing` and deleted, because the
  integration agent could not reach that file and leaving both protocols declared the same three
  requirements twice.
- `PipelineTests.swift` gained additive mock stubs outside the integration agent's file list; the
  test target would not compile without them.
- The revalidation pass is synchronous and runs only from the three points that offer deletions,
  never from a view body, so it cannot fetch from PhotoKit on every view update.

### Round 2 detail

- `wire_change_monitor` closed N1: `BatchViewModel` now constructs the monitor, starts it, and on
  each report updates limited access, takes the permission path when access is gone, and applies
  a metadata-only reconciliation. `items` is never rewritten, so a run keeps the identity it
  started with. It also closed N4: the deletion look is refreshed at tap time, so the offered list
  can only shrink.
- `warning_visibility` closed N3 by adding one `QueueWarningNotice` and drawing it on the start,
  summary, selection, processing and recovery screens. It corrected the brief with evidence:
  `BatchFinishedScreen` already drew the warning, so it was left alone rather than duplicated.
- `thumbnail_invalidation` closed N2 by adding `ThumbnailService.invalidate(identifiers:)` and a
  `revision` key on `AssetThumbnail`.
- `docs_truth` closed P1-4 across 13 documents: the three kinds of claim are now separated, and
  the contradictions it found are listed in its report.

### Round 2 integration decisions

- The thumbnail work was built but unreachable, the same shape of gap as round 1's N1. The parent
  wired it: `BatchViewModel.apply(_:)` drops the cache and bumps `thumbnailRevision`, and the
  three `AssetThumbnail` call sites plus `BatchFinishedRow` carry that revision. Left unwired,
  N2 would have changed nothing on screen.
- `LibraryReconciling` is a deliberate workaround, not an oversight. `BatchViewModel` holds
  `any LibraryScanning`, so a protocol-extension default would have statically dispatched a full
  scan instead of the metadata-only listing. See N7 for the clean version.

### Round 3 detail

- `copy_exclusion` closed N5 and N7 and N8. Created copy identifiers are now recorded in the
  history store, excluded from automatic selection, and never merged into the shrink history
  because they are not originals that were shrunk. The `LibraryReconciling` workaround is gone;
  the two methods are now real requirements on `LibraryScanning`. Five tests cover the exclusion,
  the deliberate re-run path and the reconciliation wiring, and the monitor became injectable so
  the change path could be driven from a test at all.
- `eligibility_rules` added cinematic and shared/restricted detection and reasons, plus ProRes and
  HDR reasons that nothing can reach yet (N12). It was explicit about that rather than shipping a
  rule that quietly never fires. It corrected the brief on API names: `PHAssetMediaSubtype` has
  `videoCinematic`, and `PHAsset.mediaCharacteristics` no longer exists.
- `compile_risk_audit` found no compile-blocking defect in the eight files it read, having swept
  every conformer against its protocol and every memberwise call site for argument order. It
  bounded the thumbnail key index (N9) and documented the monitor's lifecycle as deliberate
  (N10). Its best find was a real drift: `PhotoLibraryService.retrieve` never passed the new
  cinematic or shared traits, so the single-video flow - where retrieval is the only eligibility
  gate - would have processed a cinematic or shared-album video. Fixed.
- `mac_handoff` wrote `docs/MAC_VALIDATION_HANDOFF.md`: the ordered commands, the ranked list of
  likely first failures derived from the round reports, and a symptom -> file -> commit triage
  table with the narrowest revert for each.

### Round 3 integration decisions

- The parent fixed a hard compile failure in the test target: `QueueMockScanner` and
  `QueueMockHistory` in `BatchQueueTests.swift` were missing the new protocol requirements, which
  `copy_exclusion` correctly reported and could not fix. This is the third round running where a
  protocol change broke a mock outside the changing agent's file list; any further requirement
  added to `LibraryScanning` or `ShrinkHistoryStoring` must update the mocks in the same edit.
- The parent added the "Made by BatchShrink" row caption and corrected the "Select the N not yet
  shrunk" button, which had become inaccurate once copies were excluded from the count.
