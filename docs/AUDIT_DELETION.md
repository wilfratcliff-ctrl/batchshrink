# Audit of record — the deletion journey

Read-only audit performed on 2026-09-23, round 20, against the tree at `1bdd009`. It traced the one
feature in this app that destroys something the user cannot get back except from Recently Deleted:
how deletion is offered and switched on, the confirmation, the wait, the flush, the outcome, the
receipt, and the way back.

**This is a finding list, not a list of fixes.** `AGENT_LOOP.md`'s backlog carries the same `DEL`
IDs and is the only place that records status. Line numbers move with every round; read the code.

## Findings

### DEL1 — [P1] A later run deleted an original from an earlier one, and nothing could account for it
`VideoShrink/Presentation/BatchViewModel.swift` — `beginRun(with:)`, `reset()`, `flushDeletions()`,
`deletionReport`

Every per-item dictionary that drives deletion (`copyEvidence`, `readBackOutcomes`,
`revalidationOutcomes`, `deletionOutcomes`, `midSaveFindings`, `storageDemands`, `attemptedSaves`)
and the pending transaction itself (`deletionBatch`) survived a run boundary. `reset()` cleared the
dictionaries but not the batch; `beginRun(with:)` cleared only `cancelledAttempts`. And
`flushDeletions()` asked no question about the mode, so it deleted whatever the batch held as long
as receipts and looks held - the mode gate lived only in the code that *queues*.

Route, using only ordinary controls in "Delete as it goes": run three videos, Pause after two
copies are saved, "Finish with what's done" (which sets `.finished` directly, because there is no
run task to end), then "Shrink more videos" and run two more. The new run's tail flushed the batch
from the old one, so Photos asked to delete an original the current run never named, and the
finished note counted it. If the user had turned deletion off in between, it happened in a run whose
own setting said deleting was off. The durable record carried no trace: `persistQueue()` writes only
each item's state.

The destructive gate itself held - a receipt plus a fresh look at both assets immediately before
the transaction - so this was never a deletion of something unverified. It was a deletion outside
any mode the user could see, attributed to a run that did not make it.

**Fixed in round 20** by clearing the run's own facts in `beginRun(with:)` and the batch in
`reset()`, plus a guard in `flushDeletions()` that refuses to flush outside a run whose own
snapshot mode deletes originals. Two cases pin it.

### DEL2 — [P2] The confirmation named a count only the tap-time check decides, and every original that survived was explained as "kept" with no reason
`VideoShrink/Presentation/BatchScreens.swift` (`BatchFinishedRow.detail`, the delete dialog);
`BatchViewModel.swift` (`deletableItemIDs`, `refreshDeletionLook`); contradicting
`docs/BATCH_PHASE.md`

The dialog reads "Delete N originals?" from `deletableItemIDs`, which is built from the stored
revalidation look - refreshed at five moments and never on returning to the foreground, so a user
who deletes a copy in Photos and comes back sees the old count. The tap re-looks and can delete
fewer, recording each refusal as `DeletionOutcome.skipped(reason)`.

The row then rendered `" · original kept"` for every one of those refusals and **threw the reason
away**: the stored sentence had no reader anywhere in the app. A copy that had changed, a copy that
was gone, an original Photos could no longer find and a withdrawn permission all read the same.
`docs/BATCH_PHASE.md` promises the opposite - "the reason appears in the run's list".

**Fixed in round 20** for the reason, which is now rendered: `" · original kept. <reason>"`. The
stale count is **open**: the dialog is a ceiling, not a promise, and it should either say so or be
refreshed on returning to the foreground.

### DEL3 — [P2] The paused screen said nothing about originals already deleted
`VideoShrink/Presentation/BatchScreens.swift` (the paused screen)

The only place a mid-run deletion appeared was a row on the working screen. The paused screen drew
no deletion line of any kind, and its headline read "Paused.\nNothing was lost." on a run that had
deleted originals - the app's one irreversible action, with the return path being exactly where its
journalled intent exists to be read.

**Fixed in round 20**: the headline is mode/report aware, and the screen draws a settled-originals
note whenever a deletion has happened or an original's fate is unknown.

### DEL4 — [P2] In "delete at the end", the finished screen returned no deletion line while the confirmation was still waiting
`BatchScreens.swift` (`BatchScreen.deletionNote`)

The note returned nil whenever the mode deletes and candidates were ready - precisely the state the
mode promises ("You confirm once at the end"), and the state "Finish with what's done" produces.
Nothing substituted for it.

**Fixed in round 20**, as a symptom of a worse cause: `finishNow()` from a paused run never took the
fresh look the offer depends on, so `deletableItemIDs` came out empty, the "Delete N originals"
control was never drawn at all, and the confirmation quietly became originals that were never
deleted. `finishNow()` now takes the same one look per candidate the run's own tail takes, and the
note names the waiting confirmation.

### DEL5 — [P3] A cancelled Photos confirmation was stored as a save failure
`VideoShrink/Services/PhotoLibraryService.swift`; `BatchViewModel.flushDeletions()`'s catch;
`PipelineError.normalize`

`performChanges` throws when the user declines Photos' own alert. The catch normalises any error
with a `.save` fallback, so a cancel becomes `code = .save` on every item in the group - a code whose
only sentence is about a save. The row shows " · original is still here" under "Needs attention", so
a user who tapped Cancel sees a failure with no explanation, and a real failure looks identical.

**Open.** The fix depends on which error PhotoKit actually returns for a declined alert - see the
device questions below.

### DEL6 — [P3] "Original protected" was the working screen's shield line in the modes that remove originals
`BatchScreens.swift` (`BatchProcessingScreen`)

Unconditional on the mode, and shown while the card beneath it drew rows saying "original deleted" -
the same class as round 10's fix to the pre-run dialog.

**Fixed in round 20**: the line comes from the mode, and the deleting modes say what the app does
first ("Copy checked first") rather than promising the original stays.

### DEL7 — [P3] A deletion left "uncertain" is a dead end with advice and no control behind it
`BatchViewModel.swift` (`deletionDecision`, `requeueUncertain`); `BatchScreens.swift`

An interrupted delete comes back `.uncertain` and is excluded from `deletableItemIDs` for good. The
finished screen advises checking Photos, but the only "I checked Photos" control requeues
`needsCheck` items, never a deletion-uncertain one. If the user looks and finds the original still
there, no control can delete it, and re-running that video by hand makes a second copy.

**Open.** It needs either an action gated the way `requeueUncertain` is, or a sentence saying plainly
that the app will not try again.

## Checked and correct — do not re-walk

- **The gate holds for every deletion.** The raw transaction is deliberately not a requirement of
  `PhotoLibraryServing`, so a caller holding the protocol cannot submit one; its only in-app caller
  re-looks at every candidate immediately before the transaction. Nothing reads a receipt alone.
- A missing, malformed or pre-receipt queue can never authorise a delete.
- **Nothing is deleted twice**, including a save or a delete that Photos accepted but whose answer
  could not be written down.
- A copy Photos cannot hand back is never evidence, and a restored mid-save item drops any inherited
  read-back.
- The receipt is re-earned, never inherited: a fresh attempt clears it up front and writes it the
  moment Photos names the copy.
- The mode is snapshotted at run start, and both deleting modes stay off until a destructive
  confirmation in the sheet.
- Grouping is as documented: five at a time, the remainder at a flush, one transaction for "delete
  at the end", and the sheet says Photos asks per batch and cannot be pre-authorised.
- The pre-run confirmation is mode-aware and names Recently Deleted.
- No screen claims space is reclaimed by a delete.
- The one-video flow cannot delete anything at all.
- Under limited access a candidate outside the grant reads as missing and keeps its original.

## Only a device could settle

- **What Photos returns when the user declines its own delete alert.** Whether it is a
  `PHPhotosErrorDomain` cancel, an `NSUserCancelledError` or something else decides whether DEL5
  needs one narrow case or a general "Photos refused" mapping. The device plan never covers
  declining the alert.
- **Whether a deleted transaction is all-or-nothing.** The app reports `.deleted` from the set it
  *asked about*, not from what Photos reported removed. If Photos can commit part of a batch, the
  app would report a deletion that did not happen and never offer that original again.
- **The receipt's byte clause.** It compares sizes only when both looks produced one, and that
  needs an API the project's own record calls iOS 27 - so on the deployment target it is inert and
  the "changed?" answer rests on duration, dimensions and dates.
- **What the screen looks like during the alert.** In "delete as it goes" the working card reads
  "Saving to Photos" while Photos' delete prompt is up.
