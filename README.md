# VideoShrink — Phase 0

A native SwiftUI, one-video feasibility prototype. It retrieves a selected Photos video, exports a 1080p HEVC copy on the iPhone, verifies that file, previews it and saves a separate Photos item only after an explicit save action.

The project now includes an **Expo development app** that embeds the native SwiftUI harness through a local Swift module. [EAS_DEVELOPMENT_BUILD.md](docs/EAS_DEVELOPMENT_BUILD.md) describes the Windows-to-EAS setup; [EXPO_INTEGRATION.md](docs/EXPO_INTEGRATION.md) explains the shared source arrangement. EAS built and signed this app repeatedly, ending with the production build 10 recorded in [RELEASE_10.md](docs/RELEASE_10.md); the build ids that survive in the record are listed in [VALIDATION.md](docs/VALIDATION.md). Build 10 is still the last build known to have reached testers.

**Status: the source compiles, its test suite passes, and the app has now been launched on a simulator - but it has never run on a device.** Every status statement in this repository is one of three kinds, and they are not interchangeable:

- **Historical** - a past build or a past decision, recorded as it stood then. Real builds were compiled, archived and signed by EAS, most recently build 10. That is compilation evidence for the source as it was at that build, not for the tree as it is now. Build 10 is the last build known to have reached testers; every build after it targeted a simulator and reached no one.
- **Implemented source** - present in the tree and, since 2026-09-23, compiled. `.github/workflows/ios-tests.yml` runs `scripts/verify-native-tests.mjs` on a free macOS runner on every push to `main`: it generates the standalone project with XcodeGen, compiles both targets and runs the whole XCTest suite. Round 1 landed at commit `559f693` and is the reference point for the "in the tree at `559f693`" statements below; later rounds are recorded by the loop in `AGENT_LOOP.md`. The verified commit is `5d72357`, and uncommitted work is unverified until it is pushed. Compiling and passing tests is not the same as running correctly - the app's runtime behaviour is still unobserved.
- **Observed** - something that actually ran, with the evidence named beside it. The test suite is in this category: CI run `35852961091` on commit `5d72357` reported `** TEST BUILD SUCCEEDED **`, `TEST RUN ... PASSED` and `Executed 162 tests, with 0 failures (0 unexpected)`. **A screen rendering is in this category now too, for the first time:** on commit `780f14f` the `app-launch-smoke` job built the standalone app, installed it on a simulator and ran `VideoShrinkUITests`, which waits for the introduction's own Skip control, taps it and waits for the batch screen's primary control. That is the first time anything in this repository observed the app doing anything. It is one launch and one navigation on a simulator with no Photos library, so nothing else is observed: no video has been exported, no original has been deleted, no queue file has been written on a device, and every pipeline step is still unexercised.

**The CI gate is unblocked, and `main` is verified again.** It was blocked for ten days by the account's Actions minutes - every job failed about nine seconds after creation with no runner and no steps, and the billing notice named the cause: the plan's 2,000 minutes for the month were spent, with macOS drawing from the same pool at ten minutes per minute. The repository was made **public** on 24 September 2026, which removes the private-repository minute cost entirely, and the next run started all three jobs immediately. On commit `e105a5d` all three are green: the test target compiles, `Executed 411 tests, with 1 test skipped and 0 failures`, the Expo app builds for the simulator, and the app launches on a simulator and draws its first screen. **That first run also found what fifteen uncompiled rounds had hidden**: one real compile error (`BatchViewModel.selectableAssets` was a multi-statement getter with no `return`) and three tests that contradicted their own doc comments. All four are fixed. `AGENT_LOOP.md` has the detail.

**What is still unverified: anything on a real phone.** The EAS iOS build allowance is a different quota and still resets on 1 October, so no installable `.ipa` has been produced from this tree. Nothing has been exported, deleted or queued on a device; `docs/PHYSICAL_DEVICE_TEST_PLAN.md` is still the gate for all of it.

Created on Windows on 2026-09-17. Git, Node.js and ripgrep were available; Swift, Xcode and XcodeGen were not. The Python command was a Windows app alias, not a verified runtime. See [validation evidence](docs/VALIDATION.md). Phase 0 is only complete after the device acceptance test below passes.

## Batch phase (historical)

The notes in this section are **historical**: each records what one build contained at the time.
They are not claims about the tree today, and they are not device results.

The app now opens on the batch: look through the library, choose videos, watch a running
count with a time estimate, and read a measured summary. The one-video flow with a preview
before saving is still one tap away and still the safest way to judge a copy.

Build 4 adds thumbnails for every video in the list and a quality chooser: 720p (H.264),
1080p HEVC (default) or 4K HEVC, with the frame rate kept, lowered to 30 fps or lowered to
24 fps. The chooser estimates each resolution for the current selection before anything runs.

Build 5 makes the queue durable. A run is written to a small local file between steps, so
closing the app no longer throws away a long batch: it comes back paused, with anything that
was mid-save flagged for a look in Photos instead of being run twice.

Build 6 tightens what the app can prove. Copies are checked at three points in the file and
for non-empty audio, then read back from Photos after saving, and the batch stops with an
explanation if the iPhone reports a critical thermal state.

Build 7 adds opt-in deletion of originals, with two modes and one hard gate, preserves the
originals' filenames, dates, locations, favourite flags and embedded metadata, and writes down
its intent before every delete so an interrupted one is never repeated blindly. The codec
question is answered in [CODECS.md](docs/CODECS.md): AVFoundation has no AV1 encoder, so HEVC
remains the best thing an iPhone will actually encode.

Build 9 batches deletions so Photos asks once per batch instead of once per video, and adds an
opt-in "keep screen awake while working" setting for leaving a batch to run.

[BATCH_PHASE.md](docs/BATCH_PHASE.md) documents the scan, the estimate model, the queue
rules and the limits. In short: the scan downloads nothing, sizes come only from the
documented Photos API or from originals already on the iPhone, savings and time are reported
as ranges with their basis, and no released iCloud space is claimed.

After build 10, rounds 1 to 5 changed this source further. That work is in the tree, and the tree
now compiles and its tests run. In the tree at `5d72357`: a failed queue write stops a run before
it touches Photos and a committed save is never repeated after a failed follow-up write; deletion
stores an original-to-copy receipt, revalidates both assets immediately before deleting and
refuses a receipt that is missing, stale or from an older algorithm; verification requires every
sample window to decode, decodes audio instead of trusting track duration and compares the
imported copy against the output the run measured. The XCTest suite went from 102 cases to 162 and
all 162 now execute and pass on the CI runner (run `35852961091` at commit `5d72357`). A green
suite is not a device result: none of this has run against a real library. See
[VALIDATION.md](docs/VALIDATION.md) for the entries and [BATCH_PHASE.md](docs/BATCH_PHASE.md) for
the current rules.

## What this proves once tested

- Genuine `PHAsset` lookup using the system video picker’s identifier and read/write PhotoKit permission.
- Local or iCloud retrieval using PhotoKit with network access enabled and real download progress when delivered by the API.
- AVFoundation HEVC encoding, measured input/output sizes, audio track retention and display orientation checks.
- Output validation and preview before an explicit, separate Photos save.
- Cancellation, failure reporting, bounded-memory file processing and app-owned temporary cleanup.

**Nothing here lowers an iCloud bill.** The displayed byte difference is the measured saving between two files. Adding a second item initially consumes more storage, and deleting an original only moves it to Recently Deleted for 30 days before the space comes back. Opt-in deletion exists from build 7; it is off until the user turns it on, and in the tree at `559f693` it additionally needs a stored receipt naming the copy this run created plus a fresh look at both assets immediately before Photos is asked. The one-video flow never deletes.

## Defaults and deliberate limits

| Decision | Reason |
| --- | --- |
| iPhone, iOS 18+; Xcode 26+ for the first build | Modern asynchronous export/progress API; current App Store upload baseline. Use a newer stable Xcode if the phone’s OS requires it. |
| Swift 5 language mode with targeted concurrency checking | Small prototype using imported callback-based Apple frameworks; main-actor UI and a separate verification actor. Strict Swift 6 migration is future work, not claimed complete. |
| 1080p HEVC by default, with 720p H.264 and 4K HEVC optional, MOV container | Apple-provided preset policy avoids a custom sample writer. Apple ships no HEVC preset below 1080p, so 720p uses the documented H.264 preset. A video composition is used only to hold a small source at its own size or to lower the frame rate. Bitrate and exact output dimensions remain AVFoundation decisions, and some inputs will not shrink. |
| Save disabled when output is equal or larger | Avoid creating an ineffective extra copy. Negative savings remain visible. |
| Ordinary, unedited, file-backed video only | Rejects adjustment resources, edited full-size resources, PhotoKit slow-motion/time-lapse/spatial subtypes, compositions, multiple video tracks and more than one audio track. This avoids silently discarding special behavior. |
| Genuine PhotoKit access required | No picker file-provider fallback that would obscure whether Photos/iCloud integration worked. With limited access, the selected asset must already be permitted. A missing/inaccessible identifier gives instructions for Settings. |
| Original representation after rejecting detected edits | File-size comparison uses measured bytes of the retrieved original AVURLAsset. This is not all associated Photos resources, caches, or iCloud allocation. Special-format detection is conservative, not exhaustive. |
| Foreground only | Going to the background cancels download/export/verification. No background entitlement. The display can be held awake by the opt-in "keep screen awake while working" setting, which is released the moment work stops or the app leaves the foreground. |
| Metadata copied to the new item | The copy keeps the original's creation date, filename, location and favourite/hidden flags at Photos level, and the transcoder writes the original's own descriptive metadata into the file. Album membership, captions, keywords, ratings and editing history are not copied. What a given container retains still needs inspection on a device. |

There is still no overnight or background feature, subscription, user account, product analytics, advertisement, backend or app-managed media upload. Deletion exists from build 7 but is opt-in and gated. The standalone harness uses Apple frameworks. The Expo development wrapper adds Expo/React Native and their development tooling, including a local network connection to Metro. Photos can download from and sync the new item to **Apple’s existing iCloud Photos service** according to the user’s settings. “On-device” describes transcoding; it does not mean Photos operates without a network.

## Project structure

```text
project.yml                          Minimal XcodeGen project and shared test scheme
App.tsx / index.ts                    Expo entry point: renders the native prototype
app.json / eas.json                   Expo configuration and EAS development profiles
package.json / package-lock.json      npm dependencies
modules/videoshrink-native/           Local Expo native view and generated Swift copies
VideoShrink/
  VideoShrinkApp.swift                Composition root: injects real services
  Models/                            Stages, metadata, errors, savings, verification rules
  Services/                          PhotoKit, AVFoundation, verifier actor, temp files
  Presentation/                      View model, SwiftUI form, system picker, preview
  Resources/                         Info.plist, privacy manifest, placeholder app icon
VideoShrinkTests/                    Calculation/rule tests and mocked pipeline tests
scripts/                            Portable guardrails, icon generator, Mac build script
docs/                               Setup, tests, background spike, future scope, validation
```

XcodeGen is a free development-time project generator for the standalone harness, not an app dependency. Its readable specification avoids a hand-maintained `.pbxproj`. Install it on the cloud Mac for that harness; generated projects are ignored by Git. Configuration requires XcodeGen 2.44 or later; record the installed version with each tested build. The Expo route uses Expo's native project generation and the dependencies in `package-lock.json` instead.

## Pipeline and safety rules

`Waiting for permission → Choose → Retrieve → Prepare → Transcode → Verify → Ready to save → Save → Saved`

Recoverable paths terminate as Failed or Cancelled and allow a fresh selection. Preparing/verification/save use indeterminate indicators; cloud and export percentages come only from their APIs. These are per-operation percentages, never invented overall progress. Source measurements appear after retrieval, since public PhotoKit APIs do not supply a reliable original byte-size property before retrieval. No undocumented KVC size lookup is used.

Verification checks a real, nonempty regular file, a playable single video track, finite positive duration, the expected codec, audio track count and display aspect ratio. Duration tolerance is the greater of 0.25 seconds or 0.1% of source duration. Aspect tolerance is 2% for encoded dimension rounding. In the tree at `559f693` it requires a frame from every applicable sample window (near the start, the middle and the end), decodes audio samples instead of trusting the track's duration, and compares the copy Photos handed back against the properties this run measured before saving. **This is not full-file decode, listening, HDR fidelity assessment or a guarantee every later frame is intact.** Those are physical-device tests.

1. Photos writes are three: creating a new asset, reading a created asset back, and - only when the user has turned deleting on, the copy has been saved, verified and read back, a receipt naming that copy is stored, and a fresh look at both assets still matches - deleting one original through `PHAssetChangeRequest.deleteAssets`. No code path deletes without that gate, and the one-video flow never deletes. A queue written before the receipt existed carries none, and its originals are never deleted.
2. Cleanup accepts no media URL. There are two app-owned directories inside this app’s temporary directory, one per flow - `VideoShrink-Phase0` for the one-video flow and `VideoShrink-Phase0-batch` for the batch - and a manager removes only the one it was built for. They are separate because a finished, unsaved one-video copy has to survive a batch run, and the batch sweeps its directory at the start and end of every run. PhotoKit source URLs are never moved, overwritten or removed.
3. Cancelling stops the request/export and waits for the writer to unwind before cleanup. Operation tokens ignore late PhotoKit callbacks. Permission prompts cannot be dismissed programmatically.
4. A Photos save transaction cannot be cancelled once submitted. Save disables cancellation and repeated taps, keeps the file until the callback, then cleans it. Failure asks the user to inspect Photos before retrying. Process termination during save can leave an unacknowledged successful copy; durable reconciliation is next-phase work.
5. No complete video is loaded as `Data`. AVFoundation reads the file; verification decodes one frame at a time. There is no app-owned copy of the original.
6. Free-space checks are heuristics: a 256 MiB retrieval floor, then twice the source bytes plus 256 MiB before export, then output bytes plus 256 MiB before Photos save. They are not reservations or worst-case bounds. PhotoKit may need more download space and retains control of its cache. Disk-full errors are also mapped from actual operations.
7. App-owned temporary files are excluded from backup and cleaned on startup after interruptions. Cleanup failure is visible. The prototype cannot force Photos to evict downloaded originals.
8. Logs contain only fixed pipeline stage names and generic failure categories. No original filenames, paths, identifiers, coordinates, media contents or raw NSError descriptions are logged. Disk-space API use is declared in the privacy manifest.

## Open and validate

On Windows, install the Expo application dependencies with `npm ci`, then validate:

```powershell
npm run validate:native
npm run typecheck
node scripts/sync-native-sources.mjs --check
```

These checks cover repository guardrails, the Swift call-site scan, TypeScript and generated native source copies, **not Swift syntax or execution**. Swift is compiled and the XCTest suite executed elsewhere: `.github/workflows/ios-tests.yml` performs that verification, and the three local checks above are now repeated by its first job so that a push cannot skip them. That route is blocked until 1 October 2026 - the account's Actions minutes for the month are spent, see the note above the three kinds of claim - and EAS, needed only for builds that install on a real device, is out of iOS build minutes for the same period. The JavaScript development tooling uses Node on the PC; video processing stays native on the phone.

The owner does not own a Mac, so the Mac path below is kept only for a session on a rented
machine, per [CLOUD_MAC_SETUP.md](docs/CLOUD_MAC_SETUP.md):

```bash
brew install xcodegen
xcodebuild -version
xcodegen generate
open VideoShrink.xcodeproj
bash scripts/validate-mac.sh
xcrun simctl list devices available
SIMULATOR_UDID="PASTE_AN_AVAILABLE_IPHONE_SIMULATOR_UDID" bash scripts/validate-mac.sh
```

No build artifacts, certificates, provisioning profiles or credentials belong in Git. Git history now runs to `5d72357` on branch `main`, pushed to a private GitHub repository, and that is the state the CI job verifies and the state the status block above calls the verified commit. See [.gitignore](.gitignore).

## Unverified assumptions and release gate

- The first actual Xcode build has happened, and CI has repeated it on every push since: the generated project, the app target, the resource bundle and the test target all compile. What is still unproven is everything that only exists once the app runs - the app launching, its screens rendering, and framework calls behaving as the source reads. Static Windows checks cannot establish any of that.
- The preset must produce a smaller file on at least one representative large video; HEVC inputs and low-bitrate inputs may grow. No predicted ratio is promised.
- PhotoKit file-backed original access, iCloud progress/errors, limited permissions, callback cancellation races and representation lifetime require a real library.
- HEVC capability, source rotation/mirroring, audio presence/sync/channels, HDR/HLG/PQ/Dolby Vision appearance, frame rate and slow/special-format filtering require physical-device inspection. The prototype does not promise HDR or cinematic metadata preservation.
- Playback after Photos import, creation-date retention, absence/presence of other metadata and iCloud sync outcome are unverified. “Saved” means the local PhotoKit change succeeded, not that iCloud upload finished.
- Low storage, thermal pressure, interruptions, lock/background transitions, process termination and cleanup latency are unverified. An OS-terminated process cannot run cleanup immediately.
- The disk-space privacy reason, app icon, archive/export compliance answers and App Store Connect validation need checking in the submitted archive. No App Review approval is implied.
- This iPhone-targeted prototype has no separately validated iPad interface. No claim is made about unreleased or untested device models.
- The round 1 to 5 reliability work (persistence-gated Photos mutations, deletion receipts and revalidation, decoded audio and all-window verification, library reconciliation and copy exclusion) compiles, and the XCTest cases in `VideoShrinkTests/` ran and passed in CI (run `35852961091` at commit `5d72357`, when there were 162 of them). That says the logic holds against its injected fakes, not that the app works: no video has been exported, no original has been deleted and no queue file has been written on a device. A screen has been rendered - once, on a simulator, by the launch job - and that is the whole of what has been observed. A change as strict as revalidated deletion needs device validation before it is trusted.

**Acceptance:** a TestFlight build on the iPhone 15 Pro Max selects an allowed video whose original must download from iCloud, exports a smaller HEVC file, passes verification and saves a separate playable Photos item with measured potential savings. The original must remain unchanged. Record build, OS, source characteristics and evidence in the [device test plan](docs/PHYSICAL_DEVICE_TEST_PLAN.md).

Only then consider [NEXT_PHASE.md](docs/NEXT_PHASE.md). The [overnight spike](docs/OVERNIGHT_PROCESSING_SPIKE.md) is research and a proposed experiment, not an implemented feature.

## Primary references

- [Apple export presets](https://developer.apple.com/documentation/avfoundation/export-presets) and [asynchronous export](https://developer.apple.com/documentation/avfoundation/avassetexportsession/export(to:as:isolation:)).
- [PhotoKit video retrieval](https://developer.apple.com/documentation/photos/phimagemanager/requestavasset(forvideo:options:resulthandler:)) and [limited library access](https://developer.apple.com/videos/play/wwdc2020/10641/).
- [Apple required-reason API declarations](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype).
- [XcodeGen project specification](https://yonaskolb.github.io/XcodeGen/Docs/ProjectSpec.html).
