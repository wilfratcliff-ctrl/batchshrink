# Validation record

Every entry below is one of three things, and says which: **historical** (a past build or a past
decision), **implemented source** (in the tree; compiled by CI since 2026-09-23, but never run), or
**observed** (it ran, with the evidence named). See the status legend in
[README.md](../README.md).

## September 23: the test suite compiles and passes in CI (observed at 5d72357)

This is the first entry in this record that is **observed** rather than implemented source. The
XCTest suite did not merely compile: it ran, and it passed.

- **Observed.** CI run `35852961091` on commit `5d72357` printed `** TEST BUILD SUCCEEDED **` and
  `===== VIDEOSHRINK TEST RUN ===== PASSED` with
  `Executed 162 tests, with 0 failures (0 unexpected)`. The job is
  `.github/workflows/ios-tests.yml`, which runs the same `scripts/verify-native-tests.mjs` the EAS
  `verify-tests` profile runs, on a free macOS runner. It generates `VideoShrink.xcodeproj` from
  `project.yml` with XcodeGen, compiles the app target and the test target, and executes the cases
  on an iPhone simulator.
- **Observed, and new.** That job compiles the standalone Xcode project, including
  `VideoShrink/VideoShrinkApp.swift` and the resource bundle, so those are no longer uncompiled
  source. The earlier EAS builds compiled only the Swift under
  `modules/videoshrink-native/ios/`, which is the pod's copy of the app's own Swift.
- **Historical.** The builds that lead here. EAS build `9f83392c` on commit `082537a`, profile
  `development-simulator`, finished and produced an artifact: that is the first evidence that the
  round 1 to 3 Swift core compiles. The `verify-tests` profile then found the test target's two
  argument-order errors in `DeletionPolicyTests.swift`; after that fix the test target compiled.
  Its first run executed all 162 cases with 7 failures; commits `7c11f26` and `5d72357` addressed
  them, and the run above is the result. The earlier builds and their evidence stay listed further
  down this file.
- Verification is now free and automatic rather than rationed. The EAS account's free-plan iOS
  build minutes are exhausted until 1 October 2026, so EAS is now only for builds that install on
  a device; the CI job spends none of those minutes and runs on every push to `main`.
- **Still NOT RUN, unchanged and not softened.** The app itself has never run. No screen has been
  rendered, no video has been exported, no original has been deleted and no queue file has been
  written on a device. `docs/PHYSICAL_DEVICE_TEST_PLAN.md` is still entirely unexecuted. Build 10
  is still the last build known to have reached testers. A green suite exercises the app's pure
  logic against injected fakes and says nothing about PhotoKit, AVFoundation, thermal state, HDR,
  interruptions or iCloud.
- At the time of writing, branch `main` is at `5d72357` and the working tree carries uncommitted
  edits from the next round, which are unverified until they are pushed and CI is green.

## September 23: round 2 and the Mac handoff (implemented source at 65d6a09; compiled and tested later, see the entry above)

This entry records round 2 as it landed at commit `65d6a09`, and the handoff document written for
the first Mac session. Neither was compiled or executed at the time. The code described here
later became part of the tree at `5d72357`, which CI compiles and whose tests pass (see the entry
above); the handoff document itself is still an unexecuted set of instructions.

- Round 2 is in the tree at `65d6a09`: `BatchViewModel` constructs and starts the `LibraryChangeMonitor`
  and applies a metadata-only reconciliation on each report (N1), `ThumbnailService.invalidate(identifiers:)`
  plus a `revision` key on `AssetThumbnail` drops stale previews (N2), one `QueueWarningNotice` is drawn
  on the screens a failed write can leave a run on (N3), the deletion look is refreshed at tap time so
  the offered list can only shrink (N4), and 13 documents were corrected (P1-4). Round 2 integration
  wired the thumbnail work, which was built but unreachable, and left `LibraryReconciling` in place as
  a deliberate workaround (N7, N8).
- `LibraryReconciling` is still a cast: `BatchViewModel` holds `any LibraryScanning` and does
  `scanner as? LibraryReconciling`. The real service conforms; the scanner test mocks do not, so the
  cast yields nil in tests and the reconciliation path is covered by no case. Round 3 later removed
  the workaround and added tests for the wiring (N7 and N8).
- At that commit no Swift had been compiled and no XCTest case had executed, and the tree held 145
  cases. Both changed later: the same code is in the tree at `5d72357`, where 162 cases compile and
  pass (entry above). Portable checks after round 2: `npm run validate:native` passes (37 app Swift
  files, 145 XCTest cases present, icon/JSON valid), `npm run typecheck` passes, and
  `node scripts/sync-native-sources.mjs --check` passes (36 Swift source files and the privacy
  manifest). Those are pattern scans and a TypeScript check, not a compiler.
- `docs/MAC_VALIDATION_HANDOFF.md` was written for the first Mac session. That assumed a Mac with
  Xcode, and the owner uses Expo only and does not own a Mac, so the document could not be run. It
  has been replaced by `docs/VERIFICATION_HANDOFF.md`, which routes verification through an EAS cloud
  build (`npx eas-cli build --platform ios --profile development-simulator`), states what that build
  compiles and what it does not, gives the exact commands for each profile in `eas.json`, keeps the
  ranked list of things a round said it could not compile-check, and keeps the symptom-to-file-to-commit
  triage table for `10ab65f`, `559f693`, `65d6a09` and `dcd0695`. It claims no result.
- **At that commit, NOT RUN**: compilation, XCTest execution, simulator, any build, any device run,
  deletion against a real library, the queue-failure paths on a device, and the new revalidation
  lookups. Compilation and the XCTest suite have since been observed (entry above); every device
  item in this list has not.

## September 23: round 1 reliability work (implemented source at 559f693; compiled and tested later, see the entry above)

This entry records round 1 as it landed at commit `559f693`. Later round 2 work is recorded by the
loop in `AGENT_LOOP.md` and is not described here.

- P0-1, P0-2 and P0-3 from `DEVELOPMENT_REVIEW.md`, plus the `LibraryChangeMonitor` mechanism, are
  in the tree at commit `559f693`. At that point none of it had been compiled and no XCTest case
  had run; the same code is in the tree at `5d72357` today, compiled, with the suite passing.
- `BatchViewModel` now reports whether each queue write reached disk, and a checkpoint that fails
  stops the run before it submits a Photos mutation: before a save, before a delete transaction,
  and before work starts on a video. A copy Photos has already accepted is never put back on the
  waiting list after a failed follow-up write, so a second copy cannot be made.
- Deletion stores a receipt naming the copy Photos created, and what both assets looked like when
  that copy was checked. Immediately before Photos is asked, both assets are looked up again and
  the delete is refused unless the fresh look matches. A receipt that is missing, stale or written
  by an older algorithm never authorises a delete, so a queue written before the change still
  decodes and keeps every original.
- `VideoVerificationService` requires every applicable sample window to decode, decodes audio
  samples instead of trusting the track's duration, and compares the imported copy against the
  output properties this run measured before saving.
- `LibraryChangeMonitor` and the pure reconciliation rules landed with unit tests, but at `559f693`
  nothing constructed the monitor, so the library did not refresh after an edit made outside the
  app. This is N1 in `AGENT_LOOP.md`.
- The stricter deletion gate and its caller were developed separately, and deletion was briefly
  dead code because no caller passed the new evidence in. An integration pass rewired the receipt
  from read-back through the persisted queue into the gate, and the old unrevalidated delete call
  now has no caller. A change that strict needs device validation before it is trusted.
- XCTest cases went from 102 to 145 at this commit, and none had executed. (The suite is 162 cases
  now and passes in CI; see the entry above.) Portable checks after round 1:
  `npm run validate:native` passes (37 application Swift files, 145 XCTest cases present) and
  `npm run typecheck` passes. Those are pattern scans, not a compiler.
- **At that commit, NOT RUN**: compilation, XCTest execution, simulator, any build, any device run,
  deletion against a real library, the queue-failure paths on a device, and the new revalidation
  lookups. Compilation and the XCTest suite have since been observed (entry above); every device
  item in this list has not.

## September 21: selection previews and a clarity pass (historical: compiled into production build 10)

- Selection thumbnails are larger and now carry the video's length, so a shot can be recognised
  rather than guessed at from a date.
- Tapping a thumbnail opens a sheet with the system player and its scrubber, which is the point:
  deciding what to delete from a still frame is guesswork. Previews ask PhotoKit for a player item
  so Photos can stream or buffer instead of pulling an export-grade original first, and the sheet
  says that opening an iCloud video fetches what it needs. The player opens paused, so a preview
  never starts with sound.
- The row now has three targets with distinct jobs: the picture previews, the words and the tick
  choose. Each has its own VoiceOver label and hint.
- Copy was cut back across the start, scanning, summary, selection, finished, quality and deletion
  screens, with a "Fast answers" section at the top of the help sheet. The three questions people
  arrive with are when space actually comes back, whether anything downloads, and how trustworthy
  the numbers are.
- Build number moved to 10 so the next build is distinguishable from the submitted build 9.
- No build was created for these changes at the time, as requested. Historical note: they were
  later compiled into the production build 10 recorded in [RELEASE_10.md](RELEASE_10.md). They are
  still unverified on a device: no rendered layout, accessibility result or media test exists for
  them.

## September 19: deletion, metadata preservation and a reliability pass (build 7, historical)

- Added opt-in deletion of originals with two modes: after each confirmed copy, or at the end
  after the user reviews. One gate, `DeletionPolicy`, requires a saved, smaller, verified copy
  that Photos handed back. Anything less keeps the original and records the reason.
- Deleting is off by default in `ShrinkSettings`, applies to batch runs only, and is stated as
  such in the interface. Turning it on goes through an extra destructive confirmation that names
  Photos' 30-day Recently Deleted window.
- Deletion intent is persisted *before* the Photos call, so an interrupted delete comes back
  `uncertain` rather than being repeated. The finished screen lists uncertain deletions under
  "Needs attention".
- Copies now keep the original's filename (`PHAssetResourceCreationOptions.originalFilename`),
  creation date, location and favourite/hidden flags (`PHAssetChangeRequest`), and the transcoder
  writes the original's own descriptive metadata into the file. Album membership, captions,
  keywords and ratings are not copied, and the docs say so.
- Verification samples frames at three points in the track, requires non-empty audio when the
  original had sound, and reads every saved copy back from Photos. A copy that cannot be read back
  is reported, not failed.
- A batch stops itself with an explanation when iOS reports a critical thermal state, and says so
  on the working screen when Low Power Mode is on.
- Codec options were researched and written up in [CODECS.md](CODECS.md): `AVVideoCodecType` has no
  AV1 (or VP9) case and VideoToolbox exposes no AV1 encoder on iOS, so HEVC remains the best the
  platform will actually encode. Resolution and frame rate are the levers that matter.
- A static product-tester pass over every route is recorded in [QA_PASS.md](QA_PASS.md). Five
  issues were found and fixed: a possible double-resume crash in the scan's on-device size pass,
  a delete button that vanished mid-delete, a finished run offering videos it had just deleted,
  uncertain deletions missing from "Needs attention", and interface copy that still claimed
  originals are never deleted. Seven more are flagged rather than fixed, including the stale
  library after an outside edit and the fact that no test has ever executed.
- Portable checks pass: `node scripts/validate.mjs` (33 application Swift files, 95 XCTest cases
  present), `npm run typecheck`, and native source synchronization. Guardrails changed
  deliberately: Photos deletion is no longer forbidden outright, but it must live in
  `PhotoLibraryService`, must be gated by `DeletionPolicy`, must default to off, and the interface
  must mention Recently Deleted.
- Three build attempts were needed. `885fbe36-0a37-4d00-999d-3f7d5a9b27d9` was canceled to fold
  the QA fixes in. `da2b58cb-a175-434c-97ce-446772e9da72` failed with two real API mistakes:
  `CLLocation` has no `latitude:longitude:altitude:` initializer, and altitude lives on
  `CLLocation`, not on `CLLocationCoordinate2D`. `42298adc-9f3e-44e5-bc45-2e9322fd62e8` then
  failed on an optional enum comparison in the finished screen, reported by Xcode as a nonsense
  "PencilSqueezeGesturePhase" mismatch. All three were fixed, and the optional comparisons are
  now written explicitly.
- Build 7 (`c1f85401-0c03-47b5-99d0-7707681638e0`) finished successfully at 12:00 UTC on
  19 September. Deletion, its gate and durable states, the metadata and filename plumbing, the
  sampled verification, the read-back path, the thermal stop and the QA fixes all compiled,
  archived and signed for the registered iPhone. Installation link:
  https://expo.dev/accounts/wilfrat1/projects/videoshrink/builds/c1f85401-0c03-47b5-99d0-7707681638e0 .
- **NOT RUN**: XCTest execution, deletion on a real library, Recently Deleted behaviour, the
  metadata comparison against an original, the thermal stop, and every interface state above.

## September 19: durable queue (build 5, historical)

- The batch queue is now written to a small JSON file in the app's own Application Support
  directory, excluded from backup and behind `completeFileProtectionUntilFirstUserAuthentication`.
  It records library identifiers, the sizes Photos reported, the settings the run used and what
  happened to each item. No media, filename, location or thumbnail is stored.
- Writes happen between steps, not on progress ticks: `setState` compares the coarse persisted
  form of the old and new state and only writes when it actually changes.
- On launch the stored queue is reconciled. Anything waiting or in flight goes back to waiting.
  Anything that was mid-save becomes `needsCheck`, because Photos may have committed that copy
  after the app stopped; it is never run again automatically, and the user requeues it only
  through an explicit "I checked Photos" action.
- `Done` clears the queue by writing an empty record. The store contains no file deletion at
  all, and the repository guardrail that confines `removeItem` to `TemporaryFileManager` is
  unchanged.
- The paused and finished screens report recovered runs, check-in-Photos items, and a warning
  when the queue could not be written.
- Portable checks pass: `node scripts/validate.mjs` (29 application Swift files, 76 XCTest
  cases present), `npm run typecheck`, and native source synchronization. New guardrails require
  the Application Support location, backup exclusion, file protection, the absence of deletion,
  the reconciliation step and the `needsCheck` state.
- Build 5 (`bde6969a-b803-4974-9eee-2e936b9aaf3d`) finished successfully at 00:01 UTC on
  19 September. The queue record, the file store, the reconciliation rules, the restore path and
  the new interface states compiled, archived and signed for the registered iPhone. Installation
  link: https://expo.dev/accounts/wilfrat1/projects/videoshrink/builds/bde6969a-b803-4974-9eee-2e936b9aaf3d .
- **NOT RUN**: XCTest execution, a real force-quit mid-batch, a force-quit during a Photos save,
  restoring a large queue, and the interaction between a restored queue and Photos access being
  changed while the app was closed.

## September 18: thumbnails and quality options (build 4, historical)

- Added thumbnails to the batch list, the current video and the finished rows. Thumbnails are
  the only thing the app fetches without the user starting a job: Photos may hand over a
  cached preview of a video whose original is in iCloud. The library scan still asks PhotoKit
  with network access switched off, and the guardrail that checks this is unchanged.
- Added quality options: 720p (Apple's documented H.264 preset), 1080p HEVC and 4K HEVC, with
  the frame rate kept, lowered to 30 fps or lowered to 24 fps. Apple ships no HEVC preset below
  1080p, which is why 720p is H.264.
- The transcoder now chooses the preset, applies a video composition only when the preset
  cannot hold a small source at its own size or lower the frame rate, sets
  `perFrameHDRDisplayMetadataPolicy` on composed exports, and retries once without the
  composition if a composed export fails.
- Verification now also checks the expected codec, that a copy has no more pixels and no more
  frames than its original, and reports the measured codec and frame rate. Extraction moved
  to `VideoMetadata.codec` and `nominalFrameRate`, so the result screens show measured values
  rather than the requested ones.
- The estimate model is per resolution and per frame rate, keeps the planning bands
  (720p 2.5–5 Mbps, 1080p 4–8 Mbps, 4K 12–24 Mbps), and is still replaced by copy sizes
  measured on this iPhone once three exist at that size.
- Interface copy was cut back: welcome, scanning, summary, selection, working, paused and
  finished screens all carry shorter lines, the reasoning moved into the help sheet, and the
  quality chooser is a sheet with an animated highlight and animated estimate.
- Portable checks pass: `node scripts/validate.mjs` (27 application Swift files, 65 XCTest
  cases present), `npm run typecheck`, and native source synchronization. New guardrails
  require the documented preset names, the no-upscaling rule, the composition request, the HDR
  policy, and that only the thumbnail service may enable network access.
- First build 4 attempt (`ffb2f794-463f-423c-91c7-e0d3e7c69c9c`) failed in Xcode with
  `value of type 'ShrinkSettings' has no member 'codec'` in `BatchScreens.swift:548`. Fixed
  and resubmitted as `b259c514-a3b7-47a2-ba34-644353162539`.
- Build 4 (`b259c514-a3b7-47a2-ba34-644353162539`) finished successfully at 22:52 UTC. The
  quality model, the preset and composition paths, the thumbnail service, the animated
  chooser and the new verification rules compiled, archived and signed for the registered
  iPhone. Installation link:
  https://expo.dev/accounts/wilfrat1/projects/videoshrink/builds/b259c514-a3b7-47a2-ba34-644353162539 .
  This is compilation evidence, not a rendered layout, a quality comparison or a device test.
- **NOT RUN**: XCTest execution, the quality options on a real clip, the composed export path,
  the H.264 720p preset, frame-rate reduction, thumbnails over a large library, and estimate
  accuracy for each option.

## September 18: batch queue, library prescan and time estimate (build 3, historical)

- Added the batch flow: library scan, a sortable selection list, an in-memory queue, a processing display with remaining files and a time estimate, pause/resume, and a measured summary. The single-video flow keeps its behaviour and moved into `SingleVideoFlow.swift`.
- Eligibility rules now live once, in `AssetRules`, and are used by both the scan and the retrieval path. The retrieval path also rejects Live Photo video pairs, which the subtype check alone could not see.
- Original sizes come from the documented `PHAssetResource.dataSize` (iOS 27) through a runtime probe, because the EAS image compiles with **Xcode 26.6 (17F113) and iPhoneOS26.5.sdk**, which predates that SDK. Systems without it fall back to measuring originals already on the iPhone with `isNetworkAccessAllowed = false`. The scan never allows a network request and never uses key-value coding.
- Savings are reported as ranges: a 4–8 Mbps planning band for a 1080p HEVC copy, replaced by copy bitrates measured on this iPhone once three videos have finished. Time estimates appear only after one video has finished and exclude iCloud download time.
- Completion is measured, not modelled: the finished screen reports original and copy bytes for the videos Photos confirmed.
- Portable checks pass: `node scripts/validate.mjs` (22 application Swift files, 55 XCTest cases present, icon and JSON valid), `npm run typecheck`, and native source synchronization. The guardrails now also require that the scan asks for originals with network access disabled, that reported sizes use the documented property, that per-file removal stays inside the owned temporary root, and that `docs/BATCH_PHASE.md` exists.
- **NOT RUN**: Swift compilation, XCTest execution, simulator, signing, Photos/iCloud access and every device behaviour above. What the `dataSize` probe returns at runtime, whether the on-device pass ever triggers a download, the accuracy of the estimate, and the batch UI on a real library are all unverified.
- EAS build 3 (`3d8d6b29-936a-4546-a104-e32b30b46205`) finished successfully at 22:15 UTC on the same image (Xcode 26.6, iPhoneOS26.5.sdk). The batch view model and screens, the library scan service, the estimate model, the shared eligibility rules and the history store compiled into the `VideoShrinkCore` pod, archived and signed for the registered iPhone. Installation link: https://expo.dev/accounts/wilfrat1/projects/videoshrink/builds/3d8d6b29-936a-4546-a104-e32b30b46205 . **The build is compilation evidence only.** Estimate accuracy, scan coverage, the runtime result of the `dataSize` probe, whether the on-device pass ever fetches bytes, and every batch interaction still need the device.

## September 18: physical build and interface redesign (historical)

- EAS build 1 (`8441943f-fcb8-4584-ae19-cf691b7b7205`) finished successfully. The user completed signing/device registration, installed it and confirmed the native app opened through Metro on their iPhone.
- Replaced the initial form with focused welcome, processing, review, success and recovery screens. Native services and model behavior are unchanged.
- Portable guardrails passed with 13 application Swift files and 30 XCTest cases present. TypeScript checking and source synchronization passed for 12 shared Swift files. XCTest cases have not been executed.
- Build 2 (`354ed8f9-5879-4001-9c82-6d7917fdf067`) finished successfully on EAS at 21:32 UTC. The redesigned SwiftUI screens compiled, archived and signed for the registered physical iPhone. Installation link: https://expo.dev/accounts/wilfrat1/projects/videoshrink/builds/354ed8f9-5879-4001-9c82-6d7917fdf067 . This is compilation evidence, not a rendered layout or device interaction test.
- Privacy manifest XML and synchronized-source checks passed. Calculated fixed-token contrast: white on primary button 8.51:1; light accent on canvas 7.40:1; dark accent on canvas 12.11:1. These calculations do not replace an accessibility audit of the rendered interface.
- Supplied six deterministic SwiftUI previews. Visual rendering, accessibility behavior and haptics still require Xcode/device review; no simulator is available on Windows.

The sections below record the earlier September 17 setup and its limitations at that time. Their
"not available" lists describe that Windows-only environment, not the present one: compilation
and XCTest execution are now covered by CI (see the entry at the top of this file), while every
device and simulator-app behaviour they list remains unproven.

Environment: Windows 10.0.26200, PowerShell, Node.js v24.21.0, Git 2.55.0.windows.3. Date: 2026-09-17.

## Checks available here

Result: the listed portable checks passed. 11 application Swift files and **30 XCTest cases** are present. The 30 cases have **not been executed**. Source review found one app filesystem-removal call, confined to the owned temporary root, and no Photos deletion/existing-asset mutation or app network-upload path.

- `node scripts/validate.mjs`: repository presence, targeted prohibited application APIs/patterns, cleanup confinement, privacy/resource markers, XCTest case presence, JSON parsing, opaque 1024×1024 PNG structure and decompression.
- `node --check` for the JavaScript tooling.
- PowerShell XML parsing for `Info.plist` and `PrivacyInfo.xcprivacy`.
- Git whitespace check and manual source review of cancellation, saving, permission handling, source immutability, logging and background claims.
- Apple primary documentation consulted for API signatures/availability, HEVC preset, current upload baseline, required-reason API declarations and background scheduling. XcodeGen’s specification consulted for project generation.

These are static checks. A passing pattern scan is not a formal safety proof, a Swift parser, a generated-project check or a running app test.

## Expo setup validation

- Installed Expo SDK 57, `expo-dev-client` and the Expo build-properties plugin using npm. EAS CLI 24.7.0 is installed globally.
- Expo browser authentication succeeded; the personal account `wilfrat1` owns the newly linked `videoshrink` project. No Apple signing authentication was performed.
- `npm run typecheck`: passed.
- `npx expo install --check`: dependencies match this Expo SDK.
- `npx expo-doctor@latest`: **21/21 checks passed**, after removing the project-local EAS CLI dependency and conflicting npm script.
- `npx expo-modules-autolinking resolve --platform apple --json`: found the local `VideoShrinkNative` pod and `VideoShrinkNativeModule` class.
- `npx expo config --type introspect --json`: resolved both Photos privacy descriptions, iOS 18 deployment target and privacy manifest aggregation.
- `eas config --platform ios --profile development`: resolved a development client with internal distribution and `simulator: false`.
- `npx expo export --platform ios --output-dir build/expo-export`: bundled 580 modules and produced the iOS JavaScript/Hermes artifact. This is **not** a Swift or native app build.
- Native source synchronization and byte/hash comparison passed for the ten shared Swift files and privacy manifest.
- `npm audit` currently reports **10 moderate dependency-tree advisories**, originating in a transitive `uuid` dependency used by Expo's Xcode/config tooling. No high or critical advisories remain in the application dependency tree. The automated proposed fix would downgrade Expo to SDK 46, so it was not applied. Track the upstream fix; Expo Doctor passing does not mean the dependency audit is clean.

The wrapper's two Swift files, UIHostingController containment, app lifecycle forwarding, CocoaPods/resource packaging and original pipeline still need a real iOS compile and device tests. No cloud build was started: the user requested a confirmation pause first. No Git commit or push was made.

## Not available here

XcodeGen generation, Swift compiler/type checking, XCTest execution, simulator build/playback, signing/archive validation, App Store Connect/TestFlight upload, iCloud retrieval and physical-device behavior. No Apple developer credentials were requested or used. No test video was accessed.

The first cloud-Mac session must execute `scripts/validate-mac.sh` with an available iPhone simulator UUID, then perform the physical test plan. Record failures honestly and fix them before claiming Phase 0 succeeded. No generated `.xcodeproj` is included; `project.yml` is its source of truth.
