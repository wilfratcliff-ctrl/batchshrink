# Audit of record — the physical-device plan, read against the app as it stands

Read-only audit performed on 2026-09-23, after round 24, against the tree at `356c3a3` (clean). Its
subject is `docs/PHYSICAL_DEVICE_TEST_PLAN.md`, the project's only instrument for everything source
read cannot decide: there is no device on this machine, and the CI gate that compiles the Swift has
been blocked since 2026-09-23 (it resets 2026-10-01), so a device-only claim has exactly one route to
evidence — a person with an iPhone following that plan.

**Nothing was run.** No gate was executed either, by instruction: another writer may be mid-edit, and a
half-written file would mislead. The last verified commit is `356c3a3`, and every quotation below is
from that tree.

**Line numbers are `356c3a3`'s.** While this audit was being written, a later round began editing
`BatchScreens.swift`, `ShrinkStyle.swift`, `BatchTests.swift`, `AGENT_LOOP.md` and
`docs/AUDIT_ACCESSIBILITY_RECHECK.md` — a pluralisation and announcement sweep. None of the strings
quoted below is among the ones that sweep changed, but the line numbers in `BatchScreens.swift` after
its first few hundred lines will have moved by the time a round acts on this. Read the strings.

**This is a finding list, not a list of fixes.** `AGENT_LOOP.md`'s backlog is the only place that
records status. The plan itself must not be edited by whoever reads this — it is a decision for the
round that rewrites it.

## What the plan was last read against

The plan says of itself, at line 7: "These are the round 8 to 19 changes that touch a step below".
That is the honest line, and it is the finding underneath most of the ones below: rounds 20 to 24
changed the same screens the plan's rows describe, and the plan's own list of what changed stops at
round 19. One of its five newest rows also describes the tree *before* the round that added it (D3),
which is the same mistake in a smaller place.

## Findings

### D1 — [P1] No case deletes an original, declines Photos' alert, or asks whether a batch delete is all-or-nothing
*A device-only behaviour the code rests on that the plan does not ask anyone to observe.*

The plan's only deletion rows are line 66 (the read-back row, "with deleting on, edit or remove a copy
in Photos before the deletion step"), line 75 ("With deleting on, edit or remove a copy in Photos
after its run, then confirm the original is kept and the reason is shown"), line 76 (failed queue
write, "the run stops before it … asks Photos to delete anything") and line 77 (`Original safety`,
"Check no item was moved to Recently Deleted"). **Every one of them is a case where nothing is
deleted.** No row asks the tester to accept a delete, to decline one, or to read what the run said
afterwards.

The app's deletion machinery is the one thing that destroys something the user cannot get back
outside Recently Deleted, and it now has one transaction with a user-facing alert: `deleteOriginals(afterRevalidating:)`
in `PhotoLibraryService.swift` calls `PHAssetChangeRequest.deleteAssets` inside `performChanges`, and
`BatchViewModel.flushDeletions()` wraps it in a `do`/`catch` whose catch is
`BatchFailureCode(PipelineError.normalize(error, fallback: .save))`, then
`deletionOutcomes[id] = .failed(code)` (`BatchViewModel.swift:1661-1664`). A declined alert and a real
failure therefore produce the same stored code, and the finished row renders every `.failed`
deletion as `" · original is still here"` (`BatchScreens.swift:1255`) — one sentence, no reason. That
is `DEL5`, still open in `docs/AUDIT_DELETION.md`, and **its whole resolution is a device question**:
whether PhotoKit answers a declined alert with `PHImageCancelledKey`-shaped cancellation, an
`NSUserCancelledError`, or a `PHPhotosErrorDomain` error decides whether one narrow case is enough or
a general "Photos refused" mapping is needed.

The same row is where the second device question in `AUDIT_DELETION.md` lives and the plan is silent
on it too: the app reports `.deleted` from the set it *asked about* (`for id in batch { if deleted.contains(id) … }`,
`BatchViewModel.swift:1649-1657`), not from what Photos reported removed, so whether Photos can commit
part of a batch is unobservable from source and untested by the plan.

What a person can actually do, and the plan should say: turn deletion on for one expendable video,
let it copy, then **decline** Photos' alert and record what the app says about that original; then do
it again and **accept**, and check Photos and Recently Deleted for that one original. The plan also
never warns that a deleting-mode run removes originals (see D7).

Confidence: high that no row exercises either path. The plan's rows were enumerated by string search
over the file; there is no other deletion case.

### D2 — [P1] Case 5 asks for an HDR result the app refuses to produce
*A plan step that no longer describes the code, and a claim that is untrue of the app.*

Line 25: "**Long 4K HDR video:** remain in foreground on power, preview and save only if verified and
smaller. Compare brightness, highlights, color, orientation, sound and end playback with the original.
Any washed-out image, unexpected SDR conversion or lost HDR behavior is a recorded feasibility
issue…"

An HDR original cannot be previewed, exported or saved. `AssetRules.unsupportedReason` returns
`"HDR videos aren’t supported yet."` (`AssetRules.swift:43`), and that answer is reached from the
media itself by `VideoVerificationService.readMetadata(_, refusingUnsupportedFormats: true)`
(`VideoVerificationService.swift:23, 52-54`), which is what both flows call to read the original. In
the batch flow the same fact is decided earlier still, while the user watches: the chosen-video
pre-flight read (`PhotoLibraryScanService.refusedByFormat(among:progress:)`) refuses it with that
sentence before the run begins.

So the tester following case 5 does not meet a washed-out copy; they meet a refusal, and the plan
never tells them that is the expected result. Line 85 makes the same claim twice over — "Phase 0
passes only when the iCloud retrieval → **smaller HEVC output** → verification → separate Photos save
path works… HDR, special formats and background behavior each need their own result" — and line 73
("Playback after import … inspect HDR and rotation") implies an HDR copy can exist.

This is the same class of staleness `AGENT_LOOP.md` already records against the backlog's N12 row,
where three agents wrote less than the app can do because a status line had gone stale. Round 11 moved
the refusal into the scan; the plan's change list (rounds 8 to 19) never mentions it.

Case 5 should become an HDR/ProRes **refusal** case: the tester chooses the HDR clip and records the
exact sentence and where it appears (the listing's refused list, the pre-flight read, or the run's row
for that video), in both flows. Lines 73 and 85 need the same correction. The "smaller HEVC output"
phrase is also no longer the only possible output: 720p is H.264 (`CopyResolution.hd720.codec`,
`VideoQuality.swift`), so a pass at 720p contradicts a Phase 0 criterion written to require HEVC.

Confidence: high.

### D3 — [P1] The one row about an unbounded retry loop describes the tree before the round that added it
*A plan step that no longer describes the code, and a claim stronger than what a tester would see.*

Line 68, in full: "The batch loop puts an item that failed as cancelled back on its waiting list when
the run is not stopping, **and nothing caps how many times it may come back there**… If the run keeps
returning to the same video, that is the failure this row exists to catch and **the number a cap
should be set from**."

The cap exists. `private static let cancelledRetryLimit = 2` (`BatchViewModel.swift:203`) is read at
`:1414` — a video PhotoKit cancels on its own waits again at most twice and is then persisted as
`.failed(.retrieval)`, in the retrieval's own sentence. `git log -S cancelledRetryLimit` shows both the
cap and this row arriving in the *same* commit, `c7af4fc` (round 16), whose own message names "a
cancelled item retried forever" as one of the things it fixed. The row was written from the
description of the bug, not from the tree the commit produced, and no round has read it since.

What is still device-only here is the question the rest of the row asks, and it survives the
correction: nothing else in the app can make PhotoKit report a cancellation under the plain
"not stopping" state, so whether that ever happens (memory pressure on a large original, the video
edited from another app mid-fetch, an original PhotoKit will not produce) is unobservable anywhere
but on a phone. The rewritten row should ask for that, plus what the item's row says after the cap
is reached — not for a spin count and not for "the number a cap should be set from".

Confidence: high on the cap and on the commit that introduced both.

### D4 — [P1] Nothing asks anyone to look in Photos for the copy a killed save may have made, and the one-video flow has no row at all
*A device-only behaviour the code rests on that the plan does not ask anyone to observe.*

Line 71 is the plan's whole coverage: "**Process termination** | Force quit during export, reopen and
check startup cleanup. Repeat during save: Photos may have committed despite no completion UI. A
stored queue flags a mid-save item rather than repeating it, and on the next launch the app looks for
the copy the record named and settles what it can … Record which of those two answers you got, and
whether anything was left as a question for you to check in Photos."

Three things are missing from it, and each is the observation a mechanism rests on:

- **The premise itself.** The row says Photos "may have committed" and then asks which *app* answer
  the tester got. The app's answer comes from the same look that the finding depends on
  (`BatchQueueReconciliation.midSaveFinding(receipt:lookup:wholeLibraryVisible:)`,
  `BatchViewModel.resolveMidSaveItems()`), so it cannot confirm the premise. Only a person counting
  the copies in Photos for that one video can say whether a transaction the process died inside ever
  leaves a copy behind. `docs/AUDIT_RESTORED_RUN.md` and `docs/AUDIT_SINGLE_VIDEO.md` both already
  list this as unsettleable anywhere else.
- **The third answer, and the screens that carry it.** The row names two answers. Round 23 made the
  question durable in its own right: `BatchQueueRecord.questions` (`BatchQueueRecord.swift:42`,
  `struct Question` at `:203`, kinds `unknown`/`limitedAccess`) is written by `openQuestionRecords` and
  read back in `restoreQueue()` (`BatchViewModel.swift:1886-1890`), and a question outlives the run
  that raised it — ending the run writes the questions alone through `endRunRecord(with:)`
  (`BatchViewModel.swift:1816-1824`). The sentences a person meets are
  `"BatchShrink asked Photos for a copy of this video and never learned whether it was made. Look in
  Photos: if there are two copies, that copy was made; if there is one, it wasn't."`
  (`MidSaveFinding.unknownQuestion`) and the card headed `"Left out of Select all"`
  (`BatchScreens.swift:494-502`, heading at `:615`). None of that appears in the plan.
- **The one-video flow, which is the flow the plan's own first five cases use.** That flow has no
  queue, so round 24 gave it a journal in the shared store: `CompressionViewModel.save()` writes
  `history.noteUnconfirmedSave(identifier:)` **before** `photos.save` (`CompressionViewModel.swift:223`)
  and clears it only when Photos hands back an identifier (`:231-245`); the batch flow adopts every
  entry at launch and on every scan (`BatchViewModel.adoptUnconfirmedSaves()`, `:1851`). Killing the
  app in the window the flow's own screens describe — the confirmation says
  `"Saving cannot be cancelled once it starts"` and the bar says `"Please wait for Photos to confirm."`
  — is the single most likely way a person will meet the whole mid-save area, and the plan never asks
  them to try it. The round-24 record itself says this journal is the weaker of the two, because its
  durability rests on `UserDefaults` having reached disk before the process died: a device is the only
  place that can be answered.

Confidence: high on the code paths and on the plan's silence; the plan's row was read in full.

### D5 — [P2] The one-video flow's iCloud sentence is never asked about
*A device-only behaviour the code rests on that the plan does not ask anyone to observe.*

The flow's retrieving screens say `"Bringing it from iCloud."` and
`"Downloading the full original before compression."` when `retrievingFromCloud` is true
(`ShrinkScreens.swift:48, 62`), and it is set from inside PhotoKit's own progress callback —
`self.retrievingFromCloud = true` in the closure passed to `photos.retrieve`
(`CompressionViewModel.swift:140-146`). If PhotoKit reports progress for a video that is already on
the iPhone, the app tells the user it is downloading a local original.

The plan's nearest text is the tester-directed aside at line 53, "Never label a local retrieval as a
proven download", and case 2's "Look for PhotoKit download progress" — both about what the *tester*
records, not about what the *app* says. `docs/AUDIT_SINGLE_VIDEO.md` records this as its first
device-only item. The row the plan needs is one line long: run a locally stored video through the
one-video flow with the network off, and write down which retrieving sentence appears.

Confidence: high.

### D6 — [P2] "Save transaction" names a control the batch flow does not have
*A plan step that no longer describes the app.*

Line 62: "**Save transaction** | Double tap Save; only one request. Cancellation is unavailable
during save. Confirm no cleanup before Photos finishes. Revoke permission before Save to confirm
readable failure."

There is no Save control in the batch flow. A batch run saves each copy inside the run, with no user
tap anywhere in the sequence (`BatchViewModel.process(id:)` calls `photos.save` after the read-back
decision), so `Double tap Save` cannot be carried out there at all, and the row never says which of
the two flows it is about. In the one-video flow the
control is `"Save copy to Photos"`, and tapping it opens a `confirmationDialog` titled
`"Save a separate copy?"` whose action button is the same string (`SingleVideoFlow.swift`) — so a
"double tap Save" hits a dialog, not two requests, and the code's real guard is
`move(to: .saving)` before the first `await` plus `canSave` going false (`CompressionViewModel.swift:200-203`).
The row's last sentence is sound and testable, and the middle one is confirmed by the screens: during
`.saving` the bar draws `"Saving your copy…"` / `"Please wait for Photos to confirm."` instead of any
cancel control, and the batch's `stopActiveWork()` returns early while an item `isSaving`
(`BatchViewModel.swift`).

The row should be split by flow: the batch's part is "start a run and confirm the app never offers to
cancel or clean up while a copy is in Photos"; the one-video part is "confirm the dialog cannot be
made to submit two saves".

Confidence: high.

### D7 — [P2] Ordering, safety and reset: the irreversible cases are in the middle, and the plan's safety promise is no longer true
*Ordering, safety and cost.*

- **No reset step exists anywhere in the plan.** Searching the file for "reset", "reinstall",
  "uninstall" and "erase" finds nothing; "restart" appears once, in the `Lock/Home/app switch` row,
  and "fresh install" / "clean install" appear only in the introduction bullet and the `Permission
  not determined` row, where they mean "get past the introduction", not a procedure. After a
  force-quit mid-save the app is *not* in its starting state:
  it holds a queue record, a set of questions, and a history store with `createdCopyIdentifiers` and
  `unconfirmedSaves` (`ShrinkHistoryStore.swift`). Case 1's instruction "Confirm exactly one new
  Photos item appears only after Save" is already unverifiable in a later case, because earlier cases
  left copies in Photos. The plan needs an explicit between-cases reset: what to delete from Photos,
  whether to clear Recently Deleted, and that a fresh queue means reinstalling.
- **The kill-inside-a-save case sits in the middle of the matrix.** `Process termination` is line 71
  of 79, ahead of Thermal, Playback, Metadata, `Copy changed after a run`, `Failed queue write`,
  `Original safety`, Accessibility and Cleanup. Force-quitting mid-save can leave a real copy behind
  and permanently changes what a later "exactly one new item" check means. It belongs with the
  deletion cases at the end, after the reset step, not before the cases that assume a clean library.
- **`Original safety` is written as a case, but it is a per-case before/after.** Line 77 says
  "Before/after compare original item, dimensions, duration, visual quality and edit state." A tester
  who reaches it last has already lost the "before". It needs to be a line attached to every case that
  creates or removes anything, and the row itself should keep only the cross-cutting checks.
- **The plan's safety promise is no longer true.** Line 3: "No test instructs you to remove your
  original media." Line 75 says "With deleting on, edit or remove a copy in Photos after its run."
  Turning deletion on requires a destructive confirmation in the `Originals` sheet and again in the
  run-start dialog — but a batch run in either deleting mode *does* delete every original whose copy
  survived the tap-time check. A tester following line 75 with more than one video in the run removes
  originals that the case never intended to remove, and the plan never warns them. Line 75 also needs
  to say what to do afterwards (Recently Deleted, 30 days) and that the third mode,
  `afterEachCopy`, deletes as it goes rather than at the end.

Confidence: high on the ordering and on the strings; medium on how much of line 75 a given tester
would carry out as written, since the plan's preamble does say to use expendable clips.

### D8 — [P2] Two instructions a person cannot carry out, and one that times something smaller than what they watch
*A claim stronger than the observation would support, and a step that is not an instruction.*

- **Line 64, free-space gate:** "Then record the two facts the pre-retrieval check depends on:
  whether retrieving an original that is already on the iPhone writes into the app's own temporary
  workspace, and whether PhotoKit's own out-of-space failure arrives before or after bytes are
  transferred." The first fact is a sandbox inspection, and the plan's only mention of sandbox
  tooling is in `Cleanup/privacy` ("where development tooling permits"). The second is not something a
  person can watch. What a person *can* do with the same clips is cheap and should be written instead:
  record the iPhone's free space (Settings → General → iPhone Storage) before and after retrieving a
  known iCloud original, and before and after the export, and record whether the refusal's own
  sentence names the step.
- **Line 66, read-back:** "time the read-back of each, to see how long Photos takes to hand back a file
  written moments earlier and whether 10 s is ever near." The step a person actually watches can be up
  to three bounded reads in a row: `confirmReadBack(for:createdIdentifier:expected:)` tries three
  times, each `localFileURL` bounded by `PhotoLibraryService.copyReadBackTimeout` (10 s), with 400 ms
  sleeps between (`BatchViewModel.swift:1543-1558`). Timing "the read-back of each" therefore measures
  up to ~31 s and cannot say whether the 10 s bound was ever reached. The row should ask for the
  whole step's duration *and* whether the row ended as `"Saved · read back from Photos"` or
  `"Saved · Photos hasn’t handed it back yet"` (`BatchScreens.swift:1237-1238`) — the second string is
  the one that shows the bound fired, and it is named nowhere in the plan.

Confidence: high on both code facts; the first is a judgement about what a non-developer can do.

### D9 — [P3] The larger-copy question and the pause reasons are asked about the wrong way round
*Device-only behaviours the plan only half-asks about.*

- Line 56: "**Low resolution/already HEVC** | Some files may grow or stay equal. Exact negative/zero
  savings must display and Save must be disabled. Discard removes only the temporary copy." This
  describes the one-video flow only. In the batch the same file produces a row reading
  `"This copy wasn’t smaller than the original, so it wasn’t saved."` (`BatchViewModel.swift:1387`)
  and no Save control at all. The device question the code rests on — whether an ordinary original
  ever produces a copy bigger in bytes, which decides whether that branch is ever seen
  (`docs/AUDIT_SINGLE_VIDEO.md` lists it) — is not asked; the row asks only about the display. It
  should ask the tester to record, for each file, original bytes, copy bytes and which of the two
  endings appeared.
- Lines 69, 70 and 72 cover interruption, backgrounding and heat, but none asks the tester to *read
  the app's own reason line*. The paused screen now prints `BatchPauseReason.explanation`
  (`BatchModels.swift:26-36`): `"BatchShrink paused when the app left the foreground."`,
  `"Your iPhone got warm, so BatchShrink stopped. Let it cool, then continue."`, and the storage
  refusal naming the figure it asked for. That sentence is the evidence, it is free, and the plan
  never names it. `DeviceConditions.pacing()` only stops on `.critical` thermal state, so a tester who
  is told never to overheat the phone may never reach the thermal pause at all — which is exactly why
  the row should say "if a run stops on its own, record the paused screen's reason line verbatim".
  Low Power Mode is separately testable and separately unmentioned: the working screen says
  `"Keep BatchShrink open. Low Power Mode is on, so this takes longer."`
  (`BatchScreens.swift:993`), and the keep-screen-awake setting says
  `"Only while a batch is running. It uses more battery and the phone runs warmer."`
  (`ShrinkScreens.swift:285`)

Confidence: high on the strings; the thermal reachability point is a source fact
(`DeviceConditions.pacing`), not a measurement.

### D10 — [P3] "Failed queue write" names a state a plan follower cannot create, while the record notice they *can* meet has no row

Line 76: "**Failed queue write** | Make the queue file unwritable during a run." The queue lives
inside the app sandbox (`FileBatchQueueStore`, `BatchQueueStore.swift`), so nothing on a phone makes
one file unwritable — but the *state* is reachable without development tooling, because a full disk
fails the atomic write, which is what the `Low storage` and `Free-space gate` rows already arrange.
The row should be tied to those rows rather than left as a step of its own.

Round 23 added the sibling case that a person can meet on an ordinary launch but the plan never
mentions: a queue file this build cannot read. `FileBatchQueueStore.hasUnreadableRecord()` and
`restoreQueue()` set `queueReadWarning` (`BatchViewModel.swift:1870`), drawn under the heading
`"A saved run couldn't be read"` on the start and selection screens (`BatchScreens.swift:50-53`,
`:511-513`). It is not a device-only behaviour — it can be reasoned about — but it is a *user-facing*
notice no case asks anyone to see, and the wording is short enough to read aloud and check.

Confidence: high.

### D11 — [P3] The build attribution names a build that does not exist
*A plan statement that no longer matches the record.*

Line 5: "Build 10 (`0.1.0`) is the last build known to have run anywhere… The first build to carry
that work is `0.1.0` (build 11)". `app.json` says `"version": "0.1.0"`, `"buildNumber": "11"`, and
`docs/RELEASE_10.md` records that build 10 is the last uploaded and that "the next new upload should
use 11 or later" — so build 11 has never existed. The sentence reads as though build 11 were already
the first build carrying rounds 1-19, when in fact whoever runs this plan will install the first build
carrying rounds 1-*24*, and the work the plan's "Record: app version/build" line asks for is the only
thing that will say which. It should read as a commitment about the *next* upload, with the commit or
date beside it, exactly as `docs/RELEASE_10.md` does.

Confidence: high.

## Checked and sound — do not rewrite

Each of these was read against the tree rather than assumed, and the plan's words are right as they
stand.

- **The introduction.** Three pages, `Continue` then `Get started`, `Skip` in the top corner
  (`ShrinkOnboarding.swift`). The plan's bullet is accurate; the only addition worth making is the
  `Back` control on pages two and three.
- **Access is asked for when the user first needs to read, not at launch.** `LibraryChangeMonitor`
  refuses to touch `PHPhotoLibrary.shared()` while the status is `.notDetermined`
  (`observeChangesIfReadable()`), the one route to the system prompt is
  `PhotoLibraryService.requestAccess()`, and the two callers are the scan and `CompressionViewModel.chooseVideo`.
  The plan's first bullet and its `Permission not determined` row ask for exactly the right two
  halves. Its later `accessForRun()` is the same rule for a queue restored onto a phone that never
  granted access.
- **Every control name the plan lists exists with that string:** `Choose a video`, `Choose another video`,
  `Find my videos`, `More actions`, `Shrink more videos`, `Done`, and the three menu items.
- **Two temporary directories**, `VideoShrink-Phase0` and `VideoShrink-Phase0-batch`
  (`TemporaryFileManager.swift:16-17`).
- **The space gate's arithmetic.** `DiskHeadroom.bytes(_:copies:)` has no production caller — every
  call site in both view models is `neededToWrite(_:)` (`rg DiskHeadroom\.bytes` finds only
  `ModelCoverageTests.swift` and `ServiceCoverageTests.swift`), and the gate fires three times per
  flow, before the retrieval, before the export and before the save. The plan's paragraph on this is
  correct, including that the reserve has never been measured on a device and that 256 MB is the
  figure to settle.
- **The three bounded reads, as facts.** `PhotoLibraryScanService.onDeviceRequestTimeout` is 10 s and a
  video it gives up on is left unread, not refused (`PhotoLibraryScanService.swift:68`, `:428-450`);
  `PhotoLibraryService.copyReadBackTimeout` is 10 s and a read that is given up leaves the item saved
  and never offered for deletion (`:300`, `confirmReadBack`'s `outcome = .unavailable` default);
  `scrubRequestTimeout` is 20 s and a given-up wait reaches the sheet's failure line
  (`:309`, `resolvePlayerItem`). Only the read-back row's *timing instruction* is wrong (D8).
- **The "accessible-asset error".** `PipelineError.assetUnavailable` is
  `"This video is outside the Photos access granted to BatchShrink. Add it to your allowed videos in
  Settings, then try again."` — the sentence the `Limited, disallowed item` row expects, reached in
  the one-video flow when the system picker returns a result with no `assetIdentifier`
  (`VideoPicker.swift`).
- **Refusal and restriction are different sentences**, and the restricted one deliberately sends
  nobody to Settings because Photos is not on the app's Settings page while a restriction is on
  (`PipelineError.accessSentence(restricted:)`). The plan's `Denied/restricted` row conflates the two
  but does not say anything false.
- **The multi-track claim in the `Audio` row.** `"A file with more than one audio track - or more than
  one video track - is refused when the run opens the original, not at the listing or in the pre-run
  read"` is still true: the pre-flight read only decides HDR and ProRes
  (`PhotoLibraryScanService.refusalReadingFormats(of:)`), while the track-count refusal comes from
  `VideoVerificationService.readMetadata` under `inspect`.
- **The `Metadata` row's list of what is and is not copied.** `save(videoAt:identity:)` sets
  `creationDate`, `location`, `isFavorite`, `isHidden` and `originalFilename`; nothing copies album
  membership, captions, keywords or ratings.
- **`Read-back that never answers`' central claim** — a copy the app could not check is never
  evidence enough to remove an original — holds for every path that reads a receipt.
- **The one-video flow cannot delete anything**, so every screen promising the original stays is true.

## What only the plan and a device can settle

Written as the questions a rewritten plan has to ask, one per line, each of which source read cannot
answer. These are the same items `docs/AUDIT_DELETION.md`, `docs/AUDIT_RESTORED_RUN.md` and
`docs/AUDIT_SINGLE_VIDEO.md` carry, listed here because the plan is the only instrument that can
answer any of them.

- Whether Photos ever commits a copy when the process dies inside `performChanges` — the premise of
  `.needsCheck`, the stored questions and the one-video journal (D4).
- Whether Photos calls the retrieval progress handler for a video that is already on the iPhone, which
  decides whether `"Bringing it from iCloud."` is ever false (D5).
- Whether `request.placeholderForCreatedAsset?.localIdentifier` is ever nil
  (`PhotoLibraryService.swift:174`), which decides whether the round-24 branch that records the
  original as shrunk instead of asking a question is ever seen (D4). No case asks for it.
- Whether a declined Photos delete confirmation surfaces as a cancellation or as an error, and
  whether a batch delete can commit part of its set (D1).
- Whether an ordinary original ever produces a copy bigger in bytes, which decides whether the skip
  branch and its sentence are ever seen (D9).
- Whether `UserDefaults` has reached disk before the process dies inside the one-video flow's save —
  the durability the round-24 record calls the weaker of the two journals (D4).
- Whether the app's own copy is distinguishable to the user, since it keeps the original's filename
  and creation date; "look in Photos and count the copies" is only an instruction if it is.
- What a full batch does on a battery-constrained phone: Low Power Mode on, keep-screen-awake on, and
  whether any pause reason the app can print is reached on a warm but not deliberately overheated
  device (D9).
- The launch cost of `restoreQueue()`, which runs inside the view model's initialiser on the main
  actor with an uncapped number of revalidations — `docs/AUDIT_RESTORED_RUN.md`'s last device item.

## The smallest set of changes that would make the plan cover what the app rests on

In the order that spends the tester's session best. Nothing here removes a case.

1. **Re-date the plan's own change list** from "round 8 to 19" to the current round, and read the six
   bullets under it against the screens again — several of them describe a step that rounds 20 to 24
   moved.
2. **Turn case 5 into an HDR/ProRes refusal case** and correct lines 73 and 85, including that a 720p
   pass produces H.264 and Phase 0's "smaller HEVC output" is no longer the only shape.
3. **Rewrite line 68** to the cap and to the observation that survives it.
4. **Split `Process termination` into a batch case and a one-video case**, add the third answer and the
   screens that name it (`"Left out of Select all"`, the paused screen's `To look at in Photos` rows,
   `"A saved run couldn't be read"`), and put the sentence a person must act on into the row: open
   Photos and count the copies for that one video.
5. **Add a deletion section** — accept one confirmation, decline another, then check Photos and
   Recently Deleted for that one original and record the run's own row and note — and say plainly
   that a deleting run removes originals, which mode does it as it goes, and where they go.
6. **Add one row for the local-original wording** in the one-video flow with the network off.
7. **Split line 62 by flow** and drop the "double tap Save" instruction the batch flow cannot follow.
8. **Add a reset step between the creating cases and the irreversible ones**, and re-order so the
   deletion and kill-inside-a-save cases come last, after it.
9. **Make `Original safety` a per-case before/after line** rather than a case near the end.
10. **Fix the two un-actionable instructions**: line 64's sandbox facts become a free-space figure a
    person can read in Settings, and line 66 times the whole read-back step and records which of the
    two strings the row ended on. Tie line 76 to the full-disk rows.
11. **Add a Low Power Mode line and ask for the paused screen's reason line verbatim** on any run that
    stops by itself.
