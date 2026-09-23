# Audit of record — every number BatchShrink shows a user

Read-only audit performed on 2026-09-23, round 18. It traced every figure the product puts on
screen back to the arithmetic behind it: the quality estimate, the scan summary, the running
count and time estimate, the finished totals, the one-video result, and the figures quoted by
refusals. It was performed against the tree at `0e8bbae`'s parent, before the round-18 fixes.

**This document is a finding list, not a defect list that has been fixed.** The Status column is
the only place that says whether a finding has been dealt with, and it is deliberately separate
from the finding so that the finding survives its own repair. The summary table in
`AGENT_LOOP.md` carries the same IDs.

Line numbers were correct when the audit was taken. Read the code before acting on one.

## Findings

### E1 — [P2] The summary promises every video in the library can get lighter
`VideoShrink/Presentation/BatchScreens.swift:290-295`

The largest text on the summary screen reads `"\(result.assets.count) videos can get lighter."`,
and directly below it the card says `"Estimated for \(estimate.sizedCount) of
\(result.assets.count) videos"` labelled "potentially smaller". `result.assets.count` is every
eligible video — sized or not, shrinking or not.

`SavingsEstimate.likelyNoReductionCount` already computes exactly the missing qualifier (set at
`LibraryModels.swift:188` when `conservativeBytes == 0`) and **no view or view model reads it**;
only a test does. The per-row caption on the selection screen does qualify the same videos
("Little saving expected", `BatchScreens.swift:561-563`), so the summary contradicts a screen
built from the same numbers. The claim is also made when nothing has been measured at all: with
`estimate.hasNumbers == false` the card reads "No sizes yet / savings can't be estimated" while
the headline still says every video can get lighter.

**Narrowest fix:** derive the headline from the estimate — name the measured count, or subtract
`likelyNoReductionCount` when `hasNumbers` — rather than from `assets.count`.

### E2 — [P2] The basis caption names a frame-rate scaling that did not happen, and hides the one that did
`VideoShrink/Presentation/BatchScreens.swift:346-357`

With 30 fps chosen the caption reads `"Planning band 4–8 Mbps, scaled for 30 fps."` But
`CopySizeModel.make` applies `frameRateScale` in both branches (`LibraryModels.swift:68,80`) and
the band is documented as already being a 30 fps band (`LibraryModels.swift:91-92`), so
`frameRateScale(.fps30)` is `30/30 = 1.0` and nothing was scaled. `LibraryModels.swift:91-94`
states the intent this violates: the interface should name the scaling and never the band's own
baseline.

The same bug runs the other way: with a *measured* band at 24 fps the caption reads `"From
\(samples) copies measured on this iPhone."` while every number above it is 0.8× the measured
band. `BatchFlow.swift:63` has the same silence — the last screen before a run never mentions the
frame rate the user chose.

**Narrowest fix:** emit the fps clause only when the scale is not 1, and add the same clause to
the `.measured` case — or carry the frame rate inside `Basis` so the caption cannot drift from
the arithmetic.

### E3 — [P2] The confirmation before a batch promises copies "at 4K" for videos copied smaller
`VideoShrink/Presentation/BatchFlow.swift:63`

The last thing read before work starts says `"Each smaller copy is saved to Photos as it
finishes, at \(batch.settings.resolution.title)."` But `TranscodeSettings.effectiveResolution`
(`VideoQuality.swift:97-100`) never upscales: a 720p original in a run set to 4K is copied at
720p, and the estimate, the per-row figures and the export all use that rule. The app states the
rule itself one screen earlier — "Copies are never bigger than the original, so 4K only helps 4K
videos" (`QualitySelector.swift:76`). Same class as the round-10 fix to this string's sibling.

**Narrowest fix:** say the chosen picture size is a ceiling, and name the frame-rate choice here
too.

### E4 — [P2] A per-video space failure in a batch names no figure, although the run is holding one
`VideoShrink/Presentation/BatchViewModel.swift:1150` and `:1171`; sentence at
`VideoShrink/Models/PipelineError.swift:95`

The finished screen shows the generic storage sentence with no number. Both checks compute a
figure and throw it away (`DiskHeadroom.neededToWrite(original.bytes)` and
`neededToWrite(output.bytes)`); the catch block tracks only `refusingFloor` (`:1219`), so neither
reaches `insufficientStorageSentence(needed:)`.

The app already has the wording and the precedent: the *floor* refusal pauses the run and the
paused screen names the figure, and the one-video flow carries a `demanded` figure for exactly
this (`CompressionViewModel.swift:125-131,149-154,192-195`). Round 16 fixed this for one flow and
left the other.

**Narrowest fix:** hoist the demanded figure into a local for each attempt and, when
`normalized == .insufficientStorage` and a figure was held, give the item that sentence.

### E5 — [P3] The time estimate's two clocks measure different spans
`VideoShrink/Presentation/BatchViewModel.swift:1113,1153,1166-1167,413`;
`VideoShrink/Models/BatchModels.swift:185-195`

The recorded sample is transcode-only — `let started = Date()` at `:1153` and
`Date().timeIntervalSince(started)` at `:1166`, fed to the estimator at `:1167` — but the
subtraction uses `activeStartedAt`, set at the top of `process(id:)` (`:1113`) *before* the floor
check, the iCloud retrieval and the format inspect. So retrieval and inspection time is
subtracted from a prediction that never included them; for an iCloud original that takes minutes
to download, the active item's remaining time is understated by that much and can sit at "a
moment" while the export is still running. Pending items are predicted with the same
transcode-only ratio.

`testElapsedTimeOnTheActiveVideoIsSubtracted` (`BatchTests.swift:157-164`) cannot see it: it
assumes the two spans are the same.

**Narrowest fix:** take the sample from the same instant the elapsed is measured from.

### E6 — [P3] "copies about X" counts a copy for every video, including the ones the run will skip
`VideoShrink/Models/LibraryModels.swift:128-129` and `:155-156`; shown at
`QualitySelector.swift:117` and `BatchScreens.swift:314`

`estimatedCopyBytes = max(0, sizedBytes - (conservativeBytes + optimisticBytes) / 2)`. Per-video
savings are clamped at zero, so a video whose copy band is not smaller than its original
contributes its **full** size to `sizedBytes` and subtracts nothing — it is accounted for as
though a copy of it at its original size were going to be made. The pinned case
`testAVideoThatCannotShrinkIsCountedRatherThanPromised` (`ModelCoverageTests.swift:157-170`) is
exactly this: the copy figure comes out between 20 MB and 80 MB larger than any copy that will
exist, and larger than the saving the same card reports.

**Narrowest fix:** exclude never-shrinking videos from the copy subtotal, or clamp each video's
copy bytes to its own original, so the line describes only copies the run will make.

### E7 — [P3] A selection that will not shrink renders as the bold figure "Zero KB"
`VideoShrink/Presentation/ShrinkStyle.swift:52-53`; shown at `QualitySelector.swift:113` and
`BatchScreens.swift:309`

When every sized video is at or below the bottom of its band, `conservativeBytes ==
optimisticBytes == 0` and `byteRange(low: 0, high: 0)` returns the formatter's rendering of a
single zero. The value is true but it is not what the card exists to say, and the row on the same
video already says "Little saving expected". Neither view guards the zero case; `hasNumbers` only
guards "nothing was measured at all".

**Narrowest fix:** in the two views, when `optimisticBytes == 0`, render the "nothing here is
likely to get smaller" wording instead of a byte figure. Leave `byteRange` alone; its behaviour
is pinned and correct as a formatter.

### E8 — [P3] A stored non-shrinking saving renders as "--1.2 GB" in a finished row
`VideoShrink/Presentation/BatchScreens.swift:879,883`

`Text("-\(ShrinkFormat.bytes(saving.bytesSaved))")` with a negative `bytesSaved` renders as
`--1.2 GB`, while the totals card beside it says "Nothing measured / no smaller copies". Every
path that *writes* `.saved` is inside an `isSmaller` check, so this needs a queue file this app
did not write — a case the code treats as real (`LibraryModels.swift:113-114`), and
`BatchQueueReconciliation.live` rebuilds `Savings` from stored numbers with no check at all
(`BatchQueueRecord.swift:308-310`). The row's only guard is `if case .saved(let saving)`.

**Narrowest fix:** render the figure only when `saving.isSmaller`, otherwise show the "not
smaller" wording — or make `live` clamp a stored `.saved` whose copy is not smaller.

### E9 — [P3] "N selected · X of originals" pairs the full selection count with a subtotal of the sized ones
`VideoShrink/Presentation/BatchScreens.swift:483`

The action bar reads `"5 selected · 2.1 GB of originals"` where one of the five has no reported
size. `sizedBytes` sums only the sized videos, so the figure reads as the total of all five. The
qualifying sentence exists on the same screen (`:335`) but only in the scrolling footer.

**Narrowest fix:** move the "of N measured" qualifier into the same line.

## Checked and correct — do not re-walk

- One formatter for one figure everywhere: `ShrinkFormat.bytes` and `PipelineError.bytes` are the
  same `ByteCountFormatter` call, pinned by `ModelCoverageTests.swift:489-493`.
- The disk-space arithmetic is right: `DiskHeadroom.neededToWrite(_:)` asks for one file plus the
  reserve, and the export check passes the measured original while the save check passes the
  measured copy. `bytes(_:copies:)` has no production caller and says why.
- No negative or infinite saving can be *produced*: every writer of `.saved` is gated on
  `isSmaller`.
- The finished totals are a sum of what was measured, in one pass with mutually exclusive
  buckets, and the card says "less video data" rather than "space saved".
- No reclaimed-space claim anywhere; both the finished screen and the one-video flow say so.
- The running counts add up, including the mid-save cases.
- The time estimate is a range with its basis and stays silent until it has one.
- No time is quoted on the scan summary or the selection screen at all.
- Sizes reported as not measured are kept out of the estimate and the user is told.
- Basis selection is order-independent (`dominantBand` breaks ties by a documented total order).
- Formatters refuse to render nonsense (`duration`, `frameRate`, `date` return placeholders).
- A change underneath the app cannot re-point work or silently keep a stale listing.

## Not determined

- How often the summary's overclaim is actually wrong on real hardware. The planning bands are
  documented assumptions and no device has ever run the app; only the measured-samples path on a
  real library settles it.
- Whether Photos' change observer fires for the app's own deletions.
- Locale rendering of the collapsed ranges: `byteRange`/`durationRange` split formatted strings on
  U+0020 while `ByteCountFormatter` is locale-dependent.
- A restored mid-save copy whose asset has since changed: the finished total can describe sizes
  from the attempted save. A device run with the copy edited in Photos would settle it.
- A sized video with an unusable duration is excluded from `sizedCount` but not from
  `unknownSizeCount`, so the summary can be off by one. No real-library route to that state was
  found, so it was not raised as a finding.
