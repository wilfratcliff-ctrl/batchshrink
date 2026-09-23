# Audit of record - the test suite itself

Read-only audit performed on 2026-09-23, after round 27, against the working tree at `251d27f`.
Its subject is the only proof this project will have when the CI gate returns on 2026-10-01: the
test cases themselves, in `VideoShrinkTests/` and `VideoShrinkUITests/`. This is the suite whose own
defects four rounds have already had to clean up - the three vacuous cases round 14 deleted, the
unreachable assertion round 20's fault-injection harness found, the 60 ms signal round 22 caught,
and round 26's case that asserted a whole set was empty while its message defended one member of it.

**Nothing was executed.** There is no Swift compiler and no XCTest runner on this machine, so every
judgement below is a read of the case and of the code it drives. Two read-only gates were run and
both passed: `npm run validate:native` ("38 app Swift files; 407 XCTest cases present") and
`scripts/swift-call-site-check.mjs` (52 files, 0 findings). `prove:guardrails` was deliberately not
run - it copies the tree seventy times and another writer is mid-edit. At the time of reading,
`git status` showed `AGENT_LOOP.md`, `VideoShrink/Presentation/ShrinkScreens.swift`,
`VideoShrink/Presentation/VideoScrubSheet.swift`, `VideoShrink/Services/PhotoLibraryService.swift`,
`VideoShrinkTests/BatchTests.swift` and `docs/AUDIT_PREVIEW.md` modified, so this is a read of a tree
with round 27's work in flight, not of a commit.

**The count.** 407 cases in `VideoShrinkTests/` (the number the gate prints) and 1 in
`VideoShrinkUITests/LaunchSmokeUITests.swift` - 408 case bodies read, one file at a time, end to end.
The brief says 406; the extra one is `testAPlayerItemThatIsNotReadyIsAnsweredAsOneThatCannotPlay`,
which is uncommitted round-27 work, and it is finding 6 below.

**This is a finding list, not a list of fixes.** `AGENT_LOOP.md`'s backlog is the only place that
records status. Line numbers move every round; the quoted strings and the mechanism are the durable
part.

## Summary

| # | Priority | Case | File | Defect class |
|---|----------|------|------|--------------|
| 1 | P1 | `testLiveStatesRoundTripThroughTheStoredForm` | `BatchQueueTests.swift:39` | an assertion that cannot fail: `live(x) == live(x)` |
| 2 | P1 | the whole of `FlowRoutingTests` (8 cases) | `FlowRoutingTests.swift:19` | the rule's only input is re-implemented in the test, so the pair can drift |
| 3 | P1 | the mid-save question sentences | `BatchQueueRecord.swift:302,305` | a user-facing instruction with no case asserting its text |
| 4 | P2 | `testEveryFailureTheUserSeesHasItsOwnSentence` and the cases around it | `ModelCoverageTests.swift:579`; `PipelineError.swift` | the failure vocabulary is pinned for shape, never for content |
| 5 | P2 | `testTheLiveOverloadsReportWhatTheSystemSays` | `DeviceConditionsTests.swift:22` | cannot fail in the state the runner is in |
| 6 | P2 | `testAPlayerItemThatIsNotReadyIsAnsweredAsOneThatCannotPlay` | `BatchTests.swift:518` | passes against a stub that always answers `false` |
| 7 | P3 | `testCorruptContainerFailsRealVerification` | `RulesTests.swift:144` | asserts less than its name: "not a cancellation" |
| 8 | P3 | `testARowIsIdentifiedByTheVideoItIsWorkingOn` | `ModelCoverageTests.swift:802` | asserts a stored property's passthrough |

Cases with a named defect: 14 of 408 (the 8 in `FlowRoutingTests`, and 6 individual cases). The
remaining 394 read sound; the thin-but-honest ones are named in their own section rather than left
for a future round to rediscover.

## Findings

**What has happened to each finding.** The sections below are the audit as performed, against
`251d27f` plus the uncommitted round-28 work; this table is the map, because findings 1 to 4 and 7 and
8 were fixed in the round that read them.

| # | Status |
|---|--------|
| 1 | **Fixed in round 28.** The self-comparison is gone. The case now asserts the round trip in both directions for the six pairs that survive one - which is what the line was for - and asserts, for the five deliberately coarse ones, the state a restored queue actually comes back as: everything in flight waits again, and a `.saving` item comes back as a question |
| 2 | **Fixed in round 28 with a stronger case than the audit asked for.** Rather than build a second model fixture inside `FlowRoutingTests`, two cases in `PipelineTests` (where the real `CompressionViewModel` fixture already lives) drive the model to `.choosing` and to `.readyToSave` and hold the rule to the model's own `canChoose`. A change to the model's stage list now fails a case rather than silently passing eight |
| 3 | **Fixed in round 28**: `testTheQuestionsTheAppAsksCarryTheInstructionTheyExistFor` asserts both sentences' instruction as text, and that the two are different questions. Every other case about them compared a constant with itself |
| 4 | **Fixed in round 28**: `testTheSentencesThatCarryAnInstructionAreTheOnesTheyClaimToBe` pins `.save`'s "Inspect Photos before retrying" and its "extra copy" clause, `.libraryScan`, `.retrieval`, `.cancelled`, and all three `DeletionMode.detail` strings - so the confirmation case's substitution stops being a hole |
| 5 | **Recorded in round 28**, not fixed: the case now says what it cannot catch on a runner, which is the honest form of the audit's own recommendation. Live thermal state and Low Power Mode cannot be produced on a CI machine |
| 6 | **Recorded in round 28**, not fixed for the same reason: a stub returning false still satisfies the timeout case, and the half that would distinguish it needs real media. The case now says so and points at `docs/SIMULATOR_PIPELINE_PLAN.md`, which is where a generated fixture would live |
| 7 | **Fixed in round 28**: the corrupt-container case still does not pin one exact error - different OS releases reject at different points - but it now asserts the refusal arrives as a `PipelineError`, which is what its name claims, rather than merely "not a cancellation" |
| 8 | **Fixed in round 28.** The case now pins the *identity convention* the app depends on rather than the passthrough: a row's identity is the video's own identifier - every lookup in the model pairs that way - and two videos cannot collide. Adding a model identifier of its own would fail it |

### 1 - [P1] `testLiveStatesRoundTripThroughTheStoredForm` asserts a value equals itself

`VideoShrinkTests/BatchQueueTests.swift:22-45`, the loop at 37-40:

```swift
for (live, stored) in cases {
    XCTAssertEqual(BatchQueueReconciliation.persisted(live), stored)
    XCTAssertEqual(BatchQueueReconciliation.live(stored), BatchQueueReconciliation.live(stored))
}
```

`BatchQueueReconciliation.live` is a pure function of its one argument
(`VideoShrink/Models/BatchQueueRecord.swift:416-426`), so the second line compares a value with the
result of calling the same function on the same input twice. **It is true whatever the code does.**
It cannot fail for any definition of `live`, including one that returns `.pending` for everything.

**What the case looks like it pins and what it actually pins.** The name promises a round trip
through the stored form, and the line above it does pin one direction for all eleven pairs
(`persisted(live) == stored`). The return direction is never checked in either this case or any
other. A change that made `live(.saved)` return `.pending` - losing a saved copy's sizes on every
relaunch - would pass this case, and the three cases at lines 42-44 check only `.running`,
`.saving` and `.needsCheck`, not `.saved`.

**The repair is not simply to write `live(persisted(live)) == live`.** Four of the eleven pairs are
deliberately lossy (`.retrieving(0.4)`, `.preparing`, `.transcoding(0.9)` and `.verifying` all
persist as `.running`; `.saving` persists as `.saving` but comes back as `.needsCheck`), so a
whole-table round trip would fail on this code. The honest split is two tables: the lossless pairs
that must come back unchanged, and the coarse ones that must land on their documented answer - and
the three assertions at lines 42-44 already show the shape for the second table.

**Confidence: high** - it is definitional, not a reading of intent. The only judgement is how much
harm it does, and it is the case that owns the "what survives a relaunch" question for every stored
state.

### 2 - [P1] The whole of `FlowRoutingTests` drives the rule with a copy of the rule's own input

`VideoShrinkTests/FlowRoutingTests.swift:15-29`:

```swift
/// The model's own answer, as `CompressionViewModel.canChoose` computes it: no task running, on a
/// stage a run may start from again. `.readyToSave` is deliberately not one of those stages...
private func modelCanChoose(_ stage: PipelineStage) -> Bool {
    [.idle, .saved, .failed, .cancelled].contains(stage)
}
```

`CompressionViewModel.canChoose` is `work == nil && [.idle, .saved, .failed, .cancelled].contains(stage)`
(`VideoShrink/Presentation/CompressionViewModel.swift:85`). The test's helper is that expression
with `work == nil` dropped, because no task can be running in a pure test. Every one of the eight
cases passes `modelCanChoose(stage)` into `FlowRouting.decision` or
`FlowRouting.oneVideoIsAtRest` - so what the suite proves is that `FlowRouting` is a correct function
**of an input the suite computes for itself**. Nothing connects that input to the model that
produces it in the app.

**Why this is the wrong way round, and what it costs.** The rule exists (N34) for one reason: a kept
copy lives on `.readyToSave`, a stage `canChoose` excludes, and the two flow switches had to ask
`canChoose` *and* the stage so a user could not be stranded away from the only screen that can save
the copy (`VideoShrink/Presentation/ContentView.swift:41`, `SingleVideoFlow.swift:76`). The dangerous
drift is the other direction from the one the table protects: if `canChoose` ever gained `.choosing`,
a user with the picker sheet up could walk away mid-choice - which is the near-miss round 18's own
note describes ("a stage-only rule would let a user walk away mid-choice"). With this fixture in
place, that change would leave all eight cases green: the mirror would keep answering `false` for
`.choosing` while the model answered `true`, and no case in any file drives
`CompressionViewModel.canChoose` at `.choosing` or at `.readyToSave` either. The existing assertions
on the real property are `canChoose` at `.idle`/`.cancelled`/`.failed`/`.saved`
(`PipelineTests.swift:71, 91, 182, 200` and the `eventually` waits) and `canSave` at
`.readyToSave`; the exclusion of `.choosing` and of `readyToSave` - the whole point - is held by
nothing but the test's own copy of the expression.

**Confidence: high** on the code facts (the two expressions are compared above and are equal today).
**Medium** on how soon it bites: today the mirror is a faithful copy, so no case is *wrong*, it is
merely unfalsifiable about the thing it is named after. The case that would close it is small - build
a real `CompressionViewModel`, drive it to `.choosing` and to `.readyToSave`, and assert
`canChoose == false` at the first and that `FlowRouting.oneVideoIsAtRest` answers `true` at the
second.

### 3 - [P1] The sentence that tells the user to look in Photos is never asserted as text

`VideoShrink/Models/BatchQueueRecord.swift:302` and `:305`:

```swift
static let unknownQuestion = "BatchShrink asked Photos for a copy of this video and never learned whether it was made. Look in Photos: if there are two copies, that copy was made; if there is one, it wasn't."
static let limitedAccessQuestion = "Photos access covers only some of your library, so BatchShrink cannot tell whether this video was copied. Look in Photos before running it again."
```

These two strings are the entire user-facing product of the round-21/23/24 machinery: the row
sentence on the selection screen for a video the app has left out of Select all, and the reason the
user is being asked to open Photos before running it again. Their content is asserted nowhere. Every
case that mentions them compares the constant to itself:

```swift
XCTAssertEqual(relaunched.midSaveFindings["a"],
               MidSaveFinding.unresolved(question: MidSaveFinding.unknownQuestion))
```

at `BatchQueueTests.swift:259-260, 284-285, 303-304, 369-372, 374-379, 384-386, 410-413, 953-954,
1034-1035, 1084-1085, 1126-1127, 1140-1141, 1148-1149`, and
`XCTAssertEqual(fixture.batch.midSaveQuestion(for: "not-here"), MidSaveFinding.unknownQuestion)` at
`BatchTests.swift:437`. `BatchTests.testARowForAFlaggedVideoSaysWhatTheQuestionIs`
(`BatchTests.swift:423-439`) is named for exactly this sentence and asserts only that the fallback
equals the constant.

**The test's own grep is the evidence**: the literal "Look in Photos" appears in no test file. So
either sentence could be emptied, reworded into something false, or reversed ("there is no need to
look in Photos") and all 408 cases would still pass. The related screen string
`BatchSelectionScreen.unaccountedExplanation` is pinned for parts of its text
(`BatchTests.swift:464-475`), which is what makes this gap the odd one out: the heading and the
paragraph are held, the row's own sentence - the one the user acts on - is not.

**Confidence: high.** The fix is two literal assertions, or (better, and matching this project's
one-owner rule) one case per sentence that asserts its distinguishing clause, so a rewrite that
keeps the instruction passes and a rewrite that drops it fails.

### 4 - [P2] The failure vocabulary is pinned for shape, never for content

`VideoShrinkTests/ModelCoverageTests.swift:579-605` (`testEveryFailureTheUserSeesHasItsOwnSentence`)
establishes three things about `PipelineError.errorDescription`: it is non-empty, it never contains
the case name, and no two cases share one. That is a real and useful case. What it does not do is
assert what any sentence says. Of the nineteen cases, seven carry a content check somewhere:
`.insufficientStorage` and its `insufficientStorageSentence` variants (which name a figure,
`ModelCoverageTests.swift:611-647`), `.export` (must contain "free storage",
`ModelCoverageTests.swift:657-663`), `.resolutionMismatch` (must contain "picture size",
`ModelCoverageTests.swift:670-674`), and `.permissionDenied` and `.assetUnavailable` (substring
checks at `BatchTests.swift:1962-1984`). The two that carry their sentence in -
`.unsupportedOriginal(reason:)` and `.exportUnavailable(reason:)` - are asserted to hand it straight
back out, which is the right check for their shape. `.unsupported` is pinned only negatively (it
must not be what several refusals say, `ServiceCoverageTests.swift:906, 925, 948, 984`).

The ones with no content assertion at all include the two that matter most:

- **`.save`** (`VideoShrink/Models/PipelineError.swift:103`): "Photos did not confirm the save.
  Inspect Photos before retrying to avoid creating an extra copy. Your original was not changed."
  This is the sentence the mid-save question exists to show, and the only place the app tells the
  user to look in Photos before retrying - the instruction that prevents the second copy. The
  literal "Photos did not confirm the save" appears in no test file.
- **`.libraryScan`**, **`.retrieval`**, **`.cancelled`**, **`.temporaryFiles`**, **`.verification`**,
  **`.durationMismatch`**, **`.audioMismatch`**, **`.orientationMismatch`**, **`.codecMismatch`**,
  **`.frameRateMismatch`** (`PipelineError.swift:86-106`).

Every case that names them puts the same expression on both sides of the assertion, so the case
cannot see a change to it: `BatchTests.swift:333-334, 432-433, 591-592`, `BatchTests.swift:776`
(`batch.message == PipelineError.libraryScan.localizedDescription`),
`ModelCoverageTests.swift:642-646` (`let coarse = PipelineError.insufficientStorage.localizedDescription`),
and `BatchQueueTests.swift:64` (non-empty only).

**One case is worse than thin, and the round should look at it directly.** `BatchTests`'
confirmation case builds its expected string out of the source it is checking:

```swift
XCTAssertEqual(
    BatchFlow.confirmationMessage(settings: ..., deletion: .afterRun),
    "Each smaller copy is saved to Photos as it finishes, at up to 1080p, targeting 24 fps. \(DeletionMode.afterRun.detail) Deleted originals sit in Recently Deleted for 30 days.")
```

(`BatchTests.swift:2069-2077`.) The size ceiling and the frame-rate clause are pinned by hand; the
sentence this mode shows about *deletion* is substituted in from `DeletionMode.afterRun.detail`
(`VideoShrink/Models/DeletionPolicy.swift:31`), the very string under test. `DeletionMode.detail` is
asserted only to be non-empty (`DeletionPolicyTests.swift:336-345`), so the deletion half of the last
sentence a user reads before work starts is unpinned. A `detail` that said "Nothing is deleted.
You keep both copies." would leave this case green.

**Confidence: high on the facts.** The remedy is the same shape as finding 3: one literal assertion
per sentence, or one distinguishing-clause assertion per sentence, for the cases whose text is the
product.

### 5 - [P2] `testTheLiveOverloadsReportWhatTheSystemSays` cannot fail on the machine it runs on

`VideoShrinkTests/DeviceConditionsTests.swift:19-30`:

```swift
let live = ProcessInfo.processInfo
XCTAssertEqual(DeviceConditions.pacing(processInfo: live),
               DeviceConditions.pacing(thermalState: live.thermalState))
XCTAssertEqual(DeviceConditions.pacing(),
               DeviceConditions.pacing(thermalState: live.thermalState))
XCTAssertEqual(DeviceConditions.isLowPowerMode(processInfo: live), live.isLowPowerModeEnabled)
XCTAssertEqual(DeviceConditions.isLowPowerMode(), live.isLowPowerModeEnabled)
```

`pacing(thermalState:)` maps `.nominal`, `.fair` and `.serious` all to `.normal` and only
`.critical` to `.tooWarm` (`VideoShrink/Models/DeviceConditions.swift:15-17`). The doc comment says
"a stripped-out forward would show up as a mismatch", and that is true only of one spelling of
"stripped out": a forward that returned `.tooWarm` for a cool phone would fail. A forward that
returned `.normal` unconditionally - or `false` for `isLowPowerMode` - passes on every machine whose
thermal state is not `.critical` and whose Low Power Mode is off, which is every CI runner and
almost every simulator. The case's own input is the live machine, and the live machine cannot
supply the one value that would distinguish the two: there is no way to construct a
`ProcessInfo`, so the second operand can never differ from the first.

**Confidence: high** on the code fact; **medium** on whether to change it, because the case does
catch an inverted mapping, which is the likeliest accident. The honest forms are to keep it and say
in the case what it cannot catch, or to delete it and let
`testOnlyACriticalThermalStateStopsTheBatch` own the mapping (it already does, exactly).

### 6 - [P2] `testAPlayerItemThatIsNotReadyIsAnsweredAsOneThatCannotPlay` passes against a stub

`VideoShrinkTests/BatchTests.swift:518-524` (uncommitted round-27 work):

```swift
let item = AVPlayerItem(url: URL(fileURLWithPath: "/nonexistent-batchshrink-preview.mov"))
let ready = await PlayerReadiness.wait(for: item, seconds: 0)
XCTAssertFalse(ready)
XCTAssertTrue(VideoPreview.unplayableSentence.contains("export the video again"), ...)
```

`PlayerReadiness.wait` is

```swift
let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
while item.status == .unknown, !Task.isCancelled, ContinuousClock.now < deadline {
    try? await Task.sleep(for: .milliseconds(150))
}
return !Task.isCancelled && item.status == .readyToPlay
```

(`VideoShrink/Presentation/VideoScrubSheet.swift:16-22`.) At `seconds: 0` the loop never runs, so the
case is asserting `item.status != .readyToPlay` for a file that does not exist - which an
implementation that is literally `{ _, _ in false }` also satisfies. The case pins neither the
loop, nor the bound, nor the `readyToPlay` direction, and both call sites are view bodies no test
drives (`VideoScrubSheet.swift:168`, `ShrinkScreens.swift:376`). PV1's and PV2's fix is therefore
asserted only against a function that a constant would satisfy. The second assertion checks a static
string contains a substring, which is a content pin and worth keeping.

**Confidence: high** on the code facts. This one is cheapest to close while the writer is still in
the file: give the case an item that *does* become ready (or a `.failed` item, which the doc promises
answers false at once) and assert the other direction, so the pair distinguishes the wait from a
constant.

### 7 - [P3] `testCorruptContainerFailsRealVerification` asserts less than its name

`VideoShrinkTests/RulesTests.swift:144-156`. Its two siblings in the same file assert the exact case
- `XCTAssertEqual(error as? PipelineError, .verification)`
(`RulesTests.swift:131`, `:141`) - while this one asserts only:

```swift
} catch {
    // Different OS releases may reject during property loading or track inspection.
    XCTAssertFalse(error is CancellationError)
}
```

So a corrupt container that produced `.retrieval`, `.insufficientStorage`, or any other
`PipelineError` would pass a case named "fails real verification". The comment's concern is real,
but "not a cancellation" does not answer it; the honest form is to accept an explicit set of
throwable cases and name them in the failure message.

**Confidence: high** on the assertion as written; **low-medium** on the harm, since the file's other
two cases prove the happy shape of the same path.

### 8 - [P3] `testARowIsIdentifiedByTheVideoItIsWorkingOn` asserts a passthrough

`VideoShrinkTests/ModelCoverageTests.swift:802-807`:

```swift
let asset = coverageAsset("video-a", bytes: 1_000)
let item = BatchItem(asset: asset, state: .pending)
XCTAssertEqual(item.id, "video-a")
XCTAssertEqual(item.state, .pending)
```

This builds the value and then checks that the two things it just passed in came back out. It is not
false - `item.id` returning something else would fail it - but it establishes nothing a compiler does
not already establish, and its name promises a statement about how a row is *identified* (that the
row follows the video it is working on through a run) that it does not make. `BatchItem.id` is used
as the join key for eight per-item dictionaries in `BatchViewModel`, so the interesting claim is the
one no case makes: that a row's identity survives the stages of a run. Confidence: high.

## Thin but honest - named so a later round does not have to rediscover them

These are sound as written; each is recorded because it looks stronger than it is, and because the
round that reads them next should be able to tell "checked" from "not checked".

- **`BatchTests.testTheSelectionLineNamesTheVideosItsFigureCovers`** (`BatchTests.swift:2111-2118`)
  builds its expected string with `ShrinkFormat.bytes(estimate.sizedBytes)` - the same value the
  line reads - so it pins the sentence's shape ("N selected - X of M measured") and delegates the
  figure to the model. The assertion beside it (`estimate.sizedCount == 2`) is independent, so the
  coverage is real, just not as wide as the case looks.
- **The read-back doubles all agree.** `MockVerifier`, `QueueMockVerifier`, `BatchMockVerifier` and
  `ServiceMockVerifier` each implement `verifyImportedCopy` as `return expected`
  (`PipelineTests.swift:543`, `BatchQueueTests.swift:1503`, `BatchTests.swift:2625`,
  `ServiceCoverageTests.swift:1528`). `BatchViewModel.confirmReadBack` only tests
  `(try? await verifier.verifyImportedCopy(...)) != nil` (`BatchViewModel.swift:1549`), so the flow's
  branch for a copy that arrives and does *not* match is unreachable through every fixture; only a
  nil URL or a throw can produce `.unavailable`, and the nil-URL case is tested
  (`BatchTests.swift:1378-1392`). The comparison itself is covered directly
  (`PipelineTests.testImportedCopyIsComparedWithTheExpectedOutput`, `VideoVerificationService.validate`
  -> `VerificationRules.validate`), so the untested part is narrow and lands on the same branch.
- **`BatchTests.testTheScreenIsLeftAloneWhenTheSettingIsOff`** (`BatchTests.swift:1320-1328`) asserts
  `values.allSatisfy { $0 == false }`, which is vacuously true for an empty array. The sibling case
  `testTheScreenIsHeldAwakeOnlyWhenAskedAndOnlyWhileWorking` asserts `values.last == true` during
  the run, so the wiring is held as a pair; read on its own, this one would pass against a model
  that never touched the screen-awake controller at all.
- **`ModelCoverageTests.testEveryStateTheListCanShowHasItsOwnLabel`** (`ModelCoverageTests.swift:788-800`)
  pins that ten states have ten distinct titles, but not any of the titles except the three it names
  (`Waiting`, `Keeping the copy`, `Check Photos`). The rest can drift.
- **`FlowRoutingTests.testThatEveryPipelineStageHasAnAnswer`** (`FlowRoutingTests.swift:89-96`) is the
  sweep that makes a new `PipelineStage` fail the suite rather than acquire a default - a good
  instrument, weakened only by being fed the mirror of finding 2. Note also that its `atRest` list
  and the model's `canChoose` list are two hand-written statements of the same set, and the case
  checks the first against the rule rather than against the second.

## Checked and found sound - do not re-walk

- **The 26 `DeletionPolicyTests` cases are the strongest block in the suite.** Each asserts the exact
  refusal sentence for one `CopyRevalidation`, both directions of the two-receipt rule, the
  precedence of `AssetRules` (one case per trait, plus the all-traits ordering), and - unusually
  well - the *migration* paths: the pre-copy-identity queue shape is encoded through the project's
  own encoder and asserted not to carry the new key before it is decoded
  (`DeletionPolicyTests.swift:149-176`), and a damaged receipt is asserted not to authorise anything
  (`:324-332`).
- **`EligibilityTests` pins every refusal sentence verbatim and each rule's precedence**, including
  that the trait table and the media-level format entry point agree in all four combinations
  (`EligibilityTests.swift:124-133`). The sentences are `AssetRules`' own and the cases read them as
  literals, so both the words and the one-owner arrangement are held.
- **`ScanScaleTests` drives the walk and the on-device pass through the seam that exists for it and
  asserts the arithmetic that matters**: the listing that shrinks or grows mid-pass, the progress
  counter never exceeding its total, the stop being seen within one video (`read == 32`), the
  measured-versus-reported size split, the bound on the scan-time pass, and the deliberate absence
  of a bound on the chosen-video read. Its own doc comment states what a device would still have to
  settle.
- **`LibraryScanResult.reconcile` is well covered in both directions** (`BatchTests.swift:1567-1634`,
  `ScanScaleTests.swift:630-680`): a video that leaves, a running video that leaves and keeps its
  identity, a changed video, a measured size that survives a refresh that cannot measure, a refusal
  that survives a refresh, a refusal dropped for a video Photos changed, and a selection naming a
  video that was never there.
- **The queue's durability boundary is covered end to end**: a write that fails before the save, a
  save Photos accepted whose record cannot be written, a delete Photos accepted whose outcome cannot
  be written, and the relaunch each one produces (`BatchQueueTests.swift:108-169, 541-594`). The
  fictional store is a real double - it can fail exactly one chosen record.
- **`testOriginalsLeftWaitingByOneRunAreNotDeletedByTheNext`** (`BatchTests.swift:1029-1063`) is the
  harness for round 20's DEL1 and is the model for what a case about a *consequence* should look
  like: it runs two videos, pauses with an original already queued, turns deletion off, starts a new
  run, and asserts that nothing in Photos was ever asked to delete.
- **`testBatchSavesSmallerCopiesAndSkipsOnesThatGrew`** (`BatchTests.swift:190-215`) documents why its
  own fixture numbers are realistic (the 250 kbps floor in `CopyMeasurement.isValid`) and then
  asserts the saved, skipped and pending counts, the 1:1 history record, and the removal of both
  temporary copies. This is the case round 5 corrected rather than deleted.
- **`testSuccessRequiresExplicitSaveAndReverification`** (`PipelineTests.swift:9-25`) asserts the exact
  ten-stage sequence for a whole successful run, which is the cheapest possible guard against a
  stage being skipped or reordered.
- **`testTheDeletionPromptSaysWhatHappensToItsOwnCount`** (`BatchTests.swift:447-461`) is the repaired
  version of round 21's case that could not pass, and the comment records the repair rather than
  hiding it.
- **`testTheOverflowHintNamesOnlyWhatTheMenuHolds`** (`BatchTests.swift:555-572`) pins all eight
  subsets of the overflow menu's contents, and `BatchFinishedScreen.Extra.available` is asserted
  separately (`:2241-2254`), so the trigger and its contents come from one list and the hint names
  exactly what is behind it.
- **The two gates that can run here are honest about themselves.** `validate:native` prints
  `NOT RUN: XcodeGen generation, Swift compilation, XCTest execution, simulator, signing,
  Photos/iCloud/device tests`, and the call-site checker prints what it did not judge
  (896 call sites whose name is declared nowhere in the tree; 111 where the name is declared but no
  declaration accepts the labels). Neither is a compiler and neither claims to be.
- **`LaunchSmokeUITests` is the only case that observes a rendered screen**, and it is written the way
  this project's lessons require: `continueAfterFailure = false`, the Skip control as the anchor,
  a 30-second wait, the whole element tree in the failure message, and an explicit statement that the
  introduction is *not* forced by a launch argument (with the container-clearing alternative named).
  Its four assertions are real; it remains one navigation on a simulator with no Photos library.

## Only a compiler or a runner could settle

- **Whether any of the 408 cases passes**, and therefore whether the suite's 407-case gate count is a
  count of passing cases at all. The last execution of this suite in the record is round 5's
  `162 executed, 155 passed`; every case added since - 246 of them - has never run.
- **Whether the exact stage sequence in `testSuccessRequiresExplicitSaveAndReverification` is still the
  sequence the pipeline produces**, and whether any `eventually` helper's 500-iteration budget
  (about one second) is long enough on a loaded macOS runner. Three of the seven failures in round 5
  were timing-and-fixture faults of exactly this family, and the budget has not changed since.
- **Whether `PlayerReadiness.wait`'s 150 ms poll and its 10-second bound behave as documented against
  a real `AVPlayerItem`** (finding 6), and what AVKit does with an item that never becomes ready.
- **Whether `ProcessInfo.thermalState` on a runner is ever `.critical`** (finding 5), which is the only
  thing that makes that case able to fail.
- **Whether the two `verifyImportedCopy` throw paths are reachable in practice** (the read-back the
  double always answers), and what PhotoKit hands back for a copy that was edited or re-encoded
  between the save and the read-back.
- **Which of findings 3 and 4 actually harms a user** - whether the two question sentences and the
  twelve unasserted `PipelineError` sentences reach a screen in the words a case would have checked.
  A device run of the mid-save path from `docs/PHYSICAL_DEVICE_TEST_PLAN.md` is what answers it.
- **Whether the `FlowRouting` call sites pass what the mirror says they pass** (finding 2). The two
  call sites are view bodies; only a render or a UI test that taps the two switches while the picker
  is open and while a copy waits at `.readyToSave` would hold them.

## The smallest set of changes that would close what this audit found

1. **Split the round-trip table in `testLiveStatesRoundTripThroughTheStoredForm`** (finding 1): delete
   the self-comparison, assert the lossless pairs come back unchanged through
   `live(persisted(_:))`, and assert the coarse ones land on their documented answer - which is what
   the three lines below the loop already do for three of them. One case, no new fixture.
2. **Delete the mirror in `FlowRoutingTests` and drive the real model** (finding 2): a case that builds
   a `CompressionViewModel`, drives it to `.choosing` and asserts `canChoose == false`, and one at
   `.readyToSave` asserting `oneVideoIsAtRest(canChoose:stage:) == true`. With those two in place the
   remaining `FlowRoutingTests` cases can keep their mirror, because the mirror itself would then be
   held by a case.
3. **Assert the two question sentences** (finding 3) - one case, two literals or two
   distinguishing-clause assertions, in `BatchQueueTests` beside the cases that already name them.
4. **Assert the failure sentences that carry an instruction** (finding 4): `.save` first, because it
   is the only place the app says to look in Photos before retrying; then `.libraryScan`,
   `.retrieval` and `.cancelled`. And pin `DeletionMode.detail`'s three sentences, so the
   confirmation case's substitution stops being a hole.
5. **Give `PlayerReadiness` a case that can distinguish it from a constant** (finding 6): a
   `.failed` item, or an item that becomes ready, so the pair fails if the wait is stubbed.
6. **Say in the case what it cannot catch, where the fixture cannot help** (findings 5, 7 and the
   read-back double): either an explicit accepted-set assertion for the corrupt container, or one
   comment per case naming the state a runner cannot be put in. This is the same trade the project
   already makes in `ScanScaleTests`' doc comment and in the `A9` case's own text.
7. **Name the promises no case holds** (finding 3's tail, and the Originals sheet): "The one-video
   flow never deletes" (`VideoShrink/Presentation/DeletionSheet.swift:30`) is asserted by no case in
   either target - the one-video fakes have no counter on the delete path - and neither is
   "A copy has to be saved, smaller and confirmed in Photos before an original is touched"
   (`:27`) beyond the two batch cases that drive one half of it each. One case per sentence, in the
   flow the sentence names, closes the last category in the brief.
