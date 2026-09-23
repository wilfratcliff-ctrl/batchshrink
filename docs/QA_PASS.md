# Product-tester pass

This is a static pass over the app's routes: every path a user can take, read for ways it could
break, mislead, or behave worse than it should. It is not device testing and it is not the XCTest
suite.

**Status of this record, read before trusting anything in it.** The pass below is a historical
reading of the build-7-era source, kept because the reasoning is still useful. Since it was
written the tree has moved on in ways that make several of its statements false if read as
descriptions of today, so each is marked here rather than left to be discovered:

- The XCTest suite **has** executed. It ran for the first time on 2026-09-23 and passes on a
  macOS CI runner; the suite has grown well past that first run's 162 cases, and the last run
  observed to execute it was job 1 at `31b6245`, green. The runners have not started since, so
  the current tree's newest changes are uncompiled. Both facts are in
  [VALIDATION.md](VALIDATION.md) and `AGENT_LOOP.md`.
- A screen has been rendered. The round 18 launch job installs the standalone app on a simulator
  and reaches the batch screen; that is one navigation on a simulator with no photo library, and
  nothing else about the app has been observed.
- The library changed outside the app is no longer left stale: rounds 2 and 3 added the Photos
  change observer, the foreground authorization refresh and the reconciliation, with tests.
- The permission-change flag below was closed by the same work: the status is re-read on every
  activation as well as on an action.

Items under "Fixed in this pass" are a record of what that pass changed. Items under "Flagged"
are what it left, with the ones since closed marked in place.

Routes walked: first launch with and without a stored queue, a restored run in every recorded
state, scanning (allowed, limited, denied, empty library, huge library, cancelled, backgrounded),
selection (sizes known and unknown, already-shrunk videos, unsupported media, bulk shortcuts,
quality and deletion changes), a run (retrieval, transcode, verification, disk, save, read-back,
heat, background, pause, finish early, force quit), deletion in both modes, the one-video flow
end to end, and the queue file across every transition.

This pass was made against the build-7-era source. Round 1 later changed verification, deletion
evidence and the queue write boundaries, in source only and never compiled. Those changes are
recorded in [VALIDATION.md](VALIDATION.md); they are not covered by the route walk below.

## Fixed in this pass

1. **A double callback could crash the scan.** The on-device size pass resumed a continuation
   inside a PhotoKit handler with no guard. PhotoKit is documented to call that handler once, but
   a second call would have trapped. The same guard already existed for thumbnails and read-back;
   it now exists here too.
2. **The delete button disappeared mid-delete.** `deletableItemIDs` returned nothing while a
   deletion was in flight, so the button vanished instead of showing progress. The list is now
   stable and the button disables itself.
3. **A finished run could offer videos it had just deleted.** "Shrink more videos" reused the
   previous scan, including originals this app had removed, which would fail with "outside your
   Photos access". Deleted originals are now excluded from selections.
4. **An uncertain deletion was invisible.** A delete interrupted by a force quit appeared in the
   queue but not under "Needs attention" on the finished screen. It does now, with the copy and
   original states shown per row.
5. **The interface claimed originals are never deleted.** That stopped being true the moment
   deletion existed. The help sheet, the recovery screen, the start screen and the deletion sheet
   now say what actually happens.
6. **One system delete confirmation per video.** Found on a real device straight after the first
   TestFlight build: iOS confirms each Photos transaction, and the app was sending one transaction
   per original. Deletions now batch five at a time, with the remainder flushed when the run
   finishes, and "delete at the end" is a single transaction for the whole run. The deletion sheet
   says why.

## Flagged, deliberately not fixed

1. **A library changed outside the app goes stale.** **Closed since, rounds 2 and 3.**
   `PHPhotoLibraryChangeObserver`, a metadata-only reconciliation and a foreground authorization
   refresh are wired into `BatchViewModel`, with tests for the wiring. What is still unproven is
   how the reconciliation behaves against a real library.
2. **Album membership is not copied.** Nor are captions, keywords or ratings, which are newer
   Photos metadata. Dates, locations, filenames, favourite and hidden flags, and the file's own
   embedded metadata are.
3. **The one-video flow ignores the deletion setting.** It is a preview-first flow on purpose, and
   the help sheet says so, but a user who turns deletion on and then uses that flow gets
   inconsistent behaviour until they read the sheet.
4. **Recently Deleted holds the space for 30 days.** The app cannot shorten that and says so
   wherever deletion is offered.
5. **Nothing has run.** **Partly closed since.** The suite compiles and executes in CI, and a
   screen has rendered on a simulator. No video has been exported, no original has been deleted
   and no queue file has been written on a device, so every device claim in this document remains
   reasoning about code rather than observed behaviour.
6. **Estimates are planning bands** until three copies have been measured at that size on this
   device. A 60 fps original keeps more than the band assumes: the band is a 30 fps band, and the
   frame-rate choice scales it down rather than up, so a 60 fps source at "Keep original" is
   estimated on the 30 fps band. The band's origin is named beside the estimate.
7. **HDR is carried, not checked.** Composed exports propagate per-frame HDR metadata, but there
   is no HDR fidelity check beyond "preview it before saving".
8. **A Photos permission change made while the app is closed.** **Closed since, round 2:** the
   status is re-read on every activation, not only on the next action.

## Routes that look sound

- Deleting cannot happen without a saved, smaller, verified copy that Photos handed back, a stored
  receipt naming that copy, and a fresh look at both assets that still matches; with deleting off,
  nothing in the code path can remove an original.
- A stored queue reconciles in one place, and an interrupted save or delete is always flagged
  rather than repeated.
- Leaving the app pauses; a save already accepted by Photos is allowed to settle; the pause reason
  is shown.
- The app owns two temporary directories, one per flow, both excluded from backup. Each flow's
  cleanup reaches only its own, so a batch run cannot remove the one-video flow's copy while the
  user is still deciding whether to save it.
- The library scan never downloads an original. The two things that can fetch without a job being
  started are both previews and both say so: the list's thumbnails, and the scrub sheet's player
  item, which asks Photos for the video and can therefore start an iCloud fetch. Running a batch
  also downloads the originals it works on.
