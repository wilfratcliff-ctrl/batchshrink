# Verification handoff

This is the practical first-run document for the code as it stands at commit `dcd0695`. It
replaces the earlier `docs/MAC_VALIDATION_HANDOFF.md`, which assumed a Mac with Xcode. The
owner uses Expo only and does not own a Mac, so no step in that document could be run. The
verification route here is an EAS cloud build, which compiles the Swift on Apple's own
machines.

Git state at the time of writing: branch `main`, HEAD `dcd0695`, clean tree, no configured
remote.

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

- **The test target.** `VideoShrinkTests/` holds 162 XCTest cases and an EAS build never
  compiles or runs them. The pod glob above does not reach `VideoShrinkTests/`, and the
  standalone project is not part of the Expo build. Zero of the 162 cases have ever been
  compiled or executed.
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

- **Where:** the EAS build log (the app conformer); the test fakes matter only to the CI run in
  section 6.
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
  are caught by the CI run in section 6, not by EAS.
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
  visible to EAS and is found by the CI test run instead.

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

## 6. Running the 162 tests without a Mac

An EAS build never compiles or runs `VideoShrinkTests/`, so the 162 XCTest cases cannot be
executed through EAS. The honest route without a Mac is a macOS CI runner, for example GitHub
Actions, which can run the same two commands a Mac would:

```
xcodegen generate
xcodebuild test -project VideoShrink.xcodeproj -scheme VideoShrink \
  -destination 'platform=iOS Simulator,name=iPhone 15' CODE_SIGNING_ALLOWED=NO
```

`xcodegen generate` builds `VideoShrink.xcodeproj` from `project.yml`, which is the source of
truth; no `.xcodeproj` is checked in. `xcodebuild test` then compiles and runs the suite on the
runner's simulator.

Two things to be plain about:

- **This is not in place.** It requires a Git remote, and this repository currently has none
  (`git remote -v` prints nothing). No CI runner, workflow file or remote exists. Setting one up
  is a decision for the owner, not something this document has done.
- **It is the only route that executes the tests.** A simulator build under EAS proves the core
  compiles; it does not run a single test body. Until a macOS runner exists, the count of
  executed XCTest cases is zero.

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

Note that `docs/PHYSICAL_DEVICE_TEST_PLAN.md` describes the source at `559f693`, so the round 2
reconciliation and thumbnail work and the round 3 eligibility and copy-exclusion work are not
yet covered by it and need cases adding when someone next edits that file.

**Prior evidence is historical.** The build record in `docs/VALIDATION.md` and
`docs/RELEASE_10.md` is a record of earlier, separate work; its newest entry predates every
round 1 to round 3 change now in the tree. A pass against an earlier build says nothing about
the code at `dcd0695`.

## 8. Definition of done for this milestone

All three, in this order:

1. `npx eas-cli build --platform ios --profile development-simulator` finishes with no compile
   errors in its log. This proves the Swift core compiles for the simulator.
2. Every XCTest case executes and passes on a macOS runner (section 6). There are 162 cases;
   take the number from the test result rather than counting test methods in the source. If a
   case is disabled, skipped or crashes the runner, record which one and why.
3. `docs/PHYSICAL_DEVICE_TEST_PLAN.md` is executed on a physical iPhone with expendable media
   and its results are recorded, before deletion is enabled in wider testing. Deletion stays
   off by default until that has happened.
