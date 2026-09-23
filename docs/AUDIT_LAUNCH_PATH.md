# Audit of record - from the icon to the first scan, and the shell that gets there

Read-only audit performed on 2026-09-23, after round 25, against the tree at `3cdefaa` (one file was
modified in the working tree while this was written - `docs/PHYSICAL_DEVICE_TEST_PLAN.md`, by another
writer). Its subject is the shipping path's first minute: the Expo/TypeScript entry, the React Native
module that hosts the Swift, the flow that decides which screen is live, and the restore a launch
performs after an interrupted run. Every earlier audit traced the Swift screens or the Swift pipeline;
round 17 audited whether the bridge compiles and what it passes, not what a person sees while it does.

**Nothing was run.** No gate was executed, by instruction: another writer is mid-edit, and a
half-written file would mislead. There is no simulator, no device and no Swift compiler on this
machine, and the CI job that compiles the Swift and the shipping Expo app has been blocked since
2026-09-23. **Every judgement below is a source read**, and the places where that is not enough are
named rather than guessed.

Two facts about the evidence bound everything here:

- **The shell files have not changed since they last compiled green.** Round 18 put a job on the
  shipping Expo app and it passed on `31b6245`. `git diff 31b6245..HEAD` over `App.tsx`, `app.json`,
  `eas.json`, `index.ts`, `package.json`, `project.yml` and the two bridge Swift files names only
  `package.json`, for one new npm script. So the shell itself is the code that job compiled. The
  pod's *mirror* of the app (`VideoShrinkCore/`) is generated from `VideoShrink/`, which has moved on
  by 18 files and 1,642 insertions since that commit, and nothing has compiled that.
- **The only rendered screen this project has ever observed is the standalone harness.**
  `scripts/verify-app-launch.mjs` builds `project.yml`, not the Expo app, and
  `VideoShrinkUITests/LaunchSmokeUITests.swift` says so about itself: "The harness around them is not
  the shipping app, so this is evidence about the screens rather than about the two Expo bridge
  files." The transition from the React Native root into the SwiftUI root has therefore never been
  observed - it is unobserved, not merely unverified.

**This is a finding list, not a list of fixes.** `AGENT_LOOP.md`'s backlog is the only place that
records status. Line numbers move every round; the quoted strings are the durable part.

## Findings

### LP1 - [P1] The shell draws no words of its own, so a slow start is a wordless near-black screen
`App.tsx`; `modules/videoshrink-native/ios/VideoShrinkNativeView.swift`; `app.json`

The whole of the shell's success path is one line:

```tsx
return <NativePipelineView style={styles.pipeline} />;
```

with `pipeline: { flex: 1 }`. There is no placeholder, no activity indicator, no app name and no
label of any kind: the shell's only text in the entire file is the *failure* notice below. The native
view behind it is an `ExpoView` whose only content is a SwiftUI host controller, attached lazily -
`guard window != nil, host == nil, let parent = containingController else { return }` - with one
`DispatchQueue.main.async` retry, and whose own background is a flat colour,
`UIColor(red: 0.025, green: 0.035, blue: 0.065, alpha: 1)`.

So there are exactly two things the app can put on screen before `ContentView` has laid out: Expo's
splash, and a flat near-black rectangle. Which one the user actually sees is a timing question -
`SplashScreenManager` hides the splash on `RCTContentDidAppearNotification`, and whether the host has
attached and laid out by that moment is not readable from source. What *is* readable is that nothing
in the app's own code covers the gap, and that the first words a user can meet are on a screen the
shell does not draw.

**Confidence: high** that no launch-time word or indicator exists in the shell or the native view;
**the visible gap needs a device or a render** (see below).

### LP2 - [P1] A launch that restores a run does the restore work on the main actor, before the first frame
`modules/videoshrink-native/ios/VideoShrinkNativeView.swift`; `VideoShrink/Presentation/BatchViewModel.swift`

The session's models are `static let`s, so they are built on first touch - and the first touch is
inside the view's attach:

```swift
let controller = UIHostingController(rootView: ContentView(model: VideoShrinkNativeSession.model,
                                                          batch: VideoShrinkNativeSession.batch))
```

`BatchViewModel`'s initialiser then runs, synchronously and on the main actor, `cleanWorkspace()`,
`adoptUnconfirmedSaves()`, `restoreQueue()` and `monitor.start()`. For a restored run, `restoreQueue()`
also calls `refreshDeletionLook()` - which calls `revalidateForDeletion` once per item, each of those
up to two `PHAsset.fetchAssets` plus resource reads - and then `resolveMidSaveItems()`. None of this is
off the main thread, and none of it is deferred past the first layout pass.

This is the one launch where a user has something to lose, and it is the launch that costs the most
before anything is drawn. The restored-run audit
([docs/AUDIT_RESTORED_RUN.md](AUDIT_RESTORED_RUN.md)) already lists the duration as a measurement;
what this audit adds is *where* it sits in the shipping path - inside the view attach, in front of the
first frame, with LP1's wordless rectangle as its only cover if the splash has already gone.

**Confidence: high** that the work is on the launch path in this order; **the cost is a measurement**.

### LP3 - [P2] The notice for a run that could not be read is the last item of roughly 850pt of scroll
`VideoShrink/Presentation/BatchScreens.swift`; `VideoShrink/Presentation/BatchViewModel.swift`

Round 23 added the only screen that can tell a user a saved run was set aside. It is drawn at the
**bottom** of the start screen's scroll view:

```swift
QueueWarningNotice(warning: batch.queueWarning)
// A record this launch could not read is not a write that failed, so it is not drawn
// under that notice's heading. This is the only screen that can show it: nothing was
// restored from that record, so no run's screen ever comes up.
if let warning = batch.queueReadWarning {
    ShrinkNotice(symbol: "exclamationmark.triangle",
                 title: "A saved run couldn't be read", detail: warning)
}
```

with `queueReadWarning` reading: "Nothing could be restored from it, and nothing in Photos was
changed. The record stays where it is, so this notice comes back until a run writes one of its own. If
you had a run going, look in Photos before running the same videos again."

Above it, in this order, are: a 20pt top pad, the eyebrow, the headline "Less weight.\nMore memories.",
the body line, `ShrinkIllustration` - which is `ShrinkHeroArtwork()` at a fixed `.frame(height: 300)` -
the "Start with your video library" card (padding 22), `DeletionRow` (padding 18), and the deletion
footnote, all separated by 24pt gaps. That is about 850pt before the notice begins. The scroll area
below a navigation bar and the pinned action bar is roughly 750-780pt on a 6.9in iPhone and about
550pt on an SE-sized one. **Nothing above the notice says anything is below it** - no badge, no count,
no changed headline.

The paragraph in the code is right that this is the only screen that can show it (the warning is set
only on the branch where the record was *not* restored, so no run's screen ever exists). It does not
follow that the screen shows it.

**Confidence: high** on the ordering and on the 300pt hero plus fixed gaps; **medium-high** that it
lands off-screen on every current iPhone, and **a render settles the exact offset**.

### LP4 - [P2] The icon and the splash are a generated placeholder, and three documents disagree about it
`app.json`; `VideoShrink/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png`; `scripts/generate-icon.mjs`

The shipping configuration uses one asset twice:

```json
        "expo-splash-screen",
        {
          "backgroundColor": "#060911",
          "image": "./VideoShrink/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png",
          "imageWidth": 160,
          "resizeMode": "contain"
        }
```

and `icon` points at the same file. That file is a hard-edged opaque square - a white downward
download arrow into a tray on `#273D89` blue - and the script that writes it says what it is, in its
own first line: "Deterministic placeholder app icon; Node built-ins only", ending "Created opaque
1024x1024 placeholder AppIcon.png". It is drawn on the launch screen at 160pt on the app's own
near-black `#060911`, unrounded, because splash images are not masked the way Home Screen icons are.

The app's own mark is a different thing: `ShrinkBrand` draws
`Image(systemName: "arrow.down.right.and.arrow.up.left")` - an *inward* arrow - on the mint accent,
beside the word "BatchShrink". Three documents then disagree about the icon:

- `README.md` is honest: "Info.plist, privacy manifest, placeholder app icon".
- `docs/DESIGN.md` overclaims: "Original layered video artwork and a compact inward-arrow brand mark
  give BatchShrink its own identity" - true of the artwork and the in-app mark, not of the shipped icon.
- `marketing/app-store-listing.md` treats it as finished: "Note also that the app icon does exist in
  the tree", while the review it cites still owes it - `docs/DEVELOPMENT_REVIEW.md`: "finish
  icon/store assets, privacy/support pages and truthful storage/quality copy".

The result is that the first pixel the product shows, on every cold launch and on the Home Screen,
carries neither the app's name nor its mark.

**Confidence: high** (asset read directly; the generator calls it a placeholder; the splash and icon
paths are in `app.json`). **How it composites needs a render** - dark mode, a 160pt square on
`#060911` - which was not performed here.

### LP5 - [P2] If the host controller is not found, nothing is ever drawn and nothing says why
`modules/videoshrink-native/ios/VideoShrinkNativeView.swift`

Every route into the SwiftUI host goes through one guard:

```swift
private func attachHostIfNeeded() {
    guard window != nil, host == nil, let parent = containingController else { return }
```

`containingController` walks the responder chain for a `UIViewController`. If there is none, the
function returns silently, and the only retries are `layoutSubviews` and one `DispatchQueue.main.async`
hop after `didMoveToWindow`. There is no timeout, no log, no fallback view and no message: the app
stays a flat near-black rectangle for the life of the process, and on the shipping path that is
indistinguishable from a slow start (LP1).

This is the answering half of "what does the app draw if the native module fails to register": for a
*missing module* the shell draws the notice in LP6; for a *registered module that cannot attach*, the
native view draws nothing at all and says nothing.

**Confidence: high** on the code; **low reachability** - in an ordinary Expo hierarchy the RN root
view controller is an ancestor, so this needs a runtime to become a defect (see below).

### LP6 - [P3] The shell's only other state is a message written for a developer
`App.tsx`

```tsx
<Text style={styles.title}>BatchShrink needs its iPhone development build</Text>
<Text style={styles.body}>
  The Photos and HEVC pipeline uses custom Swift code. Install the BatchShrink
  development build, then connect it to this development server. Expo Go,
  Android and web cannot run this prototype.
</Text>
```

This is the correct thing to draw in Expo Go, and the styling is the app's own (mint `#A8F5D1` on
`#060911`), so it does not look foreign. It is the wrong thing to draw *on a user's phone*: a person
who installed the app from TestFlight and met this would be told to install a development build and
connect to a development server. `requireOptionalNativeModule` returns null rather than throwing, so a
build in which the pod is not linked reaches this screen instead of crashing - which is a good default
with a user-facing sentence attached. Reaching it requires a build whose pod is missing, so it is a
correctness-of-copy finding rather than a live defect.

**Confidence: high** on the strings and the path; reachability requires a mis-built app.

## Checked and found sound - do not re-walk

- **No path shows the introduction twice, and none can skip it for a genuinely new user.** The gate is
  one line in `ContentView`: `if !hasOnboarded && batch.phase == .start && model.stage == .idle`, and
  `hasOnboarded` is `@AppStorage("batchShrink.onboarding.v1")`, written only by the introduction's own
  `complete` closure. The replay in the Help sheet is `ShrinkOnboarding { showIntroduction = false }`,
  which touches no stored key. A stored queue means a run happened, a run requires the introduction to
  have been dismissed, and both the flag and the record live in the same app container - so the one
  combination that would matter (an unreadable record meeting a user who has never onboarded) is
  unreachable, and the start screen is the only screen that draws that notice.
- **A restored run takes precedence over the introduction, as designed.** `restoreQueue()` sets
  `phase = hasPendingWork ? .paused : .finished` inside the initialiser, so `batch.phase == .start` is
  already false by the time `ContentView` first evaluates its gate. `docs/DESIGN.md` states the intent
  ("An existing active or recovered run takes precedence over onboarding") and the code keeps it.
- **No launch-time route to `PHPhotoLibrary`'s prompt.** The app's one call to
  `PHPhotoLibrary.requestAuthorization(for: .readWrite)` is inside `PhotoLibraryService.requestAccess()`
  (`if status == .notDetermined`), and its only three callers are the scan
  (`BatchViewModel.scan()`), the run's first read (`accessForRun()`, round 17's fix for a restored run
  on a device that was never asked) and the picker (`CompressionViewModel.chooseVideo()`). Every other
  PhotoKit touch at launch is a status *read* (`revalidateForDeletion` returns `.accessDenied` without
  asking) or is behind `access.canRead` (`LibraryChangeMonitor.observeChangesIfReadable`, round 19's
  fix for exactly this - its log evidence was the permission alert appearing before the test had
  touched anything). The TypeScript shell contains no Photos API at all.
- **The introduction's promise is kept.** The footnote on its last page - the page whose button is
  "Get started" - reads "Photos access is requested when you scan". The scan shows its own screen
  synchronously (`phase = .scanning` is set before the task starts, so the tap is never silent) and
  asks for access as its first step. The one-video flow asks when the user taps the picker.
- **Every phase draws a screen.** `BatchFlow` switches over all eight `BatchPhase` cases
  (`start, scanning, scanned, selecting, processing, paused, finished, failed`) with no `default`, so
  no phase falls through to nothing.
- **The shell-to-app seam is invisible when the host does attach.** `app.json`'s `backgroundColor`,
  the `ExpoView`'s `UIColor(red: 0.025, green: 0.035, blue: 0.065, alpha: 1)` and `ShrinkStyle.canvas`
  are the same colour, all `#060911`; `userInterfaceStyle: "dark"` is set for the shell and
  `.preferredColorScheme(.dark)` for the SwiftUI root. This is round 17's fix, and it holds.
- **The view name resolves.** The module is `Name("VideoShrinkNative")` with a single default view, so
  the native wrapper class is `ViewManagerAdapter_VideoShrinkNative` and
  `requireNativeView<ViewProps>('VideoShrinkNative')` asks for exactly that name (`expo-modules-core`'s
  `requireNativeViewManager(moduleName, viewName?)`). `ExpoView` is `ExpoFabricView` in SDK 57, so
  subclassing it is the right shape for a Fabric build. `requireOptionalNativeModule` catches and
  returns null, so a missing module cannot crash the JS bundle at import time.
- **Nothing at launch resets what a restored run needs.** `enteredBackground()` acts only on
  `.scanning` and `.processing`, so it is a no-op for `.start`, `.paused` and `.finished`;
  `presentationRemoved()` (module destroy, React reload) keeps `.readyToSave` and pauses only work in
  flight; `cleanWorkspace()` sweeps only the batch's own temporary directory, and the one-video
  workspace is a separate one; the history store is read at launch and never cleared. The queue's
  questions, pause reason and refusals are all restored before `phase` is decided.
- **`app.json`'s claims match the code.** The usage strings describe what actually happens -
  "Estimating savings does not download videos from iCloud" is kept by a scan that lists from library
  metadata, reads sizes from `PHAssetResource.dataSize` and probes formats with
  `options.isNetworkAccessAllowed = false`; the add-usage string matches where copies are saved. The
  version facts agree (`0.1.0` in `app.json`, `package.json`, `project.yml` and the podspec; build 11
  in `app.json` against the listing's build 11; `com.wilfr.videoshrink` and App Store ID `6813894354`
  in `eas.json` and the listing), and iPhone-only/iOS 18 is stated the same way everywhere
  (`supportsTablet: false`, `deploymentTarget: "18.0"`, `TARGETED_DEVICE_FAMILY: "1"`).
  `ITSAppUsesNonExemptEncryption: false` is consistent with a tree that contains no crypto code.
- **The privacy manifest declares the required-reason APIs the app uses.** Disk space
  (`volumeAvailableCapacityForImportantUsageKey`) is `E174.1` and `UserDefaults` is `CA92.1`, in both
  copies of `PrivacyInfo.xcprivacy` (the harness's and the pod's, which are byte-identical). The other
  file reads - `fileSizeKey`, `isRegularFileKey`, `setResourceValues` - are not required-reason APIs,
  and `photo.creationDate` is a PhotoKit property, not the file-timestamp API. Worth knowing rather
  than fixing: `scripts/validate.mjs` asserts only `E174.1`, so a future round could delete `CA92.1`
  without a gate noticing.
- **The two screens this audit is about pin their primary controls.** `ShrinkActionBar` is a
  `safeAreaInset(edge: .bottom)`, outside the scroll view, on both the introduction ("Continue" /
  "Get started") and the start screen ("Find my videos", "Just one video"). No first control is below
  the fold on either, and the scan screen's count line degrades to "Looking..." rather than "0 of 0"
  while it has nothing to count.
- **The screens the audits read are the screens the pod compiles.** Compared file by file, the mirror
  under `modules/videoshrink-native/ios/VideoShrinkCore/` is identical to `VideoShrink/` for
  `ContentView`, `ShrinkOnboarding`, `BatchScreens`, `BatchFlow`, `BatchViewModel`,
  `CompressionViewModel`, `FlowRouting`, `BatchQueueRecord` and both privacy manifests. (Compared by
  reading, not by running the gate - and the mirror is git-ignored, so this says nothing about what
  any particular build used.)
- **No StoreKit, account, analytics or backend exists**, so the listing's "Free, with no purchase,
  subscription or StoreKit code anywhere in the tree" holds.

## Only a device or a render could settle

- **Whether a wordless frame is ever visible at all, and for how long.** The splash hides on
  `RCTContentDidAppearNotification`; whether the SwiftUI host has attached and laid out by then decides
  whether the user sees LP1's rectangle or nothing but the splash. This needs a real build on a
  device or simulator with a signpost between "RN content appeared" and "first SwiftUI frame".
- **The cost of the restore on a real library.** `restoreQueue()` runs inside the initialiser, on the
  main actor, with one Photos revalidation per restored item; the visible delay is a measurement, not
  a reading.
- **Where the "A saved run couldn't be read" notice actually falls.** The 850pt estimate above is
  arithmetic on fixed heights (a 300pt hero, 24pt gaps, padding 22 and 18). A render of
  `BatchStartScreen` with `queueReadWarning` set, on a small iPhone and a large one, settles both the
  offset and whether anything above it hints that content follows.
- **Whether `containingController` is ever nil in the shipping hierarchy.** If it can be, LP5 is a
  permanent blank screen; the code has no way to answer this.
- **Whether the Expo shell draws at all.** Every rendered-screen observation in this project is the
  standalone harness. That the shell compiles (at `31b6245`) is not that it launches, attaches and
  draws. A single install-and-look on a simulator would close more of this audit than any further
  reading.
- **How the placeholder icon reads on the launch screen** - a 160pt opaque square, unrounded, on
  `#060911` - and whether the icon should be masked or replaced wholesale. Needs a render.
- **The introduction and the start screen in landscape.** `app.json` permits both landscape
  orientations and nothing in the source forbids them; every screen scrolls and both action bars are
  pinned, so nothing is unreachable, but whether the 300pt hero and the headline read well in a
  375pt-tall viewport is a render.
- **Whether the first launch on a fresh install is the introduction in the shipping app**, as it is
  in the harness. `ContentView`'s gate reads the same way in both, but only the harness has been run.

## The smallest set of changes that would close the gap

1. **Give the launch a name.** Replace the placeholder with a designed icon, and use an image that
   carries the wordmark (or the `ShrinkBrand` mark) as the splash image in `app.json`. One asset plus
   one config line closes LP4 and gives LP1's gap something true to show. It is also the change
   `docs/DEVELOPMENT_REVIEW.md` is already waiting for.
2. **Give `VideoShrinkNativeView` a floor.** Keep the ExpoView's own child hidden until `host != nil`,
   and if the host has not attached after the existing async retry, show a flat `#060911` view with
   the app's name and one line such as "Starting BatchShrink...". That converts LP1's and LP5's worst
   cases from "nothing, ever" into "the app, nearly ready", without touching the SwiftUI path.
3. **Hoist the unreadable-record notice above the artwork on the start screen** - or, better, into
   the pinned action bar's `ShrinkActionBar` block, where it cannot be below the fold. That is a
   one-block move in `BatchStartScreen` and it restores the only notification round 23 added.
4. **Measure the restore before changing it.** The launch path's cost is in `BatchViewModel`'s
   initialiser; if the measurement says it is visible, move `refreshDeletionLook()` and
   `resolveMidSaveItems()` behind the first frame (they decide a screen's wording, not whether the run
   is safe) rather than moving the queue read, which the run's own screen depends on. Do this after
   the device result, not before it.
5. **Rewrite the fallback sentence in `App.tsx` for a user**, e.g. "This copy of BatchShrink is
   missing its video engine. Reinstall BatchShrink from TestFlight." - one string, no logic.
