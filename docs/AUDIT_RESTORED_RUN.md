# Audit of record — the app being closed, and what the user meets on the way back

Read-only audit performed on 2026-09-23, round 20, against the tree at `1bdd009` (with a
`BatchViewModel` edit in flight from the deletion audit's own fix, which changed none of these
findings). It traced every way the app can be killed during a batch and what the next launch does
with the queue file - the most-corrected machinery in this project, and the one no round had ever
traced from the user's side.

**This is a finding list, not a list of fixes.** `AGENT_LOOP.md`'s backlog carries the same `RR`
IDs and is the only place that records status. Line numbers move; cite the strings.

## Findings

### RR1 — [P2] The restored screen asked the user to check Photos and never said which video
`VideoShrink/Presentation/BatchScreens.swift` (the paused screen); `MidSaveReport`;
`BatchViewModel.restoreQueue`

The notice reads "1 to check in Photos" with "Photos may still have been taking the copy of this
video. Look in Photos before running it again.", and the control reads "I checked Photos — run them
again". Nothing on the screen names the video. The only list the paused screen drew was the
pre-flight refusals; the rows that carry an identity live on the finished screen, one tap and one
"Finish with what's done" away.

The flag exists so the user decides, and this is the ordinary mid-save kill: kill the app while
Photos is taking copy 1 of 10 and the other nine are pending, so the resumed run lands on the paused
screen. The app asked a question it gave the user no way to answer.

**Fixed in round 20**: the paused screen draws the flagged videos as rows, with the same row type
and finding the finished screen uses.

### RR2 — [P2] An unanswered question dropped off the screens at the next scan and out of the record at the next run, and the video it named became selectable again
`BatchViewModel.swift` (`scan()`, `beginSelecting()`, `beginRun(with:)`, `selectableAssets`)

Route: relaunch → paused screen (which did not name the video) → "Finish with what's done" → the
finished screen names it under "Needs attention" → "Shrink more videos" → `beginSelecting()` finds
no scan and sends the user to the start screen → "Find my videos" → `scan()` empties `items` and the
question is gone from every screen. The record on disk survived that until the next run's first
checkpoint overwrote it.

The second half matters more: the guard against copying that video twice is `selectableAssets`,
which excludes completed originals and app-created copies - and the original reaches
`completedIdentifiers` only *after* `photos.save` returns. So a kill inside `performChanges` leaves
it absent from that list and "Select all N" ticks it. That is the outcome the area's own comment
says it exists to prevent.

**Open, and the highest-value item either audit left behind.** It is a design change rather than a
sentence: the question has to survive a scan and stay out of bulk selection while remaining
re-runnable by hand, which is the same shape as the app-created-copy exclusion.

### RR3 — [P2] A restored run has lost why it stopped, including the two reasons about the device
`BatchViewModel.swift` (`pauseReason`); `BatchQueueRecord`; the paused screen

A run stopped for want of free space or for heat comes back saying only "Picked up where you left
off." The sentence appears only after the user taps Continue and the same check refuses again. The
record has no field for it, so nothing on that screen can be stale - this is a missing sentence, not
a false one.

**Open.** Persisting the reason (or at least the storage and thermal kinds) with the record is the
fix; it is a `BatchQueueRecord` change and so wants its own round.

### RR4 — [P2] "Nothing was lost." on a paused screen that knew an original might already be deleted
`BatchQueueRecord` (`.deleting` → `.uncertain`); `BatchViewModel.deletionReport`; the paused screen

A user whose app was killed at Photos' delete prompt relaunched to "Paused. Nothing was lost.",
resumed, and learned only at the very end that an original might be gone.

**Fixed in round 20**, together with the deletion audit's DEL3: the paused screen's headline and its
new settled-originals note both read the deletion report.

### RR5 — [P3] A queue that cannot be read is indistinguishable from no queue, and says nothing
`VideoShrink/Services/BatchQueueStore.swift` (`load()`); `restoreQueue`

A missing file, an undecodable one, a version mismatch and an empty queue all return nil, so the
user meets the ordinary start screen - exactly like someone who never ran anything. Nothing is
deleted (a delete still needs a receipt and a fresh look), so the loss is the run's bookkeeping and
the mid-save question. The unreadable record is not cleared either; it stands until the next run's
first checkpoint overwrites it.

**Open.** `load()` should distinguish "absent or empty" from "present but unusable" and let the
launch say so once, in the existing `queueWarning` wording, without claiming to know what it held.

### RR6 — [P3] A video whose outcome is unknown counted as "finished", on the screen and in the rule that decides the flow may be left
`VideoShrink/Models/BatchModels.swift` (`isFinished`); `BatchViewModel` (`canLeaveFlow`); the paused
screen

A run of one saved, one flagged and one waiting read "2 of 3 finished. Copies already saved are in
Photos." - and the same count decided `canLeaveFlow`, so the batch flow could be left with the
question unanswered, which is the first step of RR2's route.

**Half fixed in round 20**: the paused screen now counts the copies it can account for and names
the ones still to look at. Whether an unanswered flag should count as work in flight for
`canLeaveFlow` is **open** and belongs with RR2.

## Checked and correct — do not re-walk

- **Killed during a download, mid-export or mid-verification.** In-flight stages persist as
  running, `reconcile` maps them back to waiting, and the dead run's partial export is swept before
  the record is read. No stored path is ever read back.
- **Killed mid-save, both windows.** The saving state is on disk before Photos is asked, carrying
  the sizes the run measured and, once Photos returns, the copy's identity. Finding the copy forbids
  another save; concluding "no copy" requires the whole library to be visible; anything else stays
  the user's question. The settle path drops any inherited read-back, so finding a copy can never
  authorise a delete.
- **Killed during a deletion.** Intent is journalled before the call, a restored `.deleting` becomes
  uncertain, and the relaunch never re-offers that original.
- **A queue written by an older build** decodes into the legacy shapes and is handled conservatively.
- **Access changed between the interruption and the return**: a restored run whose access is gone
  moves to the recovery screen with the right wording, a device never asked is asked at the run's
  first read, and a restricted device is told the truth with no Settings route.
- **A queue that cannot be written** blocks every Photos mutation, and a save or delete Photos
  accepted is never repeated because its record could not be written.
- The pre-flight refusals survive the relaunch and are named again, so the drop from "I picked
  twenty" to "eighteen to go" still reconciles.
- A run with a waiting video cannot be walked away from into the one-video flow.

## Only a device could settle

- **Whether Photos ever commits a copy after the app is killed inside `performChanges`.** The whole
  mid-save question presumes it can. If it cannot, the flag is a permanent false alarm - harmless,
  but it would change how RR1 and RR2 should be worded.
- **The race under "no copy in Photos"**: one look after a relaunch cannot distinguish "no copy was
  written" from "Photos has not finished applying the change".
- **Whether the user can tell the two copies apart.** The copy is written with the original's
  filename and creation date, so "check Photos" asks the user to distinguish two assets the app
  deliberately made look identical.
- **The launch cost of the restore.** `restoreQueue()` runs inside the view model's initialiser on
  the main actor and takes one revalidation per saved item, each with two fetches - for an uncapped
  number of items. Whether that stalls the first frame on a large restored run is a measurement.
