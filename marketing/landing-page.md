# BatchShrink - landing page

Copy and structure for a single page. Sections are in the order they should appear.
Square brackets mark a placeholder that a human must fill in before this goes live;
nothing in this file makes a claim about a real run, a real saving figure, a tester or a
review, because none of those exist yet.

---

## 1. Structure

| # | Section | What it is for |
| --- | --- | --- |
| 0 | Header | Wordmark plus one action. Nothing else. |
| 1 | Hero | Say what BatchShrink is and what it does to your library, in the first line. |
| 2 | What it does | Four short blocks: the metadata-only scan, copies instead of edits, the copy check, on-device and offline. |
| 3 | How it works | Four steps so a reader can picture the whole job before installing anything. |
| 4 | What it will not do | The differentiator. Care with the library, written as a promise, including the videos it refuses. |
| 5 | The honest limits | Everything the app cannot do for you, stated plainly, including the state of this build. |
| 6 | FAQ | The questions a suspicious person asks, answered without hedging. |
| 7 | Closing action | One action, one supporting line. |
| 8 | Footer | Privacy line, support contact, version. |

Total: one page, eight blocks, one action repeated at the top and the bottom.

### Deliberately not on this page

- No pricing table, no tiers, no "Pro" column. There is one free app.
- No testimonials, star ratings, download counts or "trusted by" logos. None exist, and inventing
  the shape of them would be a lie even with the numbers left blank.
- No before/after storage screenshots or "freed 12 GB" figures. The app has never measured a
  saving on a real library.
- No comparison table naming other apps. The careful-with-your-library argument does not need a
  rival's name in it, and naming one invites a fight this page cannot evidence.
- No roadmap, changelog, blog, newsletter signup or "coming soon" feature list. A utility page
  that promises future features reads as a product that is not finished.
- No countdowns, "limited time", waitlist pressure or chat widget.
- No autoplaying video, no background music, no scroll-jacking.
- No team page, company story or investor paragraph. The reader wants their storage warning gone,
  not the founder's biography.
- No feature grid wider than the four blocks in section 2. Anything that can be expressed as a
  sentence belongs in the FAQ instead.

---

## 2. Copy

### 0. Header

> BatchShrink
>
> [Get BatchShrink] <- single button, target of the closing action below

No menu. There is nothing else on this page to navigate to.

### 1. Hero

**Headline**

> BatchShrink makes smaller copies of your iPhone videos. Your originals stay where they are.

**Subhead**

> It looks through your library, shows you what a smaller copy would likely save, makes the copy,
> checks it, and saves it as a new video in Photos. Deleting your originals is off unless you turn
> it on.

**Action**

> [Get BatchShrink]
>
> Free. iPhone only, iOS 18 or later.

**Status line under the action (keep it while this is true)**

> This build compiles and its automated test suite runs green on a build machine. It has not been
> used on a phone yet, so this page reports no real-world results.

**Hero visual - what is needed, and why**

One screenshot, taken from the app itself, of the library list mid-scan:

- a column of video thumbnails with duration under each one,
- the size Photos reports for each video,
- the estimated saving shown as a range next to the ones that have been sized,
- a few rows marked as already shrunk,
- the running selection count and the running time estimate on screen,
- one selected row visible with its quality choice, so the reader can see that they choose.

Why this image: this is a utility, and the reader's question is "what will it actually show me
about my videos". A grid of thumbnails with sizes is the answer, and it is also the moment the
app looks like it knows something about their library that they do not. The relief moment is a
second screenshot, not the hero: the finished screen, showing measured original bytes against
measured copy bytes, saved and skipped counts, and "0 originals deleted". Use that one beside
section 5 or in the FAQ answer about originals, never as decoration.

Two rules for whoever ships this page:

- The screenshot must come from the app. A drawn mockup of a screen that has never rendered is
  the one kind of image this page cannot afford, because the whole pitch is that the app tells
  the truth about what it did. A capture from a simulator is honest for layout; do not caption it
  as a device result.
- If no capture exists yet, ship the hero with no image rather than a stand-in. The headline and
  subhead carry the page on their own, and an abstract gradient or a stock iPhone would weaken
  exactly the claim the page is making.

### 2. What it does

**Looking at the library does not download the library.**

The scan reads what Photos already knows: how many videos you have, how long they are, their pixel
sizes, and the flags for the formats the app turns down. Sizes come from the documented Photos API
where the system reports them, and otherwise from videos that are already on the phone, asking
Photos with network access switched off. Videos that live only in iCloud are counted and listed,
and left out of the estimate instead of being downloaded to produce one.

**It makes copies. It does not edit your videos.**

A smaller copy is saved as a new item in Photos. Your original is not overwritten, moved or
trimmed. The copy keeps the original's creation date, filename, location and favourite and hidden
flags.

**Every copy is checked before it is saved.**

Each copy is opened and tested: a frame is decoded from the start, the middle and the end of the
track, the audio is decoded rather than assumed, and the duration, track counts, shape and codec
are compared with the original. After Photos accepts the save, the app asks for the new item back
and compares it with what it measured before saving. A copy Photos cannot hand back is reported as
not read back, not as a success.

**Nothing leaves your phone.**

There is no account, no sign-in and no subscription. The app has no network connection of its own
and no server to send anything to. The compression runs on the iPhone. The one thing that uses the
network is Photos itself: a copy you save is a new video, so your own iCloud Photos settings apply
to it exactly as they would to a video you recorded.

### 3. How it works

**1. Scan your library.** BatchShrink lists your videos and the space a smaller copy might save.
No download, and nothing is changed.

**2. Choose your videos and the quality.** Pick a few, or the whole batch. Choose 1080p HEVC (the
default), 720p, or 4K, and leave the frame rate alone or lower it. You see the estimate for the
selection before anything runs.

**3. Shrink.** The app takes them one at a time, makes the copy, checks it, saves it to Photos and
deletes its own temporary file. A video that will not get smaller is skipped rather than saved as
a wasted copy, and a failure on one video does not stop the rest.

**4. Decide about the originals.** Leave them all, delete them as you go, or review them at the end
and confirm. This is off by default. If you never turn it on, nothing is ever deleted.

### 4. What it will not do

This is the part that matters, so it is not a footnote.

**It will not touch an original to make a copy.** The copy is a new item. The original is exactly
where it was, with its own name, date and place.

**It will not delete anything on its own.** Deleting is off until you turn it on. When it is on,
each deletion has to pass all of this first: the copy was saved, the copy is smaller than the
original, the copy passed verification, Photos handed the copy back when the app asked for it, the
run wrote down a receipt naming that copy and what both videos looked like, and both videos still
match that receipt when they are looked at again immediately before the delete. Anything else and
the original stays, with the reason shown in the run's list. The app never deletes on the strength
of a completed export, and it never retries an interrupted delete blindly.

**It will not upload your library.** Nothing is sent anywhere. A copy you keep is a new video in
your Photos library, and Photos does with it what your iCloud Photos settings say.

**It will not turn down a video silently.** These are refused, with a readable reason, rather than
run through and quietly changed:

- Live Photos
- edited videos, and trimmed or composed ones
- slow-motion
- time-lapse
- spatial videos
- cinematic videos
- HDR videos
- ProRes videos
- shared or restricted items
- anything that is not a video, or a video with more than one audio track

That list is the point of the app. A smaller copy of a slow-motion clip loses the slow motion; a
flattened cinematic export loses the moving focus point; an SDR-shaped export of an HDR video
changes how it looks. BatchShrink is the option you pick when you would rather be told "not this
one" than find out later that something about your video changed. Some of those videos may become
supported once they have been tested properly; until then they are refused rather than guessed at.

### 5. The honest limits

Read this before you install it.

**It does not free iCloud space by itself.** Adding a copy uses more storage until the originals
are removed. If you turn deletion on, the originals go to Recently Deleted, where Photos keeps
them for 30 days, and that is when the space comes back, after your devices have synced. Nothing
here lowers an iCloud plan or changes a bill.

**Saving a video is not the same as saving storage.** Keeping both copies uses more until you deal
with the original. That is why deleting is a separate, deliberate step and not the default.

**The estimate is an estimate.** Before the first copy is made, the app plans with a published
range for a 1080p copy and reports each video's saving at the cautious end and the hopeful end.
After three copies have finished on your phone, it uses the measurements those runs produced
instead. The summary after a run reports measured bytes, and that is the only number that is a
measurement.

**Some videos will not get smaller.** A copy that would be the same size or larger is skipped, and
the original is left alone.

**Videos stored only in iCloud have to come down before they can be shrunk.** The scan does not
download them; the run does. A batch needs a connection and room on the phone for the download.
Opening the scrub preview also asks Photos for the video, which can start a download.

**The app has to stay in front.** iOS pauses work when you leave an app, and BatchShrink takes no
background entitlement. Leaving or locking the phone pauses the run; it comes back where it left
off. There is an optional setting that holds the screen awake while a run is active.

**A run is a durable list, not a promise of exactly-once.** The queue is written to a small file
between steps, so a run survives a close. If the app stops between Photos accepting a copy and the
app writing that down, that item is flagged for you to check in Photos instead of being run again.

**A copy is a re-encode, and the checks are sampling, not proof.** Frames near the start, middle
and end are decoded, and the audio is decoded, but that is not a full playback of the file. The
copy is meant to look and sound like the original at a smaller size; it is not a bit-for-bit copy.
Captions, keywords, ratings and album membership are not carried over to the copy.

**Where this build stands.** BatchShrink has been compiled and its automated test suite passes on
a build machine, including the deletion gate, the copy verification and the scan rules. It has not
yet been run on a phone. So there are no measured savings, no screenshots of a real run and no
reports from users on this page, and there will not be any until the device testing is done. What
comes back from that will be reported here.

### 6. FAQ

**Does it upload my videos anywhere?**

No. The app has no network connection of its own, no account and no server. Compression and
checking happen on the iPhone. The separate thing that uses the network is Photos: a copy you keep
is a new video in your library, so it syncs to iCloud Photos if that is how you have Photos set
up, exactly like any video you record.

**What happens to my originals?**

Nothing, by default. BatchShrink saves the smaller copy as a new item and leaves the original
untouched, so you can compare them in Photos yourself. Deletion is a separate setting that is off
until you turn it on, and even then the originals go to Recently Deleted rather than disappearing.

**Does this really free up iCloud space?**

Only after you delete the originals and Photos clears them out of Recently Deleted, which takes 30
days, and then only once your devices have synced. Until that point you are storing both, which is
more than you were storing before. The app does not change your iCloud plan and cannot make an
iCloud bill smaller. If you want the space back without waiting, Photos gives you the usual options
to remove items from Recently Deleted straight away; BatchShrink does not do that for you.

**Why does it refuse some videos?**

Because it cannot make a smaller copy of them without changing something you would notice.
Slow-motion, time-lapse, Live Photos, spatial and cinematic videos all carry behaviour that a plain
smaller file does not reproduce. An HDR or ProRes original has a look or a format the app's
presets do not preserve or match. An edited video is stored differently and the app will not guess
which version you meant. Refusing with a reason is the whole design: the alternative is an app
that quietly returns something slightly different, and by the time you notice, the original may be
gone.

**What does it cost?**

Nothing. There is no subscription, no account and no in-app purchase. There is nothing to sign up
to.

**What happens if it is interrupted?**

A run is written down as it goes, so closing the app or losing a connection pauses it with what has
finished so far. The next launch offers the run back. The one case it does not work out by itself
is a stop in the moment between Photos accepting a copy and the app recording it: that item is
marked "check in Photos" rather than run again, so you do not end up with two copies. If a delete
was interrupted, the original is left as uncertain and is never retried on its own.

**Which phones and which iOS?**

iPhone, iOS 18 or later. There is no iPad version.

**Can I undo a deletion?**

Only from Photos. Deleted originals sit in Recently Deleted for 30 days, and you restore them
there; after that, Photos removes them for good. That is also the point at which the space is
actually reclaimed.

**Do I have to sit and watch it?**

No, but the app has to stay in front of you. There is no background or overnight mode, and locking
the phone pauses the run. There is an option to hold the screen awake while a run is going, which
uses more battery and runs warmer.

**Is the smaller copy as good as the original?**

It is a re-encode, so no, not bit for bit. It is made at the quality you choose, checked before it
is saved, and read back from Photos afterwards. Preview it in Photos before you delete anything,
especially for a video you care about.

### 7. Closing action

**Heading**

> BatchShrink makes the smaller copy. You decide about the original.

**Action**

> [Get BatchShrink]
>
> iPhone, iOS 18 or later. Free. Originals are never touched unless you turn deletion on.

**Current form of this action.** The app is not on the public store yet, so the button cannot say
"download on the App Store". While that is true, the button goes to [TestFlight invite link or a
one-line request address], and the line under it reads: "Currently in testing. This link gets you
the build if you are on the list." Swap both for the store badge and its standard line on the day
the app is published, and delete this paragraph.

### 8. Footer

> BatchShrink
>
> No account, no analytics, no ads. Your videos are not uploaded anywhere by this app.
>
> Support: [support email or support page]
>
> Version 0.1.0. iPhone, iOS 18 or later. Made by an independent developer.

---

## 3. Meta

**Meta title** (50 characters)

> BatchShrink - smaller copies of your iPhone videos

**Meta description** (160 characters)

> BatchShrink makes smaller copies of the videos filling up your iPhone, saves them as new Photos
> items, and leaves your originals alone unless you say otherwise.

**Social share title**

> BatchShrink: smaller copies of your iPhone videos, originals untouched

**Social share description**

> Finds the videos taking up room, shows what a smaller copy would likely save, checks each copy
> before saving it as a new Photos item, and only deletes originals if you turn that on.

**Canonical path**

> /

No other meta tags. There is no keyword stuffing to do here: the searchable phrase is the product
name plus "iPhone video storage" or "smaller video copies", and the description already carries
both in plain words.

---

## Appendix: notes for whoever ships this (not part of the page)

### Headlines rejected, and why

| Rejected | Why |
| --- | --- |
| "Free up your iCloud storage fast." | Promises a storage outcome the app does not deliver on its own, and "fast" is unmeasured. The scan cannot even produce a saving without the user deleting originals. |
| "Reclaim your iCloud space." | Same problem stated more confidently. Space comes back 30 days after a delete, if the devices sync, and only if the user chose to delete at all. |
| "Shrink your library." | Names neither the product nor the offer, and could mean downsizing a photo library, a camera roll or a video folder. |
| "Delete the videos, keep the memories." | Describes the competitor behaviour this app is the alternative to, and misstates the default: deletion is off and most readers should leave it off. |
| "The safest way to shrink your videos." | A superlative nobody can back. Also implies other apps were assessed, which they were not. |
| "Turn bulky videos into lightweight copies in seconds." | "In seconds" is a performance claim with no measurement behind it; HEVC encoding heats a phone, and the app's own docs say long batches are a leave-it-running job. |
| "Never lose a video again." | An absolute guarantee. The app can still be interrupted mid-save, and it says so in its own docs. |
| "BatchShrink - your photos, supercharged." | The brief's banned register, and it says nothing true or specific. |

### Claims on this page, and where each one comes from

| Claim | Evidence in the repo |
| --- | --- |
| Finds videos in the library and estimates the space a smaller copy might save, as a range | `docs/BATCH_PHASE.md`, "How the savings estimate works": 4-8 Mbps planning band for 1080p HEVC, replaced by a measured band after three finished compressions. |
| The scan does not download anything | `docs/BATCH_PHASE.md`, "What the prescan can see": built from PhotoKit metadata, downloads nothing; the fallback size pass asks PhotoKit with network access disabled. `VideoShrink/Services/PhotoLibraryScanService.swift` carries the same comment. |
| iCloud-only videos are counted and listed but left out of the estimate | `docs/BATCH_PHASE.md`, same section. |
| Sizes come from a documented Photos API | `docs/BATCH_PHASE.md` names `PHAssetResource.dataSize`, "public API from iOS 27", and states that no undocumented key-value lookup is used. |
| Copies are saved as new Photos items, originals untouched | `README.md`, "Pipeline and safety rules"; `docs/BATCH_PHASE.md`, "Deleting originals" (deleting is opt-in and off by default). |
| A copy keeps creation date, filename, location, favourite and hidden flags | `docs/BATCH_PHASE.md`, "What travels with a copy". The same section is the source for the limits that captions, keywords, ratings and album membership are not copied. |
| The copy is checked by decoding frames near the start, middle and end, and by decoding audio | `docs/BATCH_PHASE.md`, "Checking a copy"; `README.md`, "Pipeline and safety rules" rule 4. |
| The copy is read back from Photos and compared with what was measured before saving | Same two sources; "a copy Photos cannot hand back is not treated as a failure" from `docs/BATCH_PHASE.md`. |
| The checks are sampling, not a full playback proof | `docs/BATCH_PHASE.md` ("None of this is an end-to-end playback proof") and `README.md` ("This is not full-file decode..."). |
| No account, no subscription, no in-app purchase, no server | `README.md`: "no overnight or background feature, subscription, user account, product analytics, advertisement, backend or app-managed media upload". No StoreKit or purchase code exists in the tree. |
| The app has no network connection of its own | `README.md` and `docs/TESTFLIGHT.md` ("no network of the app's own"). `npm run validate:native` fails the build if `URLSession` appears anywhere in the application Swift, in `AGENT_LOOP.md`. |
| Photos may still sync a saved copy | `README.md`: "Photos can download from and sync the new item to Apple's existing iCloud Photos service according to the user's settings." The app's own copy says "BatchShrink does not upload your videos. Photos may sync with iCloud" (`VideoShrink/Presentation/ShrinkScreens.swift`). |
| The deletion gate, item by item | `docs/BATCH_PHASE.md`, "Deleting originals", lists the gate exactly as summarised here; `VideoShrink/Models/DeletionPolicy.swift` implements it. |
| Deleted originals go to Recently Deleted for 30 days, and that is when space returns | `docs/BATCH_PHASE.md`, "Deleting originals"; `VideoShrink/Presentation/DeletionSheet.swift` and `BatchScreens.swift` say the same to the user. |
| The app never deletes on a completed export alone, and never retries an interrupted delete blindly | `docs/BATCH_PHASE.md`: "The app never deletes on the strength of an export alone"; an item recorded as deleting comes back as uncertain and is never retried automatically. |
| The one-video flow never deletes | `README.md`, "Pipeline and safety rules" rule 1. Not stated on the page, but the "only deletes if you turn it on" wording stays true because of it. |
| The full list of refused formats, with reasons | `VideoShrink/Models/AssetRules.swift`, which holds the sentences the interface shows, and `VideoShrinkTests/EligibilityTests.swift`, one case per trait. The reasons given in the copy (slow motion loses slow motion, a flattened cinematic export loses the focus point, an SDR export changes an HDR look) are the comments and rationale in `AssetRules.swift`, `docs/NEXT_PHASE.md` and `docs/CODECS.md`. |
| Videos that will not get smaller are skipped, not saved | `docs/BATCH_PHASE.md`: "Copies that do not shrink are skipped, never saved"; `README.md` default table: "Save disabled when output is equal or larger". |
| One video at a time, a failure does not stop the run | `docs/BATCH_PHASE.md`, "Queue behaviour". |
| Quality options: 1080p HEVC default, 720p, 4K, frame rate left alone or lowered | `docs/BATCH_PHASE.md`, "Quality options". |
| The queue is durable, and a mid-save stop is flagged for the user to check in Photos | `docs/BATCH_PHASE.md`, "Surviving a close". |
| Foreground only, no background entitlement, optional keep-screen-awake | `README.md` defaults table and `docs/BATCH_PHASE.md`, "Leaving it alone". |
| iCloud-only videos must download before a run, and the scrub preview can start a fetch | `app.json` `NSPhotoLibraryUsageDescription`; `docs/BATCH_PHASE.md`, "Thumbnails" ("It is the one place in the app where looking at an iCloud video can start a fetch, and the sheet says so"). |
| iPhone only, iOS 18 or later, no iPad version | `app.json`: `platforms: ["ios"]`, `supportsTablet: false`, `deploymentTarget: "18.0"`. |
| Version 0.1.0 | `app.json` `version`. Build number 11 is in the same file, but version 0.1.0 is what the page should show; adjust to whatever ships. |
| The build compiles and its automated test suite runs on a build machine, and it has not run on a phone | `README.md` status block and "Unverified assumptions and release gate"; `AGENT_LOOP.md` build log; `docs/BATCH_PHASE.md` ("The app has never actually run"). |

### Wanted to claim, could not substantiate

- **Any saving figure.** Not one byte has been measured on a real video, so the page says "smaller
  copy" and "estimate" and never a number, a percentage or a typical library size.
- **"Frees up your iCloud storage."** The app makes the copy; the freed space depends on the user
  deleting originals, on Photos clearing Recently Deleted after 30 days, and on the devices
  syncing. `docs/BATCH_PHASE.md` explicitly lists freeing iCloud storage as not claimed.
- **Any device result of any kind.** No screen has rendered, no export has run, no original has
  been deleted, no queue file has been written on a device. That rules out screenshots captioned
  as a real run, timings, "works on iPhone 15 Pro Max", and any before/after pair.
- **Testimonials, tester counts, star ratings.** None exist; build 10 reached testers but no
  feedback has been recorded anywhere in the repo.
- **"Verified" or "tested" as a quality claim.** The honest verb is "checked before it is saved",
  which is what the code does, not "tested and proven".
- **Approval, review status, or App Store presence.** There is an App Store Connect record and a
  TestFlight upload, but no evidence of approval, publication or availability, so the closing
  action is written for the testing phase and the "download on the App Store" line is explicitly
  marked as a later swap.
- **Anything about the accuracy of the estimate.** The band is a planning assumption until three
  copies have finished, and no run has finished. The page therefore describes the mechanism and
  not its accuracy.
- **HDR and ProRes refusals described as fully proven.** The detection exists and is tested
  against fakes (`VideoShrink/Services/VideoVerificationService.swift`,
  `VideoShrinkTests/EligibilityTests.swift`), but it has never seen a real HDR or ProRes original.
  The copy says the app refuses them, which is true of the code, and does not claim the detection
  catches every file.
- **A precise test count for the status line.** The brief says 263 cases, the older docs say 162,
  and the tree currently declares 264 `func test` cases across ten test files. That
  disagreement is why the page says "its automated test suite" instead of a number; put a figure
  in only after a CI run confirms one.
- **Support contact details.** None exist in the repo, so the footer keeps a placeholder rather
  than inventing an address.
- **The app icon and screenshots.** The repo carries a generated placeholder icon
  (`docs/TESTFLIGHT.md`), and no rendered screen exists to capture. Both are marked as work to do,
  not as assets the page can use.
