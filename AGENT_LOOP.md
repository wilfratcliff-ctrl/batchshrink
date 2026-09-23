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

It now also runs `scripts/swift-call-site-check.mjs`, added after the cloud builds found that
every compile error this project has ever produced was one of two mechanical mistakes. That
checker catches both without a compiler:

- **argument labels written out of declaration order** — it reported exactly the two
  `DeletionPolicyTests` errors the compiler later confirmed;
- **a bare optional parameter shadowing a non-optional stored property inside `init`** — it
  reported exactly the two `BatchViewModel` errors the compiler later confirmed.

It also covers the failure mode that has cost this project the most: a protocol change that leaves
a conformer behind. There are 8 protocols and 28 conformances here, 20 of them test doubles, and
that exact break happened in rounds 1, 3 and 4. Rule C checks every conformer against every
requirement; Rule D reports a declaration made twice in one scope.

It is still a scanner, not a compiler. It checks no types, no generics, no availability, no
argument counts, and nothing declared outside these files, so **a clean run is evidence and never
proof.** It resolved 618 of 3,076 call sites and skipped the rest rather than guess — though it
skipped no conformer at all — which is the trade that keeps it free of false positives: zero on
the two trees the cloud compiler verified green, and zero on the current tree. Rules C and D were
proved against injected mutations of the real tree in a temp directory, because no broken state
survives in git history.

`sync-native-sources.mjs` mirrors Swift under `VideoShrink/{Models,Services,Presentation}`
into the Expo pod. Any Swift edit in those folders requires `npm run sync:native` or the
check fails and EAS builds break. The mirrored copies are git-ignored, so they never appear
in a commit, but the check still has to pass.

## The real compile gate: EAS

The owner does not own a Mac, so `scripts/validate-mac.sh` is not a route anyone can take. The
route that does exist is an EAS cloud build, which runs on Apple hardware with Xcode:

```
npx eas-cli build --platform ios --profile verify-tests
```

That profile compiles the test target and then runs it on a simulator, printing two separate
banners in the log: `VIDEOSHRINK TEST TARGET COMPILE` and `VIDEOSHRINK TEST RUN`. **Read both.**
A green run banner is the only evidence in this project that a change is actually correct;
every gate above it is a pattern scan.

### Quota — read this before planning a round

**The account's free-plan iOS builds for September are exhausted.** The last successful build was
`5b7bd87f` on commit `7ec2d40`; an attempt on commit `7c11f26` was refused before it was created
with "This account has used its iOS builds from the Free plan this month, which will reset in 7
days (on Thu Oct 01 2026)." Nothing was queued and nothing was charged.

Consequences:

- **The EAS gate cannot run again until 1 October 2026**, unless the owner upgrades the plan.
  Until then, a round that changes Swift cannot be verified, and the honest thing to do is stop
  making Swift changes rather than stack more unverified work on top of verified work.
- Commit `7c11f26` is **unverified**. It is the fix for the four problems the first test run
  found, and it has never been compiled or tested.
- The route that costs no build minutes is the macOS CI job in `.github/workflows/ios-tests.yml`,
  which runs the same `scripts/verify-native-tests.mjs`. It needs a GitHub remote, which this
  repository does not have.

### The blocker is cleared — verification is now free and automatic

The repository now has a GitHub remote, and `.github/workflows/ios-tests.yml` runs
`scripts/verify-native-tests.mjs` on a free macOS runner on every push. **This is the gate to use,
not EAS.** It costs no build minutes and returns in about seven minutes.

First green run, 2026-09-23, commit `5d72357`:

```
===== VIDEOSHRINK TEST TARGET COMPILE ===== PASSED
===== VIDEOSHRINK TEST RUN ===== PASSED
     Executed 162 tests, with 0 failures (0 unexpected)
```

The whole suite is green for the first time. EAS is now only needed for actual app builds; its
free iOS minutes remain exhausted until 1 October.

**Working rule from here:** no Swift change is finished until a push has made CI green. `main` is
the verified branch; anything uncommitted is unverified, and `git status` is the honest answer to
"what is proven".

An EAS build compiles everything under `modules/videoshrink-native/ios/`, which includes
`VideoShrinkCore/` — the mirror of `VideoShrink/{Models,Services,Presentation}` produced by
`npm run sync:native`. That is the Swift this loop keeps changing, so **a round is not finished
until a cloud build has compiled it.** See `docs/VERIFICATION_HANDOFF.md`.

What a cloud build still does not do:

- it does not run the tests unless the `verify-tests` profile is used. Ordinary development and
  release profiles compile the app and nothing else, so a round that only ran the default profile
  has proved the app compiles and nothing more;
- prove any device behaviour. Actual deletion, audio sync, HDR appearance, interruption windows
  and iCloud retrieval need a real iPhone and `docs/PHYSICAL_DEVICE_TEST_PLAN.md`.

## Build log

| Date | Build | Commit | Profile | Result |
|------|-------|--------|---------|--------|
| 2026-09-23 | `6c39c009` | `dcd0695` | development-simulator | ERRORED, first real compile of the tree |
| 2026-09-23 | `9f83392c` | `082537a` | development-simulator | FINISHED, artifact produced |
| 2026-09-23 | `eb69125a` | `df6f128` | verify-tests | ERRORED, first compile of the 162-case test target |
| 2026-09-23 | `f4b4bcf6` | `1e6c6ba` | verify-tests | FINISHED, `** TEST BUILD SUCCEEDED **` |
| 2026-09-23 | `5b7bd87f` | `7ec2d40` | verify-tests | ERRORED, **tests ran for the first time**: 162 executed, 7 failed |

The first build's two errors, both in `BatchViewModel`'s initialiser: the init assigned the
stored monitor but then used the optional *parameter* for `onChange` and `start()`. Everything
else in three rounds of Swift compiled on the first try.

The test target's first compile found two errors, both in `DeletionPolicyTests.swift`: two calls
passed `evidence:` before `readBack:`, which `DeletionPolicy.decision`'s memberwise order does not
allow. Two errors across 162 cases, and only in the test target.

After that fix, `xcodebuild build-for-testing` reported `** TEST BUILD SUCCEEDED **`. **The whole
app and all 162 test cases now compile.** They have still never been run.

### First test run — 2026-09-23, build `5b7bd87f`

162 cases executed in 6.7 seconds on a simulator. **155 passed, 7 failed.**

| Suite | Tests | Failures |
|-------|-------|----------|
| BatchQueueTests | 12 | 0 |
| BatchTests | 70 | **7** |
| DeletionPolicyTests | 26 | 0 |
| DeviceConditionsTests | 2 | 0 |
| EligibilityTests | 12 | 0 |
| PipelineTests | 23 | 0 |
| RulesTests | 17 | 0 |

The seven failures, all in `VideoShrinkTests/BatchTests.swift`, recorded verbatim because they are
the next round's work:

1. `testACopyEditedInPhotosAfterTheRunKeepsItsOriginal` (lines 829, 831): the deletion outcome is
   `nil` where `Optional(.skipped("The copy changed after it was checked..."))` was expected, and a
   count is 0 where 1 was expected. The refusal is not being recorded.
2. `testARefreshDuringARunKeepsTheJobAndTheIdentityItStartedWith` (lines 1007, 1016, 1017): the
   reconciled listing came back `["a", "b"]` instead of `["a"]`, the batch timed out, and a
   completed count was 1 instead of 2. The running job was not carried as the test expects.
3. `testARefreshWithoutAnEarlierLibraryJustTakesTheNewListing` (line 951): one assertion is false.
4. `testBatchSavesSmallerCopiesAndSkipsOnesThatGrew` (line 207): a count is 0 where 1 was
   expected.

These are test failures against freshly written code, so the fault may be in either the test or
the code. Do not assume the test is right because an agent wrote it, and do not assume the code is
right because it compiles. Read both and decide from the behaviour that is actually intended.

## Ownership rule

Each agent owns a fixed file list for the round and edits nothing else. When a change is
needed outside the list, the agent reports it instead of making it. This is what stops four
agents from tearing each other's work apart in a codebase no one can compile.

## Keeping this file honest

**This backlog goes stale, and agents have already been misled by it.** In round 10 three
separate marketing agents correctly declined to tell users that HDR and ProRes videos are
refused — because the N12 row above still said those rules were dead. It had been fixed two
rounds earlier. Each agent trusted this file over the tree and wrote less than the app can
actually do, which is the same class of error as overclaiming, and just as damaging.

So: when a task depends on what the app currently does, **read the code, not the status column
here.** And when you close an item, update its row in the same commit that closes it.

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
| N6 | 0 | None of the round 1-3 Swift had ever been compiled | done, round 4: core compiles in EAS build `9f83392c` |
| N7 | 2 | `LibraryReconciling` workaround folded into `LibraryScanning` and the workaround deleted | done, round 3 |
| N8 | 1 | No test covered the reconciliation wiring | done, round 3 |
| N9 | 2 | `ThumbnailService` key index grew unbounded | done, round 3 |
| N10 | 2 | `LibraryChangeMonitor.stop()` is never called | documented as deliberate, round 3 |
| N11 | 1 | 162 XCTest cases had never been compiled or run | done, round 5: 162 compiled and executed, 155 pass |
| N12 | 1 | `AssetRules` refuses HDR and ProRes but nothing could set either trait | **done, rounds 6 and 7.** `VideoVerificationService` now reads the codec subtype and the transfer function where the media is readable, so HDR and ProRes originals ARE refused, in `AssetRules`' own words, and the refusal reaches the user as `PipelineError.unsupportedOriginal(reason:)` |
| N13 | 2 | `PhotoLibraryScanService.cancelled` is shared between `scan()` and `refreshListing()`, so a refresh can clear a cancel that just landed. Not user-visible today because the scan task is cancelled too | open |
| N14 | 3 | `BatchSelectionScreen.detail(_:)` has no caller. Pre-existing dead code | open |
| N15 | 3 | `withTaskCancellationHandler(operation:onCancel:)` is the pre-`isolation:` overload, deprecated in the iOS 18 SDK | open |
| N16 | 1 | Exactly-once save reconciliation (NEXT_PHASE): a save receipt is evidence, not proof the copy completed | open |
| N17 | 1 | The 162 cases compiled but had never executed | done, round 5: the `verify-tests` profile runs them on a simulator |
| N18 | 2 | `expo doctor` reports 1 failed check during every EAS setup. The build continues, so it is a warning, but a release should not ship past it unnoticed | open |
| N19 | 1 | Runtime behaviour is still entirely unproven even though it compiles: no screen has been rendered, no export has run, no queue file has been written | open |
| N20 | 0 | **7 of 162 tests failed.** One real bug — tapping Delete after the copy changed did nothing and said nothing — plus three faulty tests | **done.** Fixed in `7c11f26`, proven green by CI from `5d72357` onward |
| N21 | 0 | Prove the fixes turn the suite green | **done for the suite.** Green in CI since `5d72357`. The deletion path still needs a device run, which is N19 |

## Round log

| Round | Commit | Focus | Gates | Notes |
|-------|--------|-------|-------|-------|
| 0 | `10ab65f` | Baseline checkpoint before any agent work | all three PASS | 81 files, clean tree |
| 1 | see below | P0-1, P0-2, P0-3 and the P1-2 mechanism, by four parallel agents on disjoint file lists | all three PASS | 13 files, ~1890 insertions, 102 -> 145 XCTest cases |
| 2 | see below | N1, N2, N3, N4 and P1-4, by four parallel agents on disjoint file lists | all three PASS | 17 files, ~390 insertions |
| 3 | see below | N5, N7-N10, eligibility rules, a compile-risk audit and the Mac handoff | all three PASS | 13 files, 145 -> 162 XCTest cases |
| 4 | `082537a` | First cloud compile; fix the errors it found; move verification to EAS | EAS build FINISHED | core compiles; test gate added |
| 5 | `7c11f26` | Fix the seven failures from the first test run; add macOS CI; add a local Swift static checker | local gates PASS, **no build minutes** | the fixes are unverified |
| 6 | `e2a13a3` | HDR/ProRes refusal, exactly-once save reconciliation, accessibility, 162→224 tests, docs | CI: compile FAILED | one type error, caught by CI |
| 7 | `07526c4` | Close round 6's seams: the refusal reaches the user as itself; two reported defects fixed | CI: **green** | — |
| 8 | `0849dfd` | A false line in the start dialog; mid-save findings rendered; device readiness; 263 tests | CI: green | — |
| 9 | `81ab92c` | A scan that survives the library changing underneath it | CI: green | — |
| 10 | see below | First growth round: six marketing agents in parallel with five app agents | local gates PASS | six documents in `marketing/` |

### Round 10 — the app, and the business

Five agents worked the app: the mid-save finding is now rendered instead of left as a flat
question; the scan survives the library changing underneath it; a second coverage pass took the
suite to 264 cases; the first-run flow was audited against five questions a new user has; and
device readiness was swept (permission strings rewritten to match what the app does with iCloud
originals, privacy manifest verified against the APIs actually used, build 11 set, `expo-doctor`
now 21/21).

That audit found the worst single line in the product: the confirmation dialog before a batch
started said **"Your originals stay exactly where they are"** unconditionally, including when the
user had switched deletion on. It was the last thing anyone read before work began.

Six marketing agents produced the first business documents, in `marketing/`: a landing page with
its claims traced to evidence, an App Store listing with keyword reasoning, a social content
pack, a Reddit research and drafting pack, a ranked channel map, and a pricing decision. All of
them were required to mark each claim as verified, repo-sourced, or inferred, and none was allowed
to claim a result the app has not produced.

**The most useful thing that happened in this round was a failure.** Four of those marketing
agents read the stale N12 row above and correctly refused to say the app declines HDR and ProRes
videos — so they wrote copy that understated the product, and one of them hung a pricing gate on
the same wrong fact. A fifth agent caught it independently by reading the code. This is why the
section above exists.

### Round 5 detail

The first test run's seven failures were diagnosed as one real bug and three faulty tests.
The bug: tapping Delete after the copy changed did nothing and said nothing, because the
tap-time re-check emptied the candidate list and the function returned before recording a
reason. Refused candidates now carry the fresh look's own wording. The three tests were
corrected against intent, not against whichever side was written last — one used a 600-byte
"video" over 120 seconds, which the bitrate guard correctly rejects; one asserted that a
refresh reports nothing removed when a selected-but-vanished video legitimately is; one held
the transcoder and never released it for the second video.

Then the build minutes ran out, and rather than stack more unverified Swift the loop built the
two things that make the next verified build more likely to be green:

- `.github/workflows/ios-tests.yml`, which runs the same `scripts/verify-native-tests.mjs` on a
  free macOS runner. It needs a GitHub remote, which this repository does not have.
- `scripts/swift-call-site-check.mjs`, now part of `npm run validate:native`, which catches the
  two mechanical mistakes behind every compile error this project has produced.

### Round 4 detail

The owner has no Mac and uses Expo only, which made the loop's whole verification story wrong:
every agent report for three rounds had ended "unverified, needs a Mac". The correction is worth
more than any single code change in this round, because the feedback loop is what makes the
other rounds trustworthy.

- Two EAS builds were run against the real project. The first compiled the tree for the first
  time and found two genuine errors; the second finished and produced an artifact.
- The errors were both in `BatchViewModel`'s initialiser: the code assigned the stored
  `libraryChanges` property and then called `onChange` and `start()` on the optional *parameter*
  of the same name. A local non-optional name, plus a statement-form closure body so it cannot
  infer `Void?` where `Void` is required, fixed both.
- `docs/MAC_VALIDATION_HANDOFF.md` was replaced by `docs/VERIFICATION_HANDOFF.md`, which is
  EAS-first.
- A `verify-tests` EAS profile and `scripts/verify-native-tests.mjs` were added so the 162-case
  test target can be compiled on the builder. It is opt-in through `VIDEOSHRINK_VERIFY_TESTS=1`
  so no existing profile changes behaviour.

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
- `mac_handoff` wrote the first version of the verification handoff: the ordered commands, the
  ranked list of likely first failures derived from the round reports, and a symptom -> file ->
  commit triage table with the narrowest revert for each. Round 4 renamed it to
  `docs/VERIFICATION_HANDOFF.md` and repointed it at EAS, because the Mac it assumed does not
  exist.

### Round 3 integration decisions

- The parent fixed a hard compile failure in the test target: `QueueMockScanner` and
  `QueueMockHistory` in `BatchQueueTests.swift` were missing the new protocol requirements, which
  `copy_exclusion` correctly reported and could not fix. This is the third round running where a
  protocol change broke a mock outside the changing agent's file list; any further requirement
  added to `LibraryScanning` or `ShrinkHistoryStoring` must update the mocks in the same edit.
- The parent added the "Made by BatchShrink" row caption and corrected the "Select the N not yet
  shrunk" button, which had become inaccurate once copies were excluded from the count.
