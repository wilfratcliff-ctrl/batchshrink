# Audit of record - accessibility and Dynamic Type, rechecked after rounds 19 to 23

Read-only audit performed on 2026-09-23, round 24, against the tree at `ba87842` (round 23). It
rereads the batch flow's VoiceOver and Dynamic Type claims after rounds 20 to 23 changed the same
screens that round 19's accessibility wave had just touched. Round 19 recorded that wave as
**unverified**, and nobody has re-read the accessibility of what changed under it.

Files read: `BatchScreens.swift`, `BatchFlow.swift`, `BatchViewModel.swift`, `ShrinkStyle.swift`,
`QualitySelector.swift`, `DeletionSheet.swift`, `ShrinkScreens.swift`, `VideoScrubSheet.swift`,
`AssetThumbnail.swift`, `BatchQueueStore.swift`, `BatchModels.swift`, `PipelineModels.swift`,
`BatchQueueRecord.swift`, `BatchTests.swift`, `BatchQueueTests.swift`, `ShrinkOnboarding.swift`,
`SingleVideoFlow.swift`, and `docs/BATCH_PHASE.md`.

**Nothing was run.** There is no Swift compiler, no simulator and no device on this machine, and the
CI gate is blocked until 2026-10-01, so every judgement here is a source read. No gate was run:
another writer was mid-edit in the tree, which is also why the citations are pinned to a commit
rather than to whatever the file holds now.

**Line numbers are `ba87842`'s.** At the time of reading, `BatchScreens.swift`, `BatchFlow.swift`,
`ShrinkStyle.swift`, `QualitySelector.swift`, `DeletionSheet.swift`, `BatchQueueStore.swift`, the
models and the two test files were byte-identical to that commit, so their numbers are stable.
`BatchViewModel.swift` was being edited for round 24 (the SV1 fix: `adoptUnconfirmedSaves` at launch,
plus `history.clearUnconfirmedSave` where a question is answered); its line numbers below are also
`ba87842`'s. That change only *adds* unresolved questions and answers them, so it cannot create any
of the states these findings turn on - and it makes AX6's shape no more reachable than it already
was.

**This is a finding list, not a list of fixes.** `AGENT_LOOP.md`'s backlog carries the IDs and is the
only place that records status. Read the code before acting on a line.

## Findings

**What has happened to each finding since it was written.** The sections below are the audit as it
was performed, against `ba87842` (round 23); this table is the map, because some of them were fixed
in the two rounds that followed and two are deliberately still open.

| ID | Status |
|----|--------|
| AX1 | **Fixed in round 24.** The sentence now says what the app does: nothing could be restored, nothing in Photos was changed, the record stays where it is, and the notice comes back until a run writes one of its own. The code half named here (moving the file aside) was refused on purpose - a version this build cannot read may belong to a *newer* build, and moving or clearing it would lose that run |
| AX2 | **Fixed in round 24**, as `BatchProcessingScreen.processingSubhead`, which counts the copies the run can account for and names the rest in the paused screen's own words |
| AX3 | **Open, deliberately.** Every fix runs into a documented decision: `live()` passing the state through is what lets `BatchFinishedRow.savingDisplay` explain it rather than draw a negative figure, and the row's own words (its comment and `symbol`) are built on the same state. Clamping in `live()` would fix the headline and make all of that unreachable, and clamping in the summary would put "No copies were saved." above a row beginning "Saved ·". It needs one round that decides which of the three keeps the state, for a record only a file this app did not write can hold. See `Q3` in `AGENT_LOOP.md` |
| AX4 | **Fixed in round 25**: `BatchFinishedScreen.overflowHint(_:)` names exactly what the menu holds, from the same list that decides the trigger and its contents, with a case pinning all six shapes |
| AX5 | **Fixed in round 25**, with one helper rather than seven ternaries: `ShrinkFormat.counted(_:_:_:)` now carries the singular at the seven sites this finding named, plus two more of the same class it did not (`1 aren't measured yet`, `1 aren't supported yet`) |
| AX6 | **Open with `Q1`.** The heading is the heading half of `Q1`'s own proposed fix - one set for automatic selection, and a sentence chosen by the finding - and both halves need the state `Q1` records as unreachable from any shipped build. Latent, and recorded rather than patched |
| AX7 | **Fixed in round 25**: the notice's heading now names which finding it is ("No videos to shrink" or "No videos BatchShrink can use") instead of repeating the summary's headline word for word |
| AX8 | **Fixed in round 25**: the estimate card is one accessibility element (the same pairing `A3` made in the quality sheet), and the card's stage text leaves the accessibility tree, where the orb and the bar already say it |

### AX1 — [P2] The unreadable-record notice says the app set the record aside, and nothing does
`VideoShrink/Presentation/BatchViewModel.swift:1820-1822` builds
`"BatchShrink has set it aside, and nothing about the library was changed by this launch. If you had a run going, look in Photos before running the same videos again."`
and `VideoShrink/Presentation/BatchScreens.swift:50-53` (start screen) and `:499-502` (selection
screen) draw it as `title: "A saved run couldn't be read"`.

The first clause is a claim about an action. The only thing the app does with a record it cannot read
is *ask whether one is there*: `FileBatchQueueStore.hasUnreadableRecord()`
(`VideoShrink/Services/BatchQueueStore.swift:55-72`) reads the file and answers a `Bool`, and it is the
only reader of that question in the tree. `load()` (`:38-46`) reads and discards. The only writes are
`save(_:)`, an atomic overwrite (`:74-82`), and `clear()`, which writes an empty record (`:84-89`).
There is no rename, no move and no delete anywhere on that path, and `restoreQueue()` returns with the
file still in place - so every later launch reads the same file again and draws the same notice until
a completed run's checkpoint or `Done` happens to overwrite it.

So a user who is told the record "has been set aside" is told something the model does not do, and
will meet the same notice again. Either half can be fixed: the sentence ("BatchShrink has ignored
it"), or the code (move the file to `queue.unreadable.json` on the read that finds it). The notice
exists to make the user look in Photos for a copy the record may name (#RR5), and the code half is
the one that also stops the notice repeating.

Confidence: high that no code sets the record aside. The sentence is spoken - `ShrinkNotice` combines
its title and detail into one element (`ShrinkStyle.swift:324-343`) - and reachable on any launch
whose queue file is undecodable, or holds a newer version with something in it, which
`testAQueueFileThisBuildCannotReadIsToldApartFromNoQueueAtAll` and
`testALaunchWithAQueueItCannotReadSaysSoRatherThanLookingLikeAFreshInstall` (BatchQueueTests.swift)
already pin as real states.

### AX2 — [P3] The working screen counts a video whose save Photos did not confirm as "finished"
`BatchScreens.swift:986-989`:
`return "\(batch.finishedCount) of \(batch.items.count) finished."`

`finishedCount` is `items.filter { $0.state.isFinished }.count`
(`BatchViewModel.swift:334`), and `.needsCheck` is finished (`VideoShrink/Models/BatchModels.swift:52-57`
- `case .saved, .skipped, .failed, .needsCheck: return true`). A video whose save Photos did not
confirm is the ordinary mid-save stop: `noteUnsettledSave` (`BatchViewModel.swift:1475-1489`) flags it
and deliberately lets the run carry on to the next video. So this screen can read "4 of 5 finished"
while the "Just finished" card on the same screen (`BatchScreens.swift:1090-1107`) draws that video's
row saying `"Photos did not confirm the save. Inspect Photos before retrying to avoid creating an
extra copy. Your original was not changed."` (`Models/PipelineError.swift:103`).

Round 20 removed exactly this sentence from the paused screen, and the code that replaced it says why
(`BatchScreens.swift:1323-1336`: "`isFinished` is true for a video whose save Photos never
confirmed... a claim about a video the app does not know the outcome of", so `pauseSubhead` counts
only copies it can account for). This is the same sentence, untouched, on the screen directly before
that one - reachable in a single run with no unusual file, and read aloud as its own element.

Confidence: high on the path. The judgement that "finished" is false here is the project's own, from
round 20. RR6's row calls the remaining half open and names `canLeaveFlow`; this is a third reader of
the same flag, and the narrower half is a sentence.

### AX3 — [P3] The finished screen says "lighter" and a "smaller copy" when the copy is not smaller
In the state round 19's E8 declared in scope - a stored `.saved` whose copy is not smaller, which only
a queue file this app did not write can hold, and which `BatchQueueReconciliation.live` passes through
unchanged (`VideoShrink/Models/BatchQueueRecord.swift:415-416`) - one screen says four different things
about the same copy:

- `BatchScreens.swift:1614`: `return saved == 1 ? "One video,\nlighter." : "\(saved) videos,\nlighter."`
- `BatchScreens.swift:1621`: `"\(summary.savedCount) smaller \(summary.savedCount == 1 ? "copy" : "copies") in Photos."`
- `BatchScreens.swift:1201-1203` (the row, E8's fix): `"Saved a copy · its recorded size is not smaller than the original"`
- `BatchScreens.swift:1714-1717` (the totals card, which only draws the saving when `savings.isSmaller`): `value: "Nothing measured"`, `label: "no smaller copies"`, `detail: "originals were left as they were"`

The headline and the subhead count every `.saved` item; the card the screen exists to show does not, and
the row directly under it says so. E8 also recorded the wider fix as still open - clamping a foreign
`.saved` in `BatchQueueReconciliation.live` - and that would cure all three readers at once.

Confidence: high on the paths; reachability is the same caveat E8 accepted when it fixed the row, which
is why this is 3 and not 2.

### AX4 — [P3] The finished screen's overflow hint names three actions whatever is in the menu
`BatchScreens.swift:1581`:
`.accessibilityHint("Delete originals, try the failed ones again, or run the ones you checked.")`

The menu's contents are decided by one list, `Extra.available(deletableCount:failedCount:awaitingUser:)`
(`:1587-1608`), which returns any subset of the three - and the pinned case
`testTheFinishedBarOffersExactlyTheExtraActionsThatApply` (BatchTests.swift:2117-2129) states all of
them, including the two shapes with only one action. A run that ended with failures and nothing else
therefore draws a menu holding only "Try the failed ones again", and VoiceOver reads a hint promising a
Delete and a requeue that are not there. The trigger itself is drawn from the same list (`:1544-1546`),
so the hint is the one string on this control that does not read it. It is spoken only; the visible
menu is true.

Confidence: high. The narrow fix is the shape A2 already used for the bar: derive the hint from
`extras`.

### AX5 — [P3] The delete item in that menu says "Delete 1 originals", and six other counts have no singular form
`BatchScreens.swift:1564`:
`Button(batch.deletionInProgress ? "Deleting…" : "Delete \(batch.deletableItemIDs.count) originals", role: .destructive)`

With one candidate the row reads "Delete 1 originals", visible and spoken. The confirmation that row
opens pluralizes the same count properly - `deletionPrompt(count:)` (`:1662-1669`) returns
"Delete 1 original?" and "Delete 1 original" - so one control names its own count two ways and one of
them is wrong. The same pattern appears at six more sites, each with a reachable singular:

- `:569` `"\(batch.eligibleAssets.count) videos to explore"` - one eligible video
- `:1377` `"\(batch.remainingCount) videos left"` on the paused screen - the working screen's headline handles the same count (`:972`)
- `:1648` `"All \(saved) copies confirmed in Photos."` - a one-video run
- `:425` and `:426` `"From \(samples) copies measured on this iPhone."` - the first measured band, which is the band the caption exists to name
- `:1352` and `:1686` `"\(report.uncertain) originals may already have been deleted. Check Photos before running those again."` - one uncertain delete, which is DEL1 and DEL5's own scenario
- `:355` and `:372` `"Estimated for \(sizedCount.formatted()) of \(assets.count.formatted()) videos"` reads "1 of 1 videos"

Confidence: high. These are interpolations with no singular branch beside them, and every one is read
aloud as well as drawn.

### AX6 — [P3, latent] "To look at in Photos" is drawn over a video the app has already answered
`BatchScreens.swift:1414-1429` builds the paused screen's card from `items.filter { $0.state == .needsCheck }`
and heads it `"To look at in Photos"` (`:1417`). The notice immediately above it (`:1405-1408`) uses
`MidSaveReport` (`:1254-1300`), which splits the same items by the *answer*: a finding that
`forbidsAnotherSave` counts as `foundCopy`, and with none waiting the title becomes
`"\(foundCopy) copies found in Photos"` with the detail
`"The copies BatchShrink made are in Photos, so none of them are run again. Nothing is left to check."`
(`:1272-1284`). The row between them says
`"Photos has the copy BatchShrink made, so it is not run again and cannot be copied twice."` (`:1235-1236`).

So in the shape where a finding is `.copyInPhotos` while the item is still `.needsCheck`, one screen
says nothing is left to check, headed by a card telling the user to go and look.

Reachability: the card reads the item's state and the notice reads the finding, and today the only
writer that leaves both set is `resolveMidSaveItems`'s `break` when `attemptedSaves[id]` is missing or
not smaller (`BatchViewModel.swift:1921-1928`, the guard at `:1928`). The current writer puts the
measured sizes beside the receipt (`:1332`, then `copyEvidence[id] = receipt` and its `persistQueue()`
at `:1350-1355`, both before the `.saved` checkpoint at `:1360`), so a record it wrote settles into
`.saved` on the next launch - which `testAMidSaveRecordWhoseCopyIsStillInPhotosSettlesAsTheSaveItWas`
pins - and the door is the one Q1 records as open. This is therefore latent rather than reachable, and
it is the *heading* half of Q1's own proposed fix ("a third card sentence for 'the copy is there'"): if
Q1 is ever opened by letting a conclusion stand without `.saved`, this heading is the first string that
lies.

Confidence: high on the code, medium on reachability, for the reason Q1 gives.

### AX7 — [P3] An empty library announces the same sentence twice
`BatchScreens.swift:243-246` draws the summary's headline as a VoiceOver header, and for a library with
no videos `summaryHeadline(eligibleCount: 0, estimate:)` returns `"Nothing to shrink yet."` (`:321`).
`BatchEmptyNotice` is drawn whenever `result.assets.isEmpty` (`:251-252`), and its own title is the same
words (`:217`), read through `ShrinkNotice`, which combines title and detail into one element
(`ShrinkStyle.swift:324-343`). So the screen reads:

- "Nothing to shrink yet." (the header)
- "0 videos in your Photos library." (`:335-339`, the subhead, which has no singular case for zero)
- "Nothing to shrink yet. There are no videos in your Photos library yet." (the notice)

Reachable on any fresh install with no videos, and pinned by
`testAnEmptyLibraryDoesNotClaimVideosWereRefused` (BatchTests.swift:1811-1833), which is the fix that
gave the notice its two cases. The narrow fix is one of the three strings rather than all of them: the
notice is the one that carries the distinction between "nothing here" and "nothing I may see".

Confidence: high.

### AX8 — [P3] The working screen's time estimate is a bare figure, and its stage is announced three times
Two shapes the round-19 wave fixed elsewhere, at the two sites it did not name.

- `BatchScreens.swift:991-1015` draws the remaining-time figure in `.title` bold and its explanation
  (`"\(ShrinkFormat.durationRange(estimate)) · from \(sampleCount) finished videos"`) as a second
  `Text`, and the card has no `.accessibilityElement(children: .combine)`. That is the shape A3 fixed in
  the quality estimate (`QualitySelector.swift:149-167`, combine at `:165`) and the shape `ShrinkStat`
  (`ShrinkStyle.swift:166-182`) and `ShrinkResult` already use - the two components the round-18 audit
  cited as the precedent for that fix.
- The stage name is announced three times on the same screen: the orb's label (`BatchScreens.swift:1020`
  with `ShrinkStyle.swift:282`), the card's own `Text(batch.currentStage?.title ?? "Working")` as a
  separate element (`:1028`), and the progress bar's label (`:1036`). A7 hid the third *percentage*
  (`:1040-1042`) and left the stage name in all three places.

Confidence: high that the combine is absent and that the three stage strings are three elements. What
VoiceOver merges on its own is a render question, not a source one.

## What rounds 20 to 23 added, and whether it is announced

The six elements the recheck was asked about, one at a time.

- **The paused screen's "To look at in Photos" rows** (`BatchScreens.swift:1414-1429`): each row is a
  `BatchFinishedRow`, which combines its children into one element (`:1146`) and has no separate hint;
  the heading carries the header trait (`:1418`). Announced, once, with no hint needed. The heading's
  *truth* is AX6, not its identity.
- **The "Left out of Select all" card and the tile caption ladder** (`BatchScreens.swift:474-491`, `:693-708`,
  `:739-753`, `:761-763`): the card's heading is a header (`:842`), its rows combine and carry the
  caller's hint (`:889-890`); the tile says the same fact in a visible caption (`:740`) and in the spoken
  label (`:699`), and exposes the selection state both as a trait (`:762`) and in words (`:709`). So the
  round-22 PL5 fix is consistent between the eye and the ear - the ladder picks exactly the same fact,
  in the same order, in both. One smell worth a sweep if someone next touches this: the card's rows are
  not controls, so the hint "Tick it by hand to choose it" sits on an element that cannot be ticked - the
  control it describes is the tile above. It is true, but it is a hint on a static element.
- **The estimate line in the quality sheet** (`QualitySelector.swift:208-211`, drawn from
  `BatchFlow.swift:25-35`): its own element, and drawn only where the sheet can produce a figure, so
  round 23's SV8 fix holds. Nothing hidden, nothing duplicated.
- **The finished screen's overflow menu and its three actions** (`BatchScreens.swift:1558-1582`): named
  "More actions" by a `Label`, drawn only when the same list that fills it is non-empty, and each item
  is a `Button` with a visible title. Announced, once. Its hint is AX4 and one of its labels is AX5.
- **The `queueReadWarning` notice** (`BatchScreens.swift:50-53`, `:499-502`): its own `ShrinkNotice`,
  deliberately not under the write-failure heading, combined so it is read once. Its sentence is AX1.
- **The deletion confirmation** (`BatchScreens.swift:1523-1532`, `:1662-1669`): title, destructive
  button and message all come from one static function; the message states what happens to its own
  count rather than promising a number, and the count is pluralized. The system dialog announces it;
  what only a device can say is the order and the grouping (see below).

## Headings, lists and grouping

- The five card headings the round-19 wave turned into VoiceOver headers are still headers, and every
  heading added since is too: "Not supported" (`BatchScreens.swift:839-842`), "Just finished" (`:1094-1095`),
  "Needs attention" (`:1732-1733`), "To look at in Photos" (`:1417-1418`), and the second card's
  "Left out of Select all" through the same component (`:603`, `:842`). `QualitySelector.sectionTitle`
  covers "Picture size" and "Smoothness" (`QualitySelector.swift:130-135`).
- Every list that draws rows is guarded against being empty, so no heading is drawn over an empty list:
  `VideoReasonList` returns nothing when `assets.isEmpty` (`BatchScreens.swift:834-835`), the finished
  list (`:1091-1092`), the failure list (`:1722-1730`) and the flagged card (`:1414-1415`) each guard
  the same way. The card and the notice that share the flagged set are drawn from the same condition
  (`summary.needsCheckCount > 0` and a non-empty filter over the same state), so they cannot appear
  separately.
- The heading drawn over content that contradicts it is AX6. The heading drawn for an empty screen is
  AX7.
- The grid has no heading or container of its own: the tiles are individual elements reached under the
  screen's "Make room." header, and the grid is not an accessibility container, so a rotor user cannot
  jump to it as a group. That is navigable and I am not recording it as a finding; a render would say
  whether the group is missed.

## Text that can fit, and text that needs a render

What the source can settle: every text that holds a sentence carries
`.fixedSize(horizontal: false, vertical: true)`, so a long sentence grows its container instead of being
clipped - the cards and the action bars get taller rather than cutting words off
(`BatchScreens.swift:18`, `:22`, `:129`, `:1374`, `:1394`, `:1403`, `:1439`, `:1494`, `:1506`,
`QualitySelector.swift:102`, `:114`). The only two strings that scale themselves down instead are the
progress orb's percentage (`minimumScaleFactor(0.4)`, `ShrinkStyle.swift:270-273`) and the word mark
(`0.6`, `:247-251`, round 19's A4). Every icon-only control in the flow has a name: the selection
toolbar's `checklist` (`BatchScreens.swift:521-525`), the help button (`ShrinkScreens.swift:219-227`),
and the thumbnails, which are hidden because their button carries the facts (`:711-724`,
`AssetThumbnail.swift:61`).

The one string drawn with no wrap guard and no scale factor is the overflow menu's "More actions"
label (`BatchScreens.swift:1576-1580`), which shares its row with "Done" - and `Done` takes
`maxWidth: .infinity` (`:1539-1541`), so the menu label is the compressed one. At accessibility sizes
that is the first thing I would expect to truncate, and it is the only label on the screen a VoiceOver
user needs in order to reach the delete and retry actions.

Worth rendering, in both landscape orientations and at AX5 (and recorded as the audit's arithmetic,
not as a measurement):

1. the **finished** bar: `Shrink more videos` (58pt min) then `Done` + `More actions` in one row;
2. the **paused** bar with three controls, the middle one labelled `"I checked Photos — run them again"`;
3. the **summary** bar with three controls (`Choose videos`, `Select all N`, `Look again`) - A2 named the
   finished, paused and selection bars and the summary screen is the fourth three-control bar;
4. the **recovery** bar when `accessBlock == .refused` (up to three), and the **selection** bar, whose
   first row is a two-line estimate block that cannot truncate because it is `fixedSize` vertically.

The bar is a `VStack` on a canvas with no scroll of its own (`ShrinkStyle.swift:186-201`), so if one of
those combinations is taller than the viewport, the sentence is not clipped - the `ScrollView` behind it
is squeezed instead, which is A2's complaint in its exact shape.

## Round 19's wave after rounds 20 to 23

**Nothing the wave added has been deleted.** `git diff fb614a6..HEAD` over the presentation files
changes exactly three accessibility modifiers, and all three are additions: the refusal list's row hint
became caller-driven with the refusal's own words as its default (`BatchScreens.swift:890`, `:828-832`),
the paused screen's new card got the header trait (`:1418`), and the recovery screen's cross-flow
button got a hint that follows `canLeaveFlow` (`:1805-1807`).

Each of A1 to A10 is still at its site, re-read rather than assumed:

- A1, the running total: the figure carries `BatchFinishedRow.SavingDisplay.spokenLabel` inside the
  combining card (`BatchScreens.swift:1073-1087`).
- A2, the finished bar: two rows, one list behind the trigger (`:1534-1609`).
- A3, the quality estimate: combine at `QualitySelector.swift:165` (but see AX8 for the site it missed).
- A4, the word mark: `ShrinkStyle.swift:247-251`.
- A5, the sort pill: `sortSitsBesideHeadline` (`BatchScreens.swift:549-561`, `:595-597`).
- A6, the five card headings: all headers (see the section above).
- A7, the third percentage: hidden (`:1040-1042`; see AX8 for the stage name).
- A8, Increase Contrast: the pill outline uses `ShrinkStyle.hairline` (`QualitySelector.swift:61-69`) and
  the originals list is a card (`DeletionSheet.swift:23-26`).
- A9, haptics: one switch named "Haptics", read by the pills and by the end of a run
  (`ShrinkStyle.swift:22-53`, `BatchFlow.swift:51-55`, `ShrinkScreens.swift:280-283`).
- A10, the two inert numeric transitions: both now sit under Reduce Motion-gated animations
  (`BatchScreens.swift:998-1002`, `:1077-1087`).

Two of the wave's *classes* are unfinished at a second site rather than undone: A3 and A7 (AX8), and from
the numbers wave E8 (AX3). Nothing from the numbers wave's sentences has been reverted either - the
ceiling-and-frame-rate confirmation (`BatchFlow.swift:81-94`), the basis caption, the "No saving
expected" wording and the "N of M measured" selection line are all current.

## Checked and correct - do not re-walk

- **The unaccounted question is told the same way to the eye and the ear.** The tile's caption and its
  spoken clause are the same fact, and the exclusion rule reads from one set
  (`BatchViewModel.swift:307-318`), so a video left out of Select all is always drawn and spoken as left
  out. The card's rows carry the question rather than the refusal's words (`BatchScreens.swift:481-490`),
  which closes the finding round 21's own review made about generalising a card without its rows.
- **The three captions never contradict each other or the selection.** `unaccounted`, `madeByApp`,
  `alreadyShrunk` and the estimate are chosen in the same order in the visible ladder and in the spoken
  label (`BatchScreens.swift:698-708` vs `:739-753`), and selection is exposed as a trait *and* in words
  (`:761-763`).
- **The selection shortcuts say what they do.** `selectAll()` selects exactly `selectableAssets`
  (`BatchViewModel.swift:286-295`, `:774-777`), so "Select all N" is true on the summary and selection
  screens; "Select likely to shrink" selects the subset the name describes (`:780-783`); the toolbar menu's
  hint names its three items exactly (`BatchScreens.swift:517-525`).
- **A trigger over an empty menu cannot be drawn.** The bar's trigger and the menu's contents come from
  one list (`BatchScreens.swift:1544-1546`, `:1587-1608`), pinned by a case that enumerates the subsets.
- **The deletion confirmation is honest about its own count** and pluralizes it
  (`BatchScreens.swift:1662-1669`), and every candidate it names has passed the read-back and the fresh
  look (`BatchViewModel.swift:413-416`), so "Each one has a smaller copy that Photos handed back" is
  true of each one at the moment it is drawn.
- **The unreadable-record notice is in its own notice and nowhere else.** It is not drawn on the paused,
  finished, processing or summary screens, which is right: nothing can be restored from a record that
  cannot be read, so no run's screen can come up from one. Its sentence is AX1.
- **The read-back line, the deletion note and the paused subhead say what they can account for** - the
  read-back counts only items with an outcome, `deletionNote` distinguishes "nothing qualified" from
  "waiting to confirm" (`BatchScreens.swift:1643-1652`, `:1677-1702`), and the paused subhead names the
  videos still to check rather than counting them as saved (`:1330-1336`; AX2 is the working screen's
  version of the same count, which was not changed).
- **The working screen's shield line follows the run's own mode**, and says what the app does first
  rather than promising the original stays (`BatchScreens.swift:908-911`), so it cannot contradict the
  rows beneath it.
- **The paused and finished screens name the videos their questions are about**, with the same
  identity-bearing rows the other lists use (`:1414-1429`, `:1722-1745`), so a question can be answered
  by looking at the video it is about.
- **Colour never carries a state alone**: the tick, the captions, the row detail and the traits all say
  it in words.
- **The word mark, the help control and the recovery screen's cross-flow button are named, and the
  latter's hint follows whether it can be used** (`ShrinkStyle.swift:253-254`,
  `ShrinkScreens.swift:226`, `BatchScreens.swift:1798-1807`).
- **Nothing in the batch flow announces a saved figure without its words**: the two figures that could
  have been bare (the running total and the finished row) both borrow the one phrase
  (`BatchScreens.swift:1076`, `:1162-1167`).

## Only a render or a device could settle

- Whether iOS truncates the menu's "More actions" label at AX5, whether it scales it, and whether it
  wraps the paused screen's middle button; and whether the summary, paused, finished or recovery bar
  squeezes its `ScrollView` in landscape rather than overflowing. The four combinations are listed
  above.
- Whether VoiceOver reads the tile's `·`-separated spoken label ("5 selected · 2.1 GB of 4 measured",
  "Saved · read back from Photos", `<date>, <duration>, <size>`) as units and separators or as noise.
- Whether a `ProgressView(value:)` that carries only an explicit `accessibilityLabel`
  (`BatchScreens.swift:1035-1036`) still announces its own percentage, or whether the orb and the
  estimate are the only places the figure is spoken. The source cannot say.
- What the system announces for `confirmationDialog` - the order of title, message and buttons, and
  whether the destructive button is read with its role - for both the pre-run confirmation
  (`BatchFlow.swift:37-44`) and the deletion confirmation (`BatchScreens.swift:1523-1532`).
- Whether `.disabled` inside the overflow menu is announced as dimmed (the "Deleting…" item,
  `BatchScreens.swift:1564-1568`), and whether the `Menu`'s hint is read at all on iOS 26.
- Whether the paused screen's card heading and its notice are reached in that order by a rotor user,
  which decides how visible AX6's contradiction is in practice.
- Whether the system Haptics switch suppresses `.sensoryFeedback` on iOS 18+, which A9 left open and
  which is unchanged.
- Whether the grid's tiles are reached in a sensible order after the two headers above them, and
  whether the one-column grid at accessibility sizes is usable in a real library.

## One thing outside the subject

`docs/BATCH_PHASE.md`'s "Surviving a close" still says `"Done" clears the stored queue by writing an
empty one`. Round 23 changed that: `reset()` writes the outstanding questions on their own when there
are any (`BatchViewModel.swift:1052-1057`, `:1795-1804`), and clears the queue only when there are none.
The document is the flow's own specification, so the sentence is worth correcting in whoever's round
owns it - it is not an accessibility finding.
