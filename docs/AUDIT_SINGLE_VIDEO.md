# Audit of record — the one-video flow, from the tap to the saved copy

Read-only audit performed on 2026-09-23, round 21, against the tree at `0786a12`. The one-video
flow had never been traced, and it is the flow the README calls the safest way to judge a copy and
the one the Phase 0 acceptance test uses.

**This is a finding list, not a list of fixes.** `AGENT_LOOP.md`'s backlog carries the same `SV` IDs
and is the only place that records status. Line numbers move; cite the strings.

## Findings

### SV1 — [P2] A save interrupted while Photos holds it leaves a copy nothing remembers
`VideoShrink/Presentation/CompressionViewModel.swift` (`save()`, `init`'s cleanup)

The confirmation says "Saving cannot be cancelled once it starts" and the screen says "Please wait
for Photos to confirm". Kill the app in that window and the relaunch shows the welcome screen at
`.idle`: no notice, no question, and startup cleanup has swept the export. The only fact this flow
persists anywhere is the copy's identifier, written *after* `save` returns - so if Photos committed
the copy, the app never learned.

What it costs: the copy is a real Photos asset carrying the original's filename and creation date,
absent from `createdCopyIdentifiers`. The batch flow's `selectableAssets` therefore includes it, so
a later "Find my videos - Select all" ticks this app's own output and copies the copy; the original
is absent from `completedIdentifiers` too, so it can be run again. This is the outcome round 21 built
`unaccountedIdentifiers` to prevent, reached through the batch's route.

The batch's counterpart is the whole `needsCheck` record plus `midSaveFindings`, and it exists
because a save Photos was asked for but did not confirm is never a clean failure.

**Open.** The narrowest fix is a pending-save marker written to the shared
`ShrinkHistoryStoring` store before `photos.save` and cleared when it returns either way; a marker
left at launch is an unresolved question, and the batch already has the consumer for it. The
one-video welcome would then need one sentence.

### SV2 — [P2] The recovery screen's "Shrink one video instead" was drawn live and did nothing
`VideoShrink/Presentation/BatchScreens.swift` (the recovery screen); `ContentView.switchTo`

A run whose access goes before its first read rests on the recovery screen with every video still
pending, so `canLeaveFlow` is false. The button ran the routing rule, was refused, and changed
nothing on screen - a control offered where it cannot work, with no feedback.

**Fixed in round 21**: the control is disabled with a hint that says why, which is the same rule the
one-video flow's own cross-flow button obeys. The deeper option - a *failed* batch holds nothing in
flight, so `canLeaveFlow` might not hold the user at all - is **open** and is a `canLeaveFlow`
change, not a view one.

### SV3 — [P3] The ready-to-save screen said preview "before saving" when saving was off
`SingleVideoFlow.swift`, `ShrinkScreens.swift` (the preview sheet footer)

Both are drawn whenever there is a copy to look at, including the one that did not come out smaller,
where the sentence above them says saving is turned off.

**Fixed in round 21**: "before you decide".

### SV4 — [P3] A copy that came out bigger was drawn as "No size reduction" under an equals sign
`VideoShrink/Presentation/ShrinkScreens.swift` (`ShrinkResult`)

The branch covers both "the same size" and "bigger", and the two measured sizes printed directly
below could read 120 MB and 180 MB. **Fixed in round 21**: the sign of `bytesSaved` chooses the words
and the glyph, and `ShrinkResult.notSmaller` is static so a case can state both.

### SV5 — [P3] Cancelling the picker landed on a recovery screen about a video never chosen
`CompressionViewModel.pickerCancelled()`; `ShrinkScreens`; `SingleVideoFlow`

Closing the picker puts the flow at `.cancelled`, so the user meets "No rush. Your original is
safe." and "Choose another video" about a video that does not exist and a run that never happened.

**Open.** The narrowest fix is for `pickerCancelled()` to return to `.idle`, which needs the one
`(.choosing, .idle)` case in `PipelineStage.allows`. No test exercises `pickerCancelled` at all.

### SV6 — [P3] Two failure sentences named something other than what was found
`VideoShrink/Models/PipelineError.swift`

"HEVC export failed" was the sentence for any unrecognised export failure in a flow whose quality
can be 720p, which Apple's preset builds as H.264 - a codec claim the settings decide. And "The copy
came out larger than the original" was thrown only by the pixel check, while a copy bigger in *bytes*
is a different, ordinary ending in this flow.

**Fixed in round 21**: the export sentence names no codec (the settings are not readable from that
file), and the mismatch sentence says picture size.

### SV7 — [P3] The welcome promised "your smaller copy" before anything had been measured
`ShrinkScreens.swift` (the welcome screen)

The same class round 19 fixed twice on the batch side. **Fixed in round 21**: "preview your copy".

### SV8 — [P3] The quality sheet promises estimates the one-video flow never shows
`QualitySelector.swift` (the footer) with `SingleVideoFlow`'s always-nil estimate closure

The shared sheet's footer says "These are estimates. Real sizes appear when it finishes", and the
one-video caller can only ever show the placeholder, because this flow has no library to size.

**Open, cosmetic.** Give the sheet an optional footer, or make the sentence conditional on an
estimate being possible.

## Checked and correct — do not re-walk

- **The flow cannot delete anything.** Its only PhotoKit calls are `requestAccess`, `retrieve`,
  `save` and `cancelRetrieval`, so "your original stays untouched" and its variants are true on every
  screen. The read-back and receipt machinery it does not call is live in the batch flow.
- **The two flows share only what they should**: separate library and transcoder services (so a
  cancel cannot cross over), separate temporary workspaces (pinned in both directions), one shared
  history store and one shared settings object.
- **The history store's one direction is right and pinned end to end**: the copy is recorded under
  `createdCopyIdentifiers` and never `completedIdentifiers`, and a case drives the real store and
  asserts the batch's selection excludes it. An original the batch already shrank *can* be re-run by
  hand here, which is the same arrangement the batch's own hand-tick path uses.
- **Save cannot double-fire or double-copy**: the flag is false before the first `await`, a repeated
  tap is ignored, the file is re-verified against the chosen codec immediately before Photos is
  asked, the copy must still be smaller, and backgrounding deliberately does not touch `.saving`.
- **The demand figure cannot leak into a later failure** - it is dropped the instant each check
  passes, exactly as round 19's review required.
- **Retrieval wording distinguishes iCloud from local** by keying off PhotoKit's own progress
  callback.
- **Every failure sentence that reaches this flow is its own** where the batch's were fixed: HDR and
  ProRes keep `AssetRules`' words, the space refusal names its figure, access separates refusal from
  restriction, and an export Apple will not build carries Apple's finding.
- **The finished and ready states show measured numbers only** and never claim reclaimed space.
- **Every stage is escapable**, and the picker's own states are sound.

## Only a device could settle

- **Whether PhotoKit calls the progress handler for a video already on the iPhone.** If it does, the
  flow will say it is bringing a local original from iCloud. This is the one place its retrieval
  wording could be false.
- **Whether Photos ever commits a copy after the process dies inside `performChanges`** - SV1's whole
  weight, and the same question RR2 already carries.
- **Whether an ordinary original ever produces a copy bigger in bytes**, which decides whether SV4's
  branch is seen at all.
- **Whether the app's own copy is distinguishable to the user**, since it keeps the original's
  filename and creation date.
