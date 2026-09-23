# Verification handoff

This is the practical first-run document for the code as it stands at commit `dcd0695`. It
replaces the earlier `docs/MAC_VALIDATION_HANDOFF.md`, which assumed a Mac with Xcode. The
owner uses Expo only and does not own a Mac, so no step in that document could be run. The
verification route here is an EAS cloud build, which compiles the Swift on Apple's own
machines.

**Read this first: what has changed since the sections below were written.** They are anchored to
`dcd0695`, and several of their present-tense sentences have been overtaken. Each is corrected
where it appears; this list is the map.

- **There is a Git remote, and CI is now the everyday gate.** The repository is pushed to a
  private GitHub remote on `main`, now at `f541699` (round 19). `.github/workflows/ios-tests.yml`
  has three jobs - the tests, the Expo app build, and the app-launch smoke test - and job 1 runs
  the three local gates as well. EAS is now only for builds that install on a device.
- **The test count has moved repeatedly.** It was 162 at this document's commits and has grown
  every round since; the local gate prints the current count. Take the number from a run, never
  from this file.
- **The runners stopped starting.** On 2026-09-23 every job of the account's GitHub Actions
  workflow began failing about nine seconds after creation with no runner and no steps,
  including a throwaway Linux job, while GitHub reported all systems operational. So nothing on
  `main` after `31b6245` has been compiled, and the round 18 and 19 source in particular has
  never been built. `AGENT_LOOP.md` carries the evidence, the arithmetic and the options.
- **Both routes have now run.** The last observed green state: job 1 (compile and tests) and job
  2 (the Expo app build) green at `31b6245`; job 3 (launch and screen render) green at `780f14f`,
  the first observation of a screen in this project.
- **The device plan now describes `07526c4`**, not `559f693`, and round 18's first-launch fix
  means the system permission alert is no longer opened at launch.

Git state at the time this document was written: branch `main`, HEAD `dcd0695`, clean tree, no
configured remote. All four of those have since changed; `git log` and `git remote -v` are the
current answer.

## What has never been compiled, and where a failure would show

Three rounds of Swift sit on `main` that **no compiler has ever seen** — every change after
`31b6245`, because the account's Actions minutes ran out on 2026-09-23 and reset on 1 October. It is
about 2,300 lines across nineteen files. The local gates pass, and since round 22 the call-site
checker resolves **8,014 call sites** with no findings — up from 6,190, because it now sees two
shapes it could not before: enum cases with associated values, and calls written with a leading dot
like `.planning(resolution:frameRate:)`, of which the scan scope holds 1,371. Everything the checker
judges is still only *names and argument labels*: it checks no types, no members' types, no
generics and no availability, and it leaves a member call alone when the name is ambiguous or the
call writes no labels. So the first green gate after 1 October is the first real reading of this
work, and the point of this section is to make a failure cheap to attribute.

`git log --oneline 31b6245..HEAD` lists the commits; `git log -1 --format=%h -- <file>` names the
commit that last touched a file a compiler complains about.

Ranked by how likely a compile error is to be in them, with the narrowest revert for each:

| Area | Files | What to look for first |
|------|-------|------------------------|
| Round 19's haptics (`A9`) | `ShrinkStyle.swift`, `QualitySelector.swift`, `BatchFlow.swift`, `SingleVideoFlow.swift` | `ShrinkHaptics.feedback` is main-actor isolated and is called from closures passed to `.sensoryFeedback(trigger:_:)`. That is legal because a non-`Sendable` closure inherits its context's isolation, but it is the one place in the pile where a toolchain that disagrees would say so. The narrowest fix is to make `feedback` `nonisolated` — it returns `SensoryFeedback` values, which are plain values |
| Round 21's list (`RR2`) | `BatchScreens.swift` | `RefusedVideoList` became `VideoReasonList` with two new defaulted properties, one a tuple. Every call site goes through the synthesised memberwise initialiser, so a label that does not match is the likeliest error; the revert is to rename it back and drop the two parameters |
| Round 19's numbers (`E2`) | `LibraryModels.swift`, `BatchScreens.swift`, and three test files | `CopySizeModel.Basis`'s two cases each gained a `frameRate` label. Every construction, every `switch` over a basis and every pattern match had to move with it. The revert is the `Basis` change alone; the rest of the round's wording stands without it |
| Round 19's accessibility | `QualitySelector.swift` | the unselected pill's stroke is `AnyShapeStyle(ShrinkStyle.hairline)` in one arm of a ternary. If `strokeBorder` cannot take that, the narrowest fix is a plain `ShrinkStyle.hairline` with the selected arm's opacity moved into the style |
| Round 19's finished screen (`A2`) | `BatchScreens.swift` | a `Menu` containing a `ForEach` over an `Identifiable` enum with a `switch` inside it, fed into a `@ViewBuilder` action bar |
| Round 20's screens | `BatchScreens.swift`, `BatchViewModel.swift` | the new static sentence functions are called with explicit labels; the paused screen draws `BatchFinishedRow` with the same five arguments the finished screen does |
| Round 20's deletion fixes | `BatchViewModel.swift` | `beginRun`'s new clearing block, the mode guard at the top of `flushDeletions`, and `finishNow`'s call to `refreshDeletionLook` |
| Round 21's selection rule | `BatchViewModel.swift` | `unaccountedIdentifiers` builds a `Set<String>` by `compactMap` over a dictionary whose value is Equatable |
| Round 23's record (`RR2`, `RR3`, `RR5`) | `BatchQueueRecord.swift`, `BatchQueueStore.swift`, `BatchViewModel.swift`, `BatchScreens.swift` | three new stored members on `BatchQueueRecord` (the memberwise order is now `version, settings, items, refusals, questions, pause`), a protocol requirement whose default lives in a protocol extension (`hasUnreadableRecord()`), and `reset()`'s questions-only write. The memberwise call sites, and the `@MainActor` default that satisfies an isolated requirement, are the likeliest errors; the narrowest revert is the `questions` and `pause` fields with the restore that reads them |
| Round 23's one-video fixes | `CompressionViewModel.swift`, `PipelineModels.swift`, `QualitySelector.swift`, `BatchFlow.swift`, `SingleVideoFlow.swift` | `QualitySheet` gained a fourth stored property with a default that names a `static let` of its own type, and `BatchFlow`'s call moved off a trailing closure to a named `estimate:` argument. If the compiler dislikes either shape, the revert is the parameter and its two call sites |
| Round 24's one-video journal (`SV1`) | `ServiceProtocols.swift`, `ShrinkHistoryStore.swift`, `CompressionViewModel.swift`, `BatchViewModel.swift` | three new requirements on `ShrinkHistoryStoring` whose defaults live in a protocol extension (three of the four test doubles are unchanged; the one the batch cases drive implements them), and the note written immediately before `photos.save`. The likeliest error is the `@MainActor` default that satisfies an isolated requirement; the narrowest revert is the three requirements and the call sites that write and clear one |

If the gate fails, the fastest route is the compiler's own file and line, then `git log -1` on that
file. Every round since 19 also left its reasoning in `AGENT_LOOP.md`, and the two audits' findings
are in `docs/AUDIT_*.md`, so a change that turns out to be wrong can be judged against why it was
made rather than reverted reflexively.

| Commit | What it is |
|--------|------------|
| `10ab65f` | baseline checkpoint before any agent work |
| `559f693` | round 1: durable Photos boundaries, copy revalidation, honest verification |
| `65d6a09` | round 2: library reconciliation, thumbnail refresh, warnings that are visible |
| `dcd0695` | round 3: copy exclusion, eligibility rules, compile-risk audit |

Nothing in this document is a result. No build, test or device run recorded here has been
observed by the author of this document. The sections below describe what a command does and
what its output would mean; they do not record that any command passed.

## 1. Commands to run, in order

### Pre-flight on this machine (no Mac needed)

These three are the same checks that pass on Windows. They are pattern scans and a TypeScript
check. They say nothing about whether the Swift compiles.

```
npm run validate:native
npm run typecheck
node scripts/sync-native-sources.mjs --check
```

`npm run validate:native` is `node scripts/validate.mjs`, a source-pattern guardrail, not a
compiler. `npm run sync:native` regenerates the mirrored Swift under
`modules/videoshrink-native/ios/VideoShrinkCore/` from `VideoShrink/{Models,Services,Presentation}`;
the `--check` form fails if the mirror is stale. Any Swift edit in those folders needs
`npm run sync:native` first, because the EAS builder regenerates the mirror on its post-install
step and then checks it.

### The cheap compile check: a simulator build

```
npx eas-cli build --platform ios --profile development-simulator
```

This is the verification step to run first. A build for the iOS Simulator is not code-signed
with an Apple distribution certificate or provisioning profile and does not need a registered
device, so it needs no Apple signing credentials at all. It runs the same Swift compiler on the
same Swift sources as a phone build; the only difference is the target it compiles for. That is
why it is the cheap way to find out whether the Swift compiles.

### Builds that target the phone

Use these when the goal is to install and use the app on the registered iPhone, not to check
the compiler. Both are signed and need Apple credentials and a registered device.

```
npx eas-cli build --platform ios --profile development
npx eas-cli build --platform ios --profile preview
```

### The shipping profile

```
npx eas-cli build --platform ios --profile production
```

`production` is tied to App Store submission (`submit.production.ios.ascAppId` is set in
`eas.json`). It is for shipping the app, not for checking whether the code compiles; use the
simulator profile for that.

### What each profile does, from `eas.json`

| Profile | Key settings in `eas.json` | What it produces | When to use it |
|---------|----------------------------|------------------|----------------|
| `development` | `developmentClient: true`, `distribution: internal`, `ios.simulator: false` | a signed development client for a registered physical iPhone | run the app on the phone against the Metro dev server |
| `development-simulator` | extends `development`, `ios.simulator: true` | a simulator-only build; cannot be installed on a phone | the cheap compile check |
| `preview` | extends `production`, `distribution: internal`, `ios.simulator: false` | a signed standalone internal build with the JavaScript bundled, so it opens straight into the app with no dev client and no Metro | reviewing native interface work on the registered phone |
| `production` | `distribution: store`, `developmentClient: false` | the App Store build | shipping only |

`eas.json` also sets `cli.version` to `>= 24.7.0` and `appVersionSource` to `local`. The EAS CLI
is authenticated on this machine as `wilfrat1`.

## 2. What an EAS build proves, and what it does not

### It proves the Swift core compiles

`modules/videoshrink-native/ios/VideoShrinkNative.podspec` sets
`s.source_files = "**/*.{h,m,mm,swift,hpp,cpp}"`, which covers everything under
`modules/videoshrink-native/ios/`. That includes `VideoShrinkCore/`, the mirror of
`VideoShrink/{Models,Services,Presentation}` produced by `npm run sync:native`. That mirror is
the bulk of the app, and it holds every file rounds 1 to 3 changed. When a build finishes, the
Swift in that mirror compiled for the target it was built for.

### It does not prove any of the following

- **The test target.** `VideoShrinkTests/` holds the XCTest cases (the local gate prints the
  current count; take it from a run, never from this file), and no ordinary EAS build
  compiles or runs them: the pod glob above does not reach `VideoShrinkTests/`, and the
  standalone project is not part of the Expo build. The opt-in `verify-tests` profile in
  section 6 is the one exception: it compiles the test target and then runs it on a simulator
  when the builder has one. Every other profile does neither.
- **`VideoShrink/VideoShrinkApp.swift` and the standalone Xcode project.** The standalone
  XcodeGen app is not what EAS builds. `VideoShrinkApp.swift` is not inside the pod glob and is
  not compiled by an EAS build.
- **Every device behaviour.** Nothing about Photos, the media pipeline, memory, thermal state,
  interruptions or HDR is exercised by a compile. See section 7.

The honest one-line claim after a green simulator build is: the Swift under
`modules/videoshrink-native/ios/` type-checks and compiles for that target. Nothing more.

## 3. Reading the result of a build

```
npx eas-cli build:list
npx eas-cli build:view <build id>
```

`build:list` lists recent builds with their ids and statuses. `build:view <id>` shows one
build, including the logs URL it prints.

A failed build's log is where the compile error appears. Open the logs URL, or run
`npx eas-cli build:view <id>` and follow the link it prints, and read the compiler output: this
is the same `xcodebuild` error text a Mac would show, with the file, line and message. Copy the
failing line before changing anything, so the choice to fix forward or revert is made against
the actual error rather than a guess.

## 4. Ranked most-likely-first-failures

Ordered most likely to surface first. Every entry is a thing a round reported it could not
compile-check, taken from the round reports in `AGENT_LOOP.md`; nothing here is invented. Each
entry says where it would appear: **in the EAS build log** (a compile failure the simulator
build will show) or **only at run time** (the compiler cannot see it; it needs a simulator or a
device). Nothing here is a prediction that it fails.

### 1. Memberwise-initialiser argument order and property-list drift across all three rounds

- **Where:** the EAS build log.
- Files: `VideoShrink/Models/DeletionPolicy.swift` (`AssetSnapshot`, `DeletionEvidence`),
  `VideoShrink/Services/PhotoLibraryService.swift` (`snapshot(identifier:)`),
  `VideoShrink/Presentation/AssetThumbnail.swift` (`AssetThumbnail`), the `AssetThumbnail(...)`
  call sites in `VideoShrink/Presentation/BatchScreens.swift`, and the new `Traits` values
  (`isCinematic`, `isSharedOrRestricted`) added in round 3.
- Symptom: `argument 'x' must precede argument 'y'`, or `extra argument 'bytes' in call`.
- Why it is first: three rounds each added properties to structs and views, and a memberwise
  initializer's parameter order is the order the properties are declared. This is the largest
  single class of change that has never compiled. Reads as satisfied in the current source: no
  violation is visible by reading.
- Fix: forward, and trivial. Reorder the arguments at the call site, or give the property a
  default. Do not revert a round for an argument-order error.

### 2. The three `PhotoLibraryServing` requirements

- **Where:** the EAS build log (the app conformer); the test fakes matter only to the opt-in
  test-target step in section 6.
- Files: `VideoShrink/Services/ServiceProtocols.swift` (protocol `PhotoLibraryServing`),
  `VideoShrink/Services/PhotoLibraryService.swift` (the app conformer).
- Symptom: `type 'X' does not conform to protocol 'PhotoLibraryServing'`.
- Why: round 1 folded `PhotoLibraryDeletionRevalidating` into `PhotoLibraryServing`, so the
  protocol carries `deletionEvidence`, `revalidateForDeletion` and the revalidating delete
  `deleteOriginals(afterRevalidating:)`. Any conformer that was not updated fails to compile.
  Reads as satisfied in the current source: `PhotoLibraryService` implements all three.
- Fix: forward. Add the missing method to the conformer.

### 3. Round 3: `LibraryScanning` gained two real requirements

- **Where:** the EAS build log for the app conformer; the test mocks failed here in practice and
  are caught by the opt-in test-target step in section 6, not by an ordinary EAS build.
- Files: `VideoShrink/Services/ServiceProtocols.swift` (protocol `LibraryScanning`),
  `VideoShrink/Services/PhotoLibraryScanService.swift` (the conformer),
  `VideoShrink/Presentation/BatchViewModel.swift` (the caller).
- Symptom: `type 'X' does not conform to protocol 'LibraryScanning'`.
- Why: round 3 closed N7 by folding the old `LibraryReconciling` workaround into
  `LibraryScanning`, so `refreshListing()` and
  `reconcile(previous:selection:running:)` are now real protocol requirements rather than a
  capability declared beside the caller and found with a cast. Every conformer must implement
  them. This is the round-3 risk with the strongest evidence: the round-3 integration step
  reports that `QueueMockScanner` and `QueueMockHistory` in `VideoShrinkTests/BatchQueueTests.swift`
  were missing the new requirements and were a hard compile failure in the test target, fixed by
  the parent. The app conformer reads as satisfied.
- Fix: forward. Add the missing requirement to the conformer. A test-mock-only miss is not
  visible to an ordinary EAS build and is found by the opt-in test-target step or the CI test
  run instead.

### 4. `DeletionEvidence`'s custom `init(from:)` alongside Codable

- **Where:** the EAS build log.
- File: `VideoShrink/Models/DeletionPolicy.swift` (struct `DeletionEvidence`, `CodingKeys`, the
  explicit `init(version:copy:source:)`, and the lenient `extension DeletionEvidence { init(from decoder:) }`).
- Symptom: a compile error in `DeletionPolicy.swift` if the decode initializer does not
  initialize every stored property on every path, or a decode that loses a field.
- Why: hand-writing one half of `Codable` while the other half is synthesized has never
  compiled. Reads as satisfied in the current source, so it is ranked below the conformance
  entries. A decode that lost a field would show up as a delete that never authorises anything,
  which is a safe failure, so this is not a data-loss risk.
- Fix: forward. Default values on the properties or an explicit `encode(to:)`, not a revert.

### 5. Round 3: `PhotoLibraryService.retrieve` trait plumbing and the cinematic API name

- **Where:** the EAS build log.
- Files: `VideoShrink/Services/PhotoLibraryService.swift`
  (`retrieve` and `snapshot(identifier:)` now pass `isCinematic` and `isSharedOrRestricted`),
  `VideoShrink/Models/AssetRules.swift`.
- Symptom: a compile error on the `Traits` initializer at the `retrieve` call site, or on a
  member name such as `PHAssetMediaSubtype.videoCinematic`.
- Why: round 3's compile-risk audit found that `retrieve` never passed the new cinematic or
  shared traits, so the single-video flow, where retrieval is the only eligibility gate, would
  have processed a cinematic or shared-album video. That drift was fixed by adding the two
  arguments. The round-3 eligibility work also corrected the brief on API names: the correct
  API is `PHAssetMediaSubtype.videoCinematic`, and `PHAsset.mediaCharacteristics` no longer
  exists. A wrong API name or an argument-order mismatch at this call site is a compile error
  and lands in the EAS log.
- Fix: forward. Correct the argument or the API name.

### 6. Concurrency and actor isolation on the reconciliation path

- **Where:** the EAS build log, as a warning or an error.
- File: `VideoShrink/Presentation/BatchViewModel.swift` (`refreshLibrary()` and the
  `scanner.reconcile(...)` call), `VideoShrink/Services/LibraryChangeMonitor.swift`.
- Symptom: a warning or error on the `Task` body or on the `@MainActor` reconciler call under
  Swift concurrency checking.
- Why: this is round-2 and round-3 code that captures `self` in a `Task` and awaits a
  `@MainActor` scanner. The pod builds with `SWIFT_STRICT_CONCURRENCY targeted` and
  `SWIFT_DEFAULT_ACTOR_ISOLATION nonisolated` (`VideoShrinkNative.podspec`), which turns some of
  these into warnings rather than errors. Only the compiler settles it.
- Fix: forward. If it is a warning under targeted checking, record it and move on. If it is an
  error, annotate the closure rather than reverting.

### 7. `AVAssetReaderTrackOutput(track:outputSettings:)` with nil for the audio pass

- **Where:** only at run time. EAS does not reach it because it needs real media.
- File: `VideoShrink/Services/VideoVerificationService.swift`, `decodesAudio`
  (`outputSettings: nil`).
- Symptom: verification throws `PipelineError.audioMismatch` on a copy that has perfectly good
  audio, and the item is reported as failed.
- Why: round 1 (`559f693`) replaced "audio exists" with "audio actually decodes at three
  windows". Passing `nil` means samples come back in their stored compressed format rather than
  decoded PCM, and a sampled window might not surface a buffer, making the whole check fail.
  Unit tests will not catch it: the pure decision helpers are what the tests exercise; the
  decode only runs against real media.
- Fix: forward, and decide it on evidence. If a valid copy fails here, request decoded LPCM
  (`[AVFormatIDKey: kAudioFormatLinearPCM]`) and re-run. Keep the "every window must decode"
  policy; it is the point of the round 1 change.

### 8. The audio pass fails a short or unusual clip for the wrong reason

- **Where:** only at run time, on real media.
- File: same as above, `confirmAudioIsPresent` and `sampleWindows`.
- Symptom: `audioMismatch` on short clips whose audio track is shorter than the video track, on
  tracks that do not start at zero, or on a video whose only audio is written later than the
  0.9 window.
- Why: the window policy is stated (0.1, 0.5, 0.9 of the track's own range, a window is required
  only when enough range remains, and a clip too short is sampled as one whole-clip window), but
  the policy is only as good as the track range it is handed, which is read at runtime.
- Fix: forward. Record these as cases to fix in the policy, not as reasons to weaken the check.

Round 3's compile-risk audit read the eight files it owned and reported no compile-blocking
defect, having swept every conformer against its protocol and every memberwise call site. Entries
3 and 5 above are the round-3 items it flagged as fixed or as an integration casualty rather
than as open risks.

## 5. Triage table

Use the commit column to undo one round instead of all of them. The rounds touch largely
disjoint work, so `git revert -n` of a single commit is the narrowest surgical move available.
Capture the failing log first; a revert without the error text is guesswork.

| Failure symptom | File | Round (commit) | Safe move |
|-----------------|------|----------------|-----------|
| Library edit in Photos does not refresh the listing; a thumbnail keeps showing the old picture; every test still passes | `VideoShrink/Presentation/BatchViewModel.swift` (`refreshLibrary()`), `VideoShrink/Services/PhotoLibraryScanService.swift` (`reconcile`), `VideoShrink/Services/ThumbnailService.swift` | round 3 (`dcd0695`) wiring; thumbnail refresh is round 2 (`65d6a09`) | Fix forward. The reconciliation is now a real `LibraryScanning` requirement with tests, so a wrong rule is a bug in the rule. Reverting `dcd0695` restores the cast-based workaround the round was written to remove |
| `audioMismatch` thrown on a copy with working audio | `VideoShrink/Services/VideoVerificationService.swift` (`decodesAudio`, `outputSettings: nil`) | round 1 (`559f693`) | Fix forward. Ask for decoded LPCM in the audio output settings. Do not revert: reverting round 1 restores the "audio exists" check that round 1 was written to replace |
| `type ... does not conform to protocol 'PhotoLibraryServing'` | `VideoShrink/Services/ServiceProtocols.swift`, `VideoShrink/Services/PhotoLibraryService.swift`, plus the test fakes in `VideoShrinkTests/PipelineTests.swift`, `BatchTests.swift`, `BatchQueueTests.swift` | round 1 (`559f693`) | Fix forward: add the missing method to the conformer. Last resort is `git revert -n 559f693`, which also removes P0-1, P0-2 and P0-3 |
| `type ... does not conform to protocol 'LibraryScanning'` (missing `refreshListing()` or `reconcile`) | `VideoShrink/Services/ServiceProtocols.swift`, `VideoShrink/Services/PhotoLibraryScanService.swift`, and the scanner/history mocks in `VideoShrinkTests/BatchQueueTests.swift` | round 3 (`dcd0695`) | Fix forward: add the missing requirement to the conformer. This was a real test-target failure this round; the app conformer is the EAS-visible case |
| Compile error in `PhotoLibraryService.retrieve` on the new traits, or an unknown member such as `videoCinematic` | `VideoShrink/Services/PhotoLibraryService.swift`, `VideoShrink/Models/AssetRules.swift` | round 3 (`dcd0695`) | Fix forward. Correct the argument or the API name |
| Decode or compile error in `DeletionEvidence` | `VideoShrink/Models/DeletionPolicy.swift` | round 1 (`559f693`) | Fix forward and locally: default values or an explicit `encode(to:)`. A revert here costs the whole receipt mechanism |
| `argument must precede argument` or `extra argument` on a snapshot, receipt, thumbnail or trait call | `VideoShrink/Models/DeletionPolicy.swift`, `VideoShrink/Services/PhotoLibraryService.swift`, `VideoShrink/Presentation/AssetThumbnail.swift`, `VideoShrink/Presentation/BatchScreens.swift` | `AssetSnapshot` and `DeletionEvidence`: round 1 (`559f693`). `AssetThumbnail.revision`: round 2 (`65d6a09`). `Traits`: round 3 (`dcd0695`) | Fix forward; reorder the call or give the property a default |
| Concurrency warning or error on the reconciliation `Task` | `VideoShrink/Presentation/BatchViewModel.swift` (`refreshLibrary()`) | round 2 (`65d6a09`) and round 3 (`dcd0695`) | Fix forward with an annotation. Under `SWIFT_STRICT_CONCURRENCY targeted` a warning is acceptable to record and defer |
| Reconciliation rules themselves wrong (a changed video not flagged, a selection dropped) | `VideoShrink/Models/LibraryModels.swift` (`LibraryReconciliation`), `VideoShrink/Services/LibraryChangeMonitor.swift` | round 2 (`65d6a09`) | Fix forward. The rules are pure and unit-tested; a wrong rule is a bug in the rule, not a reason to revert the wiring |
| Queue write fails and the run continues into a save or a delete | `VideoShrink/Presentation/BatchViewModel.swift` (`persistQueue`, `setState(_:for:)`, `requireJournaledCheckpoint`), `VideoShrink/Models/BatchQueueRecord.swift` | round 1 (`559f693`) | Do not revert first. This is the P0 work; investigate before touching it. If a revert is the only way to get a green build, `git revert -n 559f693` also removes the delete gate, so treat that as a pause, not a fix |
| Verification of an imported copy weaker than the export check | `VideoShrink/Services/VideoVerificationService.swift` | round 1 (`559f693`) | Fix forward |
| Stored queue from before the change refuses to decode, or a delete authorises on an old receipt | `VideoShrink/Models/DeletionPolicy.swift`, `VideoShrink/Models/BatchQueueRecord.swift` | round 1 (`559f693`) | The conservative direction is the intended one: an old queue must keep every original. Only treat it as a bug if a queue that should decode does not |
| An image created by the app still appears in bulk selection, or is counted in the shrink history | `VideoShrink/Presentation/BatchViewModel.swift`, the history store and `VideoShrink/Models/LibraryModels.swift` | round 3 (`dcd0695`) | Fix forward. The exclusion is intended; a copy that reappears in the count is a bug in the rule, not a reason to revert |

Narrowest reverts, for reference:

```
git revert -n dcd0695      # undo round 3 only, keep rounds 1 and 2
git revert -n 65d6a09      # undo round 2 as well
git revert -n 559f693      # undo round 1 too, back to baseline behaviour
```

None is committed here, and none should be run without first capturing the failing output. A
revert of `dcd0695` also reverts the round-3 documents; a revert of `65d6a09` also reverts
`docs/VALIDATION.md`, `docs/PHYSICAL_DEVICE_TEST_PLAN.md` and the other documents that round
touched.

## 6. Running the XCTest suite without a Mac

No ordinary EAS build compiles or runs `VideoShrinkTests/`. The opt-in `verify-tests` profile
below compiles the target and then runs it on a simulator discovered on the builder, so the EAS
route can execute the suite. A GitHub Actions macOS runner is the other route, and it is the
recommended one once a remote exists. Both routes call the same script, which is deliberately the
single implementation: `scripts/verify-native-tests.mjs` runs `xcodegen generate` to build
`VideoShrink.xcodeproj` from `project.yml` (the source of truth; no `.xcodeproj` is checked in),
then runs `xcodebuild` to compile the test bundle and execute the cases on a simulator.

Two things to be plain about:

- **Both routes have now run, and both are currently blocked.** This bullet used to read that
  neither had: the EAS route was unusable because the free-plan monthly iOS build minutes were
  exhausted until 1 October 2026, and the GitHub route had no remote to dispatch from. The
  remote was created and the job has run green - the first green run was 2026-09-23 at `5d72357`,
  with both banners printed and 0 failures - and the last observed green test run was at
  `31b6245`. Since then the account's GitHub Actions runners have stopped starting altogether,
  so no route can execute the suite right now. See the note at the top of this file and
  `AGENT_LOOP.md`.
- **The GitHub route is the more reproducible one.** It spends no EAS build minutes, so the
  monthly limit does not ration it, and a macOS runner image is a fixed, observable environment,
  which makes a failing case easier to reproduce than one on the EAS builder.

### The GitHub Actions runner (costs no EAS build minutes)

`.github/workflows/ios-tests.yml` adds a macOS GitHub Actions job that performs the same
verification as the `verify-tests` EAS profile without spending any EAS build minutes. It does not
repeat the command sequence: the job sets `VIDEOSHRINK_VERIFY_TESTS=1` and runs
`node scripts/verify-native-tests.mjs`, the same script `eas-build-post-install` runs, so the
compile phase, the run phase, the two banners and the exit codes are the one implementation
described below rather than a second one to keep correct.

The job triggers on every push and pull request to `main`, and can be started by hand from the
Actions tab (`workflow_dispatch`). It uses the `macos-15` runner image, checks out the repository,
sets up Node, runs `npm ci`, and then runs the script. It needs no Apple signing, because both
`xcodebuild` invocations pass `CODE_SIGNING_ALLOWED=NO` and target the iOS Simulator. It adds no
secrets, no deployment step and no dependency cache, and it publishes nothing: the job only
proves that the cases compile and pass.

**The remote this paragraph used to ask for now exists.** It read: this repository has no GitHub
remote, so the workflow file cannot be dispatched and no runner has executed the tests. `origin`
is now `https://github.com/wilfratcliff-ctrl/batchshrink.git`, and the job has run green: the first
green run was 2026-09-23 at commit `5d72357`, with both banners printed and 0 failures, as
recorded in `AGENT_LOOP.md`. The rest of this subsection is still accurate.

Once the remote exists this is the recommended everyday verification: it costs no EAS build
minutes, so the free-plan monthly iOS build limit never rations it. It does run against that
repository's own GitHub Actions quota, which is a separate budget from EAS and is not consumed at
all while the repository is public.

### Building the shipping app on the runner (the second CI job)

`ios-tests.yml` now carries a second, independent job, `build-expo-app`. It exists because no gate
compiled the app that ships:

- the test job above, and `scripts/validate-mac.sh`, both compile the standalone project that
  `project.yml` describes. Neither runs `expo prebuild` and neither runs `pod install`, so
  `modules/videoshrink-native/ios/VideoShrinkNativeView.swift` and
  `VideoShrinkNativeModule.swift` are outside both of them;
- EAS does compile those files, but EAS iOS build minutes are a rationed monthly resource on the
  free plan and were exhausted until 1 October 2026. `VideoShrinkNativeView.swift` changed after
  the last build whose app compiled (EAS `5b7bd87f` at `7ec2d40`), so without this job a mistake in
  it would not have surfaced until then.

The job runs on `macos-15` with Node 24, runs `npm ci` -- which runs the repo's `postinstall`, so
`scripts/sync-native-sources.mjs` regenerates the mirror -- and then runs
`scripts/verify-expo-build.mjs`. That script:

1. runs `node scripts/sync-native-sources.mjs --check`, the same mirror assertion EAS makes from
   `eas-build-post-install`. Because `npm ci` has just regenerated the mirror, this confirms the
   post-install hook ran and the mirror matches `VideoShrink/{Models,Services,Presentation}`; it
   catches a checkout whose `postinstall` was skipped or removed, and a mirror left stale by an
   edit to the sync script;
2. asserts that `ios/` does not exist, naming the path if it does. That directory is generated by
   `expo prebuild` and is git-ignored (`/ios/` in `.gitignore`), so a clean checkout never has one,
   and building on top of a stale generated tree would be a different experiment from the one this
   gate claims to run. `--replace-ios` removes it instead of failing;
3. runs `npx expo prebuild --platform ios --no-install`, the same generation an EAS build does;
4. runs `pod install` in the generated `ios/`;
5. discovers the generated `.xcworkspace` and the scheme to build rather than assuming either. The
   scheme comes from `xcodebuild -list -json` on that workspace, with `Pods-*` schemes filtered out.
   Both names are derived from `expo.name` in `app.json` -- "BatchShrink" at the time of writing,
   giving `BatchShrink.xcworkspace` and the scheme `BatchShrink` -- and `app.json` is edited by
   other work, which is exactly why neither is hardcoded. The script prints the workspace and the
   scheme it chose, immediately before building;
6. builds with `xcodebuild -workspace <the discovered workspace> -scheme <the discovered scheme>
   -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' -derivedDataPath
   build/ExpoVerifyDerivedData CODE_SIGNING_ALLOWED=NO build`, exiting non-zero under a `FAILED`
   banner if the app does not compile.

**What it proves.** The pod's `source_files` in
`modules/videoshrink-native/ios/VideoShrinkNative.podspec` is
`"**/*.{h,m,mm,swift,hpp,cpp}"`, which covers the module's own Swift and `VideoShrinkCore/`, the
mirror of `VideoShrink/{Models,Services,Presentation}`. That is the Swift an EAS build compiles, so
a green run here is the free, on-every-push equivalent of the compile half of an EAS build, and the
first thing in this repository that puts `VideoShrinkNativeView.swift` under a gate.

**What it does not prove.** It does not run the tests: the first job does that, and this one
deliberately neither depends on it nor merges with it, so a red suite can never be mistaken for a
red app build, or the reverse. It does not sign, deploy or submit anything, needs no Apple account,
no certificate and no registered device, and spends no EAS minutes. And it is still only a compile:
nothing about deletion, audio sync, HDR, interruptions or iCloud retrieval is exercised by it
(section 7).

**The build path has now been run, and it works.** This paragraph used to report that nothing
from step 3 onwards had executed anywhere. It has since executed on a macOS runner: job 2,
`build-expo-app`, was green at `31b6245` alongside job 1. It needed one fix to get there, and it
is worth knowing about because it was not our code: `macos-15`'s default Xcode cannot resolve the
Expo dependency tree, and its newest Xcode 26.3 fails on a third-party C++ header, so the job is
on `macos-26`, whose default Xcode 26.6 is the toolchain `docs/VALIDATION.md` records EAS using.
The job prints `xcodebuild -version` and `swift --version` so the next failure of this kind is
attributable from the log. What has *not* run since 2026-09-23 is any job at all, for the reason
at the top of this file.

On a Mac, `npm run verify:expo` runs the same script, and `npm run verify:expo -- --check-only`
runs only the parts that need no Xcode.

### Compiling and running the test target on the EAS builder (opt-in)

The EAS builder is a macOS machine with Xcode, so it can also run `xcodegen`, `xcodebuild` and
`xcrun simctl` against the standalone project. `scripts/verify-native-tests.mjs` uses that to
compile the test target and then run it, and the `verify-tests` profile turns it on:

```
npx eas-cli build --platform ios --profile verify-tests
```

`verify-tests` extends `development-simulator`, so it stays simulator-targeted and needs no
Apple signing credentials. It sets `VIDEOSHRINK_VERIFY_TESTS=1` for the build, and
`eas-build-post-install` (in `package.json`) runs, after the existing native-source sync check:

**Compile phase:**

1. `xcodegen` is installed with Homebrew if the builder does not already have it
   (`/opt/homebrew/bin` and `/usr/local/bin` are added to `PATH` for this).
2. `xcodegen generate` builds `VideoShrink.xcodeproj` from `project.yml`.
3. `xcodebuild -project VideoShrink.xcodeproj -scheme VideoShrink -sdk iphonesimulator \
   -destination 'generic/platform=iOS Simulator' -derivedDataPath build/VerifyDerivedData \
   CODE_SIGNING_ALLOWED=NO build-for-testing` compiles both targets.

**Run phase, only if the compile succeeded:**

4. `xcrun simctl list devices available --json` is read for an available iPhone simulator,
   preferring the newest iOS runtime. If it yields nothing, `xcodebuild -showdestinations` is
   tried as a second source. The device is discovered at run time rather than hardcoded,
   because builder images change and a hardcoded model name can stop existing.
5. `xcodebuild -project VideoShrink.xcodeproj -scheme VideoShrink \
   -destination 'platform=iOS Simulator,id=<discovered udid>' \
   -derivedDataPath build/VerifyDerivedData CODE_SIGNING_ALLOWED=NO test-without-building` runs
   the XCTest cases on that destination, reusing the test bundle the compile phase built.
   Its output streams into the EAS log.

The step prints two banners so the phases stay distinguishable in a long EAS log:
`===== VIDEOSHRINK TEST TARGET COMPILE =====` with `START`, then `PASSED` or `FAILED`, followed
by `===== VIDEOSHRINK TEST RUN =====` with `START`, then `PASSED`, `FAILED` or `SKIPPED`. A
compile failure fails the build, prints the compiler output exactly as it appears in the log,
and the run phase is not attempted at all.

**What it proves:** the XCTest cases compile, and when the builder has an iPhone simulator
runtime they also execute. The compile phase still uses `build-for-testing` deliberately,
because it produces the built test bundle that `test-without-building` reuses rather than
rebuilding. A failing test exits non-zero and fails the build under the `TEST RUN` banner, and
the log states there that the compile phase had already printed `PASSED`, so a red test cannot
be read as a red compile.

**When no simulator exists:** the run phase prints a clear line that the cases compiled but
could not be run, prints the `TEST RUN` banner with `SKIPPED`, and exits 0. A missing simulator
on a builder image is an environment fact, not a code defect, so the build still passes on its
compile result and the log records which of the two happened.

**What a simulator run still cannot prove:** nothing about the device behaviours in section 7.
A simulator has no real photo library, no HDR display, no incoming call or lock, no thermal
pressure and no iCloud offload, so the executed tests exercise the app's pure logic and its
injected fakes only. Actual deletion, audio sync, HDR appearance, interruption and crash
windows, and iCloud retrieval still need the physical device run in
`docs/PHYSICAL_DEVICE_TEST_PLAN.md`. A test that depends on real `PHPhotoLibrary` behaviour
remains a gap this profile cannot close.

**It is opt-in.** The variable is unset for every other profile, so `development`,
`development-simulator`, `preview` and `production` are unchanged and do not start compiling
tests. Locally, `node scripts/verify-native-tests.mjs` with the variable unset prints one line
and exits 0 without touching Xcode.

## 7. What only a real iPhone can prove

No simulator, and no EAS build, can prove the following. They need a physical iPhone with
expendable media, and the procedure and pass criteria for each are in
`docs/PHYSICAL_DEVICE_TEST_PLAN.md`:

- **Actual deletion.** There is no real library on a simulator and no delete confirmation to
  accept. The gate logic is tested; the call to Photos and what Photos does with it are not.
- **Audio sync.** The verification reads samples at three windows; it does not measure whether
  sound lines up with picture.
- **HDR appearance.** Whether an HDR original stays HDR through the pipeline, and whether it
  looks right, needs a device and a display.
- **Interruptions and crash windows.** Calls, lock, backgrounding and force-quit during an
  export, a save or a delete, and a crash between the queue write and the Photos call. The
  `needsCheck` and `uncertain` paths have never been reached on real hardware.
- **iCloud retrieval.** Whether an offloaded original downloads, what the progress reporting
  looks like, and what happens when connectivity drops mid-download.

Note that `docs/PHYSICAL_DEVICE_TEST_PLAN.md` was written against `07526c4` and has since gained
the five rows named in its header, so the round 2 reconciliation and thumbnail work, the round 3
eligibility and copy-exclusion work, the two temporary workspaces and the round 18 and 19 wording
changes are not all covered as cases; its header now names what a tester meets that the steps do
not mention.

**Prior evidence is historical.** The build record in `docs/VALIDATION.md` and
`docs/RELEASE_10.md` is a record of earlier, separate work; its newest entry predates every
round 1 to round 3 change now in the tree. A pass against an earlier build says nothing about
the code at `dcd0695`.

## 8. Definition of done for this milestone

All three, in this order:

1. `npx eas-cli build --platform ios --profile development-simulator` finishes with no compile
   errors in its log. This proves the Swift core compiles for the simulator.
2. Every XCTest case executes and passes, on the EAS builder through the `verify-tests` profile
   or on a macOS runner (section 6). Take the count from the test result rather than counting test
   methods in the source. If a case is disabled, skipped or crashes
   the runner, or if the profile prints `TEST RUN` `SKIPPED` because no simulator was found,
   record which of those happened and why.
3. `docs/PHYSICAL_DEVICE_TEST_PLAN.md` is executed on a physical iPhone with expendable media
   and its results are recorded, before deletion is enabled in wider testing. Deletion stays
   off by default until that has happened.
