# BatchShrink - App Store listing

App Store Connect app ID `6813894354`. Bundle `com.wilfr.videoshrink`. Version 0.1.0, build 11.
iPhone only, iOS 18 or later. Free, with no purchase, subscription or StoreKit code anywhere in the
tree.

Everything below is written to be checkable against this repository. Claims that could not be
substantiated are listed in the last section rather than smoothed over, because the point of this
listing is that a reviewer never catches it promising something it does not do.

Two things constrain the whole document:

- The app has never run on a device. Build 10 was the last build to reach testers; every build
  after it targeted a simulator. So the app cannot yet honestly be described as working, only as
  built. See `README.md` and `AGENT_LOOP.md`.
- HDR and ProRes are refused too, but at a different moment from the rest. Neither fact appears in
  the library metadata the listing steps read, so both come from the file itself: a ProRes original
  by its coded subtype and an HDR original by its transfer function (PQ or HLG), read from the
  header of videos already on the iPhone, with the network off and nothing decoded
  (`VideoShrink/Services/PhotoLibraryScanService.swift`). The scan reads the newest 400 that way,
  and before the first export the run reads every video the user actually chose, cap or no cap,
  takes the refused ones out and names them with the reason. Only a video whose original is still
  in iCloud, one the scan did not reach, or one whose read failed is left to be refused when the
  run opens it. No line below may imply that every video in the list will be processed. See
  "Unsubstantiated and open" below.

## 1. Name and subtitle

Name: **BatchShrink** (immutable - it is the display branding in `ShrinkStyle.swift` and matches
the bundle and the App Store Connect record).

Subtitle options, each within Apple's 30-character limit:

| # | Subtitle | Chars | What it says |
| --- | --- | --- | --- |
| 1 | Shrink videos on your iPhone | 28 | The action, and that it happens on the phone |
| 2 | Smaller copies of your videos | 29 | The outcome, in the app's own vocabulary |
| 3 | Make videos smaller, on iPhone | 30 | The action, phrased the way people search |
| 4 | Shrink your video library | 25 | Names the batch idea without naming "batch" |
| 5 | Smaller videos, no upload | 25 | The outcome plus the privacy position |

**Ship option 1: "Shrink videos on your iPhone" (28).**

Reasons, in order of weight:

1. It states the action in the word people type. "Shrink" is the verb in the app name, so the
   subtitle reinforces the brand term instead of competing with it.
2. "On your iPhone" is a real, load-bearing claim here: it is the reason the scan can promise it
   downloads nothing, and it is the reason a video with no network connection still works. It also
   quietly explains the iPhone-only limit rather than hiding it.
3. It leaves `compress`, the word the App Store's highest-volume search actually uses, free for the
   keyword field. Option 3 spends three characters and the highest-value keyword on a near
   duplicate of what the name already says, and option 5 claims "no upload", which is true of the
   app but is a weaker reason to tap than "smaller videos".

Options 2 and 4 are the two closest runners-up, and either is defensible. Option 2 is the safest
literal statement of what the app does; option 4 is the best if the batch angle is the thing being
sold. Option 3 only makes sense if App Store search data later shows "make videos smaller" beating
"shrink videos".

## 2. Keyword field

Apple allows 100 characters, comma-separated, and indexes the field alongside the name and subtitle
rather than as a repeat of them. Ship exactly this string (98 characters, no spaces after the
commas):

```
compress,compressor,resize,reduce,downsize,storage,space,declutter,batch,library,optimizer,trim,hd
```

What it targets:

- `compress` and `compressor` - the primary intent, and the head term in the category. Including
  the noun form matters: "video compressor" is the query people type, and Apple can match a
  multi-word query across fields, so `video` (subtitle) plus `compressor` (here) can both be
  satisfied.
- `resize`, `reduce`, `downsize`, `trim` - the same intent in other words.
- `storage`, `space` - the reason someone opens the app, not what it does.
- `declutter`, `optimizer`, `library`, `batch`, `hd` - long-tail and modifier terms that a small
  app can realistically rank for, including `batch` and `library` for the multi-video story and
  `hd` for 720p/1080p/4K searches.

Deliberately left out, and why:

- `shrink`, `video`, `videos`, `iphone`, `smaller`, `copies` - all already in the name or the
  shipped subtitle, so spending characters on them buys a duplicate of an index entry. `batch` is
  the one partial exception: it appears in the name only as part of the compound "BatchShrink", so
  it is kept in the field, but this is a judgement call rather than a certainty about how Apple
  tokenises the name.
- `icloud` - the highest-volume adjacent term, and deliberately excluded. This app does not lower
  an iCloud bill and does not free iCloud space by itself; `README.md` says so in as many words
  ("Nothing here lowers an iCloud bill", "No iCloud storage is freed"). Someone searching "icloud
  storage" wants the opposite of what happens here - a smaller *iCloud* footprint - and matching
  that query would produce installs that delete the app in a week. This is a deliberate trade of
  reach for fit and it should be revisited only if the app actually gains an iCloud-specific
  feature.
- `photo`, `photos` - considered and dropped to make room. `library` already covers the
  photo-library intent, and the plural overlaps the built-in Photos app's own name, which the app
  cannot out-rank and should not try to.

**The honest reality about generic terms.** App Store search for a utility like this is dominated
by a handful of very high-volume generic terms - "video compressor", "compress video", "storage
cleaner", "free up space". Those queries are held by apps with years of history and thousands of
ratings, and store search ranks partly on exactly that. A new app with zero ratings will not rank
for them at launch, and no keyword choice changes that. So treat that string above as aiming at
the *long tail* - `downsize`, `declutter`, `batch`, `trim`, `optimizer` - where a specific app can
appear, and treat the generic terms as a target that only becomes realistic after the app has
ratings. The realistic launch traffic here is: the brand term, the long tail, and whatever comes
from links and word of mouth. Do not build the launch plan on generic-term ranking.

## 3. Description

The first three lines are what shows before "more", so the opening is written to stand alone.
Ready to paste:

```
BatchShrink makes a smaller copy of a video and saves it as a new item in Photos. The original is
not changed.

Choose one video and preview the copy before you save it, or pick a batch and let BatchShrink work
through them on your iPhone.

Every copy is checked before it counts as saved: frames from the start, middle and end of the copy
are decoded, and its audio is decoded too. If the copy is smaller and readable, it is saved. If it
is not smaller, nothing is saved and the run tells you why.

WORK THROUGH A BATCH

Point BatchShrink at your video library and it lists what is there, largest first, with the
estimated size each copy would be. Choose the ones you want, pick 720p, 1080p or 4K and the frame
rate, and let it run. Keeping the screen awake for a long run is optional.

WHAT IT DOES NOT DO

- It does not download your videos just to look at them. Scanning the library reads sizes, lengths
  and format details from what your iPhone already has.
- It does not free storage by itself. A smaller copy sitting next to the original uses more space
  until you decide what to do with the original.
- It does not lower an iCloud bill. Photos may sync your library with iCloud under your own
  Photos settings; that is not something BatchShrink controls.

ORIGINALS ARE YOURS

Deleting is off, and stays off until you turn it on. When it is on, it is one decision for the
whole batch. Before an original is touched, its copy must be saved, smaller and confirmed in
Photos, and BatchShrink looks at both files again. If either has changed, the original is kept and
the run says why. Deleted originals go to Recently Deleted in Photos, where they stay for 30 days
before the space comes back.

VIDEOS IT WILL NOT TOUCH

BatchShrink refuses a video it cannot handle properly instead of guessing. Live Photos, edited
videos, slow-motion, time-lapse, spatial and cinematic videos, and videos from a shared or
restricted album are refused as soon as your library is listed. HDR and ProRes videos are refused
as well, and those two come from the file itself, so they are caught when BatchShrink scans the
videos already on your iPhone, and again for every video you pick before the first copy is made. A
refused video is taken out of the run and named with its reason. Only a video BatchShrink could not
read - one still in iCloud, one the scan did not reach, or one whose read failed - is left to be
refused later, when the run opens it, and so is a file with more than one video track or more than
one audio track, which nothing before the run can count. Either way the refusal is explained on
screen instead of failing quietly.

PRIVATE BY DEFAULT

Compression happens on your iPhone. There is no account, no analytics and no upload of your videos.

Keep BatchShrink open while it works; leaving the app pauses the batch.
```

Notes on the copy: no numbers are asserted that the app does not produce, no ratio is promised,
and the two things most likely to generate a one-star review - "it did not free my iCloud space"
and "it would not touch my Live Photo" - are stated in the listing before the user installs.

## 4. Screenshot plan

Six screenshots, in story order. Each caption is copy and is shown in the App Store, so it is kept
short, specific and free of hype. "Must show" is what has to be genuinely on screen for the
screenshot to be honest; none of these may be mocked up, and none may show a state the app cannot
reach.

**Hard constraint on all six, updated.** The app has never rendered a screen on a device. What has
changed since this plan was written is the simulator: the round 18 launch job installs the
standalone app on a simulator and reaches the batch screen, so screens 1 and 2 - the introduction
and the home screen, neither of which needs a library - are now known to render and a layout
capture from a simulator is possible. That job saves no screenshot of its own: it asks the
interface directly and attaches the screen to its result bundle only when a step fails, so a
capture needs a screenshot step added to it or a simulator run on a Mac. A capture taken that way
is honest for layout and for nothing else. Screens 3, 4, 5 and 6 show real library data, a real
estimate and a real run, so they still cannot honestly exist until the app has run against an
actual library on a real iPhone. See "Unsubstantiated and open" below.

1. **Caption: "Smaller copies of the videos you keep."**
   Must show: onboarding step 1 of 3, headline "Keep the moment. Lose the weight.", the
   "Compressed on your iPhone" footnote, and the step indicator reading 1 of 3. This is a real
   first-launch screen (`ShrinkOnboarding.swift`). No savings figure on this screen, because none
   exists yet.

2. **Caption: "Pick the videos taking up space."**
   Must show: the home screen on `BatchStartScreen` - eyebrow "A little room for more", headline
   "Less weight. More memories.", the "Start with your video library" card, the Originals row in
   its default state, and the "Find my videos" button. The Originals row must show the shipped
   default (keeping every original), not a toggled-on deleting state.

3. **Caption: "See what could get lighter, before you choose."**
   Must show: the library summary on `BatchSummaryScreen` - "N videos can get lighter.", the
   "ROOM TO RECLAIM" stat with its range and the words "potentially smaller", the detail line
   "Estimated for X of Y videos" with real counts, the original-and-copy size bars, and the line
   about storage being reclaimed after originals are deleted and cleared from Recently Deleted.
   The figure must be a real estimate from a real library and must be labelled as an estimate on
   the screen itself, because it is one.

4. **Caption: "Choose the ones you want, largest first."**
   Must show: the selection screen on `BatchSelectionScreen` - "Make room.", "N videos to
   explore", the two-column thumbnail gallery with genuine Photos-library thumbnails, at least one
   item selected with its visible check and border, the size and duration badges on the tiles, and
   the Quality row. The thumbnails must be real library items, not stock images.

5. **Caption: "Set the picture size and frame rate."**
   Must show: the quality sheet on `QualitySelector` - the Picture size pills (720p, 1080p, 4K)
   with their codec captions, a real per-video saving range in the estimate block, the Smoothness
   pills, and the "These are estimates. Real sizes appear when it finishes." line. The estimate
   must be visible as an estimate, not presented as a measurement.

6. **Caption: "Measured results, and every copy confirmed in Photos."**
   Must show: the finished screen on `BatchFinishedScreen` - the "Finished" eyebrow, the "N videos,
   lighter." headline, the "A LITTLE LIGHTER" card with measured bytes and the copy count, and the
   read-back line ("All N copies confirmed in Photos."). The numbers must come from a real run, and
   the screenshot must not be taken until a run has actually happened on a device.

If a sixth-slot swap is ever wanted, the honest alternative is the Originals sheet
(`DeletionSheet.swift`), which states the 30-day Recently Deleted window and the confirmation
rules. It is a real screen and reachable. It is not the lead recommendation because leading with a
deletion screen in a screenshot set mainly sells caution, and the story above already carries it.

## 5. App Store Connect metadata

### Promotional text (170 characters)

Ship this (160 characters):

```
Make smaller copies of your videos, on your iPhone. Copies are checked before saving, scans never download originals, and deleting is off unless you turn it on.
```

It is deliberately longer-lived than "What's New" - promotional text can be edited without a new
build - so it states the three durable, differentiating facts (smaller copies, checked before
saving, deleting off by default) rather than anything version-specific.

### What's New for build 11

Build 11 is the first public release, so this is the first-release note:

```
First public release.

BatchShrink makes smaller copies of your videos and saves them as new items in Photos, working
through a batch on your iPhone.

Before a copy counts as saved, frames from the start, middle and end of the copy are decoded, and
its audio is decoded too. Deleting originals is off by default. When you turn it on, the copy must
be saved, smaller and confirmed in Photos, and both the copy and the original are looked at again
immediately before the original is touched.
```

This describes what is implemented in the build, which is all that can be said about a build that
has not run on a device. It must not be edited to describe behaviour observed on a phone until
that has actually happened.

### Outstanding before submission: support and privacy URLs

`docs/DEVELOPMENT_REVIEW.md` records that privacy and support pages do not exist yet ("finish icon,
store assets, privacy/support pages"). Both URLs are required fields in App Store Connect, and
submission is blocked without them. Note also that the app icon does exist in the tree
(`VideoShrink/Resources/Assets.xcassets/AppIcon.appiconset`) and a privacy manifest already exists
(`VideoShrink/Resources/PrivacyInfo.xcprivacy`); it is the hosted web pages that are missing.

**Privacy policy - what it must contain.** Every statement below is grounded in what the app
actually does, so the page and the app agree:

- What is collected: nothing leaves the device. There is no account, no analytics, no advertising,
  no backend and no app-managed upload of media (`README.md`).
- Photos access: the app reads video metadata (sizes, durations, thumbnails) and, for videos already
  on the device, the codec and colour details in the file header, to build the estimate and to refuse
  formats it cannot handle; it reads the videos the user chooses in order to make copies. State that
  with limited access only the permitted videos are visible.
- Photos writing: copies are saved as new Photos items; the optional delete moves originals to
  Recently Deleted, where they remain for 30 days.
- iCloud: scans do not download originals; videos chosen for processing may be downloaded through
  PhotoKit, and Photos may sync new items under the user's own iCloud settings. The developer
  receives none of it.
- Logging: only fixed pipeline stage names and generic failure categories are logged; no
  filenames, paths, identifiers, coordinates or media contents (`README.md`, rule 8).
- The disk-space API use is declared in the privacy manifest.
- Local data: the run queue is stored in a file on the device and goes when the app is deleted.
- A contact address for privacy questions, and the date the policy took effect.

**Support page - what it must contain.**

- One paragraph on what the app does and what it does not free (storage, not an iCloud tier).
- Which videos are refused, named plainly: Live Photos, edited, slow-motion, time-lapse, spatial,
  cinematic, and shared or restricted album items, refused straight from the list; and HDR and
  ProRes, refused once the app reads the file - during the scan for videos already on the iPhone,
  and for every video the user picked before the first copy is made. Say plainly that a video the
  app could not read (one still in iCloud, one the scan did not reach, or one whose read failed)
  can be refused later in the run, so nothing implies every video in the list will be processed,
  and name the one other late refusal: a file with more than one video track or more than one audio
  track is refused when the run opens the original, because nothing before that can count an
  original's tracks.
- How saving works (a new Photos item) and how deleting works (off by default, one confirmation,
  30 days in Recently Deleted).
- Why a run can pause on its own (the app left the foreground, or the phone got warm).
- How to change Photos access in iOS Settings if videos seem to be missing.
- How to report a problem, and what to include: iPhone model, iOS version, app version and build,
  and what happened; plus a note that the developer does not want users to send personal videos.

### Other App Store Connect fields still to fill

- Category: Utilities or Photo & Video; pick one as primary and one as secondary.
- Age rating questionnaire.
- App Privacy "nutrition label", which must match `PrivacyInfo.xcprivacy` and the privacy page.
- Export compliance is already answered in the app config (`ITSAppUsesNonExemptEncryption` is
  `false` in `app.json`), which should remove the per-build question.
- Copyright holder and a support contact address. No support inbox exists anywhere in the
  repository, so one has to be created before the support URL can point anywhere.

## 6. The honest launch-positioning problem

This is the part of the listing that most needs to be written deliberately, because it is the
part a competing listing would write differently.

BatchShrink is cautious in two specific ways. It refuses a video it cannot reproduce faithfully -
a Live Photo, an edited clip, slow-motion, time-lapse, spatial, cinematic, a shared-album item, or
an HDR or ProRes original - rather than processing it and losing something. And it asks the user to
think before deleting:
deleting is off until it is turned on, it needs a saved and re-checked copy first, and a deleted
original sits in Recently Deleted for 30 days before the space returns.

A faster app would say yes to more of those videos and delete more readily. BatchShrink says no to
some of them, and that is the point rather than the apology. The framing to use is not "we are
careful and they are not" - the honest statement is that both approaches are reasonable, and they
are choosing different things. An app that processes a Live Photo without preserving its paired
motion is not reckless; it is making a different trade, and for many people that trade is fine.
BatchShrink is for the person who would rather be told "not this one" than find out afterwards
that the thing they cared about is gone.

So the listing should say, plainly, in the description and in the support page:

- There are videos this app will not shrink. If yours is one, it says so on screen instead of
  doing it anyway.
- There is a step where you decide about originals, and it is off by default, because the app is
  not entitled to make that choice for you.

That is the reason to choose it, and it is stated without pretending anyone else is doing it wrong.
The one thing that would undercut this position is overstating coverage. Do not add a screenshot
or a line implying broad format support, and do not soften the refusal list to make the app look
more capable than it is. A user who is told "not this one" and reads that the app promised it up
front stays; a user who is promised everything and gets a refusal writes the review that says it
did not work on their Live Photos.

## Unsubstantiated and open

Flagged rather than hidden, in the order they matter:

1. **The HDR and ProRes detection has never met a real original.** The refusal is implemented and
   reachable: `VideoVerificationService` reads each format description of an original, refuses an
   Apple ProRes coded subtype (the six ordinary ones and the two RAW ones) and a PQ or HLG
   transfer function, and throws `PipelineError.unsupportedOriginal(reason:)` carrying
   `AssetRules`' own sentence. The same read runs in the scan, over videos already on the phone,
   and in the run over every video the user picked, before the first export; a video whose original
   could not be read is left to be refused when the run opens it, as is one whose original turns
   out to carry more than one video or audio track - a rule that lives in the same read but is not a
   format refusal, so the scan and the pre-run pass do not decide it. The test suite exercises
   every branch against constructed format descriptions. What has not happened is a real HDR or
   ProRes video on a real phone, so nothing here says the detection catches every such file. The
   description above therefore says "refused", not "detected reliably".
2. **Nothing in the listing may be described as observed behaviour, with one narrow exception
   since this was written.** No export has run, no original has been deleted and no queue file has
   been written on a device (`README.md`, `AGENT_LOOP.md` N19). A screen *has* now been rendered:
   the round 18 launch job installed the standalone app on a simulator, tapped the introduction's
   Skip control and reached the batch screen, first observed green at `780f14f`. That is one
   navigation on a simulator with no photo library, so it is enough to say the app launches and
   draws its own interface, and not enough to describe a screen as it behaves. Every screenshot
   above and every "what it does" sentence otherwise still rests on implemented source rather than
   on the app having worked - and the newest of that source has not been compiled at all, because
   the account's Actions runners stopped starting on 2026-09-23, so nothing on `main` after
   `31b6245` has been built.
3. **"Free" is a store setting, not a repo fact.** The tree contains no purchase, subscription or
   StoreKit code, and `docs/DEVELOPMENT_REVIEW.md` lists a purchase model as later work, so there
   is nothing to buy inside the app. The App Store price itself is set in App Store Connect and
   cannot be verified from this repository.
4. **The savings figures are estimates until a run measures them.** Screenshot 3 shows an
   "estimated" range, which is what the app actually produces before a run; the app also says that
   a smaller file is not freed storage. Keep both facts visible in any screenshot of the summary
   screen.
5. **Device testing gates submission.** `docs/DEVELOPMENT_REVIEW.md` requires device validation
   before wider testing, and build 11 has reached no device. Listing copy can be written now; it
   cannot honestly be published, and its screenshots cannot honestly be taken, before the app has
   run on a real iPhone.
