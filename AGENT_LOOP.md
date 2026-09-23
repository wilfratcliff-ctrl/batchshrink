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

**One of those patterns was broken, and `npm run prove:guardrails` is why we know.**
`scripts/prove-guardrails.mjs` injects one fault per assertion into a throwaway copy of the tree
and requires the gate aimed at it to refuse it: **seventy mutations across all four local gates**
(`validate.mjs`, the pod-mirror check, the Expo prebuild's own preflight, and the Swift call-site
checker), each naming a file, the edit that should break exactly one assertion, and a fragment of
the message that assertion should print.
Only `CAUGHT` is proof; `MISSED` means the assertion is vacuous, `WRONG` that the failure was
about a different assertion, and `NO MATCH` that the mutation itself has drifted. It is not part
of `validate:native` (it copies the tree seventy times and takes about a minute) and it is
worth running whenever an assertion is added, changed or doubted.

Its first run found this: the force-unwrap guardrail was written `/\btry!\b/`, and **that
expression cannot match anything**. `!` is not a word character, so no word boundary can follow
it - it returns false for `try! foo()`, for `try!` at the end of a line, and for every other way
a force unwrap can be written. An agent could have committed `try!` and the gate would have said
PASS. It is now `/\btry!/`, which is what the rest of the list does and what the guardrail always
meant. The other seven patterns in that list were checked by injection and all caught their
faults.

The harness also found one assertion that is **unreachable rather than wrong**: the queue store's
`!removeItem(` check can never fire, because the temporary-file confinement check runs earlier
and fails for any file but `TemporaryFileManager.swift` first. The property it protects still
holds - the confinement check is what protects it - so it is recorded rather than changed.

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
| N43 | 1 | **The guardrail against force-unwrapping could never fire.** `scripts/validate.mjs`'s forbidden-pattern list had `/\btry!\b/`, and no word boundary can follow `!`, so the expression returned false for every way a force unwrap can be written | done, round 20: the pattern is `/\btry!/`, and `npm run prove:guardrails` now proves it fires. Found by the fault-injection harness below, which also proves the other seven patterns and forty-six further assertions |

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
| 20 | see below | Prove the guardrails guard (and fix the one that could never fire), then a deletion-journey audit and a restored-run audit, and their screen-truthfulness fixes | local gates PASS; `prove:guardrails` 54/54; **CI blocked** | 372 tests, none executed |
| 21 | see below | The highest-value open finding from round 20's audits: a video that may already have a copy was bulk-selectable again | local gates PASS; `prove:guardrails` 67/67; **CI blocked** | 375 tests, none executed |
| 22 | see below | The gate could not see a leading-dot member call, enum cases with associated values, or a member that does not exist | local gates PASS; `prove:guardrails` **70/70 across four gates**; **CI blocked** | 380 tests, none executed |
| 23 | see below | The question a run leaves behind outlives the run - in the record and across a relaunch - and a restored run says why it stopped; with it, two of the one-video flow's own findings | local gates PASS; `prove:guardrails` **70/70 across four gates**; **CI blocked** | 390 tests, none executed |
| 24 | see below | The one-video flow journals the copy it could never account for, so the batch flow cannot be made to copy the *original* again on its own - the copy itself stays unnameable | local gates PASS; `prove:guardrails` **70/70 across four gates**; **CI blocked** | 402 tests, none executed |
| 25 | see below | The count, the menu hint and the two empty states say what they mean - and the physical-device plan is made to cover the deletion it never tested | local gates PASS; `prove:guardrails` **70/70 across four gates**; **CI blocked** | 405 tests, none executed |
| 26 | see below | The Originals sheet checked against the code and found honest, and the first audit of the launch path: the advisories a user has to see are no longer buried, and the shell says something rather than nothing | local gates PASS; `prove:guardrails` **70/70 across four gates**; **CI blocked** | 405 tests, none executed |
| 27 | see below | The launch label now reaches the screen before the restore that blocks the runloop, the uncertain-original advisory says what the app has decided, and the quick look speaks for itself when Photos cannot hand a video over to play | local gates PASS; `prove:guardrails` **70/70 across four gates**; **CI blocked** | 406 tests, none executed |
| 28 | see below | Both previews now say what is happening, and the test suite that will be the only gate in October had four cases repaired that could not fail or pinned the wrong thing | local gates PASS; `prove:guardrails` **70/70 across four gates**; **CI blocked** | 410 tests, none executed |

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

### Round 20's audits — the deletion journey, and the way back in

Two more read-only audits, written to disk in the same shape as the two above:
**[docs/AUDIT_DELETION.md](docs/AUDIT_DELETION.md)** and
**[docs/AUDIT_RESTORED_RUN.md](docs/AUDIT_RESTORED_RUN.md)** carry the evidence, the proposed fix,
the confidence and the list of what was checked and found correct. The table is the index.

| ID | Priority | Item | Status |
|----|----------|------|--------|
| DEL1 | 1 | Every per-item deletion dictionary and the pending Photos transaction survived a run boundary, and the flush asked no question about the mode - so a later run could delete an original it never named, during a run whose own setting said deleting was off | **done, round 20**, unverified. `beginRun` clears the run's own facts and the batch; `reset` clears the batch; the flush refuses to run outside a run whose snapshot mode deletes originals |
| DEL2 | 2 | The row said " · original kept" for every refusal and threw the stored reason away - the sentence had no reader in the app - against `docs/BATCH_PHASE.md`'s promise that the reason reaches the list | **done, rounds 20 and 21**, unverified. The reason is rendered, and the confirmation now qualifies its own count: every candidate is looked at again before Photos is asked, so the number can only go down |
| DEL3 | 2 | The paused screen said nothing about originals this run had already deleted, under a headline reading "Nothing was lost" | done, round 20, unverified |
| DEL4 | 2 | In "delete at the end" the finished screen said nothing about the confirmation it was waiting for - and the real cause was worse: `finishNow()` from a paused run never took the look its offer depends on, so the control was never drawn and the originals were silently kept | done, round 20, unverified: `finishNow` takes the same one look per candidate the run's own tail takes |
| DEL5 | 3 | A cancelled Photos confirmation is stored as a save failure, so cancelling reads as a failure with the wrong sentence behind it | open, and device-dependent: which error PhotoKit returns for a declined alert decides the shape of the fix |
| DEL6 | 3 | The working screen's shield line read "Original protected" in the two modes that remove originals | done, round 20, unverified |
| DEL7 | 3 | A deletion left "uncertain" is a dead end: the app advises checking Photos and no control can act on the answer | **open, and now for a reason rather than for want of time.** The obvious fix - have the app look up that original's identifier at launch and settle the question itself - is unsafe in exactly the window the journal exists for: PhotoKit may answer "gone" for a deletion still being applied, and an original read as "still here" would become deletable again, so the app could submit a second deletion for an asset the first one is still processing. The advisory is the safe behaviour until a device can say what PhotoKit answers in that window. See round 26's verification below |
| RR1 | 2 | The restored pause asked the user to check Photos and never named the video | done, round 20, unverified |
| RR2 | 2 | An unanswered mid-save question drops off every screen at the next scan and out of the record at the next run - and the video becomes selectable again, which is the second copy that area exists to prevent | **done, rounds 21 and 23**, unverified. Round 21 kept the video out of automatic selection, made the finding survive a scan and a new run inside the session, and named the videos on the selection screen. Round 23 closed the record with a **different shape from the one this row predicted**: not an item merged back, but `BatchQueueRecord.questions` - the identifier and the kind of question, written beside the run and *not* as an item, because a question outlives the run it came from and is a fact about the library rather than a piece of a run. Every checkpoint writes it, `reset()` ("Done") writes it on its own instead of clearing the queue, and a launch reads it back into `midSaveFindings`, where it keeps the video out of Select all and names it on the selection screen. A tick by hand is the answer and clears it |
| RR3 | 2 | A restored run has lost why it stopped, including the storage and thermal reasons | **done, round 23**, unverified: `BatchQueueRecord.pause` holds `PauseKind` (the four reasons, by kind and not by sentence), a checkpoint writes it and a launch draws `BatchPauseReason.explanation` again |
| RR4 | 2 | "Nothing was lost" on a paused screen that knew an original might already be deleted | done, round 20, unverified, with DEL3 |
| RR5 | 3 | A queue that cannot be read is indistinguishable from no queue, and says nothing | **done, round 23**, unverified: `BatchQueueStoring.hasUnreadableRecord()` tells "no file, or an empty queue" from "a file this build cannot read", and the launch screen draws that in its own notice - not under `QueueWarningNotice`, whose heading claims a write failed |
| RR6 | 3 | A video whose outcome is unknown counts as finished, on the screen and in `canLeaveFlow` | half done, round 20: the paused counts are honest now. Whether an unanswered flag should hold the flow is open, with RR2 |

### Round 21's audit — the one-video flow

The flow that had never been traced, written up in **[docs/AUDIT_SINGLE_VIDEO.md](docs/AUDIT_SINGLE_VIDEO.md)**.

| ID | Priority | Item | Status |
|----|----------|------|--------|
| SV1 | 2 | A save interrupted while Photos holds it leaves a real copy that nothing remembers, and the batch's Select all can then copy the copy | **done, round 24**, unverified, and **not as far as this row's first wording claimed**. The shared history store keeps a bounded list of unconfirmed saves: the one-video flow writes the original before `photos.save` and clears it on the two answers that are answers - a copy Photos named, and a save Photos finished without naming, where the *original* is recorded as one this iPhone has shrunk instead of a question being raised about a copy the app knows exists. A throw leaves the entry. The batch adopts every entry at launch **and at every scan** (so a save in the other flow during the same session still reaches the selection screen), where it is an unresolved question: out of `selectableAssets`, named with the sentence. The entry goes wherever the question is answered - a settling look, the "I checked Photos" tap, a tick by hand, or a later one-video save Photos confirms - and it is deliberately **not** copied into the queue file, which would let it outlive the answer the other flow gave. **The copy itself stays unnameable**, because Photos never returned its identifier, so an automatic selection can still shrink the copy; what this round prevents is the app making a *third* copy of the original on its own. The one-video flow still says nothing on its own screens, and whether `UserDefaults` has reached disk by the time the process dies inside `performChanges` is unverified - the batch uses a real file for the same job |
| SV2 | 2 | The recovery screen's "Shrink one video instead" was live and did nothing | done, round 21, unverified. The deeper question - whether a *failed* batch should hold the user at all - is open and is a `canLeaveFlow` change |
| SV3 | 3 | The ready-to-save screen said preview "before saving" when its own text said saving was off | done, round 21, unverified |
| SV4 | 3 | A copy that came out bigger was drawn as "No size reduction" under an equals sign over two different figures | done, round 21, unverified |
| SV5 | 3 | Cancelling the picker lands on a recovery screen about a video that was never chosen | **done, round 23**, unverified: `pickerCancelled()` moves to `.idle`, with `(.choosing, .idle)` added to the stage rule. The `.choosing -> .cancelled` edge is still allowed and now has no caller - kept deliberately, and a candidate for tightening |
| SV6 | 3 | "HEVC export failed" for a 720p H.264 export, and "larger" for a pixel mismatch | done, round 21, unverified |
| SV7 | 3 | The welcome promised "your smaller copy" before anything had been measured | done, round 21, unverified |
| SV8 | 3 | The shared quality sheet promises estimates the one-video flow cannot show | **done, round 23**, unverified: `QualitySheet.estimateNote` is the sentence and its default is the batch's own, so the one-video caller passes nil. **The same defect had a second half the finding did not name**: the batch sheet is reachable from the summary screen, where nothing is chosen, so `BatchFlow` now passes nil there too rather than only when the flow has no library |

### Round 22's review findings — the tooling, and two in the app

The whole-pile review's findings, beyond the three tooling gaps the round fixed:

| ID | Priority | Item | Status |
|----|----------|------|--------|
| PL1 | 1 | The call-site checker dropped every call written with a leading dot - 1,371 in scope, 429 labelled - so it could not judge the shape this codebase writes almost every enum case in | **done, round 22**, with a mutation proving the shape. A whole-pile review found it by watching the harness report MISSED then CAUGHT on the same fault written two ways |
| PL2 | 1 | The checker collected no enum case with an associated value, so its labels were never recorded and a call to it was never order-checked | done, round 22 |
| PL3 | 2 | No rule asked whether a member referenced by name exists at all, which is the class a large unverified pile is most likely to contain | done, round 22: Rule E, judging 986 references |
| PL4 | 3 | The deletion flush's mode guard returned silently where the function beside it records a reason | done, round 22 |
| PL5 | 3 | A grid tile for a video left out of Select all showed an ordinary estimate and a tick circle | done, round 22 |
| PL6 | 3 | A round-19 case asserted a 150 ms signal against a 60 ms delay with a 10 ms margin | done, round 22: the delay is 150 ms |

Everything that compiles is still unverified until CI is green. A clean local gate run is
evidence, never proof.

### Round 23's own findings — the question outlives the run, and two of the one-video flow's

Round 23 closed `RR2`, `RR3` and `RR5` and two of the one-video flow's findings, and it left the
two below behind. The second was found by taking the first auditor's own observation to the code
rather than trusting the revision it was written against.

| ID | Priority | Item | Status |
|----|----------|------|--------|
| Q1 | 3 | **A video the app has *concluded* has a copy would be reachable by Select all again.** `unaccountedIdentifiers` holds only an *open* question, and the app's own answer to one - `.copyInPhotos` - both keeps the video out of that set and records only the **copy's** identifier (`rememberCreatedCopy`), never the original's. An item that keeps that conclusion without settling into `.saved` (a receipt with no measured sizes, which `resolveMidSaveItems` refuses to claim) would leave the **original** in `selectableAssets` | **open, and an independent read that doubted the reachability was checked against the code that writes the receipt.** The reviewer argued from field dates - `copyEvidence` arrived in round 1, `attemptedSave` in round 6 - that a build in between could leave that shape. The writer settles it the other way: rounds 1 and 5 both persist `.saved` **before** `confirmReadBack` writes the receipt, so a `.saving` record on disk never carried one, and the repo's own `LegacyMidSaveQueue` fixture asserts exactly that (`copyEvidence: nil`). Rounds 6 and later write the identity and the sizes in the same checkpoint. So the door needs a hand-edited or corrupt file, which is why this is 3 rather than 2 - and the fix is unchanged: one set to decide automatic selection, and a third card sentence for "the copy is there", so a video the app has *concluded* about is not named with a sentence about not being able to tell |
| Q2 | 3 | The `.choosing -> .cancelled` edge in `PipelineStage.allows` now has no caller, after SV5 moved picker cancellation to `.idle` | open, and a decision rather than a fix: it is the only move into `.cancelled` from a stage `canCancel` is false for, and pruning it is the riskier edit of the two |
| Q3 | 3 | `AX3`: a stored `.saved` whose copy is *not smaller* is passed through by `BatchQueueReconciliation.live`, so the finished screen can say "One video, lighter." and "1 smaller copy in Photos." over a row whose own words are "its recorded size is not smaller than the original" | **open, and the fix is a decision, not a patch.** Only a queue file this app did not write can hold that state (`live()` is the reader round 19's `E8` named as the better place, and `BatchFinishedRow.savingDisplay` exists to explain it rather than draw a negative figure). Clamping in `live()` fixes the headline and makes the row's explanation, its comment and its `symbol` unreachable; clamping in the summary puts "No copies were saved." directly above a row beginning "Saved ·". One round has to choose which of the three keeps the state - and it is worth choosing only because a *second* reader of that record has now appeared |

### Round 24's audit — the accessibility wave, re-read after four rounds of UI changes

Round 19's ten accessibility findings were recorded as unverified, and rounds 20 to 23 then changed a
great deal of the same UI. The re-read is in
**[docs/AUDIT_ACCESSIBILITY_RECHECK.md](docs/AUDIT_ACCESSIBILITY_RECHECK.md)**, with the string, the
site, the reachability and a confidence per finding. It found all ten round-19 items still present,
and eight new things:

| ID | Priority | Item | Status |
|----|----------|------|--------|
| AX1 | 2 | Round 23's notice about a record that could not be read said the app had **"set it aside"**, and nothing in the code moves, deletes or clears that file - the store answers a Bool and the record stays. It also meant the notice returns on every launch until a run overwrites the record, which the sentence did not say | **done, round 24.** The sentence now says what is true: nothing could be restored, nothing in Photos was changed, the record stays, and the notice comes back until a run writes one of its own. Found by an independent audit of the *accessibility* of the screens, which is a reminder that this class of defect is not confined to what a test asserts |
| AX2 | 3 | The **working** screen's "N of M finished" counted a video whose save Photos never confirmed as finished - the same claim round 20 took off the paused screen, left standing one screen earlier, directly above a card whose own row says Photos did not confirm that save | **done, round 24**, as `BatchProcessingScreen.processingSubhead` in the paused screen's own words, with a case pinning both plural forms |
| AX3 | 3 | The finished screen says "lighter" and "a smaller copy in Photos" in the state round 19's `E8` declared in scope (a stored `.saved` whose copy is not smaller), while its own row and totals card say the opposite | open. Same caveat `E8` accepted; a stored non-shrinking saving has to be handled once, in one place |
| AX4 | 3 | The finished screen's overflow hint names all three actions ("Delete originals, try the failed ones again, or run the ones you checked") whatever subset the menu actually holds, so a run with only failures reads a hint promising a Delete that is not there | **done, round 25**: `BatchFinishedScreen.overflowHint(_:)` names exactly what the menu holds, built from the same list that decides the trigger and its contents, with a case pinning all eight subsets |
| AX5 | 3 | "Delete 1 originals" in that menu, and six other counts with no singular form (`1 videos to explore`, `1 videos left`, `All 1 copies confirmed`, `From 1 copies measured`, `1 originals may already have been deleted`, `1 of 1 videos`). The confirmation dialog for the same count pluralizes correctly, so one control names its own count two ways | open, and a batch rather than a one-off: several screens want one small plural helper, which is why it is not being patched string by string |
| AX6 | 3, latent | "To look at in Photos" heads every `.needsCheck` item, including one whose finding the app has already answered, which the notice above it can describe as "Nothing is left to check". Latent: both halves need the state `Q1` records as unreachable from any shipped build | open with `Q1`, and it is the heading half of `Q1`'s own proposed fix |
| AX7 | 3 | An empty library announces "Nothing to shrink yet." twice, once as the header and once as the notice title, with "0 videos in your Photos library." between them | open, cosmetic |
| AX8 | 3 | The working screen's time estimate is a bare figure with its explanation as a separate element (the fix `A3` made in the quality sheet is five lines away), and a stage is announced three times over - the orb's label, the card's text and the bar's label, where `A7` hid only the percentage | open |

### Round 25's second half — the device plan, read against the code it will be used on

`docs/PHYSICAL_DEVICE_TEST_PLAN.md` is the only instrument for everything the source cannot decide, and
nobody had re-read it against the code since round 20 while rounds 21 to 24 changed the deletion path,
the question machinery and the one-video flow. The audit is
**[docs/AUDIT_DEVICE_PLAN.md](docs/AUDIT_DEVICE_PLAN.md)**; the plan itself was then rewritten to its
change set, which is one file with no Swift in it and therefore the only part of this round that a
person can read and check.

| ID | Priority | Item | Status |
|----|----------|------|--------|
| D1 | 1 | **The plan never exercised the app's one irreversible action.** Every deletion row was a case where nothing is deleted, so Photos' own confirmation was never declined, never accepted, and the "a deletion did not happen" endings were never seen - and the code has exactly one deletion transaction, whose catch maps any error to one sentence | **done, round 25.** Two new cases: decline Photos' confirmation, and accept it. The first records what the app said and whether it claimed a deletion that did not happen, and states plainly that a phone cannot separate a decline from an error - which is `DEL5` |
| D2 | 1 | Case 5 asked the tester to compare brightness and highlights in an **HDR copy** of a video both flows refuse by name, and to judge a ProRes original the app also refuses | **done, round 25**: the case is now a refusal case, and a copy offered for either clip is the failure it exists to catch |
| D3 | 1 | The retrieval-cancelled row described the loop before round 16: "nothing caps how many times it may come back there" and "the number a cap should be set from", while `cancelledRetryLimit` landed in the same commit as the row | **done, round 25**: the row now states the cap (back on the waiting list twice, failed on the third) and asks for the count, the timings and the row's own sentence after it gives up |
| D4 | 1 | Nothing asked a person to open Photos and count the copies after a save was killed - the one observation the whole mid-save question rests on - and the one-video flow had no row at all | **done, round 25.** The process-termination row became two cases, split by flow: the batch case asks for the restored row, the `Left out of Select all` heading and the count in Photos; the one-video case asks whether the journal survived the kill, and adds the `Made by BatchShrink` versus `Previously shrunk` captions that tell whether Photos named the copy |
| D5 | 2 | The iCloud-versus-local wording question was not asked, though the code decides it from PhotoKit's progress callback, so a local original can be told it is being downloaded | done, round 25: a `Local original, network off` row naming both pairs of sentences and which belongs to which |
| D6 | 2 | The "Save transaction" row named a Save control the batch flow does not have | done, round 25: split by flow |
| D7 | 2 | No reset existed between cases, the kill-a-save case sat in the middle of the matrix, `Original safety` was one case near the end rather than a before-and-after on each case, and one row could remove originals while the preamble promised none would | done, round 25: a reset case, the irreversible cases last, and `Original safety` clauses on every case that saves or deletes |
| D8 | 2 | One row asked for sandbox facts a phone cannot give, and another timed a single read where the step can be three bounded reads (about 31 s) | done, round 25: both rewritten to what a person can record |
| D9 | 3 | The larger-copy row described the one-video flow only, and did not ask whether an ordinary original ever produces a copy bigger in bytes - the device question `docs/AUDIT_SINGLE_VIDEO.md` names | **done, round 26**: the row now takes the same file through both flows and asks for the original bytes, the copy bytes and which ending appeared, because that branch is only ever met or missed by a real file |
| D10 | 3 | The "Failed queue write" step could not be performed on a phone, and the *reachable* sibling - a record the app cannot read, with its notice - had no place in the plan | **done, rounds 25 and 26**: the write row is tied to the storage cases that can actually make a write fail, and the notice has its own bullet in the change list, which is where a state a phone cannot create belongs - it says what the notice means and what to look through Photos for |
| D11 | 3 | The build attribution named a build that has never existed: `app.json` is build 11 and `docs/RELEASE_10.md` records that the next upload should use 11 or later, so nobody has run build 11 | **done, round 26**: the preamble now says the build that carries this work has not been made, that the number is a commitment rather than a fact, and that every result below is evidence about one recorded build and no other |

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

## Round 20 — prove the gate, then trace the two moments nobody had traced

The blocker did not lift, so the round asked what could still be *verified* here. The answer was the
local gates: they are the only instruments that run, and nobody had ever checked that they can fail.

**The harness, and what it found.** `scripts/prove-guardrails.mjs` injects one fault per assertion in
each gate into a throwaway copy of the tree and requires it to refuse the fault: sixty-one mutations
across `validate.mjs`, the pod-mirror check and the Expo prebuild's preflight, each naming a file,
the edit that should break exactly one assertion, and a fragment of the message that assertion should
print. Four outcomes, and only one is good — `CAUGHT`, versus `MISSED`
(the assertion is vacuous), `WRONG` (the failure was about a different assertion) and `NO MATCH` (the
mutation itself has drifted). It copies the tree once per mutation and takes twenty seconds, so it is
not part of `validate:native`; run it when an assertion is added, changed or doubted.

The first run found that the force-unwrap guardrail was written `/\btry!\b/`, and **that expression
cannot match anything**. `!` is not a word character, so no word boundary can follow it: it returns
false for `try! foo()`, for `try!` at the end of a line, and for every other spelling a force unwrap
can take. An agent could have committed a force unwrap and the gate would have said PASS. It is
`/\btry!/` now. The other seven forbidden patterns all caught their faults, forty-six further
assertions caught theirs, and the run is 61 of 61. The same run found one assertion that is
unreachable rather than wrong — the queue store's `!removeItem(` check can never fire, because the
temporary-file confinement check fails first for any file but `TemporaryFileManager.swift` — and that
one is recorded rather than changed, because the property it protects is still protected.

This is the round's most useful hour, and it is the same lesson the loop already carries about the
other checker: an assertion nobody has tried to break is a claim, not a guard.

**Two audits instead of more Swift.** With compilation unavailable, the highest-yield work left was
tracing moments no round had traced, and both paid: the deletion journey, and what a user meets when
the app is reopened on a queue. Their findings are in `docs/AUDIT_DELETION.md` and
`docs/AUDIT_RESTORED_RUN.md`, indexed in the table above. Two were serious.

The first: every per-item deletion dictionary and the pending Photos transaction survived a run
boundary, and the flush asked no question about the mode. Run "delete as it goes", pause after two
copies, "Finish with what's done", start again with deleting turned off — and the new run would flush
the old run's queued originals, deleting an original it never named, in a run whose own setting said
deleting was off. The destructive gate still held (a receipt and a fresh look at both assets are
required), so nothing unverified was deleted; what broke was that the deletion happened outside any
mode the user could see, attributed to a run that did not make it, and left no trace in the record.
`beginRun` now clears the run's own facts, `reset` clears the batch, and the flush refuses to run
outside a run whose snapshot mode deletes originals.

The second is open, and is the most valuable thing either audit left behind: an unanswered mid-save
question drops off every screen at the next scan and out of the record at the next run, and the video
it names becomes selectable again — because the guard that keeps a copied original out of bulk
selection is the history store, and the original only reaches it *after* `photos.save` returns. So a
kill inside `performChanges` can end with "Select all N" ticking a video that may already have a
copy. That is the outcome the area's own comment says it exists to prevent, and it is a design change
rather than a sentence, so it wants its own round.

The rest of the round's fixes were the truthfulness on the two screens a user meets while originals
are in play: the working screen's shield line no longer says "Original protected" in the modes that
delete, the paused screen's headline no longer says "Nothing was lost" when an original is in
question and it now draws the deletion note and the flagged rows it was asking about, a kept original
now says *why* it was kept instead of dropping the stored reason, and "Finish with what's done" takes
the look its own confirmation depends on — which it never did, so in a deleting mode the
confirmation was silently never offered and the originals were quietly kept.

**All of that Swift is unverified**, and the loop's rule stands: it was written because leaving a
known safety defect in the tree for a week is worse than leaving it there unbuilt. `npm run
validate:native`, `npm run prove:guardrails` and the mirror check all pass; nothing has compiled it.

## Round 21 — the second copy, which is the one outcome that area exists to prevent

Round 20's audits left one finding above all the others, and this round took it. A video the app
stopped mid-save on may already have a copy - that is the whole question the flag asks - and the
route "finish, shrink more videos, find my videos, Select all" put it straight back into a run.
`selectableAssets` excluded originals this iPhone had shrunk, copies this app had made and originals
it had deleted, and it knew nothing about the one category whose answer it could not give.

The fix is the arrangement the project already had for its own copies, because the shape is the
same: keep the video out of *automatic* selection, leave it on screen, and let it be ticked by hand.
The predicate is deliberately the strictest of the three mid-save findings - only "the app looked at
the whole library and found no copy of its own" leaves a video clear, because a copy the app *can*
see and a question it could not answer are both cases where running the video again can make the
second copy this area exists to prevent.

Naming the videos is the other half, and it is not decoration: a question about whether a copy
exists cannot be answered by a user who cannot recognise the video it is about, which is exactly what
round 20's other audit found on the paused screen. So the selection screen draws them with the same
thumbnail-and-details rows every other list uses, under a heading that says they are left out of
Select all and a sentence that says why and what to do. That meant generalising `RefusedVideoList`,
whose heading and summary were hardcoded to "the app read this and cannot shrink it" - reusing it as
it stood would have told the user something false about videos that are neither read-and-refused nor
unshrinkable. It is `VideoReasonList` now, with the refusal's own words as its defaults.

One statement in round 20's own fix had to be revisited: `beginRun` cleared every per-item
dictionary, and `midSaveFindings` is not one of them. The others are conclusions a run reached about
videos it looked at; a finding is a question the user still has to answer, and it is what keeps the
video out of bulk selection until they do. Clearing it would have restored the defect on the next
run. How far that protection reaches is now stated exactly: it lasts as long as the app does. A
relaunch after the next run's checkpoint loses the question, because the record has no field for it -
that is RR2's remaining half in `docs/AUDIT_RESTORED_RUN.md`, and it needs a queue-schema change with
a compile gate behind it.

Also closed, from the other audit: the deletion confirmation now says what happens to its own count -
every candidate is looked at again before Photos is asked, so the number can only go down and an
original whose copy has changed is kept with its reason on the row. The count is still the one from
the last look; the dialog states the rule rather than promising a number, which is the narrower of
the two fixes the audit offered.

**Unverified, again, and for the same reason.** The local gates pass and the proof harness is 67 of
67, but nothing has compiled this since `31b6245`.

### Round 21 continued — a review of the round's own work, and the last untraced flow

**The review paid for itself again, and the two worst findings were mine.** An independent read of
round 21's diff found that the round's central fix was half-done in two places. First: generalising
the list component changed its heading and its summary and left its rows alone, so every row of the
new card on the selection screen read "This video is not supported yet." - of a video the app can
process perfectly well and is inviting the user to tick by hand - and told VoiceOver it could not be
chosen. Changing a card's headline is not changing its rows. Second: "Done" cleared the findings
through `reset()`, so the exclusion held for "Shrink more videos" and not for the button beside it,
and `reset()` leaves the library already scanned, which put the flagged video one tap of Select all
away in the same session. Both are fixed, and the mirror of the second is fixed too: nothing cleared
a finding when the *question was answered*, so `requeueUncertain` now does.

The review also found a test of mine that could not pass - it asserted the deletion message contains
no "3" while that message says "30 days" - and a doc comment that had become attached to the wrong
function. Both corrected.

**And the one-video flow was traced for the first time.** Eight findings, in
`docs/AUDIT_SINGLE_VIDEO.md`. Six were the small truthfulness class the last four rounds have been
working through and are fixed; two are open and both matter more than their priority suggests. SV1:
a save interrupted while Photos holds it leaves a real copy that nothing remembers, and the batch's
Select all can then copy the copy - the same outcome round 21 exists to prevent, reached through the
other flow. SV5: backing out of the picker is answered with a recovery screen about a video that was
never chosen.

**Its most useful contribution is a reassurance.** The one-video flow cannot delete anything, and
every screen's claim about that is true, checked against the code rather than the comments. It is
also the flow whose code has been compiled - most of the findings above are in files CI has built -
which is why the audit could rank its findings by compilation state at all.

**Where the round leaves the project.** Six more Swift fixes than round 20, and the same caveat: the
local gates pass, the proof harness is 67 of 67, and nothing since `31b6245` has been compiled. The
verification handoff now carries a triage table for the moment that changes.

### Round 22 — the gate could not see the shape this codebase writes most

A whole-pile review — three rounds of unverified Swift read as one thing rather than round by round —
found the most valuable defect of the day, and it was in the *tooling*, not the app.

`scripts/swift-call-site-check.mjs` collected calls with a guard that dropped any call written with a
leading dot: `.planning(resolution:frameRate:)`, `.saved(originalBytes:copyBytes:)`, and the rest of
the shape this codebase uses for almost every enum case and member call. The guard's reasoning was
that resolving `.member(...)` needs type inference the scan does not have - which is true about
*which type* the member belongs to, and cost far more than it saved. There are **1,371 of them in the
scan scope, 429 carrying at least one label, and not one was judged.** The one local substitute for
the compiler could not see a mis-ordered argument in the most common constructor shape in the app.

It was found by the harness proving it to itself: the first mutation written for the new Rule E fired
and the Rule A one came back MISSED, because the call it mutated was written with a leading dot. The
same call written qualified was CAUGHT. Both shapes are mutations now.

**Three things were wrong with the checker, and all three are fixed.**

- **Leading-dot calls are collected and resolved tree-wide** (a leading-dot call has no file-local
  meaning, so it never takes the local-first step). Call sites read went from 6,190 to 7,623 and
  judged calls from 1,982 to 2,058, with no findings on the tree - the same standard the checker
  holds itself to.
- **Rule E is new**: a member referenced through a type's own name, where no such member exists. This
  is the class every reviewer of the last three rounds named as uncovered - Rules A to D never ask
  whether the thing being called exists - and it is the class a 1,900-line unverified pile is most
  likely to contain, because almost every change was a new static sentence or rule called by name.
  It judges 986 references and reports the ones whose name exists nowhere.
- **Enum cases with associated values were invisible to every rule.** The case scanner advanced while
  a bracket-depth counter matched, and that counter counts `(` - so `case noSession(resolution:)`
  arrived as the text `noSession(`, matched nothing, and produced no declaration at all. Its labels
  were never recorded, a call to it was never order-checked, and Rule E is what surfaced it by
  reporting 23 of them as names declared nowhere. Fixing it added 20 declarations and made 24 more
  calls judgeable.

Two smaller findings from the same review are fixed with it: the deletion flush's new mode guard
returned silently, in a file whose neighbouring rule says exactly why that is wrong (the originals
are now recorded as kept, with a sentence), and the selection grid's tile for a video left out of
Select all shows an ordinary estimate and a tick circle - the caption now says so, which is what the
comment beside it always said the row had to do. A case of round 19's that asserted a sample spans
the retrieval had a 10 ms margin against a 60 ms delay; the margin is 100 ms now.

**The lesson this round is the one the loop already carries, applied to its own tools**: `prove`
covers four gates and seventy mutations, and everything it says is about what it was built to inject.
The leading-dot hole survived two rounds of "local gates PASS" because nothing had tried to break
that shape. A gate's numbers are evidence about the code; they are not evidence about the gate.

### Round 23 — the question outlives the run

`RR2` had been half done for two rounds. Round 21 stopped the *session* from forgetting the question
a mid-save stop leaves - the video is kept out of automatic selection, the finding survives a scan
and a new run, and the selection screen names it. What it could not survive was a **relaunch after
the next run's checkpoint**, and that route was ordinary: relaunch, finish with what is done, shrink
some more videos, and the record the new run writes describes only its own items. The question was
gone, and the video it was about was, from the app's point of view, an ordinary video that Select all
would cheerfully copy a second time.

**The round chose a different shape from the one the backlog predicted.** That row said the fix was
"an optional field on `BatchQueueRecord` and a restore that merges it back" - an item merged back into
the run. It is not that, because a question is not a piece of a run: the run it came from is over, so
nothing may be continued from it and no run's screen should pretend otherwise. `BatchQueueRecord`
gained `questions`, which is the identifier and the kind of question and nothing else, and a launch
reads one back into `midSaveFindings` - the same place the session already keeps questions, which is
what makes the video leave `selectableAssets` and what the card on the selection screen already
names. No screen draws a question from the file: the row that names the video is drawn from the
library the launch scans, which is the only thing that knows what the video looks like now.

Written from three places, deliberately. Every checkpoint carries the questions **none of this run's
own items describes** (an item that is waiting to be checked already travels in `items`, with its
identity and its evidence); "Done" writes the outstanding questions on their own instead of clearing
the queue, because the user ending the run does not answer a question about their library; and a
video the run was handed by hand clears its own question, because running it is the same answer the
"I checked Photos" tap gives. The store's empty-record convention is what makes the third case
possible: `load()` now reads a record holding only questions as a record, and an empty one as no
queue, exactly as before.

**Two of the round's findings were older than the round.** `RR3`: a run left behind by a warm iPhone
or by not enough room came back saying only "picked up where you left off", so the reason is now
`BatchQueueRecord.pause` - the four reasons by kind, and the sentence asked of `BatchPauseReason` as
before. `RR5`: a queue file that could not be read was indistinguishable from never having run, so
`BatchQueueStoring.hasUnreadableRecord()` tells the two apart and the launch screen says so - in its
**own** notice rather than under `QueueWarningNotice`, whose heading claims a write failed, which is
not what an undecodable file or a newer version's record is.

The same round took two findings from the one-video flow's audit: closing the video picker now returns
to the welcome screen instead of a recovery screen written for a run that ended, and the shared
quality sheet's sentence about estimates is now drawn only where the sheet can produce a figure -
including the second half of that finding, which the audit had not named: the *batch* sheet is
reachable from the summary screen, before anything is chosen, and had the same untrue sentence there.

**What this round did not do.** A carried question is the user's to answer and the app will not
answer it for them: the receipt and the measured sizes are deliberately not written beside a
question, so a launch cannot look the copy up, and it must not claim a save it cannot describe. A
question whose video the app *can* see a copy of is `Q1` above. And `RR6`'s open half - whether an
unanswered question should hold the flow - is answered by construction rather than by a rule change:
a restored question is not an item, so `remainingCount` is zero and the user may leave the flow, and
the question goes on protecting the video from Select all wherever they go next.

**An independent read of the round found three things worth changing.** A new case could not have
passed as written - `testAVideoAnEarlierRunCouldNotAccountForSurvivesTheNextRunAndItsRelaunch`
asserted the relaunched selection was `["b"]`, but "b" is the video the run above saved and the
fixture's history is shared with the second model, so nothing was tickable at all; the case now
tests the two reasons separately (`"b"` completed, `"a"` unaccounted) rather than the one number that
could not distinguish them. A second assertion held for the wrong reason: a record that describes no
run imposes nothing on the flow, and the case asserted a value that only matched because the app's own
default is the same resolution - it now gives the sheet a different quality so the assertion tests
the restore rather than the default. And "Done" had begun reaching `write(_:)`'s failure sentence,
which says the run stops before changing anything else in Photos; there is no run left to stop, so a
failed end-of-run record now says what a failed clear says, from one shared sentence. The fourth
finding was the reachability argument recorded as `Q1` above, where the evidence went the other way.

Validation, all of it on Windows and none of it a compiler: `npm run validate:native` PASS (38 app
files, 390 XCTest cases present), the call-site checker PASS over 52 files, 1,201 declarations and
7,804 call sites with 0 findings, `npm run typecheck` clean, the pod mirror verified, and
`prove:guardrails` 70 of 70 caught across four gates. Nine new cases pin the round: the file keeps a
questions-only record and reads it back, an unreadable file is told apart from no queue, a launch
with an unreadable queue says so, a saved question leaves its video out of Select all and is named
with the right sentence, the video survives a later run *and* that run's relaunch, ending a run keeps
its question while a run with nothing outstanding still clears the record, a hand tick answers the
question, a restored run remembers why it stopped, and every reason maps through the file. **None of
it has been compiled.**

### Round 24 — the copy the other flow could not account for

`SV1` was the last P2 on the one-video flow's list, and it is the same class as round 23's work on the
batch side: a copy that exists and is written down nowhere. The one-video pipeline asks Photos for a
copy, and if the app stops inside that transaction, Photos may have committed it - but the copy's
identifier is only ever learned *after* the call returns, so nothing on the device names it. The
original is not recorded either, because nothing completed. The batch flow's automatic selection
therefore saw two ordinary videos: this app's own output, and the original it came from.

The batch flow had already solved this for its own saves, by journalling them in the queue it writes
before every Photos step. The one-video flow has no queue, so the journal went where the two flows
already share memory: `ShrinkHistoryStoring` gained a bounded list of **unconfirmed saves**, written
with the original's identifier immediately before `photos.save` and cleared only when Photos hands
back an identifier. A throw and a nil answer both leave it, deliberately - those are exactly the two
cases where nobody knows whether the copy exists - and a later save that *is* confirmed clears it.

The batch flow adopts every entry at launch, **before** it restores its queue, as the same unresolved
question it raises for its own mid-save stops: the video leaves `selectableAssets`, the selection
screen names it and explains why, and the card's own hint says how to answer it. The order matters
and is the reason the adoption is a separate step: a question the queue can name more precisely -
the one where access covers only part of the library, or a finding a fresh look settles - has to
replace the adopted one rather than be written over by it. The entry is dropped wherever the question
is answered: the settling look, the "I checked Photos" tap, the tick by hand, and the one-video
flow's own confirmed save.

**What this round did not do, deliberately.** The copy itself is still not nameable: without the
identifier Photos never returned, no rule can exclude it from a selection, and the card's advice -
look in Photos for a second copy - remains the only instrument for it. That is a real limit and it is
written into the audit rather than papered over. The one-video flow also still says nothing on its
own screens about a previous unconfirmed save; the harm this finding names is only reachable through
the batch flow's automatic selection, which is where the app now excludes the video and explains
itself, and the alternative - a sentence about a video this flow cannot name either - would be a
claim without an instrument. `Q2` (the `.choosing -> .cancelled` edge with no caller) and `Q1` (the
concluded-copy exclusion) are still open, unchanged.

**A second, independent audit ran alongside it**, on the part of the app nobody had re-read since
round 19: what the batch screens say to VoiceOver, after four rounds of changes to those same
screens. Its eight findings and its sound list are in `docs/AUDIT_ACCESSIBILITY_RECHECK.md`, and the
table above is the index. The most valuable one is **not** an accessibility defect at all: round 23's
own notice about an unreadable record said the app had "set it aside", and no code sets anything
aside - which is what an independent read of a *different* subject is for. Both that sentence and the
working screen's count are fixed here; the other six are recorded rather than rushed, three of them
because they want one shared plural helper rather than six string patches.

**An independent review of the round found two routes the first version missed, and both are fixed
here.** The store was read only when the model was built, so an entry created while the app stayed
open - the batch flow handed to the one-video flow and back - never reached the selection screen;
`adoptUnconfirmedSaves()` now runs where the model already re-reads the store, on every scan, and it
leaves an existing open finding alone so a re-read cannot downgrade the queue's more specific kind.
And the second store could resurrect a question the first had answered: `openQuestionRecords` was
writing adopted entries into the queue file, which the one-video flow answers without ever touching,
so the file's stale copy would put the video back under "Left out of Select all" with a sentence
about a copy the app had since recorded. A question the store carries is now deliberately left out of
the file - one fact, in the store that every launch and every scan reads.

The same review corrected three claims the round had made about itself, which is worth recording
because the file's whole purpose is that its sentences are true. The headline said the batch "can no
longer be made to copy a copy": only the *original* is protected, and the copy stays unnameable. A
comment said two entries "can only pile up across a relaunch" - a save that throws leaves the flow
able to choose another video and throw again, and the round's own new case piles two up in one
session. And the handoff said the four test doubles implement none of the new requirements, when the
one the batch cases drive implements all three. It also read the two new sentences against the route
that raises them without stopping: "BatchShrink stopped while Photos was taking a copy" is false for a
one-video save that *failed*, so both the row's question and the card's paragraph now say what
happened to the copy rather than what happened to a flow. And it named one honest gap: the note's
durability rests on `UserDefaults` having reached disk before the process dies inside
`performChanges`, which is not something this machine can show - the batch uses a real file with a
protection class for the same job, and this is the one place the one-video flow's journal is weaker.

Validation, on Windows and none of it a compiler: `npm run validate:native` PASS (38 app files, 402
XCTest cases present), the call-site checker PASS over 52 files, 1,228 declarations and 7,966 call
sites with 0 findings, `npm run typecheck` clean, the pod mirror verified, and `prove:guardrails` 70
of 70 caught across four gates. Twelve new cases pin the round: the store's round trip and its
two-entries-in-one-session behaviour; the one-video flow writing the note before the call (read from
inside the save fake, which is the only way to tell that write from one made afterwards) and clearing
it on the answer; a save that throws leaving it; a save Photos finishes without naming the copy
recording the original instead of raising a question; the batch excluding and naming the video; the
tick by hand, the "I checked Photos" tap and a settling look each dropping the entry; the queue's
more specific question winning over the adopted one, and a scan not writing over it; and the working
screen's count naming what is still a question. **None of it has been compiled.**

### Round 25 — the sentences a single-video library reads

The accessibility recheck round 24 produced had eight findings and two were fixed with it. This round
takes four of the remaining six, all of them the class this project keeps finding: a sentence that is
right for the usual case and wrong for a reachable one.

`AX5` was the cluster. Seven screens wrote a count with no singular form - "1 videos to explore",
"1 videos left", "Delete 1 originals", "All 1 copies confirmed", "1 original may already have been
deleted" - and one video is the commonest library there is, so these are not corner cases; they are
what a person with one video reads first. The fix is one helper, `ShrinkFormat.counted(_:_:_:)`, with
the noun passed in so each screen still owns its own words, rather than a ternary at every site. Two
more of the same class turned up while applying it and are fixed with it: "1 aren't measured yet" and
"1 aren't supported yet".

`AX4`: the finished screen's overflow hint named all three actions whatever the menu held, so a run
with only failures read a hint promising a Delete that was not behind the trigger. The trigger's
presence and its contents already came from one list; the hint now does too, with a case pinning all
six shapes. `AX7`: a fresh install with an empty library was told "Nothing to shrink yet" twice, once
by the summary's headline and once by the notice below it, with "0 videos in your Photos library."
between them; each now names its own finding. `AX8`: the working screen's estimate figure and the line
explaining it were two unrelated elements to VoiceOver, and the stage was announced three times - the
card is now one element (the same pairing `A3` made in the quality sheet) and the card's repeated
stage text leaves the accessibility tree, exactly as the percentage text beside it already did.

**Two findings were left open on purpose, and the reasoning matters more than the patch.** `AX3` - a
stored save whose copy is *not smaller* being counted as a lighter video by the headline while its own
row says the opposite - cannot be fixed at one end without contradicting another: `live()` passing the
state through is what lets the row explain it rather than draw a negative figure, and clamping in the
summary would put "No copies were saved." directly above a row beginning "Saved ·". That is now `Q3`,
for a round that decides which of the three keeps the state, for a record only a file this app did not
write can hold. `AX6` belongs with `Q1` - it is the heading half of that fix.

`AX8`'s two changes are view structure, and this suite has no view harness: nothing here pins them, and
the round says so rather than implying a test covers the reading order. The count helper, the overflow
hint and the two empty-state headings **are** pinned, by three new cases.

Validation, on Windows and none of it a compiler: `npm run validate:native` PASS (38 app files, 405
XCTest cases present), the call-site checker PASS over 52 files, 1,233 declarations and 8,014 call
sites with 0 findings, `npm run typecheck` clean, the pod mirror verified, and `prove:guardrails` 70
of 70 caught across four gates. **None of it has been compiled.**

**The same round re-read the device plan against the code it will be used on**, which is the only
instrument for everything the source cannot decide and had not been checked against the tree since
round 20 - while rounds 21 to 24 changed the deletion path, the question machinery and the one-video
flow. Its worst finding was not a stale sentence: the plan never exercised the app's one irreversible
action at all. Every deletion row was a case where nothing is deleted, so Photos' own confirmation was
never declined, never accepted, and the app's "a deletion did not happen" endings were never seen -
in a plan whose whole purpose is to be the evidence for the risky paths. Two cases now do that, one
declining and one accepting, and the first says plainly that a phone cannot tell a declined alert
from an error, which is `DEL5`. Three more P1s went with it: case 5 asked the tester to compare
brightness in an HDR copy both flows refuse to make; the retrieval row said "nothing caps how many
times it may come back" about a loop a cap had landed under; and nothing anywhere asked a person to
open Photos and count the copies after a save was killed - the one observation the whole mid-save
question rests on. The process-termination row became two cases, one per flow. The audit's D9 to D11
are recorded above rather than taken in passing; the plan's own file carries the changes, and it is
the one part of this round a person can check by reading.

**An independent read of the round found one thing that would have failed the first gate, and
several the eye had missed.** The failing one was a *pre-existing* case: changing the empty notice's
heading left `testAnEmptyLibraryDoesNotClaimVideosWereRefused` asserting the old string, so the first
CI run after 1 October would have reported a failure in a case the round did not touch - and the audit
document that prompted the change named that very case as its pin. It is updated, and the round's own
case no longer repeats what it already asserts. Two more were wording: `1 isn't measured yet` and
`1 isn't supported yet` used a bare digit as the subject of a verb, where every other singular this
round pairs the number with a noun, so both now read `1 video isn't ...` - and the two `measured`
sites are the summary screen's notice *and* the selection screen's footer, which had the same
sentence. The paused screen's "Copies already saved are in Photos." read as a plural over one copy, so
it says "The copy already saved is in Photos." at one. And the new helper was dropping the thousands
grouping the old string had, so it formats its own count. The remaining findings are recorded rather
than patched: the overflow hint's `the originals` is a generic plural (`the original` would be wrong
for several, and the count is on the menu item right beside it), and `marketing/app-store-listing.md`
now asks for a multi-copy run for the screenshot whose caption quotes the read-back line, because the
one-copy screen no longer prints that line.

### Round 26 - the Originals sheet checked, and what a launch shows before the app draws

The app's riskiest setting is the one choice that decides whether an original is removed, and no round
had ever read the *sheet that sets it* against the code that obeys it. Round 26 did, and it found
nothing to change - which is worth recording, because "we checked and it holds" is the other half of
the evidence a future round needs, and because two of the claims look wrong until the code is read.

| What the sheet says | What the code does |
| --- | --- |
| "Photos asks you to confirm each batch of deletions, and no app can pre-authorise that." | True. One `PHPhotoLibrary` transaction is one confirmation. `Deletion as it goes` queues candidates and flushes a transaction every `deletionBatchSize` (5) plus a final one - pinned by a case asserting `[5, 2]` for a run of seven - and the comment beside the constant says batching is the only lever over how often iOS shows its confirmation. The word *batch* is doing real work in that sentence: a run of a hundred videos in `Delete as it goes` meets about twenty confirmations, and the mode's own description ("Each original goes as soon as its copy is saved and checked") is approximate for the four that wait for the fifth |
| "Deleting at the end means one confirmation for the whole run." | True, and it is a different code path from the mode above: nothing is queued during the run at all, and the finished screen's offer submits every candidate in a single transaction. So "one confirmation" is exact for this mode however long the run was |
| "A copy has to be saved, smaller and confirmed in Photos before an original is touched. Anything else is kept, and the run tells you why." | True. `DeletionPolicy.decision` requires the mode to delete, a smaller saving, a confirmed read-back, a recorded receipt and a matching fresh look. Kept candidates are recorded with the reason in the row, and the modes that keep everything say so collectively |
| "This applies to batch runs. The one-video flow never deletes." | True: that flow's only PhotoKit calls are access, retrieve, save and cancel |
| The tap on a deleting mode goes through one more hard confirmation | True: `.off` is set immediately, and either deleting mode raises a confirmation naming the mode before it is stored |

**Two boundaries the same reading exposed**, recorded rather than fixed.

| ID | Priority | Item | Status |
|----|----------|------|--------|
| Q4 | 3 | `UserDefaultsShrinkHistoryStore` holds **2,000** completed identifiers, 2,000 created-copy identifiers and 2,000 unconfirmed saves, oldest first, each evicting silently once full (one `append`, three keys). The first two exist to keep Select all off a video this app has copied, so an evicted mark means the run re-ticks it: a second copy of an original that already has one, or - for an evicted *copy* - the app shrinking its own output. The third would resurrect round 24's harm instead: the note that keeps an original out of an automatic selection would be gone | **open, and deliberately not patched with pruning.** Each processed video appends one entry to each of the first two lists, so the first eviction lands around the **two thousandth** video - far, but not absent. Pruning (dropping marks for videos the library no longer lists) is the obvious relief and does not work for this app: a user who deletes originals keeps the *copies*, whose marks are the ones that matter and which pruning cannot remove. The honest next step is a decision about the bound itself: a file-backed store could hold an order of magnitude more than `UserDefaults` reasonably should, and that is a migration whose failure mode is losing the marks - the harm they exist to prevent. The comments in the store say only that a list "cannot grow without limit"; nothing in the tree argues for 2,000 as the number |
| DEL7 | 3 | See the row in the round-20 table above. Round 26 wrote down why the *lookup* half is blocked - and the honest version of that is narrower than "leave it": the audit that raised this proposed two fixes, and only one of them needs to know what PhotoKit answers in the deletion window. Settling it by looking the original up is unsafe while a delete may still be landing, and re-offering a deletion is worse. But a sentence saying plainly that the app will not try again, or a one-way control that settles only the safe direction (treat it as gone and never re-offer), needs no knowledge of PhotoKit at all | **open.** The row is a dead end in the sense that nothing can act on the answer; it is not yet a dead end that has to stay one |

**The same round audited the launch path for the first time**, from the Expo shell through the module
to the SwiftUI root, because every earlier audit had looked at the Swift screens or the Swift pipeline
and nobody had asked what a person meets in the seconds before the first screen exists. The audit is
**[docs/AUDIT_LAUNCH_PATH.md](docs/AUDIT_LAUNCH_PATH.md)**; two of its findings are fixed here and the
rest are recorded with what they need.

| ID | Priority | Item | Status |
|----|----------|------|--------|
| LP1 | 1 | The shell draws no words of its own: `App.tsx` renders one native view, the view behind it is a flat colour, and the SwiftUI host attaches lazily - so until the first SwiftUI frame the app can be a wordless near-black rectangle, and if the host never attaches it stays one | **half done, round 26.** The native view now draws its own words while it is waiting (a centred "Starting…" in the app's near-black) and replaces them with "BatchShrink could not start. Close the app and open it again." if the controller is never found - see LP5. What is *not* done is the shell's own segment before the view exists (Expo's splash covers it) and a ready signal that would let JS draw something until the host reports itself; that needs a render to justify a new inter-layer contract |
| LP2 | 1 | The interrupted-run restore runs on the main actor in front of the first frame: `cleanWorkspace`, the adopted save notes, the queue restore with one Photos revalidation per saved item, the mid-save resolution and the monitor's registration all happen when the view first touches the session | **open, and now with the fix shape rather than a blocked one.** The settle path needs the lookups only for the *flagged* items - `resolveMidSaveItems` iterates `.needsCheck` items, which is usually none or one - while the full `refreshDeletionLook()` over every saved item exists for the finished screen's delete offer and for nothing else. So the split is: look up the flagged items before settling, and let the screen that offers the deletion ask for the rest when it appears (`BatchFinishedScreen` is the only reader of `deletableItemIDs`, and the run's own tail and `finishNow()` already take that look before that screen is drawn). It is a change to the exactly-once work, not a launch tweak, and the cost it removes is still a **measurement**: the restored-run audit named the launch cost as device-only in round 20, and it is the first question for the 1 October session, because if the restore is fast the whole thing is invisible |
| LP3 | 2 | The notice for a record that could not be read was the last item of about 850 points of scroll on the start screen, below a 300-point illustration, and its twin on the selection screen sat below the whole grid - while the advice it carries ("look in Photos before running the same videos again") is about the choice the user is making on that screen | **done, round 26.** Both notices are now drawn under the headline on the start screen and above the grid on the selection screen, with the reason written beside them |
| LP4 | 2 | The app icon and splash are a generated placeholder, and two documents described it as the finished brand mark | **docs done, round 26**: `docs/DESIGN.md` no longer claims a brand mark it has not got and `marketing/app-store-listing.md` no longer counts the icon as existing rather than owed. **The mark itself is open and is a design decision**: `scripts/generate-icon.mjs` draws it deterministically, so a new mark either has to be drawn in that script or the convention that keeps binaries out of the repository has to change deliberately |
| LP5 | 2 | If the host controller is never found, the view drew nothing, logged nothing and said nothing - indistinguishable from a slow start | **done, round 26**: the view retries twenty times at 50ms, then says "BatchShrink could not start. Close the app and open it again." and logs an error naming the reason. Reachability is low (an ordinary Expo hierarchy has the controller as an ancestor) but the failure mode was a silent black screen on the shipping path |
| LP6 | 3 | The shell's only other state is developer copy ("Install the BatchShrink development build, then connect it to this development server"), which a user would meet only in a misconfigured build | open, and honest as it stands: that string is the missing-module fallback, and it is written for the person who can fix it |

The audit's "checked and found sound" list is worth keeping: no path shows the introduction twice or
skips it for a new user, a restored run deliberately takes precedence over it, the replay touches no
stored key, there is no launch-time route to the Photos prompt (`requestAccess()` has exactly three
callers and all are the user's own), the introduction's promise about when access is asked holds, all
eight phases draw a screen, the shell and the app use the same near-black, and `app.json`'s version,
permission, device and orientation facts match the code. The boundary worth stating plainly: **every
rendered-screen observation in this project is the standalone harness; the Expo shell to module to
SwiftUI transition has never been observed by anything.**

**What could not be verified, said plainly.** Three of this round's changes are not behaviour a case
can hold: where two notices sit in a scroll view, whether a conditional group adds a gap when it draws
nothing, and a UIKit placeholder label in the module that no test target compiles. The gates pattern-
scan all of it and the checker sees the new declarations, but nothing here reads a screen or runs the
shell. Two things were therefore checked by hand and are worth the next reader's attention: the
ViewBuilder child counts on both screens (seven and nine, under the ten-child limit a compiler
enforces and no local gate can see), and that each notice group sits behind a single `if`, because a
group that draws nothing must also take no room - otherwise every ordinary launch would gain a 24-point
gap where the notices are not. The honest statement about the placement is *narrower* than "no test can
cover it": the UI test target launches the app on a simulator and waits on drawn controls, and whether
the notice is visible without scrolling is exactly what a hittability or frame check would measure -
what is missing is a hook that puts the harness into the unreadable-record state, and that file already
documents why a naive launch-argument hook is a trap.

**An independent read of the round found the most valuable defect of the cycle, and it was not in the
round's own diff.** Rereading the one-video flow's save path, it found that a *confirmed* save records
the copy and never marks the **original** as one this iPhone has shrunk - while the batch flow does
mark it, and while round 24's branch for a save Photos finished without naming the copy marks it too.
The consequence is the second copy this whole area exists to prevent, and unlike `Q4` it needs no
unusual state: shrink a video in the one-video flow, then run a batch and tap Select all, and the app
makes a second copy of a video that already has a smaller one. The old test asserted it away by
checking that the whole set was empty while its message defended only the copy, and its library did not
contain the original, so the consequence was never exercised. The original is now recorded on either
answer, and the case drives the whole save, hands the batch flow the original, the copy and one other
video, and checks what an automatic selection does with each. The same read found the launch
placeholder leaving the screen one line before the expensive part it exists to cover (the session's
own initialisers run while the root view is built), which is fixed by moving the removal after the
host's view is added; a give-up log that stated a verdict rather than the observation it had; and that
the one sentence written for a stuck user was the only string in three rounds of VoiceOver work that
nothing announced, which now posts an announcement when it appears.

### Round 27 — the label that was never drawn, and an advisory with no way to act on it

Round 26 gave the shell a placeholder so a launch would not be a wordless rectangle, and an
independent read then found it was removed one line too early. Round 27 found that both of those fixes
were aimed at the wrong thing. **The label was never drawn at all on the path that matters.** The
common case is the controller being found on the first layout pass: the label is added and removed
inside that one call, and between those two lines the root view is built - which is the first touch of
the session's statics, whose initialisers run the workspace sweep, the adopted notes and the queue
restore **on the main actor, inside the same runloop turn**. UIKit commits a turn's drawing at the end
of the turn, so a label added and covered within it never reaches the screen; the screen stays the
native view's own background, which is the app's near-black. Neither when the label was removed nor
what covered it was the problem; nothing could draw.

The fix is one hop through the main queue between finding the controller and building the host, so the
label commits before the work it describes starts, and the removal then happens after that work rather
than before it. The cost is that the app draws its own content one frame later on a launch where the
restore is instant, and the gain is that a launch where it is not shows a word instead of a blank
rectangle. A `isBuildingHost` flag keeps a burst of layout passes from building two hosts, and the
give-up path now distinguishes a view that left its window (where the next attach will do) from a
controller that went away (where another look is worth taking) - so the log line is an observation
rather than a verdict about a controller that may never have been missing.

The lesson is one this file already carries and had to be taught again: a fix aimed at the line that
looked wrong, without asking what the mechanism does, is not a fix. Two agents and two rounds moved one
`removeFromSuperview()`.

**And the mechanism this round rests on is itself a claim only a render can settle**, which the
independent read said plainly: one main-queue hop is a turn boundary only if the queued block is drained
*after* UIKit commits the turn's drawing. If React Native's mount drives the first layout from inside a
main-queue block, libdispatch drains the queue until it is empty before the commit - so the label would
be added, covered and removed inside one commit, exactly as before, and the change would be a no-op
rather than a regression. Both outcomes are acceptable; which one happens is the first thing to look at
on a simulator, and it is worth more than any test this round could have added.

The other half of the round closes `DEL7`, the last *reachable* advisory with no way to act on it. An
original whose delete Photos never answered for comes back as uncertain, and the app then never offers
it for deletion again while this run's record is the one in hand - so there was nothing for the user to do and
nothing that said so. Both screens now end that sentence with what the app has decided, and the
sentence itself moved into one function, because the paused screen's note and the finished screen's
line carry the same branch and either can be the one a user reads.

Validation, on Windows and none of it a compiler: `npm run validate:native` PASS (38 app files, 406
XCTest cases present), the call-site checker PASS over 52 files, 1,240 declarations and 8,074 call
sites with 0 findings, the pod mirror verified, and the cases that state the uncertain-original
sentence updated with it. The shell change cannot be compiled or rendered here at all - no target on
this machine builds the module, and the transition has never been observed - so it is written to be
read rather than to be trusted.

**The same round opened the last surface no audit had ever read: what the app shows when it previews a
video.** Two places do that - the quick look from the selection grid, and the copy the one-video flow
shows before saving it - and neither had been through anything. The audit is
**[docs/AUDIT_PREVIEW.md](docs/AUDIT_PREVIEW.md)**, its own status map is at the top of that file, and
the shape of what it found is one this project should recognise by now: a state the code can reach that
says nothing at all.

| ID | Priority | Item | Status |
|----|----------|------|--------|
| PV1 | 2 | The 20-second bound covers PhotoKit's *request*, not the player: an item that arrives and never becomes ready left a black rectangle under a note telling the user to press play, with no sentence and no bound left running | **half done, round 27**: the sheet waits for the item's own status, under 10 seconds of its own, and a `.failed` item or a wait that gets nowhere gets a sentence. Two clocks now, and the device plan's row says so |
| PV2 | 2 | The one-video preview has no loading and no failure state at all - one unconditional player under a footer asking the user to check the picture | **done, round 28**: the same three states as the quick look, through the one `PlayerReadiness.wait` both previews now call, with the sheet's own sentence because a failure here means the app's own file is gone. The footer is drawn only once there is something to check |
| PV3 | 2 | Both of the scrub sheet's notes were drawn in the states that contradict them | done, round 27 |
| PV4 | 2 | The one failure line is whichever pipeline sentence was written for another moment - including "add it to your allowed videos in Settings" for a video Photos no longer has | **done, round 27**, with the sheet's own words for the two errors it can see and a plain sentence for the rest - which is also where a disk-full error and a cancelled fetch land - pinned by a case |
| PV5 | 2 | Nothing tells VoiceOver that the look finished, failed or arrived | **done, rounds 27 and 28**: the failure is one element whose words wrap under the box, and both previews post an announcement when a look becomes playable, because the spinner's disappearance moves nobody's focus |
| PV6 | 2 | Both previews play PhotoKit's `.current` version while the run exports `.original` - kept in step today only because edited videos are refused by name | **recorded as an invariant, round 28**: `PhotoLibraryService.playerItem` now says why `.current` and the run's `.original` are the same file for every video this app will play, and what has to move if `AssetRules` ever stops refusing edited videos. Stated rather than changed, because asking for the original of an unedited asset buys nothing and can cost a full iCloud download for a look |
| PV7 | 3 | Neither preview reacts to backgrounding, and no audio session is configured, so "check the sound" can be silenced by the Ring/Silent switch | open, and it is a decision about what the app claims from the phone rather than a patch |
| PV8 | 3 | "Size on screen" is PhotoKit's pixel size, while every other picture size in the app is the media's with rotation applied | open |
| PV9 | 3 | Dismissing during the load could build a player nothing would ever clear | done for the scrub sheet, round 27; the other preview's await belongs with PV2 |
| PV10 | 3 | At the largest text sizes the failure sentence lived in a box whose height is decided by its width | done, round 27: the words moved out of the box and under it, where they wrap |
| PV11 | 3 | A copy this app made was labelled "Original file" on its own sheet | done, round 27: the row names the file's size, not whose file it is |

The audit's sound list is worth keeping too: nothing in either preview ever calls `play()`, both pause
and clear their item on dismissal, the batch's sheet cannot outlive its screen, the 20-second bound and
its failure line are pinned by two tests, the iCloud sentence matches `isNetworkAccessAllowed`, the copy
the one-video sheet plays is byte-for-byte the file `save()` re-verifies, and neither sheet is offered
where it cannot work.

### Round 28 — the preview that had no states at all

The preview audit's second finding was the plainest one in the file: the sheet that shows the copy
before it is saved drew a player and nothing else. No loading state, no failure state, one footer
asking the user to check picture, orientation and sound - over a file that, if it were gone or
unplayable, would leave a black rectangle and a working-looking transport that does nothing. Its
reachability is lower than the quick look's, because the file is one this app wrote seconds earlier and
verified, but the state existed and said nothing, which is the class this project keeps finding.

It now has the same three states the quick look got in round 27, through **one** implementation:
`PlayerReadiness.wait(for:seconds:)` is the wait both previews call, because both can be handed a player
item that never becomes a video and both must answer the same way. The sentence is the sheet's own,
because the failure means something different here: "This copy could not be played, so there is nothing
to check. Discard it, then export the video again." - the route that exists, since the save path
re-verifies before Photos is asked and would refuse the same file. The footer is drawn only once there
is something to check.

The same round closed the rest of `PV5`: both previews now post an announcement when a look becomes
playable, because the spinner disappearing moves nobody's focus, so a VoiceOver user who heard
"Opening…" had to go looking for whatever replaced it. And `PV6` - the previews playing PhotoKit's
current version while the run exports the original - is now an invariant recorded where the option is
set, rather than a change: for every video this app will play the two are the same file, because
`AssetRules` refuses an edited video by name, and asking for the original of an unedited one would buy
nothing while risking a full iCloud download for a look.

Validation, on Windows and none of it a compiler: `npm run validate:native` PASS (38 app files, 407
XCTest cases present), the call-site checker PASS over 52 files, 1,243 declarations and 8,105 call
sites with 0 findings, the pod mirror verified, and a case that pins the readiness wait's timeout path
with an item for a file that is not there - which is deterministic, because a wait of no seconds
answers before the item can change its mind. What no case can hold is the two views' layout, the
announcement, or whether AVKit paints anything over an item that never becomes ready.

**The other half of the round was aimed at the thing that will be the only evidence in October.** The
suite is the gate once CI returns, and a case that cannot fail is worse than no case - so this round
audited the suite itself. The audit is **[docs/AUDIT_TEST_SUITE.md](docs/AUDIT_TEST_SUITE.md)**, it read
all 408 case bodies, and it found fourteen worth naming. Four were repaired here, because they were
false assurance about safety rather than redundancy.

| # | Priority | Item | Status |
|---|----------|------|--------|
| 1 | 1 | `testLiveStatesRoundTripThroughTheStoredForm` asserted `live(stored) == live(stored)`: `live` is pure, so the assertion held whatever the mapping did, in the case that guards the queue's state machine | **done, round 28.** Six pairs round-trip in both directions and five are asserted as the coarsening they are - everything in flight waits again, and a save Photos may have committed comes back as a question |
| 2 | 1 | Every `FlowRoutingTests` case fed the rule a *copy* of `canChoose`'s stage list, so a model that gained `.choosing` would leave all eight green while a user could walk away from an open picker | **done, round 28**, in `PipelineTests`, where the real model fixture lives: two cases drive the model to `.choosing` and to `.readyToSave` and hold the rule to its own answer |
| 3 | 1 | The two sentences that tell a user to look in Photos were never asserted as text - every reference compared a constant with itself, so "Look in Photos" could have become its opposite with all 407 cases green | done, round 28 |
| 4 | 2 | The failure vocabulary was pinned for shape only, and one confirmation case built its expectation out of the very string it was checking | **done, round 28**: the sentences that carry an instruction are asserted as content, including `.save`'s "Inspect Photos before retrying" and the three `DeletionMode.detail` strings |
| 5 | 2 | `testTheLiveOverloadsReportWhatTheSystemSays` cannot fail on a runner, and its comment claimed the opposite | recorded, round 28: the case now says what it cannot catch and why the two cases above it matter more |
| 6 | 2 | The `PlayerReadiness` case added in the same round passes against a stub returning false, because a wait of no seconds ends at the deadline | recorded, round 28: the case says so, and names the simulator plan as where a real item would come from |
| 7 | 3 | The corrupt-container case asserted only "not a cancellation" while its siblings assert the exact error | **done, round 28**: the refusal is asserted to arrive as a `PipelineError`, which is what its name claims |
| 8 | 3 | `testARowIsIdentifiedByTheVideoItIsWorkingOn` built a value and checked what it had just passed in | **done, round 28**: it now pins the identity convention every lookup in the model depends on, and that two videos cannot collide |

The audit's "thin but honest" list is worth reading before adding cases to those areas, and its sound
list - the 26 deletion-policy cases, the eligibility sentences, the scan arithmetic, the queue's four
durability boundaries, the eight-subset overflow hint - is what not to re-walk. The four P1 and P2
repairs above were possible without executing anything: each is a case that *had* been asserting a
value, so replacing the assertion with the one its name promised is a source edit whose meaning can be
read.

**An independent read of the round found four things, and three of them were in the round's own new
code.** The first was the class the round had just fixed, one state further in: while the quick look
waits for the item to become playable, the box is drawn as a player - so the note under it said "press
play" over something that does nothing, for up to ten seconds. The spinner now covers both waits and
the note is drawn only once the item says it can play. The second and third were in the shell's hop: a
`host != nil` that arrives while a hop is pending was being retried and could eventually log "no parent
view controller was found" and announce a failure on an app that started, which now returns quietly;
and the retry budget was never reset when a cycle gave up *without* building, so the comment promising
that a later attach starts its own count was only true of the cycles that succeeded - it is now reset
on detach as well. The fourth was in the deletion sentence the round added: it is drawn for a deletion
still with Photos, where the app has decided nothing and an answer that comes back refused leaves the
original deletable again, so the clause now waits for the answer rather than predicting it, and a case
pins both forms. The read also corrected three claims in this record and one in the audit's status map
- the sentence is scoped to *this run* rather than promising anything about a later one, the sheet's
own words cover two errors while a disk-full error and a cancelled fetch land on the plain sentence,
and hiding the iCloud note on failure goes one step past what the audit recommended, which is now
recorded as a choice rather than as the finding's own fix.
