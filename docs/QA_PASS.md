# Product-tester pass

This is a static pass over the app's routes: every path a user can take, read for ways it could
break, mislead, or behave worse than it should. It is not device testing, and it is not the
XCTest suite, which still has not been executed anywhere.

Routes walked: first launch with and without a stored queue, a restored run in every recorded
state, scanning (allowed, limited, denied, empty library, huge library, cancelled, backgrounded),
selection (sizes known and unknown, already-shrunk videos, unsupported media, bulk shortcuts,
quality and deletion changes), a run (retrieval, transcode, verification, disk, save, read-back,
heat, background, pause, finish early, force quit), deletion in both modes, the one-video flow
end to end, and the queue file across every transition.

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

6. **A library changed outside the app goes stale.** If a video is edited or removed in Photos
   after the scan, the app still lists it and the item fails with a readable message instead of
   refreshing. `PHPhotoLibraryChangeObserver` plus a re-scan is the real fix.
7. **Album membership is not copied.** Nor are captions, keywords or ratings, which are newer
   Photos metadata. Dates, locations, filenames, favourite and hidden flags, and the file's own
   embedded metadata are.
8. **The one-video flow ignores the deletion setting.** It is a preview-first flow on purpose, and
   the help sheet says so, but a user who turns deletion on and then uses that flow gets
   inconsistent behaviour until they read the sheet.
9. **Recently Deleted holds the space for 30 days.** The app cannot shorten that and says so
   wherever deletion is offered.
10. **Nothing has run.** 95 XCTest cases exist and none have executed, because there is no Mac
    here. Everything in this document is reasoning about code, not observed behaviour.
11. **Estimates are planning bands** until three copies have been measured at that size on this
    device. A 60 fps original keeps more than the band assumes, which the selector says.
12. **HDR is carried, not checked.** Composed exports propagate per-frame HDR metadata, but there
    is no HDR fidelity check beyond "preview it before saving".
13. **A Photos permission change made while the app is closed** is only discovered on the next
    action, which then fails with a readable message rather than a re-request.

## Routes that look sound

- Deleting cannot happen without a saved, smaller, verified copy that Photos handed back; with
  deleting off, nothing in the code path can remove an original.
- A stored queue reconciles in one place, and an interrupted save or delete is always flagged
  rather than repeated.
- Leaving the app pauses; a save already accepted by Photos is allowed to settle; the pause reason
  is shown.
- The temporary workspace holds at most one output, is excluded from backup, and cleanup is
  confined to the app's own directory.
- The library scan never downloads an original, and thumbnails are the only preview traffic.
