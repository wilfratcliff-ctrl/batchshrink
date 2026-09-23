# Running the media pipeline on a simulator, in CI

A plan for the one instrument this project does not have: a run that takes a real video
through retrieve, export, verify, save, read back and delete, on a simulator, with no device,
no Mac and no EAS minutes.

Written 2026-09-23 against commit `0786a12`, with the tree clean. It is a plan and not code
because nothing that touches Swift can be compiled until the account's Actions minutes reset
on 1 October and the runners start again (see `AGENT_LOOP.md`, "The gate is blocked again").
The document is written to be landed in pieces, and section 8 says which piece comes first.

## 0. How to read this document

Every claim below carries one of three labels, and they are not interchangeable:

- **[verified]** - read out of this repository, with the file named. Where a claim is about a
  command, it means this script runs that command today.
- **[documented]** - an outside reference, named. Where the outside reference is Apple's
  `simctl` or XCTest documentation, the reference is named *and* the fact that this machine
  cannot open it is stated, because a Windows box can run none of it.
- **[inferred]** - my reasoning, not verified. Where a whole step rests on an inference, it is
  said so at the point of the inference and again in section 7 as a first-run question.

This is the discipline `marketing/` uses under the labels Repo / Looked up / Inferred
([verified] in `marketing/market-map.md`, section 0). The same three ideas, named the same way
as the round reports are.

Two facts about the current state that the rest of this document depends on:

- The standalone harness is not the shipping app. `project.yml` builds a pure SwiftUI app whose
  screens and view models are the real ones - `VideoShrinkApp.swift` constructs
  `PhotoLibraryService`, `PhotoLibraryScanService`, `VideoTranscodingService`,
  `VideoVerificationService` and the two `TemporaryFileManager`s for real, with no fakes -
  while the shipping Expo app compiles the same files a second time through the pod
  **[verified]**. So a simulator run against the harness exercises the real services, but not
  the two Expo bridge files, which remain job 2's business **[verified]** in
  `scripts/verify-app-launch.mjs` and `.github/workflows/ios-tests.yml`.
- Nothing has ever exported a video. The largest remaining gap in this project is that
  retrieve, export, verify, save, read back and delete have never run anywhere
  **[verified]** - `AGENT_LOOP.md` N19, `docs/VALIDATION.md`, `docs/QA_PASS.md`.

## 1. The claim a green run would establish

Stated exactly, as one sentence a log could not overclaim:

> On an iPhone simulator, against the simulator's own Photos library, the app's own services
> took a video that Photos had imported, fetched it through PhotoKit as a file on the device,
> exported a smaller copy with `AVAssetExportSession`, verified that copy against the original
> by decoding it, saved it to Photos as a new asset, read that asset back as a file and verified
> it again against the properties it had measured, then deleted the original through Photos'
> change request and reported what it had removed.

Each clause is a separate observed fact, and the useful thing about this instrument is that
each one can fail on its own with its own sentence. What follows is what a green run would
prove, and then - the part that matters more - what it would still not prove.

### 1.1 What it would prove

1. **The retrieval path works against a real PhotoKit library.** Today `retrieve` is exercised
   only against a test double. The real one refuses anything that is not a file on the device
   (`unreadableOriginalRefusal()` when PhotoKit answers with a streaming asset) and refuses a
   whole list of traits before it asks at all **[verified]**
   `VideoShrink/Services/PhotoLibraryService.swift`. A run says which of those it met.
2. **The export produces a file that exists and is smaller.** `AVAssetExportSession` with
   `AVAssetExportPresetHEVC1920x1080` at the default quality **[verified]**
   `VideoShrink/Models/VideoQuality.swift` and `VideoShrink/Models/ShrinkSettings.swift`
   (default is 1080p HEVC, frame rate kept).
3. **The verification layer's claims survive a real file.** Every sample window decodes, the
   audio track decodes rather than being trusted by duration, and the copy's duration, shape,
   resolution, frame rate and track counts are compared against the original
   **[verified]** `VideoShrink/Services/VideoVerificationService.swift`.
4. **A copy can be created in Photos from a file this app wrote**, and Photos hands back an
   identifier for it **[verified]** - `save(videoAt:identity:)` in `PhotoLibraryService`.
5. **A copy this app created can be read back off the device with the network switched off**
   (`isNetworkAccessAllowed = false`) and re-verified **[verified]** -
   `localFileURL(identifier:)` and `verifyImportedCopy`.
6. **Photos' deletion change request runs, and the revalidated gate lets it through only with
   a receipt that still holds** **[verified]** -
   `deleteOriginals(afterRevalidating:)` and `DeletionPolicy`.
7. **The whole path runs without the user in the room.** Every step above is reachable from a
   test, so a step that only works because a person is watching the screen would be exposed.

That is a large change in what this project knows. It converts the pipeline from "compiles and
is pattern-checked" into "has run", which is a class of evidence the repository has never had
for anything beyond the launch of one screen **[verified]** - `AGENT_LOOP.md` N40.

### 1.2 What it would not prove, because a simulator is not an iPhone

This list is the reason the document exists, and it is deliberately longer than the one above.

- **HEVC encode capability, and quality.** A simulator has no iPhone encoder: the export runs
  through the host's VideoToolbox, which is not the phone's hardware path
  **[inferred]** - the encode is real, but its speed, its power draw and its *picture* are not
  the phone's. A simulator green run must never be read as "the phone's HEVC output is good".
  The review of the copy's appearance stays where `docs/PHYSICAL_DEVICE_TEST_PLAN.md` puts it.
- **HDR and HLG appearance.** The plan's fixture is SDR by construction (section 3), and the
  app refuses HDR originals anyway **[verified]** `AssetRules.unsupportedFormatReason`. Even an
  HDR fixture would prove only that the refusal fired, never that a kept copy looks right.
- **Audio sync.** The verification layer says so itself: "This says nothing about audio sync
  or how the picture looks; those are not measurable here" **[verified]**
  `VideoVerificationService.swift`. A simulator run adds track counts and nothing more.
- **Thermal behaviour, backgrounding and battery.** A simulator has no thermal state worth
  the name and no real interruption model. `docs/PHYSICAL_DEVICE_TEST_PLAN.md` keeps the rows.
- **Real iCloud retrieval.** The simulator has no iCloud Photo Library, so
  `isNetworkAccessAllowed = true` **[verified]** on the real request has nothing to fetch: the
  asset is local, the download-progress callback never fires, and the offline-failure path
  cannot be produced. A green retrieval here is evidence about the *local* branch only.
- **Photos' own prompts.** With the grant from section 2 there is no permission alert at all,
  so nothing about the alert's wording, timing or refusal behaviour is observed. The deletion
  confirmation is a simulator's alert if it appears at all.
- **Memory, time and throughput on real hardware.** The estimate model records
  seconds-per-content-second from every run into the device's own store
  **[verified]** - `estimator.record(...)` in `BatchViewModel`. On a simulator that store is
  the simulator's, so no phone's numbers can be corrupted by this - but a figure printed by
  this job is a runner figure and must never be quoted as an iPhone figure.
- **Playback.** Nothing here plays the copy in Photos, seeks to the end, or listens. The device
  plan's "Playback after import" row is the only instrument for that.
- **The shipping app's own two bridge files** (`modules/videoshrink-native/ios/`) - job 2
  compiles those and they are not on this path **[verified]**.
- **Limited access and refusal.** `simctl privacy` has grant/revoke/reset and no "limited"
  **[documented]** (Apple's `simctl` reference), so the limited-access screens and the
  Settings-recovery path stay device-only.

The standing rule this document does not change: `docs/PHYSICAL_DEVICE_TEST_PLAN.md` is still
the acceptance gate for Phase 0 **[verified]**, and a green simulator run is a prerequisite
that removes one class of unknown, not a device result.

## 2. The mechanism, with the exact commands

### 2.1 What the launch job already does, exactly

`scripts/verify-app-launch.mjs` is the only thing in this repository that has ever driven the
app, and the new work is an extension of it rather than a new idea. Read from the file
**[verified]**, in order:

1. asserts the native-source mirror is in sync - `node scripts/sync-native-sources.mjs --check`;
2. installs XcodeGen with Homebrew if it is not on PATH, trying PATH first and then
   `/opt/homebrew/bin/brew`, `/usr/local/bin/brew`;
3. runs `xcodegen generate` and fails if no `VideoShrink.xcodeproj` appears;
4. discovers a simulator from `xcrun simctl list devices available --json`, keeps iPhones
   whose `isAvailable` is not false and which carry no `availabilityError`, and sorts by iOS
   version then name;
5. boots it with `xcrun simctl boot <udid>` (a non-zero status is tolerated, because that is
   what an already-booted device returns) and then blocks on
   `xcrun simctl bootstatus <udid> -b`, which is the step that decides whether the device is
   usable;
6. reads the app's bundle identifier out of the generated project with
   `xcodebuild -project VideoShrink.xcodeproj -target VideoShrink -showBuildSettings` and a
   `PRODUCT_BUNDLE_IDENTIFIER` match, rather than copying it from `project.yml`;
7. clears the app's stored state with `xcrun simctl uninstall <udid> <bundle id>`, tolerating
   a non-zero status because "not installed yet" is the honest state of a clean simulator;
8. runs
   `xcodebuild -project VideoShrink.xcodeproj -scheme VideoShrinkUITests -destination platform=iOS Simulator,id=<udid> -derivedDataPath build/LaunchDerivedData CODE_SIGNING_ALLOWED=NO test`.

The rest is banners, error text and a `--check-only` path for Windows. The bundle identifier
this step resolves is `com.example.VideoShrink` for the app, `com.example.VideoShrink.Tests`
for the unit tests and `com.example.VideoShrink.UITests` for the UI tests
**[verified]** `project.yml`.

### 2.2 What has to be added

Three commands on top of the above. Every one of them is `xcrun simctl`, so the script's
existing runner and its `fail`/banner discipline can carry them.

**Put the fixture in the simulator's Photos library.**

```
xcrun simctl addmedia <udid> build/SimulatorFixture.mov
```

**[documented]** - `simctl addmedia` is Apple's own subcommand for adding photos, live photos,
videos or contacts to a device, and it takes one or more file paths. It is used nowhere in
this repository today **[verified]** - a search for `addmedia` across `docs/`, `scripts/`,
`README.md` and `AGENT_LOOP.md` finds nothing. **[inferred]** the device must already be
booted, and the import is over when the command returns, so no wait is needed; both are cheap
to check on the first run by fetching the library afterwards and printing how many videos were
found.

**Pre-authorise Photos.**

```
xcrun simctl privacy <udid> grant photos com.example.VideoShrink
xcrun simctl privacy <udid> grant photos-add com.example.VideoShrink
```

**[documented]** - `simctl privacy` takes a service, an action from grant/revoke/reset, and a
bundle identifier; `photos` and `photos-add` are among its services. **[inferred]** the app's
own `requestAccess()` then returns without a prompt, because it only calls
`requestAuthorization` when the status is `.notDetermined` **[verified]**
`PhotoLibraryService.requestAccess()`. Granting `photos-add` as well as `photos` is
**[inferred]** to be unnecessary given that the app only ever asks for `.readWrite`, and it is
in the list because the two services are separate and a save that fails for want of the add
permission would otherwise look like a pipeline failure.

Whether a grant for a bundle identifier that is not installed yet takes effect is
**[inferred]** and is the first-run question in section 7. The fallback, if it does not, is to
install the built app explicitly first - `xcrun simctl install <udid> <path to .app>`
**[documented]** - then grant, then run with `test-without-building`, which is the same
build-then-run split `scripts/verify-native-tests.mjs` already uses for the unit tests
**[verified]**. The second fallback, if `simctl privacy` will not grant `photos` on this Xcode
at all, is to let the UI test answer the alert itself with `addUIInterruptionMonitor`
**[documented]** (XCTest), which is how the same alert would have to be handled if a device
were ever driven this way.

**Order matters, and this is the order to use**: boot and confirm with `bootstatus`, then
`addmedia`, then the two grants, then the test run. The reason for the grant last is that the
existing script already uninstalls the app between the boot and the test **[verified]**, and an
uninstall clears that app's TCC entries **[inferred]** - so a grant issued before it would be
the one piece of the setup most likely to be thrown away.

### 2.3 Where the pipeline test itself goes

Two targets could carry it, and the choice decides what it can assert.

**The unit-test target** (`VideoShrinkTests`) can reach the services directly: every test file
already does `@testable import VideoShrink` and imports Photos **[verified]**
`VideoShrinkTests/BatchTests.swift` and `BatchQueueTests.swift`. A test there can assert on
`VideoMetadata` values - byte counts, duration, track counts, codec - rather than on strings on
a screen, which is the strongest form of assertion available in this project. It cannot
dismiss a system alert: `PHAssetChangeRequest.deleteAssets` raises a Photos confirmation and
the test process has no interface with which to answer it **[inferred]**, so the deletion leg
would hang. The app's own comment confirms the alert exists: "Photos asks the user to confirm a
transaction once" **[verified]** `PhotoLibraryService.deleteOriginals(identifiers:)`.

**The UI-test target** (`VideoShrinkUITests`) can dismiss that alert with an interruption
monitor, and it drives the shipping screens, so it proves the screens too. It cannot read the
app's internal values, so its assertions are about what the interface says.

**Recommendation: put the pipeline test in the unit-test target, and leave deletion to a
second, UI-level test.** The reasoning is that the first five steps produce the evidence that
is worth most, they can be asserted on values rather than words, and they need no alert
handling at all - `save` does not prompt, only delete does **[inferred]**, and the whole point
of the pre-grant is that no permission prompt appears either. Deletion is one step further
along the same path and gets the UI instrument once the five steps under it are green, which is
exactly the "land one piece and learn from it" shape the loop asks for.

One consequence to state now, because it is the kind of thing that rots silently: the unit
test suite is run by job 1 on every push, and job 1 has no fixture and no Photos library
**[verified]** `.github/workflows/ios-tests.yml`. So the pipeline test must be opt-in, keyed on
an environment variable in the same style as `VIDEOSHRINK_VERIFY_TESTS` **[verified]**
`scripts/verify-native-tests.mjs`, and section 7 says exactly what the opt-out does and what
the opt-in job demands.

## 3. Where the video comes from

The repository refuses to carry test media. `.gitignore` ignores `TestMedia/`, `*.mov`,
`*.mp4` and `*.m4v` under the comment "Never check in personal test media" **[verified]**, so
a fixture has to be generated. Four options were considered.

### 3.1 A small `AVAssetWriter` program, run with the toolchain the runner already has

**Recommended.** A single Swift file under `scripts/` (where every other tool in this
repository lives **[verified]** - `scripts/*.mjs`, `scripts/validate-mac.sh`) which writes the
fixture with `AVAssetWriter` and then re-opens it and validates it before exiting.

```
swift scripts/simulator-fixture.swift build/SimulatorFixture.mov
```

Why this one:

- **Nothing is downloaded.** The runner already has Xcode, so it already has `swift` and
  `AVFoundation` **[verified]** - job 2 prints `swift --version` on its own runner
  **[verified]** `.github/workflows/ios-tests.yml`, and the workflow's own notes record that
  `macos-15`'s default Xcode is 16.4 with Swift 6.1 **[verified]**.
- **It costs seconds, not minutes.** On a macOS runner billed at ten minutes per minute (below),
  a large download is a real cost.
- **The fixture can be tuned to the app's rules.** The size decision the app makes depends on
  the copy being smaller than the original **[verified]** - `BatchViewModel` saves only when
  `saving.isSmaller` - so the fixture must be built to make that certain, and a generated file
  can be.
- **It is a plain file, reviewable in a diff, and it stays out of every Xcode target**:
  `project.yml`'s sources are the three target directories only, so nothing under `scripts/`
  is compiled into the app **[verified]**.

The program's own acceptance criteria, so a broken generator fails under its own sentence
rather than as a mysterious test failure: it writes the file, re-opens it with `AVURLAsset`,
and exits non-zero unless it can read back a duration within a frame of the intended one,
exactly one video track and exactly one audio track, and a byte size above a floor. It prints
duration, pixel dimensions, nominal frame rate, track counts and bytes - and no file path
beyond the one it was given.

### 3.2 `ffmpeg` from Homebrew

The launch script already knows how to find Homebrew and already installs a formula through it
**[verified]**, so the plumbing is free.

**Rejected on cost, not on capability.** `ffmpeg` is a large formula with many dependencies,
and the first install on a cold runner is minutes of a macOS runner, billed at ten times the
Linux rate **[verified]** `AGENT_LOOP.md`. Spending that on every push to avoid writing ninety
lines of Swift is the wrong trade at this price. It is also worth noting what it would *not*
buy: an `ffmpeg`-written fixture is no more or less real than an `AVAssetWriter` one, and the
app reads it with `AVFoundation` either way.

### 3.3 A checked-in base64 blob

`*.mov` and `*.mp4` are ignored but a text file is not, so `scripts/SimulatorFixture.mov.b64`
with 270 KB of base64 in it would work **[verified]** against `.gitignore` as it stands.

**Rejected.** It puts binary media into a text file in git, which no one can review; it cannot
be tuned when the first run shows the copy is not smaller; and the repository's stated
position on test media is a blunt rule for a good reason **[verified]** `.gitignore`. It is
listed because it is the only option with no runner dependency at all, which is what makes it
worth considering if the toolchain turns out not to have `swift` on PATH.

### 3.4 Generate the fixture inside the test, and import it with the app's own `save`

This is a fourth option the first draft of this document missed and it deserves stating,
because it is the only one that can make an HDR fixture. A test can write a file with
`AVAssetWriter` and put it into Photos with `PhotoLibraryService.save` **[verified]** the
method exists - which removes `simctl addmedia` from the picture entirely.

**Rejected for this round, and for a specific reason:** it makes the test's own input depend on
the code under test. If `save` is broken, the test cannot prepare its input, and "the fixture
could not be created" becomes indistinguishable from "the save path failed" - which is exactly
the confusion this project keeps paying for. It becomes attractive later, for an HDR or
multi-track fixture that `simctl addmedia` cannot easily provide.

### 3.5 The fixture's shape

- **1920x1080, 30 fps, 3 seconds, H.264, `.mov`.** The app's default quality is 1080p HEVC with
  the frame rate kept **[verified]**, so a 1080p 30 fps source takes the plain preset path with
  no video composition at all (`TranscodeSettings.needsComposition` is false when the size and
  frame rate match) **[verified]** `VideoShrink/Models/VideoQuality.swift`. That is the shortest
  path through the export code and therefore the right first fixture.
- **Per-frame noise, at a deliberately high bitrate** (order 40 Mbit/s, deterministic seed so
  the file is the same every run). Noise defeats the encoder, which is the point: it makes the
  source large enough that an HEVC 1080p re-encode is unambiguously smaller. A smooth clip
  would risk the app deciding not to save at all, which would make the first run prove nothing.
- **Exactly one video track and one audio track** (AAC stereo 48 kHz, a 440 Hz tone). The
  verification layer requires `videos.count == 1` and `audios.count <= 1` **[verified]**
  `VideoVerificationService.readMetadata`, so a second track would be refused as unsupported
  media and would look like a pipeline failure.
- **No HDR, no ProRes, no edit metadata, no slow-motion.** Each of those is a documented refusal
  **[verified]** `AssetRules.unsupportedReason`, and a fixture carrying one would only prove the
  refusal fired.
- **If the first run shows the copy was not smaller**, the escalation is a 3840x2160 fixture at
  the same frame rate. That additionally exercises the composition path, which is more
  coverage for more moving parts; it is the second fixture, not the first.

The file is roughly 15 MB at those numbers, mentioned because it lands in the simulator's Photos
library and in the runner's `build/` directory, both of which are disposable.

## 4. What to assert

The pipeline's own outputs are the assertions, not screenshots and not timing. Each row says
what can be asserted honestly on a simulator and what cannot.

| # | Claim | Honest here? | How it is asserted |
|---|-------|--------------|--------------------|
| 1 | The fixture is in the simulator's library and the app can see it | yes | `PHAsset.fetchAssets(with: .video)` finds exactly one video, and the app's own `LibraryScanning.scan()` returns it **[verified]** `PhotoLibraryScanService` |
| 2 | PhotoKit handed the original back as a file on the device | yes | `retrieve` returned a `RetrievedVideo` whose URL is a file URL and exists. This is the branch the code insists on **[verified]** |
| 3 | An export produced a file | yes | `transcode` returned a URL; the file exists and is non-empty |
| 4 | The copy is smaller than the original | yes | `output.bytes < original.bytes`, where the original's bytes come from `inspect`'s own measurement of the retrieved file, not from the simulator's library metadata |
| 5 | The copy is a decodable video of the same shape | yes | the app's own `verify` throws otherwise, and the returned `VideoMetadata` must carry one video track, at most one audio track, the same duration within tolerance and the expected codec **[verified]** `VerificationRules` |
| 6 | Audio survived | yes, at track level | `audioTrackCount` equal on both sides. **Not** sync, loudness, channel layout or spatial fidelity - the verification layer says it cannot see those **[verified]** |
| 7 | Photos accepted the copy as a new asset | yes | `save(videoAt:identity:)` returned a non-nil local identifier |
| 8 | The copy can be read back off the device with the network off | yes | `localFileURL(identifier:)` returned a file URL, and `verifyImportedCopy` matched it against the pre-save measurements **[verified]** |
| 9 | The original was not touched | yes, when deletion is off | the original's identifier still resolves, and its `AssetSnapshot` still matches the one taken before the run **[verified]** `snapshot(identifier:)` |
| 10 | The copy carries the original's identity | yes | the created asset's `creationDate`, and its video resource's `originalFilename`, match what PhotoKit reports for the imported fixture - the two facts the app copies in `save` **[verified]**. The comparison is copy-against-original rather than copy-against-a-hardcoded-name, because what `simctl addmedia` does with a filename is one of the things this run is finding out |
| 11 | Deletion removes the original and reports it | not in a unit test | a Photos confirmation alert cannot be dismissed from a unit-test process **[inferred]**. This is the second, UI-level instrument (section 2.3) |
| 12 | The copy looks right, plays right, sounds in sync, is HDR-correct | no | nothing in section 1.2. `docs/PHYSICAL_DEVICE_TEST_PLAN.md` keeps these rows |
| 13 | Retrieval from iCloud works | no | the simulator has no iCloud library, so the local branch is all that runs |

### 4.1 Two rows worth spelling out, because they can fail in a way that reads as a pass

**Row 4 and the "no save" outcome.** The app only saves when the copy is smaller
**[verified]** `BatchViewModel`. So a fixture that fails to shrink produces a *skip*, not a
saved copy, and a test that asserted only "a copy exists" would report a failure; a test that
asserted nothing would report success. Both sizes must be asserted, and the failure sentences
must differ: "the export produced a copy that was not smaller" is a fixture or encoder problem,
while "no copy was saved" is a save problem.

**Row 7 and a nil identifier.** `save` is declared `-> String?` and returns nil when Photos
reports no placeholder for the created asset **[verified]** `ServiceProtocols.swift` and
`PhotoLibraryService.save`. That is a real, if unlikely, outcome and not the same failure as a
thrown error. The test should assert non-nil and, if it gets nil, say so in its own words -
because a nil here means the app has created a copy it can never find again, which is worth
knowing on its own terms.

### 4.2 Fail, or skip?

Both, in different places, and the split is what keeps a skip from being silent.

- **In the ordinary unit-test suite (job 1), the test skips.** It has no fixture and no
  prepared library, so running it there would fail for a reason that is not a defect. The guard
  is the environment variable, and `XCTSkip` is the mechanism. Job 1's log will then read
  "1 test skipped" rather than nothing at all, which is the visible form.
- **In the job that prepares the fixture, a skip is a failure.** The script that prepares the
  fixture and runs the test must refuse to print its pass banner unless the pipeline test
  actually executed. `scripts/verify-native-tests.mjs` already sets the precedent for reading
  the tool's own output before printing a banner **[verified]**, and the launch script prints
  banners only on the branch that did the work **[verified]**. The new script follows both: it
  runs the one test by name (`-only-testing:VideoShrinkTests/...`, **[documented]** xcodebuild),
  and it fails if the output does not show that case executed and passing.
- **Everything inside the test, once it is running, is a failure.** A missing fixture, a library
  with the wrong number of videos, a permission status that is not authorized, a refused
  export, a copy that did not shrink, a nil identifier, a failed read-back. Each gets its own
  sentence naming the step. This is the one arrangement in which the job cannot be green
  without having measured something.

## 5. Permission and privacy

- **What the grant does.** With `photos` granted, `PHPhotoLibrary.authorizationStatus(for:
  .readWrite)` reports authorized, so `requestAccess()` returns immediately and `limitedAccess`
  is false **[verified]** `PhotoLibraryService.requestAccess()`. The app's scan then reads the
  whole library and `canPerform(.delete)` is true for the fixture, which matters because a
  shared-or-restricted item is refused **[verified]** `AssetRules.Traits.isSharedOrRestricted`.
- **What the app does with limited access, and why it does not matter here.** The app carries a
  `limitedAccess` flag, states it on the library screen and refuses to act on assets outside
  the grant **[verified]** `BatchScreens.swift`, `PhotoLibraryService.revalidateForDeletion`
  (an asset outside the allowed set reads as missing and keeps the original). None of that is
  exercised by a simulator run with a full grant. `simctl privacy` has no "limited" action
  **[documented]**, so it cannot be, short of driving `PHPickerViewController`'s own limited
  flow, which is a UI test with a system picker and belongs in a later round if at all.
- **Does pre-granting change what the test measures?** Yes, in exactly one place, and it should
  be said rather than hidden: the app's own permission request path is not exercised. What is
  measured is the pipeline *given* access. The permission request path has its own, cheaper
  instruments already - three unit cases count the monitor's registrations around the status
  **[verified]** `AGENT_LOOP.md` N41 and `ServiceCoverageTests.swift` - and the prompt itself
  stays in the device plan.
- **Privacy.** The fixture is synthetic and generated per run, so the repository's rule about
  personal test media is honoured by construction **[verified]** `.gitignore`. The job must
  print counts, byte figures and durations, never `localIdentifier` values, file paths inside
  the simulator's containers, or anything from the fixture beyond its shape - the same rule the
  device plan states for the console **[verified]** `docs/PHYSICAL_DEVICE_TEST_PLAN.md`,
  "Cleanup/privacy". Nothing here touches a real library, an account, or the network.

## 6. What it would cost

The arithmetic is the loop's own, and it is the reason this section exists at all
**[verified]** `AGENT_LOOP.md`: the plan's 2,000 Actions minutes are one pool, macOS runners
draw from it at ten minutes per minute, and the three-job workflow costs roughly
`7 + 12 + 6` macOS minutes per push - about **250 pool minutes**, so the pool holds about
**eight pushes a month**.

**Folded into the existing `app-launch-smoke` job: about 2 to 3 extra macOS minutes, so about
20 to 30 pool minutes, roughly 8 to 12 per cent more per push** **[inferred]**. That job already
generates the project, boots a simulator and compiles the standalone app, so the marginal costs
are the fixture (seconds), the two `simctl` calls (seconds), the unit-test bundle's compile
(the one real addition, since that scheme is not built in this job today - the app target it
depends on is already built into the same derived data path, so the compiler should reuse it),
and the test's own execution.

**As a fourth job: about 7 to 9 extra macOS minutes, so about 70 to 90 pool minutes per push,
roughly a third more** **[inferred]**. A fourth job pays for the whole app compile a second
time as well as a second runner's setup.

**Recommendation: fold it into `app-launch-smoke`**, because that job has already built the app
target into its derived data path, so the only compile left to pay for is the unit-test bundle
itself, and because a job that already exists is a job whose cost is already understood. It
keeps the three-question shape (do the tests pass / does the shipping app build / does the app
run) and adds a fourth question to the job that is already watching the app run.

**If the total has to come down**, in the order I would cut:

1. **Make `build-expo-app` conditional on the paths it is about.** It is the largest job at
   about 12 macOS minutes **[verified]** `AGENT_LOOP.md`, and it is the only gate that compiles
   the two bridge files - but a round that touches only `VideoShrink/` or `VideoShrinkTests/`
   cannot break it. A path filter over `modules/`, `App.tsx`, `app.json`, `eas.json`,
   `package.json`, `package-lock.json` and `index.ts` would keep the question and stop paying
   for it on the pushes that cannot change the answer. **[inferred]** - and it does mean a
   bridge-file mistake could travel on a commit that did change them plus a later one that did
   not, which is the trade to weigh.
2. **Stop running the workflow on pull requests.** Every job triggers on `pull_request` as well
   as `push` **[verified]** `.github/workflows/ios-tests.yml`; on a solo repository that is
   paying twice for most changes.
3. **Reduce the pipeline test's scope to the fixture and the scan** if the export leg proves
   slow on a software encoder - which section 8 recommends as the first step anyway.

What I would not cut: job 1, which is the only thing that runs the suite, and the launch test,
which is the only thing that has ever looked at a screen.

And the standing fact from the loop: making the repository public removes the private-repository
minute cost entirely and is by far the cheapest fix **[verified]** `AGENT_LOOP.md`. This
document's arithmetic is what that decision should be made against, and it is not mine to make.

## 7. The risks, and how the plan fails safely

**The risk that matters most is a job that silently skips**, because it costs the same as a job
that works and pays back nothing. The arrangements in section 4.2 exist for it: opt-in in the
suite, a script that refuses its own pass banner unless the case executed, and no skip inside
the test once it is running. A skip is a fact to be printed, not a way to be green.

**The second risk is flakiness**, and each source has a specific answer:

| Risk | Why it would be flaky | What the plan does about it |
|------|----------------------|-----------------------------|
| Simulator not ready | Boot races | Already solved by `bootstatus -b` **[verified]** |
| Media not visible yet | The import may not be instantaneous | **[inferred]** - the test polls for the fixture for a bounded time and fails naming the count of videos it could find, rather than asserting immediately |
| The grant did not take | See 2.2 - the install/grant ordering is inferred | The test reads the authorization status first and fails with the `simctl privacy` sentence rather than letting a prompt hang the run |
| Software encoder is slow | A 3-second clip is not much work, but the simulator is not fast | The test asserts outcomes, never durations; the job's `timeout-minutes` bounds the worst case |
| The copy is not smaller | Noise level, preset behaviour on the runner | The fixture is built for margin (section 3.5), and a miss produces the "not smaller" sentence, which is a fixture fix rather than a code fix |
| A Photos confirmation alert | Deletion prompts | The deletion leg is deliberately not in the first instrument (section 2.3) |
| A green run is over-read | The whole point of section 1.2 | The script's own pass text must state the claim and the exclusions, exactly as `verify-app-launch.mjs` does today **[verified]** |

**Failure attribution.** Every precondition gets its own sentence: no fixture file; the fixture
program failed to write or read back its own output; `addmedia` rejected the file; `privacy`
rejected the service name; the status was not authorized afterwards; the library held zero or
more than one video; the export was refused (which will carry the transcoder's own words
**[verified]** `ExportRefusal`); the copy was not smaller; `save` returned nil; the read-back
did not answer. That is the same discipline the launch job already uses, and it is what made
the launch job's own first failure diagnosable from the log alone **[verified]**
`AGENT_LOOP.md` N41.

**What the first run should be expected to reveal**, in the order it will hit them - these are
the genuinely open questions, and each is cheap to answer once:

1. whether this Xcode's `simctl privacy` accepts `photos` as a service and whether the grant
   takes effect for an app that is not yet installed;
2. whether `simctl addmedia` puts the fixture where `PHAsset.fetchAssets(with: .video)` will
   find it, and how many videos the library then holds;
3. whether the simulator's PhotoKit reports `dataSize` at all - almost certainly it will not
   **[inferred]**, since the app probes for a property documented from iOS 27 **[verified]**
   `PhotoLibraryScanService`, which means the scan falls back to measuring the original on
   device. That path works and is what makes the sizes appear, but it is worth seeing stated in
   the log rather than assumed;
4. whether `AVAssetExportPresetHEVC1920x1080` is supported on the simulator - if not, the app
   throws `ExportRefusal.cannotWriteMovieFile`, and the first run says so in the transcoder's
   own sentence rather than in ours;
5. how long one 3-second export takes on a software encoder, which is a runner fact and must
   never be quoted as an iPhone fact;
6. whether the simulator's PhotoKit answers the read-back for a copy written moments earlier
   with the network off.

## 8. The first step

The smallest change that produces evidence is **not** the whole job. It is the setup and the
listing: prove that a generated fixture can be imported into a simulator's Photos library, that
the app can be granted access to it without a prompt, and that the app's own scanner sees it and
reads it correctly.

Concretely, one round's work:

1. `scripts/simulator-fixture.swift`, the generator from section 3.1, with its own read-back
   validation and its own failure sentences.
2. One new test case in `VideoShrinkTests` (say `SimulatorLibraryTests`), opt-in on a
   `VIDEOSHRINK_SIMULATOR_PIPELINE=1` style variable, which asserts: the fixture is in the
   library; the app's `scan()` returns exactly one video; that video has a size, from either
   source; its format reads as H.264 1080p at 30 fps with one audio track; and `AssetRules` does
   not refuse it.
3. A few steps added to the existing `app-launch-smoke` job, or a small
   `scripts/verify-simulator-pipeline.mjs` that the job calls: generate the fixture, `bootstatus`,
   `addmedia`, the two `privacy` grants, then `xcodebuild ... -only-testing` for that one case,
   under the same banner discipline as the launch script.

What that buys, before a single line of export code is written on top of it: answers to first-run
questions 1, 2 and 3 above, and a real assertion that the app's listing and on-device read work
against a library this app did not create. Every later piece - the export, the save, the
read-back, then deletion through the UI test - is then built on machinery that is known to work
rather than on machinery that is assumed to.

The step after that is the same test extended with `retrieve` and `inspect`, then `transcode` and
`verify`, then `save` and the read-back; each of those is an assertion added to a test that
already runs, which is the cheapest kind of progress this project has.

## Sources I could not open from this machine

The three external facts this plan leans on, and what would settle each:

| Fact | Where it comes from | How it gets confirmed |
|------|--------------------|-----------------------|
| `simctl addmedia`, `simctl privacy`, `simctl install`, `simctl erase` exist and take the arguments used above | **Documented**: Apple's `xcrun simctl` reference and the Simulator User Guide. Not openable from Windows, and nothing in this repository uses any of them **[verified]** | The first run prints each command's own output, and the script prints `xcrun simctl help privacy` and `xcrun simctl help addmedia` into the log before it relies on them |
| XCTest's `addUIInterruptionMonitor` can answer the Photos alert | **Documented**: XCTest, and the fallback in section 2.2 | Only needed if the grant proves unreliable; the UI test would print the alert it dismissed |
| A unit-test bundle in a `bundle.unit-test` target that depends on an app target is hosted by that app, so the app's usage descriptions apply | **Inferred** from `project.yml`'s dependency and from every test file's `@testable import VideoShrink` **[verified]** | The first run prints the generated project's `TEST_HOST` and `BUNDLE_LOADER` from `xcodebuild -showBuildSettings`, so a wrong assumption is visible in the log instead of looking like a PhotoKit failure |
