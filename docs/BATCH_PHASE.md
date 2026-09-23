# Batch shrinking and the library prescan

This phase makes the batch the main way into BatchShrink: look through the library, choose
videos, watch a running count with a time estimate, and read an honest summary. The
single-video path with a preview before saving is still there, one tap away.

A smaller copy is added to Photos as a separate item, and only after it passes the existing
checks. Deleting an original is opt-in, applies to batch runs, and is described below.

**Status: implemented source; the newest of it is uncompiled.** This document describes the batch
as it exists in the tree after round 19. Earlier builds compiled earlier states of it. The round 1
to 5 reliability work - the queue write boundaries, the deletion gate, verification, the library
reconciliation and the copy exclusion - is all in that tree, as are the round 18 and 19 changes to
the estimate's arithmetic and wording, the two temporary workspaces and the finished screen's
action bar.

The tree's suite has grown well past the 162 cases that first ran (the local gate prints the
current count; take the number from a test run, never from this line, because it moves with every
round). The cases execute on a macOS CI runner - `.github/workflows/ios-tests.yml`
runs `scripts/verify-native-tests.mjs`, which generates the standalone project with XcodeGen,
compiles both targets and runs the suite. The last run observed to execute them was job 1 at
`31b6245`, green. **Since 2026-09-23 the account's GitHub Actions runners have not started**, so
nothing on `main` after `31b6245` has been compiled, and the round 19 source in particular has
never been built. `AGENT_LOOP.md` carries the evidence and the options.

**Nothing in this document is a device result.** A screen has been rendered - the round 18 launch
job installed the standalone app on a simulator, tapped Skip and reached the batch screen, which
is the first observation of any screen in this project - but that is one navigation on a simulator
with no photo library. No video has been exported, no original has been deleted and no queue file
has been written on a device.

## What the prescan can see

The scan is built from PhotoKit metadata, plus one network-disabled header read per on-device
video. It downloads nothing.

| Fact | Source |
| --- | --- |
| Count of videos, dates, durations, pixel sizes, favourite/hidden flags | `PHAsset` |
| Slow-motion, time-lapse, spatial and cinematic flags | `PHAssetMediaSubtype` |
| Edited assets and Live Photo video pairs | `PHAssetResource` resource types |
| Shared, synced or otherwise restricted items | `PHAsset.sourceType` and `canPerform(.delete)` |
| Original byte size | `PHAssetResource.dataSize`, public API from iOS 27 |
| Codec subtype and colour transfer function | the video track's format descriptions, read from the original during the on-device pass |

`dataSize` is the only supported way to read an original's size without fetching it. Apple
exposes no equivalent on earlier systems, and BatchShrink does not use undocumented
key-value lookups to guess one.

The listing is always followed by one bounded on-device pass over the videos already on this
iPhone, on every system and however the library was listed. It asks PhotoKit for the original
with network access disabled, one request per video, and reads two things from the file it is
handed: the original's byte size, on a system that does not report one, and the codec and colour
tags that no PhotoKit listing carries. The size it reads is what lets a video be offered with a
real number on an older system. The format it reads is what refuses an HDR or ProRes original
while the library is still being listed, in the same words a run would use. A video that lives
only in iCloud cannot answer the request, so nothing is downloaded: its size and its format both
stay unknown, it is counted and listed, and a run refuses it later if the media turns out to be one
this app cannot process. A video the scan read and refused is counted in the summary and named
with its reason on the selection screen, rather than disappearing from view. The pass is capped
at the 400 newest videos so a large library cannot turn a scan into an unbounded wait, and it
can be stopped at any time.

With limited Photos access, the allowlist *is* the library. Totals are labelled accordingly.

## How the savings estimate works

Every sized video gives a measured source bitrate: `bytes × 8 ÷ duration`. The unknown is
the size of the copy, so the estimate uses a band for it, per resolution:

- **Planning band:** 4-8 Mbps for a 1080p HEVC copy. Apple does not publish the bitrate of
  `AVAssetExportPresetHEVC1920x1080`, so this is a published-range planning assumption
  rather than a quoted figure. The same assumption at the other two preset sizes is 2.5-5 Mbps
  for 720p and 12-24 Mbps for 4K.
- **Measured band:** once this iPhone has finished three or more compressions, the band is
  replaced by the copy bitrates those runs produced, widened by 10% either side.

The band is a 30 fps band, and choosing a lower frame rate scales it down - 24 fps is 0.8x. That
choice travels inside the band's own `CopySizeModel.Basis`, so the caption beside the estimate and
the arithmetic read the same value and the caption names the scaling only when it actually moved
the numbers. 30 fps is the band's own baseline and is deliberately not named, because it scaled
nothing.

For each video the app reports the saving if the copy lands at the top of the band
(conservative) and at the bottom (optimistic). A video whose conservative saving is zero is
counted separately and still offered, because only a real run can settle it; its row reads
"Little saving expected" and a selection the band expects to save nothing at all reads "No saving
expected" rather than a bold figure of zero. Copies that do not shrink are skipped, never saved.
The "copies about" figure counts only the originals the band expects a copy for, so a video the
run is likely to leave alone is not counted as though a copy of it were going to be made.

This is an estimate, not a measurement. The summary says so, and the completion screen
reports measured bytes only.

## How the time estimate works

The estimate is built from videos this run has actually finished: processing seconds per
second of video, plus a fixed per-video overhead, with a band taken from the spread of the
observed samples. Before the first video finishes the app shows no number at all.

One sample spans a whole attempt - retrieval, the format read, the export and the check of what
came out - because that is what waiting for one video is made of. Round 19 changed this: the
sample used to cover the transcode alone while the remaining-time subtraction included the
retrieval, so an original being fetched from iCloud was subtracted from a prediction that had
never counted it, and the wait could read "a moment" while the copy was still downloading. Time
spent fetching an original is therefore **inside** the estimate now, not excluded from it. On a
device, watch for the converse: one very slow iCloud retrieval now enters the mean.

## Quality options

| Option | Preset | Codec |
| --- | --- | --- |
| 720p | `AVAssetExportPreset1280x720` | H.264 |
| 1080p (default) | `AVAssetExportPresetHEVC1920x1080` | HEVC |
| 4K | `AVAssetExportPresetHEVC3840x2160` | HEVC |

Apple ships HEVC size presets for 1080p and 4K only, so 720p uses the documented H.264 preset
rather than a hand-built encoder configuration. Smoothness offers every frame (the default),
30 fps or 24 fps. A frame rate is only ever lowered, never raised, and a clip that is already
at or below the chosen rate is left alone.

The app never encodes larger than the original. If the chosen size is larger than a source,
the export runs at the source size instead and the estimate uses that smaller band. A video
composition is applied only when the preset alone cannot do the job: to hold a small source
at its own size, or to lower the frame rate. Composed exports set
`perFrameHDRDisplayMetadataPolicy` so HDR display metadata is carried through instead of
being dropped. Exports fall back rather than failing on the first refusal: a composed export that
fails is retried without the composition, and if that still fails it is retried once more without
the original's descriptive metadata, so a container that will not carry the metadata can still
produce a copy. The result screens report the measured size and frame rate rather than the
requested ones.

Every copy is checked before saving: playable, one video track, duration within tolerance,
matching audio track count, matching display shape, the expected codec, no more pixels than
the original and no more frames than the original. Receiving HEVC when the smaller H.264 copy
was requested is treated as a better result, not a failure.

The chooser estimates each resolution for the current selection before anything runs. That
estimate is a range from the same band model as the library summary.

## Thumbnails

The list shows a thumbnail per video. Thumbnails are the one thing this app fetches without
the user starting a job: Photos can hand over a cached preview for a video whose original
lives in iCloud, and only that preview is requested. Originals are never downloaded for a
scan or a list, and the on-device scan pass still asks PhotoKit with network access disabled.

Thumbnails are sized to be recognisable rather than decorative, and each carries the video's
length. Tapping one opens a player you can scrub through before deciding, because choosing what
to delete from a still frame is guesswork. That preview asks PhotoKit for a player item, which
lets Photos stream or buffer rather than pulling an export-grade original down first. It is the
one place in the app where looking at an iCloud video can start a fetch, and the sheet says so.

## Checking a copy

Before a copy is saved, and again immediately before the save, BatchShrink checks:

- it is a real, non-empty file that plays;
- exactly one video track, with a duration within 0.25 s or 0.1% of the original;
- the same audio track count, and decoded audio samples when the original had sound;
- the same display shape within 2%;
- the expected codec, no more pixels than the original, and no more frames than the original;
- a frame decodes from every applicable sample window near the start, the middle and the end of
  the track. A window that fails to decode fails the check; a window is only left out when the
  remaining track is too short to hold one, and a clip too short for any window is sampled as a
  single window over the whole clip rather than skipped.

After Photos accepts the save, the app asks for the new item back, compares it against the output
properties this run measured before saving, and decodes it under the same rules. This is what
turns "Photos said yes" into "the copy is there, readable and the one this run approved". A copy
Photos cannot hand back yet is not treated as a failure: the finished screen reports how many
copies were read back and how many were not.

None of this is an end-to-end playback proof. A few decoded windows are not a decoded file,
decodable audio is not audio fidelity or sync, and reading a copy back on this iPhone says nothing
about whether iCloud has finished uploading it.

## What travels with a copy

A copy keeps what Photos knows about the original:

- the creation date;
- the filename, through `PHAssetResourceCreationOptions.originalFilename`;
- the location, through `PHAssetChangeRequest.location`;
- the favourite and hidden flags.

The transcoder also writes the original's own descriptive metadata into the file, camera and
location tags included, wherever the container can carry it. Captions, keywords and ratings are
newer Photos metadata that this build does not copy yet. Album membership is not copied either:
Photos treats a new item as a new item, and adding it to every album the original belonged to
would be a separate feature with its own risks.

## Deleting originals

Deleting is off until the user turns it on, and it applies to batch runs. There are two modes:

| Mode | Behaviour |
| --- | --- |
| Keep every original | Nothing is ever deleted. |
| Delete as it goes | Each original is removed after its copy is saved and read back. |
| Delete at the end | Originals wait until the run finishes, then the user reviews and confirms. |

Every deletion goes through one gate, `DeletionPolicy`. It answers "delete" only when all of
these hold:

- deleting is switched on;
- a copy was saved and it is smaller than the original;
- that copy passed verification;
- Photos handed the copy back when the app asked for it;
- the run stored a receipt naming that copy and what both assets looked like when the copy was
  checked;
- both assets were looked up again immediately before Photos was asked, and that fresh look still
  matches the receipt;
- the original has not already been dealt with.

Anything else returns a reason, the original stays, and the reason appears in the run's list. The
app never deletes on the strength of an export alone: a copy that cannot be read back keeps its
original, and so does one that changed, disappeared or was checked by an older algorithm. A queue
written before the receipt existed carries none, so its originals are never deleted.

Deleted items go to Photos' Recently Deleted, which keeps them for 30 days. That is also when the
space comes back, and only once the devices have synced. The interface says so before the setting
can be turned on, on the finished screen, and in the help sheet.

**Photos confirms a transaction, not a video.** Every call to `PHAssetChangeRequest.deleteAssets`
produces one system alert, and no app can pre-authorise it or suppress it. The only lever is how
many originals go into one call, so deletions are batched: five at a time while "delete as it
goes" is running, with the remainder sent when the run finishes, and a single transaction for
the whole run in "delete at the end". That turns one confirmation per video into one per batch,
or one for the entire job.

Because iOS needs the app in front to show that alert, a paused run leaves its pending batch
alone. The originals stay eligible, and they are sent the next time the run finishes or the user
confirms from the finished screen.

Because this is the one irreversible thing the app can do, intent is written to the queue before
the call. An item recorded as `deleting` that is still there on the next launch comes back as
`uncertain` and is never retried automatically; the user checks Photos first.

## Leaving it alone

A long batch is meant to be started and left. Two things decide how far that goes:

- **The app has to stay in front.** iOS suspends background work, and this app takes no background
  entitlement, so locking the phone or leaving the app pauses the batch rather than pretending to
  continue. It comes back where it left off.
- **The screen can be held awake.** "Keep screen awake while working" in the help sheet stops the
  display sleeping while a run is active. It is off by default, it is released the moment work
  stops or the app leaves the foreground, and it uses more battery and runs warmer.

With deleting set to "at the end", that combination is: connect power, start the batch, leave the
phone face down, and come back to one confirmation for the whole job.

## Heat and power

Encoding for an hour heats a phone. Before each video the batch reads the device's thermal state
and stops with an explanation when iOS reports `critical`, instead of being killed mid-export.
Low Power Mode is not a reason to stop, so the working screen simply says that things will take
longer.

## Queue behaviour

- One video at a time, in the order chosen. Retrieval, preparation, compression and
  verification keep their existing stage rules and cancellation checks.
- A verified, smaller copy is saved to Photos immediately, and its temporary file is deleted
  straight afterwards, so only one output exists at a time.
- A failure records a readable reason and the run continues with the next video.
- Leaving the app pauses the run: the in-flight video returns to the waiting list, and copies
  already saved stay in Photos.
- The final screen reports saved, skipped, failed and unattempted counts, plus measured
  original and copy bytes for the videos that were actually saved.

## Surviving a close

The queue is written to a small JSON file in the app's own Application Support directory,
excluded from backup and behind file protection. It holds library identifiers, the sizes
Photos reported, the settings the run used and what happened to each item. No media, filename,
location or thumbnail is stored.

It is written between steps rather than on progress ticks: when a video starts, at each stage
change, at each result, and on pause or finish. On the next launch the stored queue is
reconciled:

- Anything waiting or in flight had produced no copy, so it waits again.
- An item that was *mid-save* is different. Photos may have committed that copy after the app
  stopped, so it is flagged as "check in Photos" rather than run again. Running it again could
  make a second copy, and the app will not do that on its own.
- Items already saved, skipped or failed keep their recorded outcome.

A restored run opens on the paused screen with what finished so far, or on the finished screen
when nothing is left waiting - a kill during the last video's save is exactly that case, and the
sentence here said "paused" unconditionally until a read-only audit checked it against
`BatchViewModel`'s own `hasPendingWork ? .paused : .finished`. "Continue" picks up the
waiting videos; check-in-Photos items are only requeued when the user says they have looked.
"Done" clears the stored queue by writing an empty one, and nothing is ever deleted.

This is a durable *list*, not exactly-once execution. A stop between Photos committing a copy
and the app recording it can still leave one real copy plus one flagged item. The flag exists
so the user decides what happens to it.

## On-device history

The app records the local Photos identifiers it has successfully shrunk, and the copy
bitrate of each result, in its own `UserDefaults` (declared as reason `CA92.1` in the
privacy manifest). This marks already-shrunk videos in the list, keeps them out of the bulk
shortcuts (individual rows can still be chosen deliberately), and sharpens the estimate. It
stores no media, filename, location or date, and nothing leaves the device.

The list is capped at the 2,000 most recent identifiers and 80 measured bitrates.

## Not claimed by this phase

- No iCloud storage is freed, and no subscription tier is lowered. Keeping both copies uses
  more storage until the user manages the originals themselves.
- No background or overnight processing. There is no background entitlement, the screen is held
  awake only when the user turns that option on, and leaving the foreground pauses the run.
- The stored queue survives a close, but there is still no exactly-once guarantee: a save that
  Photos committed just before the app stopped is flagged for the user to check rather than
  reconciled automatically.
- No prediction of a copy's exact size, and no promise that every video gets smaller.
- Deletion is opt-in and gated. There is no bulk "delete everything" action, nothing is deleted
  without a stored receipt and a fresh look that both still match, and the one-video flow never
  deletes at all.
- No supported media beyond ordinary, unedited, single-video, at-most-one-audio-track files.

## What still needs a device

The XCTest suite has left this list: the cases compile and run on a macOS CI runner, which
exercises the pure logic against injected fakes. The last run observed to execute them was green
at `31b6245`; the runners have been unable to start since, so the cases in the tree today have not
run. That is a statement about the gate, not about the code. A simulator has no thermal or storage
pressure and no iCloud offload, and it is not a phone's encoder, so everything below still needs a
physical iPhone to be *trusted*. Two things outside this list did get cheaper, and the wording here
used to overstate the gap: the round 18 launch job has shown that a screen renders on a simulator,
and a simulator's Photos library is a real one that `simctl addmedia` can be given a video - so the
screens that need no library can be inspected there, and
[SIMULATOR_PIPELINE_PLAN.md](SIMULATOR_PIPELINE_PLAN.md) sets out how far the pipeline itself could
be driven the same way. Neither replaces the device list: what a simulator cannot tell anyone is
whether Photos, the encoder and the system behave as a phone does.

1. Confirm the scan reports sizes on a device running iOS 27, and that it degrades to counts
   with no sizes on an older system instead of failing.
2. Confirm with the on-device measure pass that no bytes are downloaded: watch network use
   while scanning a library that has iCloud-only videos, and check with connectivity off.
3. Compare the estimate against real results for a mix of 1080p and 4K clips, then confirm
   the band tightens after the first three finishes.
4. Time a batch of five to ten videos and compare the reported estimate with the clock,
   including one failure, one skip and one pause/resume.
5. Compare the three quality options on one 4K clip: confirm 1080p and 720p are smaller than
   4K, that the 720p copy is H.264, and that no copy is ever larger than its source.
6. Check a reduced frame rate on a 60 fps clip: picture smoothness, audio sync and the
   measured frame rate shown in the details. Confirm the composed path either works or falls
   back without saving anything broken.
7. Confirm thumbnails appear for every row, including videos whose originals are in iCloud,
   and that scrolling a large library stays responsive.
8. Re-run the existing device matrix from [PHYSICAL_DEVICE_TEST_PLAN.md](PHYSICAL_DEVICE_TEST_PLAN.md)
   for the single-video path, which this phase moved but did not change.
9. Force-quit mid-batch, reopen and confirm the run is offered back with the right counts.
   Repeat while a save is in flight and confirm the item is flagged for a look in Photos
   rather than run again.
10. Run a long batch on a warm device and confirm the app stops with the heat message rather
    than being killed, and that continuing after it cools works.
11. Confirm the finished screen's read-back line matches what is actually in Photos, and that a
    copy Photos cannot hand back is reported as not read back rather than as a failure.
12. With deleting off, confirm no original is ever removed, whatever happens.
13. With deleting on, confirm nothing is removed without a confirmed copy, then check Photos'
    Recently Deleted to see the originals sitting there, and check the app's own report.
14. Force-quit while an original is being deleted and confirm it comes back as uncertain rather
    than being deleted twice.
15. Count the system confirmations in "delete as it goes": one per five originals, not one per
    original, plus a final one for the remainder.
16. Leave a batch running with the screen-awake option on and confirm the display stays on, then
    that it is released when the batch finishes or the app is backgrounded.
17. With deleting on, edit or remove a copy in Photos after a run, then confirm the original is
    kept and the kept reason appears, because the fresh look no longer matches the receipt.
18. Restore a queue written by an earlier build (7 through 10) and confirm none of its originals
    can be deleted, because those records carry no receipt.
19. Make the queue file unwritable during a run and confirm the app stops before it saves a copy or
    asks Photos to delete anything, rather than mutating Photos without a record.
20. Scan a library that already holds HDR or ProRes originals on the device and confirm the scan
    offers none of them as candidates: they are absent from the list to choose from and from every
    bulk shortcut, and each one is named on the selection screen under "Not supported" with its
    reason, rather than only being counted.
21. Time the on-device pass on a large local library, several hundred videos, and confirm that
    reading each video's codec and colour tags every time keeps the scan within a wait a person
    would accept, with the count still moving while it runs.
