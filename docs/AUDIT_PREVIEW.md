# Audit of record - the two preview surfaces: the quick look, and the copy before it is saved

Read-only audit performed on 2026-09-23, after round 26, against the tree at `97369a0`. Its subject is
the only two places this app lets a user *look at a video*: the quick look from the selection grid
(`VideoScrubSheet.swift`), and the sheet that plays the compressed copy in the one-video flow (the
preview card in `SingleVideoFlow.swift` and `VideoPreview` in `ShrinkScreens.swift`) - together with
what feeds them (`PhotoLibraryServing.playerItem(identifier:)`, `PhotoLibraryService`'s implementation
of it and its `scrubRequestTimeout`, and the SwiftUI state that presents and dismisses each sheet).
Every other user-facing surface has been through an audit. These two had not: round 24's accessibility
recheck listed `VideoScrubSheet.swift` among the files it read and wrote no finding about it, and no
audit has read `VideoPreview` at all.

**Nothing was run, and no gate was executed**, by instruction: another writer is mid-edit in the tree.
At the time of reading, `git status` showed `AGENT_LOOP.md`, `VideoShrink/Presentation/BatchScreens.swift`,
`VideoShrinkTests/BatchTests.swift` and `modules/videoshrink-native/ios/VideoShrinkNativeView.swift`
modified. The in-flight `BatchScreens.swift` change is in the paused and finished screens, not in the
selection screen whose lines this audit quotes, so the scrub sheet's own citations are unaffected.
There is no simulator, no device, no Swift compiler and no AVFoundation runtime on this machine, and
the CI job that compiles the Swift has been blocked since 2026-09-23 - so **every judgement below is a
source read**, and what a render of a `VideoPlayer` actually draws is named as device-only rather than
guessed at.

Files read for this audit: `VideoScrubSheet.swift`, `SingleVideoFlow.swift`, `ShrinkScreens.swift`
(`VideoPreview`, `ShrinkResult`), `BatchScreens.swift` (the selection screen and its row),
`CompressionViewModel.swift`, `PhotoLibraryService.swift`, `PhotoLibraryScanService.swift`
(`boundedAnswer`, `describe`), `ServiceProtocols.swift`, `AssetRules.swift`, `LibraryModels.swift`,
`PipelineError.swift`, `VideoVerificationService.swift`, `TemporaryFileManager.swift`,
`AssetThumbnail.swift`, `ThumbnailService.swift`, `BatchFlow.swift`, `ContentView.swift`,
`ServiceCoverageTests.swift`, `BatchTests.swift`, `VideoShrinkUITests/LaunchSmokeUITests.swift`,
`docs/PHYSICAL_DEVICE_TEST_PLAN.md`, `docs/BATCH_PHASE.md`, `docs/QA_PASS.md`,
`docs/AUDIT_SINGLE_VIDEO.md`, `docs/AUDIT_ACCESSIBILITY_RECHECK.md`.

**This is a finding list, not a list of fixes.** `AGENT_LOOP.md`'s backlog is the only place that
records status. Line numbers move every round; the quoted strings are the durable part.

## Findings

**What has happened to each finding.** The sections below are the audit as performed, against
`97369a0`; this table is the map, because some of them were fixed in the round that read them.

| ID | Status |
|----|--------|
| PV1 | **Half fixed in round 27.** The sheet now waits for the item's own status, bounded at 10 seconds of its own, and answers a `.failed` item or a wait that gets nowhere with a sentence instead of a black rectangle. The device plan's row now states both clocks, because the look's worst case is the fetch's bound and then this one |
| PV2 | **Open.** The shape is the same as PV1's, in a second view: a player, its own bounded wait for the item, and a failure line. Its reachability is lower than PV1's - the file is local and was verified seconds earlier by the flow's own verifier - so the note here is deliberately specific: what a failure would mean is that the file is gone, which the save path refuses as well |
| PV3 | **Fixed in round 27**: each note is drawn only in the state it describes - "press play" only when there is a player, the iCloud note only when nothing has failed |
| PV4 | **Fixed in round 27.** The sheet has its own words for the two errors it can see (`assetUnavailable`, `retrieval`), says both of the things it cannot distinguish for the first, and mentions no copy; every other pipeline error gets a plain sentence rather than a claim about a run. Pinned by a case |
| PV5 | **Half fixed in round 27**: the failure branch is one accessibility element with a label, and the sentence is announced as one thing. What is still open is the half this finding leads with - nothing posts an announcement when the look *finishes* (or fails at the fetch), so a VoiceOver user hears "Opening…" and then has to go looking |
| PV6 | **Open, latent, and a decision rather than a patch.** PhotoKit's `.current` version is what both previews play, while the run exports `.original`; `AssetRules` refuses edited videos by name, which is what keeps the two in step today. The fix is not one line - the preview must be given the same version the run will export - and doing it wrong would show the user a different video from the one they get |
| PV7 | **Open**: neither preview reacts to the app leaving the foreground, and neither configures an audio session, so "check the sound" asks the user to hear something the Ring/Silent switch can silence. The decision is whether to claim an audio session for a preview, which is a change in what the app does to the phone |
| PV8 | **Open**: "Size on screen" comes from PhotoKit's `pixelWidth`/`pixelHeight` while every other picture size in the app comes from the media with the rotation applied |
| PV9 | **Fixed for the scrub sheet in round 27**: the load's answer is checked against cancellation before a player is built, because `onDisappear` has already run and will not run again to pause a player created after it. The one-video preview has the same await and is part of PV2's work |
| PV10 | **Fixed in round 27**: the failure's words moved out of the fixed 16:9 box and under it, where they wrap instead of clipping |
| PV11 | **Fixed in round 27**: the size row no longer says "Original file", because the grid can be showing a copy this app made |

### PV1 - [P2] The 20-second bound covers the request, not the player: an item that arrives and never becomes ready is a black area with no sentence
`VideoShrink/Presentation/VideoScrubSheet.swift` (`start()`, `playerArea`);
`VideoShrink/Services/PhotoLibraryService.swift:353-385` (`playerItem`, `resolvePlayerItem`)

`scrubRequestTimeout` is `static let scrubRequestTimeout: Duration = .seconds(20)`, and the doc on
`playerItem` says what it buys: "a request that never calls back, or one that calls back after the
bound, cannot leave the sheet on its spinner or resume the same continuation twice". That is exactly
true, and the device plan's `Quick look that never answers` row rests on it. What the bound does not
touch is what happens *after* Photos answers. `start()` is:

```swift
let item = try await load()
player = AVPlayer(playerItem: item)
loading = false
```

`loading = false` is set on the strength of an `AVPlayerItem` existing, and `playerArea` then draws
`VideoPlayer(player: player)` for that branch and nothing else. Nothing in the app ever reads
`AVPlayerItem.status` - a search for `status ==`, `.status`, `timeControlStatus` and
`automaticallyLoadedAssetKeys` across `VideoShrink/` finds no reader in either the presentation or the
service layer. So an item PhotoKit hands back for media the player cannot actually load (an unplayable
resource, a stream that never fills, a fetch that fails once the item is already in hand) leaves the
sheet showing a black 16:9 area under the title "Check this video", with the system chrome and no
sentence at all, indefinitely. Every other wait in this app is bounded and every other failure has a
sentence; this one has neither.

The plan's own wording is the honest measure of the gap: "A wait that is given up reaches the sheet's
own failure line instead of leaving a spinner that no control can end" is a claim about the *wait*, and
the row never asks what the sheet does when the wait succeeds and the player still will not play. What
AVKit itself draws over a failed item (a black surface, or some message of its own) is not decidable
from source - see "Only a device could settle".

**Confidence: high that the code has no such branch and no status reader; medium that an ordinary
library reaches it**, since it needs PhotoKit to answer with an item it cannot play.

### PV2 - [P2] The one-video preview sheet has no loading and no failure state at all
`VideoShrink/Presentation/ShrinkScreens.swift:309-328` (`VideoPreview`); `SingleVideoFlow.swift:87-92`

```swift
struct VideoPreview: View {
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer
    init(url: URL) { _player = State(initialValue: AVPlayer(url: url)) }
```

The body is a `NavigationStack` whose whole content is `VideoPlayer(player: player)` with the title
"Your compressed copy" and the footer "Check picture, orientation and sound before you decide." - one
branch, unconditionally, whatever the player does with the URL. The scrub sheet at least has a spinner
and a failure sentence ("This video couldn't be opened."); this sheet has neither, and no state to hold
them in.

It is a lower-frequency risk than PV1 because the file was measured before the card that opens it is
drawn - `CompressionViewModel.selected` runs `verifier.verify(written, source: original, expecting:
activeSettings.codec)` before it sets `previewURL = written` - and the same file is verified again
inside `save()`. What is not protected is the file's continued existence: the copy lives in
`temporaryDirectory/VideoShrink-Phase0`, which is exactly where iOS purges from, and nothing between the
card being drawn and the sheet being opened re-reads it. A user who opens the preview, backgrounds the
app (nothing in either preview reacts to `scenePhase` - see PV7), and comes back to a purged workspace
meets a black surface under a title that promises a copy and a footer that asks them to check it. There
is no sentence for that state, so there is nothing to read either.

**Confidence: high in the code fact (no branch, no state); medium that the state is reached** - it needs
the temp file to go, or the player to refuse a file verification already approved.

### PV3 - [P2] Both footnotes are drawn in the states that contradict them
`VideoShrink/Presentation/VideoScrubSheet.swift:19-30`

```swift
playerArea
facts
Text("If this video lives in iCloud, Photos fetches what it needs to play, so the first few seconds can take a moment.")
Text("Press play, or drag the bar, to check you've got the right video.")
```

Both sentences are siblings of `playerArea`, outside every branch of it, so they are on screen in all
three of its states. The second one is the problem: while the sheet is still loading there is no player
and no bar on screen, and in the failure branch there is deliberately no player at all - that branch is
`Image(systemName: "video.slash")` and `Text(problem ?? "This video couldn't be opened.")`. So the sheet
can read "Press play, or drag the bar, to check you've got the right video." with neither a play control
nor a bar anywhere in it, and a VoiceOver user is told to operate two controls that are not there. The
iCloud sentence is sound in all three states, including the failure one, and is left out of this
finding.

This is the class round 19 fixed on the batch side and `SV3` fixed for the preview card ("before saving"
-> "before you decide"): a sentence that is right for the usual state and false for a reachable one.
Here it belongs inside the `player` branch, or should be worded for the sheet rather than for the
player.

**Confidence: high** - it is a plain reading of what is a sibling of what.

### PV4 - [P2] The sheet's one failure line is whichever sentence the pipeline wrote for another moment
`VideoShrink/Presentation/VideoScrubSheet.swift:92-95`;
`VideoShrink/Services/PhotoLibraryService.swift:379-385`; `VideoShrink/Models/PipelineError.swift`

```swift
} catch {
    loading = false
    problem = error.localizedDescription
}
```

The sheet prints whatever `localizedDescription` it is handed, and the sentences it can be handed were
written for a run, not for a look:

- `.retrieval` - "Photos could not retrieve this video. If its original is in iCloud, check your
  connection and local storage, then try again." True of this moment, and the common case.
- `.assetUnavailable` - "This video is outside the Photos access granted to BatchShrink. Add it to your
  allowed videos in Settings, then try again." This is what `playerItem` throws when
  `PHAsset.fetchAssets(withLocalIdentifiers:)` finds nothing, which is also what a video that has simply
  *left the library* produces (deleted in Photos, or on another device). A user whose video was deleted
  is told to change Photos access, and sent to a Settings screen where nothing is wrong.
- `.insufficientStorage` - "There wasn't enough free space to make a copy. Nothing was saved and your
  original is unchanged. Getting a video from iCloud and saving a copy both need room, so free some
  space and try again." `resolvePlayerItem` pushes a Photos error through `PipelineError.normalize`,
  which maps a disk-full error anywhere in the chain to this case - and this sheet is not making a copy
  and was never going to. `docs/AUDIT_DEVICE_PLAN.md` records that mapping as a fact; whether PhotoKit
  ever reports a disk-full error to a *player-item* request is not something this machine can show, so
  this third one is the weakest of the three.

**Confidence: high that the sheet prints the case's sentence unchanged, and high that the
`.assetUnavailable` wording is wrong for a vanished asset; medium that `.insufficientStorage` is
reachable here at all.**

### PV5 - [P2] Nothing tells VoiceOver that the look finished, failed, or arrived
`VideoShrink/Presentation/VideoScrubSheet.swift` (whole file); `ShrinkScreens.swift:309-328`

The sheet's whole accessible account of opening is "Opening..." in the loading branch, and then a state
change that is never announced. A search for `AccessibilityNotification` and `UIAccessibility` over the
app finds exactly one call in the tree - `VideoShrinkNativeView.swift:195`, the launch placeholder - so
neither preview posts an announcement when the spinner becomes a player or becomes a failure sentence.
A VoiceOver user who opens the quick look hears the title, the facts card and "Opening...", and then
nothing says the answer arrived; the failure branch is also two separate elements (`Image` then `Text`)
rather than one sentence. This is the same shape round 26 fixed for the one string in the app that
nothing announced.

The player surface itself is labelled deliberately - `.accessibilityElement(children: .contain)` and
`.accessibilityLabel("Video player")`, which is the right call because it keeps AVKit's own transport
controls in the accessibility tree - and it is worth saying plainly that round 24's accessibility
recheck listed this file as read without raising any of this.

**Confidence: high in the code fact (no announcement is posted); the operability of the system scrubber
under VoiceOver is device-only.**

### PV6 - [P2] The previews show the *current* version; the run exports the *original* one
`VideoShrink/Services/PhotoLibraryService.swift:353-359` vs `:32-58`; `ThumbnailService.swift:53-56`;
`BatchScreens.swift:765-766`

```swift
// playerItem(identifier:) - what the grid's preview and the scrub sheet both use
options.version = .current
options.deliveryMode = .automatic
options.isNetworkAccessAllowed = true
```

```swift
// retrieve(identifier:) - what a run exports
options.version = .original
options.deliveryMode = .highQualityFormat
options.isNetworkAccessAllowed = true
```

The grid's thumbnails ask for `.current` too, so both preview surfaces agree with each other and both
disagree with the run. The user-facing claim that turns on this is the tile's own hint, "Opens the
original video player.", and the sheet's facts - "Recorded", "Length", "Size on screen", "Original
file" - which all come from the scan's description of the original. For a video with no adjustment data,
`.current` and `.original` are the same file and every claim holds, and **a video that has been edited in
Photos is refused before it can reach the grid**: `PhotoLibraryScanService.describe` sets
`hasAdjustmentData: resources.contains { $0.type == .adjustmentData }`, and `AssetRules.unsupportedReason`
answers "Edited videos aren't supported yet." So today the divergence is latent rather than live.

It is still worth recording, for two reasons. It is the same class as the batch dialog round 19 fixed:
if the edited-video refusal is ever relaxed, or if `.current` answers with anything other than the
original for a video whose original is not local, the sheet's facts and the run's export describe
different files and nothing in the app says which one the user just looked at. And `.automatic` is not
`.highQualityFormat`, so whether the picture in the quick look is the same rendition the run exports is
not decidable from source at all.

**Confidence: high in the code fact; high that it is latent today (the edited refusal is what holds it);
low-medium that any current library reaches it.**

### PV7 - [P3] Neither preview reacts to the app leaving the foreground, and no audio session is configured for either
`VideoScrubSheet.swift:37-40`; `ShrinkScreens.swift:325`; `SingleVideoFlow.swift:114-116`;
`CompressionViewModel.enteredBackground()`; `BatchViewModel.enteredBackground()`

Both sheets pause and clear their item in `onDisappear`:

```swift
// VideoScrubSheet
.onDisappear { player?.pause(); player?.replaceCurrentItem(with: nil) }
// VideoPreview
.onDisappear { player.pause(); player.replaceCurrentItem(with: nil) }
```

and neither sheet reacts to `scenePhase`. The two `scenePhase` handlers in the app are the flows', not
the previews': `SingleVideoFlow`'s calls `model.enteredBackground()`, which only touches
`[.retrieving, .preparing, .transcoding, .verifying]` - never `.readyToSave`, the state the preview sheet
is opened from - and `BatchFlow`'s calls `batch.enteredBackground()`, which acts on `.scanning` and
`.processing` only. So backgrounding with a preview open is deliberately untouched by the app; what iOS
does to a playing `AVPlayer` with no background-audio mode is a device question.

The audio half is a code fact with a reachable consequence. A search for `AVAudioSession` over
`VideoShrink/`, `modules/videoshrink-native/ios/` and the test targets finds nothing, so a preview plays
under the system default category, `.soloAmbient`, which is silenced by the Ring/Silent switch. Both
sheets ask the user to judge sound - the one-video card says "Check picture, orientation and sound." and
the preview sheet repeats "Check picture, orientation and sound before you decide." - and on a silenced
iPhone that check cannot be performed: the user taps play, hears nothing, and has no way to tell that
from a copy whose audio was lost. This is the kind of thing the app spent rounds learning not to do:
asking for a judgement the app itself has made impossible.

**Confidence: high in both code facts; medium that the silent-switch behaviour follows in practice** - it
depends on the implicit category and on when AVKit activates the session, and a device settles it.

### PV8 - [P3] "Size on screen" is read from PhotoKit's pixel size, while every other picture size in the app is read from the media with the rotation applied
`VideoShrink/Presentation/VideoScrubSheet.swift:77-79`; `PhotoLibraryScanService.swift:245-251`;
`VideoVerificationService.swift:41-44`

The sheet's third fact is

```swift
if asset.longEdge > 0 {
    LabeledContent("Size on screen", value: "\(asset.pixelWidth) x \(asset.pixelHeight)")
}
```

and `asset` is a `LibraryAsset`, which the listing fills from `PHAsset` alone - `describe` passes
`asset.pixelWidth, asset.pixelHeight` straight through. Everywhere else the app names a picture size it
reads the track's `naturalSize` and `preferredTransform` and takes the transformed rect:
`VideoVerificationService.readMetadata` does
`let rect = CGRect(origin: .zero, size: naturalSize).applying(transform)` and reports
`Int(abs(rect.width).rounded())`, so the run's own "Original resolution" and "Copy resolution" in
`VideoDetails` are the transformed figures. For a video whose track carries a rotation (the ordinary
portrait clip) the two readings are not the same measurement: at least one of them is not the size on
screen, and the quick look and the run can name the same video differently. The label is hedged ("Size
on screen" rather than "Resolution"), which reads like an intent to show the displayed size - but the
value underneath comes from the one reading that never applies the transform.

**Confidence: high in the code fact (two different readings); medium that they actually differ**, because
whether `PHAsset.pixelWidth` reports the pre- or post-rotation size for a video is exactly what a device
settles.

### PV9 - [P3] Dismissing the sheet during the load can still build a player that nothing will ever clear
`VideoShrink/Presentation/VideoScrubSheet.swift:36, 86-96`; `PhotoLibraryScanService.boundedAnswer`

The dismissal path is mostly sound, and worth stating as such: `.task` teardown cancels the load, the
cancellation handler calls `read.giveUp()`, the bounded read answers nil, and `resolvePlayerItem(nil)`
throws `.retrieval` - so a sheet dismissed *during the wait* ends in the failure branch and never builds
a player. The gap is the window after the handler has already claimed the continuation. `start()` runs

```swift
let item = try await load()
player = AVPlayer(playerItem: item)
loading = false
```

with no `Task.isCancelled` check between the two statements, while `CompressionViewModel.selected` - the
one place in the app that has learned this lesson - checks `try Task.checkCancellation()` after every
single await. If the sheet is torn down in that window, `onDisappear` has already run its
`pause()`/`replaceCurrentItem(with: nil)`, and the `AVPlayer` is then created on a view that is gone,
holding an item nobody will ever clear. It is not audible - nothing in the app ever calls `play()`, so a
leaked player is silent - but for a streamed item it is a retained player with a live item behind a
sheet that no longer exists, and it is the one shape of "a player that outlives its sheet" this code can
produce.

**Confidence: high in the code shape (no post-await check, and the check is the house pattern everywhere
else); low-medium that the window is reachable in practice**, since the two statements that would have
to interleave both run on the main actor.

### PV10 - [P3] At the largest text sizes the failure sentence lives in a box whose height is decided by its width
`VideoShrink/Presentation/VideoScrubSheet.swift:43-71`

`playerArea` is a `ZStack` of `Color.black` and one branch, closed by
`.aspectRatio(16.0 / 9.0, contentMode: .fit)` and `.clipShape(RoundedRectangle(cornerRadius: 18))`. On an
iPhone that is roughly 350 x 197 points. The failure branch is an icon plus
`Text(problem ?? "This video couldn't be opened.")` with `.multilineTextAlignment(.center)` and
`.padding(20)` - and the longest sentence it can hold is `.retrieval`'s, "Photos could not retrieve this
video. If its original is in iCloud, check your connection and local storage, then try again." The box
cannot grow with its text and nothing inside it scrolls, so at accessibility sizes the sentence the
sheet exists to show is the thing at risk of being clipped. The loading branch's "Opening..." is shorter
and much less exposed. The app's own convention for a sentence that must not clip is
`.fixedSize(horizontal: false, vertical: true)`, which the facts card and the two footnotes carry and
this branch does not.

**Confidence: high that the geometry is fixed and the text is not; medium that it clips at the largest
sizes** - a render is what settles it.

### PV11 - [P3] A copy this app made is called an "Original file" on its own sheet
`VideoShrink/Presentation/VideoScrubSheet.swift:80`; `BatchScreens.swift:765, 787`

The tile's caption says "Made by BatchShrink" for a copy in the library, and its hint says "Opens the
original video player."; the sheet it opens then labels that asset's size "Original file". The sheet has
no idea which kind of asset it was handed - `LibraryAsset` carries an identifier, a date, a length, a
pixel size and a byte count, and nothing about provenance - so a user who taps the tile their own app
just made reads the copy's size under the words "Original file", having been told on the tile that they
were opening the original. Neither statement is dangerous and the sheet's title ("Check this video") is
neutral, but the two surfaces disagree with each other about what the user is looking at.

**Confidence: high** - both strings are unconditional.

## Checked and found sound - do not re-walk

- **Neither preview ever plays anything by itself.** A search for `.play()` over `VideoShrink/` and
  `modules/videoshrink-native/ios/` finds no call at all, so `AVPlayer(playerItem: item)` and
  `AVPlayer(url: url)` both exist paused, exactly as the comment beside the first one says.
- **Both sheets do tear their player down on dismissal.** `onDisappear` on each sheet's own content root
  calls `pause()` and then `replaceCurrentItem(with: nil)`; the second of those is what ends any
  picture-in-picture or buffered session the player was holding.
- **The batch's quick look cannot outlive its screen.** It is presented from `BatchSelectionScreen`,
  which is one case of `BatchFlow.screen`'s `switch batch.phase` - a run starting, a scan stopping or a
  failure replaces that view, so the sheet goes with it. Nothing in the app can change `batch.phase`
  while the sheet is covering the controls that would do it.
- **The one-video preview cannot be left playing by the flow switching.** `useBatch` has exactly two
  call sites in `SingleVideoFlow`: the toolbar's "Batch" button, which is behind the sheet, and the
  action bar's "Shrink several videos instead", which is drawn only at `.idle` - a state with no copy to
  preview. So a preview is only ever dismissed by its own "Done".
- **The 20-second bound is real and pinned.**
  `testTheTwoPhotoKitWaitsThisServiceMakesAreBounded` asserts `scrubRequestTimeout == .seconds(20)`, and
  `testAQuickLookThatNeverAnswersIsGivenUpAndExplainedInsteadOfSpinning` drives `boundedAnswer` with no
  answer and asserts `resolvePlayerItem` answers `.retrieval` - the sentence that reaches the failure
  line.
- **A bounded-out wait cannot resume twice, and a late handler is harmless.** One lock-guarded claim in
  `boundedAnswer` decides which of the handler, the bound or the stop finishes the read.
- **The scrub sheet's own claim about downloading is true.** "If this video lives in iCloud, Photos
  fetches what it needs to play..." matches `playerItem`'s `isNetworkAccessAllowed = true`, and the help
  sheet carries the matching statement for the grid ("Looking through your library never downloads your
  videos. Preview images may come from iCloud."), so the two surfaces that can fetch both say so.
- **The two flows' temporary workspaces cannot step on each other**, so a batch run cannot delete the
  copy the one-video preview is playing - the case that used to be possible, pinned in both directions.
- **The copy the one-video sheet plays is the copy that would be saved.** `previewURL` and `outputURL`
  are the same `written` URL, it is verified before either is set, and `save()` re-verifies that same
  file against `activeSettings.codec` and saves it unchanged.
- **The preview card cannot promise something that is not there.** It is drawn only when
  `model.stage == .readyToSave` and `model.previewURL` is non-nil, its two texts ("Take a look", "Check
  picture, orientation and sound.") are neutral about saving, and round 21's `SV3` already removed the
  "before saving" wording.
- **The scrub sheet does describe the video for someone who cannot see it.** The facts card gives date,
  length, pixel size and original bytes from the scan, and the surface itself carries
  `.accessibilityElement(children: .contain)` with `.accessibilityLabel("Video player")` - the
  combination that keeps AVKit's own transport controls in the accessibility tree rather than replacing
  them.
- **No sheet is offered where it cannot work.** The preview button is drawn only for a row that has an
  asset, and the one-video preview card only in `.readyToSave`.

## Only a device could settle

- **What AVKit draws over a player item that never becomes ready** - PV1's whole weight. Whether the
  system puts up a message of its own, or a black surface with a dead play button, decides whether that
  state is wordless or only unexplained.
- **Whether PhotoKit ever answers a player-item request with an item it cannot play**, and how long it
  takes to answer for a local original, an iCloud original on a good connection, a slow one and with the
  network off. The plan's `Quick look that never answers` row asks the timing half of this; it does not
  ask the item half.
- **Whether the sound is audible with the Ring/Silent switch off** (PV7), which decides whether "Check
  picture, orientation and sound." can be carried out at all.
- **What iOS does to a preview left open across a background and a return** (PV7), and whether the audio
  session is released after a preview stops.
- **Whether `PHAsset.pixelWidth` reports the pre- or post-rotation size for a portrait video** (PV8) -
  the sheet and the run can only disagree if it is the former.
- **Whether `.automatic` hands back a different rendition from `.highQualityFormat`** (PV6), which is
  what decides whether the quick look shows the same picture the run exports.
- **Whether opening the same video's quick look twice in a row draws the second time.** `.sheet(item:)`
  must have been set to nil by the first dismissal for the second tap to re-present; if it were not, the
  second tap on the same tile would open nothing at all. Nothing on this machine can observe a sheet.
- **Whether an interactive drag-to-dismiss runs `onDisappear`**, as the "Done" button's `dismiss()`
  does - the pause on both sheets depends on it.
- **Whether AVKit's transport controls stay usable at the largest Dynamic Type sizes inside a roughly
  350 x 197 point box** (PV10), whether the failure sentence clips, and whether the scrubber is operable
  under VoiceOver at all.

## The smallest set of changes that would close what this audit found

1. **Give the scrub sheet a state for an item that does not become ready** (PV1): observe the item's
   `status` (or `AVPlayerItem.failedToPlayToEndTime`) and reuse the existing failure branch and its
   sentence. One branch in `playerArea` and one observation in `start()`, no protocol or service change.
2. **Move the "Press play, or drag the bar..." footnote inside the player branch** (PV3), leaving the
   iCloud sentence where it is. One line, and it removes the sheet's only outright contradiction.
3. **Give `VideoPreview` the same loading and failure shape the scrub sheet already has** (PV2): a
   `@State` for the outcome plus the two branches, now that the scrub sheet has a shape to copy.
4. **Write the quick look's own sentences for the two cases whose pipeline wording does not fit**
   (PV4): a vanished asset and a player-item failure. Both are distinguishable before the sheet prints
   them - `playerItem` throws `.assetUnavailable` for the first - so this is a switch in the sheet's
   `catch`, not a change to `PipelineError`.
5. **Post one announcement when the look resolves** (PV5), success or failure, using the pattern
   `VideoShrinkNativeView.swift` already has.
6. **Decide the sound question deliberately** (PV7): either set the preview's session category so the
   check the sheet asks for can be performed, or soften the sentence to say the sound follows the
   Ring/Silent switch. This is a product decision, not a bug fix, and it should be made in the open.
7. **Read the sheet's picture size the way the run reads it** (PV8): the transformed `naturalSize` the
   verifier already computes is the number both screens should name, and `LibraryAsset` already carries
   a measured-value channel (`withBytes`) that a display-size reading could follow.
8. **Add a `Task.isCancelled` check after the load's await in `start()`** (PV9), matching the pattern
   `CompressionViewModel.selected` uses after every await.
9. **Extend the device plan's `Quick look that never answers` row** (PV1, PV2, PV7, PV8) to ask what the
   sheet shows when Photos *answers* and the player still will not play, whether the sound is audible
   with the switch off, whether the sheet's pixel size matches the run's own "Original resolution" for a
   portrait clip, and whether the preview stops when the sheet closes. These are four observations this
   plan's preview rows do not currently ask for, and three of them are the whole evidence for findings
   above.
