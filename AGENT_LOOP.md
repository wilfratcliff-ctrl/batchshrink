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
proof.** It order-checked 1,776 of 5,673 call sites and skipped the rest rather than guess —
though it skipped no conformer at all — which is the trade that keeps it free of false positives:
zero on the two trees the cloud compiler verified green, and zero on the current tree. Rules C and
D were proved against injected mutations of the real tree in a temp directory, because no broken
state survives in git history.

As of round 18 it reads **four** trees: `VideoShrink/`, `VideoShrinkTests/`, `VideoShrinkUITests/`
and the Expo bridge directory `modules/videoshrink-native/ios/` (excluding the generated
`VideoShrinkCore/` mirror, which is named in the output so the file count reconciles). Reading the
bridge files was not enough on its own: Rule A originally resolved a call only against
declarations in the same file, and the bridge files declare almost nothing — every call in them
constructs a type declared in `VideoShrink/`. So Rule A now falls back to the rest of the tree
when the call's own file declares nothing of that name, for calls that write at least one
argument label. That restriction is load-bearing rather than an approximation: an unlabelled call
cannot break the ordering rule, and without it a framework call such as Expo's `View(_:)` would
resolve to the same-named helper `View` extension this project declares. The step is additive:
no call site the old scan judged stopped being judged, and 715 new ones are judged now. The counts
move whenever a file is added, so read the current run's own numbers rather than these.

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

### The gate is blocked again: the account's Actions minutes are spent, and reset on 1 October

On 2026-09-23, a few hours after the three-job workflow above went green on two of its three jobs,
every job stopped starting. The evidence, in the order it was gathered:

- run `35885102232` (commit `9d0e745`, a one-line test-name fix) reported **failure for all
  three jobs about nine seconds after it was created**, with `runner_name` empty and `steps`
  empty; there is no log to fetch, and the API returns 404 for the job log blob;
- re-running the failed jobs (`run_attempt` 2) reproduced it exactly;
- GitHub's status API said **"All Systems Operational"** at the same moment, so it is not a
  platform outage;
- a throwaway `ubuntu-latest` job was pushed, dispatched and observed: it also failed with no
  runner, so it is **not** a macOS-only quota. The probe then deleted itself;
- **and then the account's own billing notice said it outright:** *"You have used 100% of the
  Actions minutes included for the wilfratcliff-ctrl account. Your plan includes 2,000 Actions
  minutes per month at no extra cost. You have used 100% so far this billing cycle. 2,000 min
  used / 2,000 min included... usage will reset in 8 days on October 01, 2026."* A $0 budget for
  Actions blocks further usage until then, so nothing is being charged and nothing will run.

That last line is the one that matters for planning, and the arithmetic behind it is worth
keeping because it is what bit first: the 2,000 minutes are a **single pool shared by every
runner**, and macOS runners draw from it at **ten minutes per minute**. The three-job workflow
costs roughly `7 + 12 + 6` macOS minutes per push, so about **250 pool minutes**, and the pool
holds about **eight pushes a month**. This project pushes far more often than that. The workflow
that made the project verifiable, at this price, is also what used it up.

**What this means for a round, until it is resolved.**

- **Nothing that needs macOS can be verified.** The local gates still run on Windows and are
  still worth running, but they are pattern scans.
- **Do not stack unverified Swift on top of unverified Swift without saying so.** The rule from
  round 5 applies again, and the honest answer to "what is proven" is a commit, not a wish.
- The last states that were actually seen: `31b6245` had job 1 and job 2 green. `780f14f` had
  job 3 green — **the first observation of a rendered screen in this project** — and job 1 red on
  a test-only typo, which `9d0e745` fixes without being verified. Everything after `31b6245` is
  unverified, and the accessibility wave is unverified.

**The options, for whoever reads this next.** Make the repository public, which removes the
private-repository minute cost entirely and is by far the cheapest fix; buy minutes; or cut the
workflow down so one push costs about one macOS job instead of three. That last one is a real
trade — the three jobs answer three different questions, and job 2 is the only thing that
compiles the Expo app — so it should be a decision, not a silent edit. Whichever it is, the
arithmetic above is the thing to decide against.

**What a round should do until 1 October.** The local gates still run and are still worth
running. Beyond that, two things are worth more than more Swift: documentation and the record,
because they are verifiable on Windows; and read-only review of the Swift already on `main`,
because that is the one part of this tree nobody can compile. A round that adds Swift before
then should say plainly, in its own report and in this file, that it did so unverified.

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

## How a round should be structured

Seventeen rounds is enough evidence to say what works. This is the shape to keep.

**Four or five agents, not a swarm.** Throughput here is capped by *verification*, not headcount:
every change is unverified until CI runs, and CI is serial. Ten agents produce ten times the
unverified change, which is merge risk rather than progress. Useful parallelism is also bounded by
the number of genuinely disjoint file sets, which for this app is about five.

**Give every agent an explicit, exclusive file list**, and tell it to edit nothing outside it and
to *report* any change it needs elsewhere. This is the single rule that makes parallel work safe,
and the rounds that suffered were the rounds where a change needed a file its author did not own.

**Expect a seam every round.** Work that is "built but not wired" has happened in almost every
round: a mechanism nobody constructs, a rule nothing reaches, a value nobody persists. Budget one
integration pass per round, by the parent, and look for the seam explicitly rather than hoping.

**Weight rounds toward read-only audits.** Two audits traced what a *user* meets — the first sixty
seconds, and one video's real journey — and found roughly fourteen real defects between them while
300-plus tests were green. That is a far better yield per agent than more feature work. Static
checks and tests tell you the code agrees with itself; only tracing a path tells you what the user
meets. Audit a specific moment, not a file.

**Any round that changes a protocol updates every conformer in the same round**, test doubles
included. Three separate rounds stranded a conformer in a file the changing agent did not own.
`scripts/swift-call-site-check.mjs` exists to catch that, and it is not a substitute for looking.

**Nothing is done until the cloud gate is green.** The local gates are pattern scans. A clean run
is evidence, never proof.

**Write the lesson down.** Fresh agent windows are cheap and carry no institutional memory — the
same `@MainActor` default-argument trap was solved once, documented, and then repeated. Anything a
future round needs to know belongs in this file, in a comment beside the code, or in a test.

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
| N13 | 2 | `PhotoLibraryScanService.cancelled` was shared between `scan()` and `refreshListing()` | **done, round 6.** The flag is `scanCancelled` and belongs to the scan alone. Note the sequel: it then leaked into the pre-flight, which read a stop flag only a new scan clears, so a stop-then-run would have silently done nothing — found and fixed in round 13 |
| N14 | 3 | `BatchSelectionScreen.detail(_:)` had no caller | **done, round 6.** Removed. This row was stale for seven rounds and is exactly the kind of thing the warning above is about |
| N15 | 3 | `withTaskCancellationHandler(operation:onCancel:)` was the pre-`isolation:` overload | **done, round 7.** Migrated with `isolation: #isolation` named explicitly |
| N16 | 1 | Exactly-once save reconciliation: a save receipt is evidence, not proof the copy completed | **done, rounds 6 and 16.** A restored mid-save record now looks for the copy it recorded rather than only flagging a question, and a save Photos was asked for but did not confirm is never a clean failure. What is still owed is a device result, which is N19 |
| N17 | 1 | The 162 cases compiled but had never executed | done, round 5: the `verify-tests` profile runs them on a simulator |
| N18 | 2 | `expo doctor` failed one check during every EAS setup | **done, round 8.** Two patch-level packages were behind; `expo-doctor` now reports 21/21. This row sat stale for seven rounds, which is the warning above in miniature |
| N19 | 1 | Runtime behaviour is still unproven even though it compiles: no export has run, no original has been deleted, no queue file has been written, and nothing has run on a device | **partly closed, round 18.** A screen *has* now been rendered - the launch job on `780f14f` built the standalone app, installed it on a simulator and drove `VideoShrinkUITests` through the introduction and one navigation. That is the first observation of the app doing anything, and it is one launch on a simulator with no Photos library. Everything else in this row stands: nothing has been exported, deleted, queued or run on a phone, and the device acceptance test is still the gate for all of it. See N40 |
| N20 | 0 | **7 of 162 tests failed.** One real bug — tapping Delete after the copy changed did nothing and said nothing — plus three faulty tests | **done.** Fixed in `7c11f26`, proven green by CI from `5d72357` onward |
| N21 | 0 | Prove the fixes turn the suite green | **done for the suite.** Green in CI since `5d72357`. The deletion path still needs a device run, which is N19 |
| N22 | 2 | `localFileURL` and `playerItem` were unbounded waits | **done, round 16.** Both now go through the scan's `boundedAnswer`, so one mechanism owns the single resumption |
| N23 | 2 | A storage refusal named no figure, and a batch repeated it per item | **done, round 16.** The floor refusal now pauses the run once; a size-specific one fails only its video |
| N24 | 3 | The single-video flow sent a restricted user to a Settings switch that is not there | done, round 16 |
| N25 | 2 | A paused restored run resumed with access revoked said the wrong thing | done, round 16 |
| N26 | 0 | **Pause during a batch export silently restarted it** | **done, round 16.** Two holes: the stop never reached the export, and a session built after the stop had nothing to cancel it |
| N27 | 0 | **A save failure was labelled an export failure, and an error after Photos committed could make a second copy on retry** | **done, round 16.** An item Photos was asked to save is never persisted as `.failed`; it becomes the question, with the `.saving` evidence kept |
| N28 | 2 | `retrieve` discarded the refusal reason it had already computed | done, round 16 |
| N29 | 2 | A copy made in the one-video flow was not recorded as app-created | done, round 16 |
| N30 | 3 | The device plan described code that no longer exists | done, round 16 |
| N31 | 2 | A cancelled item was retried immediately, forever, and a failed export left its partial output behind | done, round 16 |
| N32 | 2 | `.notDetermined` access with a restored queue reached Continue and a per-video failure | **done, round 17.** The run now asks for access at its first read, which is the app's existing rule, and a refusal leaves the restored run intact |
| N33 | 2 | `makeSession` threw the generic `.unsupported` list when Apple would not build an export | done, round 17: a new `exportUnavailable(reason:)` carries the transcoder's own sentence |
| N34 | 2 | After a reload with a finished copy waiting at `.readyToSave`, `ContentView`'s flow resets to the batch and `switchTo(.single)` needs `canChoose`, which is false in that stage — so the kept copy is unreachable and "Just one video" is a silent no-op until restart | **done, round 18.** A new pure rule, `FlowRouting`, asks the model's own "no task is running" answer *and* the stage together, in both directions, and both flow switches use it. Asking the stage alone would have been the near-miss: `.choosing` has no task running while the picker sheet is up, so a stage-only rule would let a user walk away mid-choice. The eight new cases include a sweep over `PipelineStage.allCases`, so a stage added later fails the suite rather than quietly acquiring an answer |
| N35 | 3 | `project.yml` pins `CURRENT_PROJECT_VERSION: "1"` while `app.json` ships build 11 — two surfaces disagreeing about the same fact | **done, round 18.** Decided from the code and the records, not from the numbers: the product *version* is the shared fact and `scripts/validate.mjs` now fails when `app.json`'s `expo.version` and `project.yml`'s `MARKETING_VERSION` drift apart (both read 0.1.0, and both are required to be present exactly once so a target-level override cannot bypass the check). The two *build numbers* are different facts and are deliberately not compared: `app.json`'s 11 is the shipped build number, which `docs/RELEASE_10.md` records as the next upload after build 10, while `project.yml`'s 1 counts only the standalone harness, whose bundle id is `com.example.VideoShrink` and which CI compiles and never ships. `validate.mjs` prints a `NOT CHECKED:` line naming both numbers and that reason, so the difference is stated rather than silent. Proved by drifting `app.json` to 0.2.0 in a temp copy of the tree: the check fails with both numbers named, and passes again when restored |
| N36 | 1 | The shipping target now has a CI job, but **no local gate compiles the two Expo bridge files**; the interface call-site checker scans only `VideoShrink/` and `VideoShrinkTests/` | **done, round 18.** `scripts/swift-call-site-check.mjs` now reads `modules/videoshrink-native/ios/` as a third tree. The generated `VideoShrinkCore/` mirror is excluded by name (it is a byte copy of `VideoShrink/Models`, `Services` and `Presentation`, so reading it would make every judged call ambiguous) and the exclusion is printed with its reason. Rule A had to change to make the bridge files mean anything: a call is resolved against its own file first and the rest of the tree only when its own file declares nothing of that name, and only when it writes at least one argument label. That step is strictly additive - 1010 call sites were judged before, 1724 are judged now, and no call judged before is skipped now - and 13 of the new ones are in the bridge files, where a label-order mistake in `BatchViewModel(...)` had been invisible. The output now counts what was NOT order-checked and why, and names the ExpoModulesCore calls as skips rather than coverage. Proved by injecting four faults into a temp copy: a reversed `history:`/`queueStore:` in the bridge file, an optional parameter shadowing a stored property in a bridge initialiser, a bridge type declared twice in one scope, and a type declared on both sides of the pod's own seam. The old scan reported 0 findings on all four; the new one reports each |
| N37 | 1 | **The new `build-expo-app` CI job fails on the runner's toolchain, not on our code.** `macos-15`'s default Xcode 16.4 ships Swift 6.1, and a Swift package in the Expo module tree declares tools version 6.2, so `xcodebuild` fails with "Could not resolve package dependencies" before compiling anything of ours. EAS builds the same project fine, so its image is new enough. The fix is a newer runner image or selecting a newer Xcode — the failed run is `35877195086`, job `build-expo-app`. The existing `verify-native-tests` job is green (336 tests) and must stay that way | **half done, round 18.** Two toolchain faults, not one, and the first fix only cured the first. Fault one, as the row says: the default Xcode 16.4's Swift 6.1 cannot even resolve the tree. Fault two, found by the first fix's failure on `0e8bbae`: `macos-15`'s newest Xcode is 26.3, and its clang rejects a header inside a *dependency* (`node_modules/expo-modules-jsi/apple/Sources/ExpoModulesJSI-Cxx/include/RuntimeScheduler.h:53`, `SWIFT_RETURNS_RETAINED` on a type that is not a shared reference). Not our code, and a toolchain the dependency does not accept. The job is on `macos-26` now, whose default Xcode 26.6 is the toolchain `docs/VALIDATION.md` records EAS as using, and prints `xcodebuild -version` so the next failure of this kind is attributable without another run. The lesson is in the round-18 detail: selecting "the newest Xcode available" was the wrong instinct for a tree with third-party Swift/C++ in it, and the project's own record named the right toolchain all along |
| N38 | 1 | **No CI job ran the local gates at all.** `npm run typecheck`, `npm run validate:native` and the mirror check were documented for a human to run on Windows and were run by nothing else, so the one gate that reads the *whole* tree was the one most likely to be skipped on the push that broke it | done, round 18: job 1 runs all three, for a few seconds |
| N39 | 2 | **A batch run's workspace sweep deleted the one-video flow's kept copy.** Both flows shared one temporary directory and `cleanWorkspace()` removes the whole root, so after a batch run the one-video screen could still offer "Save copy to Photos" over a file that no longer existed, and the save would fail its own re-verify. Found by the round-18 agent that made the flow switch legal, and it was reachable before that too: a reload lands on the batch flow with the copy kept | done, round 18: `TemporaryWorkspace` gives each flow its own directory inside the app's temporary area, each manager can remove only its own, and a test pins both directions |
| N40 | 1 | **The app had never rendered a screen, and nothing could observe a launch.** Every status block in the repository says so, and no instrument existed that could change it without a device or EAS build minutes | done, round 18: a `VideoShrinkUITests` target launches the standalone app on a simulator, waits for the introduction, taps Skip and waits for the batch screen. Job 3 runs it on every push. It proves a screen renders and one navigation works; it proves nothing about Photos, iCloud or any pipeline step |
| N41 | 1 | **The app asked for Photos access at launch, before the user asked for anything.** `LibraryChangeMonitor.start()` reached for `PHPhotoLibrary.shared()` from `BatchViewModel`'s initialiser, which puts iOS's permission alert on screen - breaking the promise the app's own introduction makes, "Photos access is requested when you scan" | done, round 19: the change observer is registered only once the authorization status says the app may read, and the foreground re-check registers it the moment a grant arrives. Found by the round-18 launch test, from the alert in its log |
| N42 | 2 | A `.denied` report with nothing in hand moves the flow off `.start`, so on a device where Photos was already refused the introduction is replaced by a recovery screen | **considered and deliberately left, round 19.** `testAccessRefusedOnTheWayInStillFailsTheFlow` pins it, with the reasoning that a refusal is the one access state the user can undo in Settings and a start screen whose only button fails is less useful than the route back. With N41 fixed nothing reaches this on a first launch, and the intro-versus-recovery question only arises for a refusal that predates the app's first run. Revisit if that is ever seen on a device |

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
| 11 | `42d67f6` | HDR/ProRes refusal moved into the scan; every user-facing string audited | CI: **green** | 276 tests |
| 12 | see below | Close round 11's seams: the new scan phase gets its own wording, refused videos are named, stale strings fixed | local gates PASS | 277 tests |
| 13 | see below | A pre-run format check, first-run expectations, and a whole-app coherence review | local gates PASS | 286 tests |
| 14 | `4d5da93` | Fix three tests that passed vacuously; correct the marketing again | CI: **green** | 289 tests |
| 15 | see below | A first-sixty-seconds device audit and its findings | local gates PASS | 307 tests |
| 16 | see below | A pipeline audit of one video's real journey, and its findings | local gates PASS | 331 tests |
| 17 | see below | The shipping path: an audit of the Expo bridge, CI that builds it, and the last code items | local gates PASS | 336 tests |
| 18 | see below | Make the shipping target compile again, observe the first rendered screen, close the kept-copy flow and the seam it opened, move the local gates into CI, and two read-only audits | local gates PASS | 345 tests |
| 19 | see below | The two audits' nineteen findings, an early permission prompt the launch job found, twenty-two documents corrected against the code, and an independent read of the Swift nobody could compile | local gates PASS; **CI blocked, runners not starting** | 364 tests, none executed |

### Round 17 — the path that actually ships

The two experience audits had both implicitly assumed the SwiftUI app was the app. It is not: the
shipping product is a SwiftUI app inside an Expo native module, and the bridge had never been
audited or compiled by anything that runs.

- **A third read-only audit** traced the shipping path: the host controller's lifecycle, the
  module's forwarding, the shared session, the React entry and the build config, and the mirror
  itself. Its worst finding: `presentationRemoved()` called `model.cancel()`, and `.readyToSave`
  is cancellable — so **a reload deleted a finished export** and told the user it had been
  discarded. Teardown is now exactly as destructive as backgrounding, and nothing more.
- **CI now builds the shipping app.** A second job runs `expo prebuild`, `pod install`, and
  `xcodebuild` on the generated workspace, discovering the scheme rather than assuming it. Until
  this existed, a mistake in the two bridge files would not have surfaced until an EAS build —
  and EAS minutes are gone until 1 October.
- **The launch appearance was unconfigured**: React Native's root view is white, so a dark app
  flashed light on every launch. `expo-splash-screen` and `expo-system-ui` (both first-party, at
  the versions SDK 57 bundles) now set the splash and the root colour, and the upside-down
  orientation the two surfaces disagreed about is settled explicitly.
- The last two code items: a restored run on a device that was never asked for Photos now asks
  rather than failing every video, and an export Apple will not build says so in its own words.

### Round 16 — the pipeline audit, and the two worst things it found

The device-focused audits keep outperforming code review, so this one traced a single video all
the way through the real path: retrieve, export, verify, save, read back, delete. It found seven
things. Two were serious:

**Pausing during an export silently restarted it.** The transcoder's plan loop retried on any
failure and only gave up when the enclosing Swift task was cancelled — but `pause()` never
cancelled that task, and each retry built a fresh session that nothing could cancel. So tapping
Pause on a long clip made progress jump back to zero while the phone encoded the whole clip
again. This is device-plan case 4, the one the first real run would have hit.

**A failed save could make a second copy.** A save failure was normalised with the export
fallback, so the user read "HEVC export failed" about something that never exported — and worse,
an error arriving *after* Photos had committed the copy was persisted as `.failed`, which is
exactly the state Retry runs again. `PipelineError.save`'s own sentence, written for this moment,
was thrown nowhere in the app. An item Photos was asked to save is now never persisted as a clean
failure: it becomes the question, with the `.saving` evidence kept.

Also fixed: two unbounded PhotoKit waits that could freeze a run with both controls dead; a
storage refusal that named no figure and repeated itself once per video; a restricted user sent to
a Settings switch that does not exist; a retrieval step that threw away the refusal reason it had
already computed; a copy from the one-video flow that Select all could shrink again; and a
cancelled item retried forever with no cap.

**The pattern across rounds 15 and 16 is worth keeping.** Both audits were read-only, both were
aimed at a specific moment in the user's experience rather than at the code in general, and both
found defects that all 300-odd tests were green through. Static checks and tests tell you the code
agrees with itself; only tracing a path tells you what the user meets.

### Round 15 — an audit aimed at the one thing that is actually blocked

Everything now waits on a single device run, so this round aimed at that minute instead of at the
code in general. A read-only audit traced cold launch, the permission prompt, the first scan, the
first selection, the pre-flight and the first export as they will execute on a real iPhone. It
found seven things; five are fixed here.

The worst was a first-run dead end of the same shape as the one round 13 found, but reached by the
most ordinary route there is: **deny the permission prompt, grant it in Settings, come back — and
the app still said access was unavailable.** The grant was reported, but the pass the user had
asked for was already failed and nothing recorded why, so nothing acted on the way back, and the
"Try again" button could not prompt again. Regaining access now finishes the pass the user asked
for.

Also fixed: backgrounding during the pre-flight silently swallowed the tap; an empty library
claimed videos had been seen and refused; the batch flow's permission sentence talked about "the
video you want to test", a single-video idea in a batch context; and a restricted device (Screen
Time or MDM) both hid onboarding and sent the user to a Settings switch that does not exist,
because a restriction is not a refusal and cannot be lifted from this app's settings page.

Two more came out of the same audit. The export's free-space gate demanded **two** copies of the
original even though one file is about to be written and the original is already on the disk —
which turned away phones that had room to finish, on the phones this app exists for. And the
format read had no bound, so a PhotoKit handler that never called back would have left the user on
a screen whose only control was Stop.

### Round 13 — the last mile of the refusal problem, and a review that paid for itself

**The pre-flight.** The scan refuses HDR and ProRes for the newest 400 videos whose original is
on the device. Everything else — an iCloud-only video, or one past the cap — was still refused
*after* the run started. `start()` now reads the formats of the videos the user actually chose, in
one bounded cancellable pass with its own screen wording, and takes the refused ones out before
the first export. A selection can be checked exactly, cap or no cap, because a selection is tens
of videos rather than thousands. A video still in iCloud stays unknown and is refused later,
exactly as before, because the probe never downloads.

**The coherence review.** Eight findings across an app that had been changed by thirty agents. It
was read-only, and it is the highest-value agent of the day: it found a **first-run blocker** that
every gate had missed — on a fresh install the app treated "Photos access was never asked for" as
"access lost" and could show a false recovery screen *instead of onboarding*. It also found a
contradiction between two screens about when HDR is detected, a paused screen whose title denied
the button beneath it, and a finished screen that never explained videos the pre-flight removed.
Six of the eight are fixed in this round; two were fixed by the agent that wrote the code it was
reviewing.

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

## Round 18 — the round that made the shipping target verifiable, and the first screen

Baseline re-measured from a clean checkout before any edit: `npm run typecheck` PASS,
`npm run validate:native` PASS, the mirror check PASS. The live CI run for `ea1740e` was still
going, and the previous completed run (`57a4227`, run `35877195086`) had `verify-native-tests`
**success** and `build-expo-app` **failure**, so N37 was real and not stale. A second failure on
`ea1740e` confirmed it.

The round's premise, and the reason for its shape: this project's bottleneck was never
throughput, it was *verification*. Two of the three things that could prove anything about the
app were broken or missing — the shipping target did not compile in CI, and nothing had ever
observed the app doing anything. So the round spent its parent-owned workstream on the
verification path itself, and its delegated workstreams on the defects and the audits that
path made worth doing.

**The shipping target had two toolchain faults, not one (N37).** The first is the one the row
described and the job log names exactly: `package 'apple' is using Swift tools version 6.2.0 but
the installed version is 6.1.0`, from `/Applications/Xcode_16.4.app`, which is `macos-15`'s
*default*. The first fix kept the image and selected its newest Xcode 26 — and that produced the
second fault, which is the more interesting one: the build got all the way into the Expo
dependency tree and died on a **third-party** C++ header,
`node_modules/expo-modules-jsi/apple/Sources/ExpoModulesJSI-Cxx/include/RuntimeScheduler.h:53`,
where Xcode 26.3's clang refuses a `SWIFT_RETURNS_RETAINED` annotation on a type that is not a
shared reference.

So "select the newest available Xcode" was the wrong instinct, and the reason is worth keeping:
this tree contains other people's Swift and C++, compiled by whatever toolchain the runner
happens to offer, and for that code the newest compiler is not the safest one — the *matching*
one is. The job is on `macos-26` now, whose default Xcode is 26.6, and that is not a guess:
`docs/VALIDATION.md` already recorded "the EAS image compiles with **Xcode 26.6 (17F113) and
iPhoneOS26.5.sdk**". The project had the right answer written down in its own record of what
actually built, and the round only found it because the first fix failed. The job now prints
`xcodebuild -version` and `swift --version` as its own step, so the next failure of this kind is
attributable without spending another run finding out what compiled it.

**The local gates run in CI now (N38).** This was found by an agent, not by the round's brief,
and it is the kind of gap this file exists to catch: `typecheck`, `validate:native` and the
mirror check were documented in README.md for a human to run on Windows, and **no CI job ran
any of them**. The one gate that reads the whole tree was the one most likely to be skipped on
the push that broke it. Job 1 now runs all three before the tests, for a few seconds.

**A screen renders (N40).** Every status block in this repository says the app has never run and
no screen has ever been rendered. That was true, and it was the largest gap in the project.
The *standalone* harness is pure SwiftUI with no Metro in front of it, so a macOS runner can
build it, install it on a simulator and ask it what is on screen — no EAS minutes, no device.
The first attempt at this was a screenshot comparison, and it was abandoned mid-round in favour
of a UI test, because "the pixels changed" is a weaker and more brittle claim than "the
introduction drew and Skip reached the batch screen". `VideoShrinkUITests` is in a scheme of its
own, deliberately not in the `VideoShrink` scheme's test action, so the unit-test job keeps its
exact meaning and runtime. A pass is a real observation and covers exactly one navigation; the
script's own output says so, and says what it does not cover.

The first run of that test **found something, which is the point of it**: the app installed and
launched, the introduction drew — `Skip` was found and tapped — and the batch screen never
appeared. The cause turned out to be the test, not the app, and it is worth writing down because
it is a trap that reads as a product defect. The test had forced the introduction on with
`launchArguments += ["-batchShrink.onboarding.v1", "<false/>"]`, and a launch argument is read
from the *argument domain*, which sits above the application domain in the defaults search list.
It therefore shadowed that key for writes as well as reads: the tap on Skip stored the new value
and every later read still saw the argument, so the introduction could never go away. The fix is
to make the state genuinely fresh instead — `scripts/verify-app-launch.mjs` asks the generated
project for the app's bundle identifier and removes the app from the simulator before the run, so
its container, and with it the default, is empty on every machine. A comment in the test says
this, and the failure message now prints the application state and the whole element tree, so the
next failure of this kind is diagnosed rather than guessed at.

**The seam (N39), which is why the parent does an integration pass every round.** The agent that
made the flow switch legal reported, outside its file list, that `BatchViewModel`'s
`cleanWorkspace()` removes the whole shared temporary root — so the copy it had just made
reachable could still be deleted out from under the screen offering to save it. That is exactly
the "built but not wired" failure this file warns about, one layer down: not a mechanism nobody
constructed, but a rule nobody could safely use. `TemporaryWorkspace` now gives each flow its
own directory, each manager removes only its own, and a test pins both directions. Reachable
before this round too — a reload lands on the batch flow with the copy already kept.

**N34 and N36 and N35** closed as described in the backlog table.

**The two audits.** Both were read-only and both paid, which is now four rounds running. The
numbers audit traced every user-facing figure to the arithmetic behind it and found nine defects,
four of them P2 and three of those *overclaims* — the summary saying every video can get lighter,
the confirmation promising copies "at 4K" for videos that will be copied smaller, and the basis
caption naming an fps scaling that did not happen while hiding the one that did. The
accessibility audit found two P1s, including a VoiceOver figure that is hidden from the very
announcement it was added for. Their findings are listed below and are round 19's backlog.

### Round 19 candidates — the two round-18 audits

Numbering is new and local to these lists: `E` for the numbers audit, `A` for the accessibility
audit. Each is a finding with a file and a line in the agent's report, which is worth re-reading
rather than re-deriving; what is recorded here is only what the next round must not lose.

Both audits are now written to disk rather than left in a conversation, because a finding that
exists only in a chat is lost at the next compaction: **[docs/AUDIT_NUMBERS.md](docs/AUDIT_NUMBERS.md)**
and **[docs/AUDIT_ACCESSIBILITY.md](docs/AUDIT_ACCESSIBILITY.md)** carry the file, the line, the
evidence, the proposed fix and — just as important — the list of what was checked and found
correct, so the next round does not walk settled ground. The table below is the index; those
documents are the detail.

| ID | Priority | Item | Status |
|----|----------|------|--------|
| E1 | 2 | The scan summary's headline says every eligible video "can get lighter", including the ones the estimate its own screen shows says will not shrink. `SavingsEstimate.likelyNoReductionCount` is computed and read by nothing but a test | **done, round 19.** The headline is derived from `likelyShrinkCount` (`sizedCount - likelyNoReductionCount`) and reads "Nothing here is likely to get lighter." or "No sizes to estimate from yet." where those are the truth |
| E2 | 2 | The basis caption names a frame-rate scaling that did not happen (30 fps is a ×1.0 no-op) and hides the one that did (a measured band at 24 fps is 0.8×) | **done, round 19.** The frame rate moved *inside* `CopySizeModel.Basis`, so the caption and the arithmetic read the same value and cannot be told different things; `Basis.frameRateScaling` returns a clause only when the choice actually moved the band |
| E3 | 2 | The confirmation before a batch promises copies "at 4K" for videos that will be copied smaller, on the last screen read before work starts | **done, round 19.** "at up to 4K" plus the frame-rate target; the sentence is now a static function so a case can read it |
| E4 | 2 | A per-video space refusal in a batch names no figure, although the run computed one and the one-video flow already has the sentence for it | **done, round 19.** The measured demand is carried per item and rendered with `insufficientStorageSentence(needed:)`, the sentence the paused screen already used |
| E5 | 3 | The time estimate's two clocks measure different spans: the sample is transcode-only, the elapsed subtraction includes retrieval | **done, round 19.** One `attemptStarted` feeds both sides, so a sample spans retrieval, format check, export and verify. Worth watching on a device: a single very slow iCloud retrieval now enters the mean |
| E6 | 3 | "copies about X" counts a copy for every sized video, including ones the run will skip entirely | **done, round 19.** A `copiedBytes` subtotal counts only originals whose copy is smaller even at the bottom of the band |
| E7 | 3 | A selection that will not shrink renders as the bold figure "Zero KB" | **done, round 19.** `SavingsEstimate.predictsNoSaving` with one shared wording; `byteRange` itself is untouched |
| E8 | 3 | A stored non-shrinking saving renders as "--1.2 GB" in a finished row | **done, round 19**, on the view side. The alternative half — clamping a foreign stored `.saved` in `BatchQueueReconciliation.live` — is still open and would be the better place if a second reader of that record appears |
| E9 | 3 | "N selected · X of originals" pairs the full selection count with a subtotal of the sized ones only | **done, round 19.** "5 selected · 2.1 GB of 4 measured" |
| A1 | 1 | The batch working screen's saved-so-far figure is `.accessibilityHidden(true)` inside a `.combine` container, so VoiceOver never reads the number the comment says it reads | **done, round 19**, unverified - see the gate note above. It now carries `BatchFinishedRow.SavingDisplay.spokenLabel`, so the phrase exists once rather than twice |
| A2 | 1 | The finished screen's action bar can stack five controls — about 304pt, and more at accessibility sizes — against a landscape viewport of roughly 330pt, crushing the screen it exists to show | **done, round 19**, unverified. The bar is two rows at most: the primary, then Done and one "More actions" menu holding delete, retry-failed and the checked-again action. `BatchFinishedScreen.Extra.available` is the one list deciding both the trigger's presence and its contents. The height figures are the audit's arithmetic; a render in both landscape orientations would settle them |
| A3 | 2 | The quality estimate reads as a bare number with its explanation as a separate element | done, round 19, unverified |
| A4 | 2 | The word mark cannot fit beside "Skip" at accessibility sizes | done, round 19, unverified: `.lineLimit(1).minimumScaleFactor(0.6)`. Whether 0.6 is enough at AX5 is a source reading |
| A5 | 2 | The selection header keeps the sort pill beside a `.largeTitle` headline at accessibility sizes, truncating the order the user cannot otherwise read | done, round 19, unverified: the pill stacks under the headline at accessibility sizes, with the boundary in `sortSitsBesideHeadline(at:)` so a case can state it |
| A6 | 3 | Five section headings inside cards are not VoiceOver headers, unlike every title above them | done, round 19, unverified |
| A7 | 3 | The working screen can announce the same percentage three times | done, round 19, unverified: the duplicate figure is hidden from VoiceOver rather than deleted, because it is a real visual cue |
| A8 | 3 | Two surfaces bypass `ShrinkHairline`, so Increase Contrast misses the two things a user must distinguish | done, round 19, unverified |
| A9 | 3 | The app's haptics switch does not cover the quality pills | done, round 19, unverified. The key deliberately stays `completionHaptics`: a renamed key is a different preference, and everyone who had turned haptics off would have found them on |
| A10 | 3 | Two `.contentTransition(.numericText())` modifiers have no enclosing animation and are inert | done, round 19, unverified: both got Reduce Motion-gated animations rather than deletion |

Everything that compiles is still unverified until CI is green. A clean local gate run is
evidence, never proof.

## Round 19 — the numbers tell the truth, and the app stops asking too early

The round began as the audit-fixing round: the two read-only audits from round 18 produced nine
number findings and ten accessibility findings, and this round takes them in two waves, numbers
first, because they grow in the same two files and overlapping edits are how this loop has been
bitten before.

**The numbers (E1-E9).** All nine are fixed, and the change is larger than it looks because two
of them were not really wording problems. E1 found a value — `likelyNoReductionCount` — that the
model computed and no screen read: the summary promised every video could get lighter while the
card beneath it said some would not shrink. E2 found the caption and the arithmetic disagreeing
about the frame rate, and the fix that stops it recurring was to move the frame rate *inside*
`CopySizeModel.Basis`, so there is one value to read rather than two to keep in step. E3 was the
last sentence read before a run, promising copies "at 4K" for videos that would be copied
smaller. The rest are the class this project cares most about: a figure shown without the fact it
depends on. Every one of them asserts on the sentence in a test, because here the sentence is the
product.

**The finding the new launch test made, which is in neither audit (N41).** Round 18's third CI job
launches the app on a simulator. Its first two runs failed, and both times the answer came from
the diagnostics rather than from a guess — the second run printed the whole element tree and
named its own application state. The app was on the *recovery* screen, saying Photos access was
unavailable, on a fresh install, before the user had asked for anything. The first run's log had
the cause: **the system permission alert was up before the test touched anything**, and XCUITest's
default handler answered it "Don't Allow".

One line put it there. `LibraryChangeMonitor.start()` resolved `PHPhotoLibrary.shared()` — which
is what makes iOS ask — and `BatchViewModel` starts the monitor in its initialiser, so the alert
was opened at launch. The app's own introduction promises on its first screen that "Photos access
is requested when you scan", so this was a broken promise as well as a hostile first minute. The
monitor now registers its change observer only once the authorization status says the app may
read, and `enteredForeground` — which already re-read the status on every activation — registers
it the moment a grant arrives, so the first listing after a grant is watched like any other.

That fix is provable without a Photos library, which is why the monitor grew two closure seams:
`PHPhotoLibrary` cannot be built in a test, and reaching for the real one is the behaviour under
test, so a test counts registrations instead. Three cases cover it: nothing is touched when
nothing has been asked, the observer is registered once and only once when access exists, and an
app that may already read watches from the start — the last is what stops the first from passing
on an implementation that never registers at all.

**One thing the round deliberately did not change.** The "first-run dead end" instinct says a
refusal with nothing in hand should leave the introduction alone, exactly as a device restriction
now does. It does not, and `testAccessRefusedOnTheWayInStillFailsTheFlow` pins that with its own
reasoning: a refusal is undoable in Settings, so the route back is worth more to the user than a
start screen whose only button will fail. With N41 fixed, nothing reaches that path on a first
launch. It is recorded as N42 rather than quietly changed, because a deliberate decision deserves
a test and a reason, not a re-litigation.

**The accessibility wave (A1-A10)** came second, on the same two files, and finished them. Its two
P1s were the ones worth having: the batch working screen's running total was `.accessibilityHidden`
inside a container that combines its children, so the number the code's own comment promised
VoiceOver never arrived; and the finished screen's action bar could stack five controls against a
landscape viewport, which is about 304pt of inset against about 330pt of screen. The bar is two
rows now, with one list - `BatchFinishedScreen.Extra.available` - deciding both whether the
overflow control is drawn and what is behind it, so a trigger over an empty menu cannot happen.

**Then the round reviewed itself, because nobody else could.** The account's runners were already
gone, so the Swift this round wrote had never been built. An independent read of `31b6245..HEAD`
found three real things, all in this round's own work: the demanded space figure was never cleared
after a check that *passed*, so an export that ran out of room inside the encoder would have been
reported with a figure the phone had demonstrably met - the one-video flow drops that figure and
says why, and the batch had copied the sentence without the clear; the summary's headline read the
conservative end of the estimate's band while the card beneath it read the optimistic one, so a
single borderline video produced "Nothing here is likely to get lighter" over "up to 10 MB"; and
the summary's bulk button said "Select the N worth shrinking" while selecting everything. All
three are fixed, with cases. It also caught one of this round's own tests claiming coverage it
could not have, which is now stated in the test rather than implied by its name.

**And the documentation, which is the only part of this round a Windows machine can verify.** A
truth pass over `docs/` and `marketing/`, reading the code for each claim rather than any status
column, corrected twenty-two files. It found what round 10's failure looked like from the inside:
`marketing/market-map.md` still listed N16, N13, N15 and the expo-doctor row as open, all of them
closed between rounds 6 and 8; and four marketing files carried a real overclaim, because the
pre-run format read decides formats only and a video with more than one video or audio track is
refused inside the run instead.

**The round's honest summary.** Three of its five workstreams are verified: the CI unblocker, the
first rendered screen (both on `31b6245` and `780f14f`), and every documentation change, which the
local gate checks. The Swift in rounds 19's two waves is not, and cannot be until 1 October. It
has been read twice - once by its author and once by a reviewer who was told to assume nothing -
and the second read found three defects, which is the argument for doing it again if the block
lasts.
