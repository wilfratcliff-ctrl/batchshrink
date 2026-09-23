# Mac validation handoff

This is the first-run document. It assumes a Mac with Xcode installed, a clean
checkout of this repository, and nothing else read beforehand. Nothing in this
repository has been compiled or tested: no Swift compiler, Xcode or XCTest
runner existed on the machine the code was written on. At the last commit,
`65d6a09`, 145 XCTest cases exist and zero have executed.

Git state at the time of writing: branch `main`, HEAD `65d6a09`, clean tree.

| Commit | What it is |
|--------|------------|
| `10ab65f` | baseline checkpoint before any agent work |
| `559f693` | round 1: durable Photos boundaries, copy revalidation, honest verification |
| `65d6a09` | round 2: library reconciliation, thumbnail refresh, warnings that are visible |

Round 3 work was in progress in the working tree while this document was written. Beyond the
three commits above there may be uncommitted changes on top of `65d6a09` when you run. Anything
uncommitted is a fourth thing to consider: it has no commit to revert to, so `git stash` is the
way back to `65d6a09`, and a failure in uncommitted work is fixed forward or discarded, not
reverted. The triage table in section 3 maps symptoms to `10ab65f`, `559f693` and `65d6a09` as
recorded; if the working tree has moved, check `git log` and `git status` before using it.

## 1. Commands to run, in order

Start from a clean checkout of `main` at `65d6a09`.

```
git status                     # confirm the tree is clean before you start
npm run validate:native        # portable pattern scan, not a compiler
npm run typecheck              # TypeScript for the Expo wrapper
node scripts/sync-native-sources.mjs --check
```

Those three are the same checks that pass on Windows. They are pattern scans
and a TypeScript check. They say nothing about whether the Swift compiles.

Then the thing this document exists for:

```
SIMULATOR_UDID="$(xcrun simctl list devices available | awk -F '[()]' '/iPhone/ {print $2; exit}')"
echo "$SIMULATOR_UDID"
SIMULATOR_UDID="$SIMULATOR_UDID" ./scripts/validate-mac.sh
```

Pick a real simulator UDID from `xcrun simctl list devices available` if the
one-liner above prints nothing. `SIMULATOR_UDID` is the only input the script
takes, and it is optional.

### What `scripts/validate-mac.sh` actually does

Read from the script at `65d6a09`, in the order it runs:

1. Refuses to run unless `uname -s` is `Darwin`. On anything else it prints
   "This script requires macOS and Xcode." and exits 1.
2. `cd`s to the repository root.
3. `command -v xcodegen` - XcodeGen must be installed and on `PATH`. A missing
   XcodeGen is a hard failure before anything else happens.
4. `xcodebuild -version` and `xcodegen --version` - both must answer.
5. `plutil -lint VideoShrink/Resources/Info.plist VideoShrink/Resources/PrivacyInfo.xcprivacy`
   - both property lists must lint.
6. `xcodegen generate` - generates `VideoShrink.xcodeproj` from `project.yml`.
   No `.xcodeproj` is checked in; `project.yml` is the source of truth.
7. `xcodebuild -project VideoShrink.xcodeproj -scheme VideoShrink -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO build`
   - a compile for the simulator, with no signing. This compiles the app
   target and the `VideoShrinkTests` target, because the `VideoShrink` scheme
   builds `VideoShrinkTests` for `test`.
8. If `SIMULATOR_UDID` is set:
   `xcodebuild -project VideoShrink.xcodeproj -scheme VideoShrink -destination "platform=iOS Simulator,id=$SIMULATOR_UDID" -derivedDataPath build/DerivedData -resultBundlePath "build/Tests-$(date +%Y%m%d-%H%M%S).xcresult" CODE_SIGNING_ALLOWED=NO test`
   - runs the XCTest suite and writes a timestamped `.xcresult` under `build/`.
   If it is **not** set, the script prints
   `Build complete. Tests NOT run: set SIMULATOR_UDID from xcrun simctl list devices available and rerun.`
   and stops there.

Two things to be blunt about:

- **A build is not a test.** Step 7 compiling proves the Swift type-checks. It
  does not execute a single test body.
- **A passing run with `SIMULATOR_UDID` unset has proved nothing about the 145
  test cases.** It has proved the app and test targets compile. That is the
  whole claim. If the final line is the "Tests NOT run" message, the milestone
  is not met.

The result bundles accumulate in `build/Tests-*.xcresult`. To read one:

```
xcrun xcresulttool get test-results summary --path build/Tests-<stamp>.xcresult
```

Note that `build/DerivedData` and those `.xcresult` bundles are not part of the
repository, and `build/` is not committed.

## 2. Ranked first-failure list

Ordered most likely to bite first. Each entry says what to look for, why it is
on the list, and what the fix is. Nothing here is a prediction that it fails;
every entry is a thing a round said it could not compile-check, ordered by how
likely it is to surface first.

### 1. The reconciliation path never runs, and no test notices

- File: `VideoShrink/Presentation/BatchViewModel.swift` (the
  `scanner as? LibraryReconciling` cast near line 108, and
  `refreshLibrary()` near line 360).
- Symptom: not a crash and not a red test. On the simulator the app runs, the
  library scans, and an edit made in Photos while the app is open does not
  refresh the listing. In the test suite every case still passes, because the
  scanner mocks (`BatchMockScanner` in `VideoShrinkTests/BatchTests.swift:1102`,
  `QueueMockScanner` in `VideoShrinkTests/BatchQueueTests.swift:402`) conform to
  `LibraryScanning` only, so the cast yields nil and `refreshLibrary()` returns
  at its first `guard`. The real service is the only conformer
  (`PhotoLibraryScanService` conforms through
  `extension PhotoLibraryScanService: LibraryReconciling {}`).
- Why: `LibraryReconciling` is declared beside its caller in
  `BatchViewModel.swift` and is a deliberate workaround (N7 in
  `AGENT_LOOP.md`), taken because `BatchViewModel` holds
  `any LibraryScanning` and a protocol-extension default would statically
  dispatch a full scan instead of the metadata-only `reconcile`. N8 records the
  consequence: no test covers the wiring, because no scanner mock can satisfy
  the protocol as written.
- Fix: forward. Add a scanner mock that conforms to `LibraryReconciling` and a
  case that drives `libraryChanged(_:)` through to `apply(_:)`. The clean
  version, folding the two reconciliation requirements into `LibraryScanning`
  and updating the mocks, is N7 and is a restructure, not a first-run fix.
  Reverting round 2 (`65d6a09`) removes the mechanism instead of testing it.

### 2. `AVAssetReaderTrackOutput(track:outputSettings:)` with nil for the audio pass

- File: `VideoShrink/Services/VideoVerificationService.swift`, `decodesAudio`
  (`outputSettings: nil`, line 182).
- Symptom: verification throws `PipelineError.audioMismatch` on a copy that has
  perfectly good audio, and the item is reported as failed. Unit tests will not
  catch this: the pure decision helpers (`sampleWindows`, `allWindowsDecoded`,
  `validate(expected:observed:expecting:)`) are what the tests exercise. The
  decode itself only runs against real media, on the simulator or a device.
- Why: round 1 (`559f693`) replaced "audio exists" with "audio actually
  decodes at three windows". Passing `nil` means samples come back in their
  stored compressed format rather than decoded PCM. If a sample buffer does not
  surface at a sampled window in that mode, `copyNextSampleBuffer()` returns
  nil, `decodesAudio` returns false, and `allWindowsDecoded` fails the whole
  check. This was flagged as a risk precisely because it cannot be settled by
  reading the source.
- Fix: forward, and decide it on evidence. If a valid copy fails here, change
  the audio output settings to request decoded LPCM
  (`[AVFormatIDKey: kAudioFormatLinearPCM]`) rather than nil, then re-run. Keep
  the "every window must decode" policy; it is the point of the round 1 change.

### 3. The audio pass fails a short or unusual clip for the wrong reason

- File: same as above, `confirmAudioIsPresent` and `sampleWindows`.
- Symptom: `audioMismatch` on short clips whose audio track is shorter than the
  video track, on tracks that do not start at zero, or on a video whose only
  audio is written later than the 0.9 window.
- Why: the window policy is stated (0.1, 0.5, 0.9 of the track's own range, a
  window is required only when at least `minimumSampleWindow` remains, and a
  clip too short is sampled as one whole-clip window). The policy is only as
  good as the track range it is handed, and the track range is read at runtime.
- Fix: forward. Treat these as cases to record and fix in the policy, not as
  reasons to weaken the check.

### 4. `DeletionEvidence`'s custom `init(from:)` alongside Codable

- File: `VideoShrink/Models/DeletionPolicy.swift` (struct `DeletionEvidence`,
  `CodingKeys`, the explicit `init(version:copy:source:)`, and the lenient
  `extension DeletionEvidence { init(from decoder:) }`).
- Symptom: a compile error in `DeletionPolicy.swift` if the decode initializer
  does not initialize every stored property on every path, or a decode that
  loses a field.
- Why it is on the list: hand-writing one half of `Codable` while the other
  half is synthesized is exactly the kind of change that has never compiled.
  The risk is real but **reads as satisfied in the current source**: the
  explicit `init(version:copy:source:)` exists (so the memberwise initializer
  the call sites rely on is not the one Swift would have synthesized), it
  initializes all three properties, the fallback path through the custom
  `init(from:)` assigns all three before returning, and the synthesized
  `encode(to:)` matches the hand-written `CodingKeys`. Ranked here rather than
  first because reading the source does not show the expected mistake.
- Fix: forward, and small. If the compiler objects, the fix is to give the
  properties default values or to add an explicit `encode(to:)`, not to revert.
  A decode that loses a field would show up as a delete that never authorises
  anything, which is a safe failure, so this is not a data-loss risk.

### 5. The three new `PhotoLibraryServing` requirements

- File: `VideoShrink/Services/ServiceProtocols.swift` (protocol
  `PhotoLibraryServing`), `VideoShrink/Services/PhotoLibraryService.swift`
  (the conformer), and the three test fakes
  (`VideoShrinkTests/PipelineTests.swift:301`, `VideoShrinkTests/BatchTests.swift:1020`,
  `VideoShrinkTests/BatchQueueTests.swift:338`).
- Symptom: `type 'X' does not conform to protocol 'PhotoLibraryServing'`, in the
  app target or the test target, at build time.
- Why it is on the list: round 1 folded `PhotoLibraryDeletionRevalidating` into
  `PhotoLibraryServing`, so the protocol carries `deletionEvidence`,
  `revalidateForDeletion` and `deleteOriginals(afterRevalidating:)` that did
  not exist before. Any conformer that was not updated fails to compile. Reads
  as satisfied in the current source: `PhotoLibraryService` and all three test
  fakes implement all three. It stays on the list because a missed conformer is
  a compile-time failure, which is exactly what the first Mac run is for.
- Fix: forward. Add the missing method to the conformer. If the failure is in
  the test target only, the missing method is a stub; do not revert a round to
  make a mock compile.

### 6. `LibraryReconciling` is a cast, and casts are silent

- File: `VideoShrink/Presentation/BatchViewModel.swift`, line 108
  (`self.libraryReconciler = scanner as? LibraryReconciling`).
- Symptom: the same visible behaviour as entry 1, from the same line. Listed
  separately because the cast is the mechanism: if `PhotoLibraryScanService`'s
  conformance is dropped or the protocol moves, the cast goes back to nil and
  the app is silently back to the pre-N1 behaviour with a green build.
- Fix: forward, together with entry 1. The fix that removes the class of
  failure is N7: fold `reconcile` into `LibraryScanning` so the compiler
  requires it, and update the mocks.

### 7. Memberwise-initialiser argument order

- Files: `VideoShrink/Models/DeletionPolicy.swift` (`AssetSnapshot`,
  `DeletionEvidence`), `VideoShrink/Services/PhotoLibraryService.swift`
  (`snapshot(identifier:)`), `VideoShrink/Presentation/AssetThumbnail.swift`
  (`AssetThumbnail`), and the `AssetThumbnail(...)` call sites in
  `VideoShrink/Presentation/BatchScreens.swift` (lines 393, 567, 648).
- Symptom: `argument 'x' must precede argument 'y'`, or
  `extra argument 'bytes' in call`, at build time.
- Why it is on the list: both structs and the view gained properties during the
  rounds, and a memberwise initializer's parameter order is the order the
  properties are declared. Reads as satisfied in the current source:
  `AssetSnapshot`'s declaration order (identifier, duration, pixelWidth,
  pixelHeight, creationDate, modificationDate, bytes with a default) matches
  every call site, and `AssetThumbnail` is called as
  `identifier:size:badge:showsPlayBadge:revision:`, which is its declaration
  order. Ranked last because no violation is visible in the source.
- Fix: forward, and trivial. Reorder the arguments at the call site, or add
  defaults to the properties, whichever keeps the declaration honest. Do not
  revert a round for an argument-order error.

### 8. Actor isolation on the reconciliation `Task`

- File: `VideoShrink/Presentation/BatchViewModel.swift`, `refreshLibrary()`
  (`libraryRefresh = Task { [weak self] in ... }`).
- Symptom: a warning or error on the `Task` body, or on the
  `any LibraryReconciling` property, under Swift concurrency checking.
- Why it is on the list: this is new code in round 2 that captures `self` in a
  `Task` and calls a `@MainActor` reconciler. It reads as safe: `BatchViewModel`
  is `@MainActor`, `LibraryReconciling` is declared `@MainActor`, and the
  closure hops back through `self` before touching state. The project builds
  with `SWIFT_VERSION 5.0`, `SWIFT_STRICT_CONCURRENCY targeted` and
  `SWIFT_DEFAULT_ACTOR_ISOLATION nonisolated` (`project.yml`), which turns some
  of these into warnings rather than errors. Ranked here because it is the kind
  of finding that only a compiler settles.
- Fix: forward. If it is a warning under targeted checking, record it and move
  on. If it is an error, annotate the closure rather than reverting.

## 3. Triage table

Use the commit column to undo one round instead of all of them. `559f693` and
`65d6a09` each touch disjoint work, so `git revert -n` of a single commit is
the narrowest surgical move available.

| Failure symptom | File | Round (commit) | Safe move |
|-----------------|------|----------------|-----------|
| Library edit in Photos does not refresh the listing; a thumbnail keeps showing the old picture; every test still passes | `VideoShrink/Presentation/BatchViewModel.swift` (`scanner as? LibraryReconciling`, `refreshLibrary()`, `apply(_:)`), `VideoShrink/Services/ThumbnailService.swift` | round 2 (`65d6a09`) | Fix forward. Add a `LibraryReconciling` mock and a test. Reverting `65d6a09` deletes the change instead of testing it, and is only the right move if round 2 also broke the build |
| `audioMismatch` thrown on a copy with working audio | `VideoShrink/Services/VideoVerificationService.swift` (`decodesAudio`, `outputSettings: nil`) | round 1 (`559f693`) | Fix forward. Ask for decoded LPCM in the audio output settings. Do not revert: reverting round 1 restores the "audio exists" check that round 1 was written to replace |
| `type ... does not conform to protocol 'PhotoLibraryServing'` | `VideoShrink/Services/ServiceProtocols.swift`, `VideoShrink/Services/PhotoLibraryService.swift`, `VideoShrinkTests/PipelineTests.swift`, `VideoShrinkTests/BatchTests.swift`, `VideoShrinkTests/BatchQueueTests.swift` | round 1 (`559f693`) | Fix forward: add the missing method to the conformer. Last resort is `git revert -n 559f693`, which also removes P0-1, P0-2 and P0-3 |
| Decode or compile error in `DeletionEvidence` | `VideoShrink/Models/DeletionPolicy.swift` | round 1 (`559f693`) | Fix forward and locally: default values or an explicit `encode(to:)`. A revert here costs the whole receipt mechanism |
| `argument must precede argument` or `extra argument` on a snapshot, receipt or thumbnail call | `VideoShrink/Models/DeletionPolicy.swift`, `VideoShrink/Services/PhotoLibraryService.swift`, `VideoShrink/Presentation/AssetThumbnail.swift`, `VideoShrink/Presentation/BatchScreens.swift` | `AssetSnapshot` and `DeletionEvidence`: round 1 (`559f693`). `AssetThumbnail.revision`: round 2 (`65d6a09`) | Fix forward; reorder the call or give the property a default |
| Concurrency warning or error on the reconciliation `Task` | `VideoShrink/Presentation/BatchViewModel.swift` (`refreshLibrary()`) | round 2 (`65d6a09`) | Fix forward with an annotation. Under `SWIFT_STRICT_CONCURRENCY targeted` a warning is acceptable to record and defer |
| Reconciliation rules themselves wrong (a changed video not flagged, a selection dropped) | `VideoShrink/Models/LibraryModels.swift` (`LibraryReconciliation`), `VideoShrink/Services/LibraryChangeMonitor.swift` | round 2 (`65d6a09`) | Fix forward. The rules are pure and unit-tested; a wrong rule is a bug in the rule, not a reason to revert the wiring |
| Queue write fails and the run continues into a save or a delete | `VideoShrink/Presentation/BatchViewModel.swift` (`persistQueue`, `setState(_:for:)`, `requireJournaledCheckpoint`), `VideoShrink/Models/BatchQueueRecord.swift` | round 1 (`559f693`) | Do not revert first. This is the P0 work; investigate before touching it. If a revert is the only way to get a green build, `git revert -n 559f693` also removes the delete gate, so treat that as a pause, not a fix |
| Verification of an imported copy weaker than the export check | `VideoShrink/Services/VideoVerificationService.swift` | round 1 (`559f693`) | Fix forward |
| Stored queue from before the change refuses to decode, or a delete authorises on an old receipt | `VideoShrink/Models/DeletionPolicy.swift`, `VideoShrink/Models/BatchQueueRecord.swift` | round 1 (`559f693`) | The conservative direction is the intended one: an old queue must keep every original. Only treat it as a bug if a queue that should decode does not |

Narrowest reverts, for reference:

```
git revert -n 65d6a09      # undo round 2 only, keep round 1
git revert -n 559f693      # undo round 1 as well, back to baseline behaviour
```

Neither is committed here, and neither should be run without first capturing
the failing output. A revert of `65d6a09` also reverts `docs/VALIDATION.md`,
`docs/PHYSICAL_DEVICE_TEST_PLAN.md` and the other docs it touched.

## 4. What this run cannot prove

A green build and a green test suite on the simulator prove that the Swift
compiles and that the pure logic in the tests behaves as the tests describe.
They do not prove any of the following, and no combination of simulator runs
will:

- **Photos deletion actually happening.** There is no real library on a
  simulator, and no delete confirmation to accept. The gate logic is tested;
  the call to Photos and what Photos does with it are not.
- **Audio sync.** The verification added in round 1 reads samples at three
  windows. It does not measure whether sound lines up with picture.
- **HDR appearance.** Whether an HDR original stays HDR through the pipeline,
  and whether it looks right, needs a device and a display.
- **Interruptions.** Calls, lock, backgrounding and force-quit during an export
  or a save. The states exist in code; none has been reached for real.
- **Crash windows.** A crash between the queue write and the Photos call, or
  between the Photos call and the follow-up write, is designed for and never
  exercised. The `needsCheck` and `uncertain` paths have never been reached on
  real hardware.
- **iCloud retrieval.** Whether an offloaded original downloads, what the
  progress reporting looks like, and what happens when connectivity drops
  mid-download.

All of that is `docs/PHYSICAL_DEVICE_TEST_PLAN.md`. That plan describes the
source at `559f693`, so the round 2 reconciliation and thumbnail work is not
covered by it and needs cases adding when someone next edits it.

For context on what has actually run before: **build 10 was the last build
known to have reached testers.** It predates every round 1 and round 2 change.
A pass in build 10 says nothing about the code at `65d6a09`.

## 5. Definition of done for this milestone

All three, in this order:

1. `./scripts/validate-mac.sh` builds green with `SIMULATOR_UDID` set, and the
   build step reports no errors. A `Build complete. Tests NOT run` line does
   not count.
2. Every XCTest case executes and passes. There are 145 at `65d6a09`; take the
   number from the `.xcresult` rather than counting test methods in the source,
   because it will be higher if uncommitted work is present. If a case is
   disabled, skipped or crashes the runner, record which one and why.
3. `docs/PHYSICAL_DEVICE_TEST_PLAN.md` is executed on a physical iPhone with
   expendable media, and its results are recorded, before deletion is enabled
   in wider testing. Deletion stays off by default until that has happened.
