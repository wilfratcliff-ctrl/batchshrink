# BatchShrink social pack

For the solo developer. This is a content pack you can shoot from, not a campaign plan and not a
promise of reach.

## 0. What is true today, before anything gets written

Anything you post has to survive one question: could a stranger with a full iCloud library read
this and feel that they were told the truth? These are the facts the copy in this document is
built on.

| Fact | Status |
| --- | --- |
| BatchShrink finds videos in Photos, estimates what smaller copies would save, makes smaller copies as new Photos items, checks each copy, and can optionally delete originals behind a gate that is off by default | Implemented source. Its automated test suite compiles and passes in CI |
| A scan never downloads originals | Implemented source. Not watched on a real device yet |
| The app is an iPhone app, iOS 18+, and free | Decided |
| The app has never been run on a device | True. Build 10 is the last build known to have reached testers |
| Any number for saved space, time saved, installs or users | Does not exist |
| Any testimonial | Does not exist |

Two consequences shape the whole pack:

1. You cannot show the app working, because you have not seen it work. Every format below is either
   shootable with no app screen at all, or explicitly gated on a device run.
2. You cannot say the product frees space. What exists is a smaller copy and, optionally, the
   original moved to Recently Deleted for 30 days. That is a different sentence.

### Claim ladder

Say this:

- "It makes a smaller copy and leaves the original alone."
- "It estimates the saving before it runs, and reports measured bytes afterwards."
- "Deleting originals is off unless you turn it on."
- "It is built to leave special videos alone rather than handle them badly."
- "The scan does not download your originals."
- "It has not been tested on a real phone yet. I am not going to pretend otherwise."

Do not say this, at all, in any format:

- "Frees X GB" or "reclaim your storage".
- "Safe to delete" without the Recently Deleted and sync caveat.
- "Works on Live Photos", or any implication that it touches them.
- "Replaces your videos" or "no quality loss".
- Anything in the voice of a happy user.

## 1. Three formats

### Format A: The settings walkthrough

No app screen. No screen recording. Shootable today.

**What the camera sees.** Your own iPhone held in your hand, filmed by a second phone or a tripod.
You walk Settings > General > iPhone Storage on the physical device, filling the frame. The
audience reads the real bar: Photos at the top, and inside it, videos. Cut to your face only at the
end, or never.

**Voice.** Calm, level, like explaining something to a friend who just got the warning. No rising
"but wait". The screen does the arguing; you just point at it.

**On-screen text.** Short labels that name what the viewer is looking at: "Videos." "This is one
file." "45 minutes long. 2 GB." Then the turn: "There is a third option between keeping and
deleting."

**Length.** 25 to 40 seconds.

**Why it suits an on-device utility.** The viewer's own phone can produce the first half of the
video from memory. The annoyance is visual, not conceptual: it is a bar chart, and the biggest bar
is a video they forgot about. It also sidesteps the one thing you cannot do yet, which is show your
own app.

### Format B: Face to camera, plain answer

No app screen. No screen recording. No device at all. Shootable today, and the format to fall back
on when everything else stalls.

**What the camera sees.** You, chest up, ordinary light, ordinary room. Phone camera is fine. No
ring light, no cut-away B-roll required, though a single shot of the storage bar as a cutaway helps.

**Voice.** First person, one idea per sentence. You are the person who got annoyed enough to build
something, and you are also the person who will tell the viewer the parts that are not finished.

**On-screen text.** Used sparingly, only to land one number or one refusal: "Off by default."
"No iCloud download during a scan."

**Length.** 20 to 35 seconds. This format punishes padding.

**Why it suits an on-device utility.** A storage tool is a trust purchase, and the audience for it
is actively suspicious of storage apps. A face saying "here is what it does not do" reads as a
person rather than as an App Store listing. It is also the only format where the not-yet-released
status becomes an asset instead of a gap, because build-in-public is the actual story.

### Format C: The screen demo

App screen recording. Gated on a device run. Do not shoot this until the app has actually run on
your iPhone and you have watched it do the thing you are about to show.

**What the camera sees.** Real screen recording of a real scan on a real library, with your voice
over it. Show the estimate screen, the run, and the finished summary with measured bytes. Cut out
anything that has not happened on the device.

**Voice.** Present tense, past tense only for things you saw. "It found 61 videos. It thinks 24 of
them will get smaller. That number is an estimate." Then the measured line, read off the screen.

**On-screen text.** "Before it runs: an estimate." "After it runs: measured bytes." "Originals
still in Photos."

**Length.** 35 to 45 seconds.

**Why it suits an on-device utility.** On-device is the whole pitch. A screen recording proves the
work happens on the phone, with no upload and no account. It is also the single most damaging video
to post early: a stutter, a wrong number or a screen that does nothing is visible to everyone, and
it would be the first real evidence anyone has seen.

## 2. Ten hooks

First two seconds. Word counts are shown so nothing drifts over the line.

1. Your iPhone says storage is full. The videos are the reason. (11)
2. That storage warning is almost always one kind of file. (10)
3. The biggest file in your Photos is a video you forgot. (11)
4. I built an app that makes smaller copies of videos. (10)
5. Nobody warns you that video is what filled your phone. (10)
6. Check your storage. Look at what videos are holding. (9)
7. I will not show a freed-space screenshot. Here is why. (10)
8. There is a third option besides keep it or delete it. (11)
9. Shrinking a video is not the same thing as deleting it. (11)
10. I wrote an app that refuses videos it cannot handle properly. (11)

Hooks 1 and 6 work best in Format A, with the Settings screen already on screen at frame one. Hooks
7, 8 and 10 are Format B lines and should be spoken, not captioned, because the tone is the point.

## 3. Three scripts

All three are TikTok, Reels and Shorts at once. Shoot 9:16, keep action in the middle third, and
burn the on-screen text in.

### Script 1: "The third option" (Format A, no app screen)

Length: 38 seconds.

**Hook (0:00-0:02).**
On-screen text: "That storage warning is almost always one file type."
Voice: "Your iPhone tells you storage is full and then leaves you to guess."
Shot: your thumb opening Settings, filling the frame. Do not show your face yet.

**Beat 1 (0:02-0:10).**
On-screen text: "Videos." Then: "One file. 45 minutes. 2 GB."
Voice: "It is videos. One clip from a trip can be two gigabytes, and you have never watched it
twice."
Shot: Settings > General > iPhone Storage, slow enough to read. Hold on the Photos row.

**Beat 2 (0:10-0:20).**
On-screen text: "Keep it or delete it. That is the choice every app gives you."
Voice: "Every storage app gives you the same two buttons. Keep the video you are never going to
watch, or delete the memory you kept."
Shot: back to your face, or stay on the bar. Keep the framing still.

**Beat 3 (0:20-0:31).**
On-screen text in three cards: "A smaller copy." "The original stays." "The copy is checked before
it is kept."
Voice: "I built the third option. BatchShrink makes a smaller copy as a new item in Photos, checks
the copy before it is kept, and does not touch the original. Deleting is in there, off by default,
behind something closer to a receipt than a button."
Shot: face, straight to camera. No app UI anywhere in this script.

**Ending (0:31-0:38).**
On-screen text: "Never run on a real phone yet. Building it in public."
Voice: "It is still pre-release. It has never run on a real iPhone, including mine, so I am not
going to show you numbers I have not measured. Follow if you want to see what happens when it
does."
Shot: face, settle. No music sting, no zoom punch.

### Script 2: "Two things my app will not do" (Format B, no device)

Length: 27 seconds. Face to camera the whole way. This is the trust script; do not wrap it in
editing tricks.

**Hook (0:00-0:03).**
On-screen text: "Two things my video app will not do."
Voice: "I am building an app that makes your big videos smaller, and there are two things it will
not do."

**Beat 1 (0:03-0:12).**
On-screen text: "1. It will not touch your originals."
Voice: "One. It will not touch your originals. The smaller version is a new item in Photos. Your
original file stays where it is until you personally decide otherwise."

**Beat 2 (0:12-0:21).**
On-screen text: "2. It will not fake a number."
Voice: "Two. It will not invent a saving. Before a run it gives you an estimate and says it is an
estimate. After a run it reports the bytes it actually measured. Those are different things and
most apps blur them."

**Ending (0:21-0:27).**
On-screen text: "Not released. Not run on a phone yet."
Voice: "It is free, it is not out, and it has not run on a real phone yet. That is the honest
version, so that is the one I am posting."

### Script 3: "The demo" (Format C, device run required)

Do not shoot this until a real iPhone run exists. Record the screen only after you have watched the
app do every step you show, on that device, that day.

Length: 44 seconds.

**Hook (0:00-0:02).**
On-screen text: "This is not a freed-space screenshot. This is the app running."
Voice: "Here is the whole thing, start to finish, on my phone."
Shot: screen recording, app opening. No logo animation.

**Beat 1 (0:02-0:14).**
On-screen text: "No upload. No account. The scan does not download your originals."
Voice: "It looks through the library first. That pass does not download your videos, so it does not
take an hour and it does not use your data."
Shot: the scanning or listing screen, uncut, at real speed.

**Beat 2 (0:14-0:26).**
On-screen text: "Before the run: an estimate." "It will not promise the exact number."
Voice: "It tells me which videos are worth shrinking and gives me a range, not a promise. Some of
them it will refuse outright rather than process badly."
Shot: the estimate screen. Pause on whatever the app actually says. If it says nothing useful, cut
this beat, do not stage it.

**Beat 3 (0:26-0:37).**
On-screen text: "After the run: measured bytes."
Voice: "This is the part that matters. After the run it reports the bytes it measured, not the
bytes it hoped for. Every copy is checked before it is kept, and the originals are still sitting in
Photos where they were."
Shot: the finished summary, then Photos open on the originals, still there.

**Ending (0:37-0:44).**
On-screen text: "Free. iPhone, iOS 18 and up. Not on the App Store yet."
Voice: "It is not out yet. When it is, it will be free, and it will still leave your originals
alone unless you say otherwise."

## 4. Caption pack

Ten captions. Each has a hook line, one or two sentences of substance, and hashtags. Hashtag
reality is spelled out at the end of this section, and it matters more than the tags themselves.

1.
Hook: The storage warning is rarely about photos.
Body: It is about video. A handful of long clips can be most of your library, and they are the ones
you never open twice. I am building an app that makes smaller copies of them and leaves the
originals alone.
Tags: #iphonestorage #icloudstorage #iphonehelp #storagetips #iphonevideos

2.
Hook: Keep it or delete it. Every other app stops there.
Body: There is a third option: a smaller copy as a new Photos item, checked before it is kept, with
the original untouched. Deleting the original is a separate switch, and it is off.
Tags: #iphonehelp #iphonetips #photostorage #storagespace #apps

3.
Hook: I am not going to post a before-and-after storage screenshot.
Body: The app has not run on a real phone yet, so I have no real numbers. I would rather show the
measured result later than a fake bar chart today.
Tags: #buildinpublic #iphonestorage #indiedev #iphonehelp #techtips

4.
Hook: Two things my video app will not do.
Body: It will not touch your originals, and it will not invent a saving. Before a run you get a
range and it is labelled as an estimate. After a run you get measured bytes.
Tags: #iphonehelp #iphonestorage #indiedev #apps #icloudstorage

5.
Hook: Video is what fills an iPhone, not photos.
Body: Photos is usually a mix, and the heaviest items in it are clips recorded at the highest
setting your phone offers. Most of them are one long take you have not opened since the day you
took it.
Tags: #iphonestorage #iphonetips #iphonevideos #storagespace #tech

6.
Hook: What actually happens when you shrink a video.
Body: The app makes a second, smaller file and adds it to Photos as a new item. It checks the copy
plays, has the right track and shape, and matches what the run measured, before it keeps it.
Tags: #iphonehelp #iphonestorage #videoediting #photostorage #techtips

7.
Hook: Every storage app wants two buttons. Keep or delete.
Body: The video you are never going to watch is usually the one you are least willing to throw
away. A smaller copy is the third option, and it does not require deciding today.
Tags: #iphonehelp #storage #icloudstorage #iphonetips #apps

8.
Hook: The gate before an original can be deleted.
Body: Switching deletion on is not enough. The copy has to be saved, smaller, verified and handed
back by Photos, and the app takes a fresh look at both items immediately before it asks. Anything
that does not line up keeps the original.
Tags: #iphonestorage #iphonehelp #datasafety #iphonetips #tech

9.
Hook: What my app refuses, and why that is the feature.
Body: Ordinary videos only. Edited clips, slow-motion, time-lapse, spatial and cinematic video, and
HDR and ProRes files, are left alone rather than processed badly. The last two are spotted when the
app opens the file, not in the list, so a video you pick can stop there. The app is a tool for the
normal case, not a one-size-fits-all converter.
Tags: #iphonehelp #iphonevideos #iphonestorage #apps #techtips

10.
Hook: Building a storage app in public, with no users yet.
Body: The test suite passes and the app still has not run on a real phone. I am going to post the
first run honestly, including whatever breaks in it.
Tags: #buildinpublic #indiedev #iosdev #iphonestorage #iphonehelp

### Hashtags: what is realistic and what is not

For an account with a handful of followers, hashtags are light metadata, not a distribution
channel. The realistic ones are specific enough that the algorithm has somewhere sensible to place
you and that a person searching will actually find the post:

- Workable at this size: `#iphonestorage`, `#icloudstorage`, `#iphonehelp`, `#iphonetips`,
  `#storagespace`, `#photostorage`, `#iphonevideos`, `#buildinpublic`, `#indiedev`, `#iosdev`,
  `#datasafety`.
- Weak but harmless in one or two per post: `#apps`, `#tech`, `#techtips`. Big pools, low
  precision, fine as filler and not worth more than that.
- Vanity tags, do not use them: `#fyp`, `#foryou`, `#foryoupage`, `#viral`, `#trending`,
  `#explore`, `#apple`, `#ios`, `#iphone`, `#tech` at volume. Millions of posts compete for these
  every hour. They will not place a small account anywhere, and a post stuffed with them reads as
  spam to the humans who open it.

Use three to five tags per post. Put the effort into the words in the caption and the text on
screen instead: on TikTok, search indexes the caption, the burned-in text and the spoken words,
and that is where a stranger with a full phone will actually find you. "how do I free up space on
my iPhone" and "why is my iPhone storage full" are searched constantly and are worth using as
plain phrases in a caption or as searchable on-screen text. Do not chase the tag, chase the query.

## 5. Two-week posting plan

Assumptions: one account, one person, no audience, app not released, no app screens until a device
run exists. Post to TikTok first and upload the same file to Reels and Shorts the same day. Do not
re-export or change anything between platforms; identical files keep the comparison clean.

Ten posts over fourteen days. The order matters more than the dates, because two of them are gated
on the device run.

| Day | Post | Format | Why here |
| --- | --- | --- | --- |
| 1 | Post 1: "The storage warning is rarely about photos" | A | Leads with a screen the viewer already recognises. Cheapest possible first post |
| 2 | Post 3: "I am not going to post a before-and-after screenshot" | B | Sets the honesty contract before you ask for anything |
| 4 | Post 4: "Two things my video app will not do" | B | Trust script. This is the one most likely to get a comment |
| 6 | Post 2: "Keep it or delete it" | A | The clearest statement of the product in the pack |
| 8 | Post 5: "Video is what fills an iPhone" | A | Educational, no product ask, broadens who the account reaches |
| 9 | Post 10: "Building in public, no users yet" | B | The build-in-public post for the accounts that started following |
| 11 | Post 6: "What actually happens when you shrink a video" | A or C | Educational. Use C only if the device run has happened by now |
| 12 | Post 9: "What my app refuses" | B | The refusal list is the most distinctive thing the product has |
| 13 | Post 7: "Every storage app wants two buttons" | A | Reframes the whole category. Works as a follow-up to 9 |
| 14 | Post 8: "The gate before an original can be deleted" | B or C | The safety story. Strongest as a screen demo, fine as a talk |

Gate: Post 6 and Post 8 in Format C, and all of Script 3, wait for the device run. If the device run
has not happened by day 14, post the Format A or B version and keep going. Nothing in the plan
depends on showing the app.

### What to watch in the numbers

Be realistic about the starting line. A new account with no existing audience and no face-cam
built-in should expect tens of views on early posts, occasionally a few hundred, and should not
read a low first 48 hours as a verdict on the post. Most utility accounts stay flat for weeks and
then move on one post. That is normal and it is not a signal to change everything.

Watch, in this order:

1. Retention at the two-second mark. This is the only number the hook owns. If most viewers leave
   in the first two seconds, the hook is the problem and nothing later in the video can fix it.
2. Retention from two to five seconds. If the drop is here instead, the hook worked and the first
   beat did not, which usually means the promise and the payoff are too far apart.
3. Saves and shares. For a utility, these matter more than likes and more than views. One save
   means someone intended to act on this later.
4. Comments that are questions. "Does it work on..." and "how do I get it" are the highest-value
   thing on the whole account. That question is your next hook and your next caption.
5. Follows per thousand views. Low views with a good follow rate says the content is right and the
   reach is not. High views with a poor follow rate says people want the answer, not the account.
6. Traffic sources, where analytics shows them. Search is worth watching specifically. If search
   is sending people in, the wording in the captions is doing the work and should be pushed harder.

Change one variable at a time. Two consecutive hooks in the same style is a test; two posts with
everything different is nothing you can learn from.

By the end of the two weeks you are looking for a direction, not a result: which format got the
best two-second retention, which caption produced the most saves, and whether any single question
keeps repeating. Keep the format that wins and rewrite the others around it.

## 6. What not to post

Hard no:

- No freed-space claims, in any size, from any source. No "frees 20 GB", no "reclaim your storage",
  no bar chart going down. Nothing has been measured on a device, so there is no number to use.
- No before-and-after storage screenshots. Not faked, not borrowed, not "for illustration", and no
  screenshot from another app presented as this one.
- No app screen recording before a device run. This covers the scan, the estimate, the run, the
  summary and the copy. If you have not watched it happen on the phone, it does not go on camera.
- No claim about Live Photos beyond leaving them alone. Do not imply they are supported, processed
  or shrunk.
- No pretending to be a user. No fake testimonial, no invented comment screenshot, no staged
  "I tried this and..." post written in someone else's voice.
- No claim that it handles HDR or ProRes video. Both are refused, but only once the app opens the
  video: a file's codec subtype and its colour transfer function appear in no Photos listing, so a
  video can be selected and then refused at that point
  (`VideoShrink/Services/VideoVerificationService.swift`). If you list refusals, say edited,
  slow-motion, time-lapse, spatial, cinematic, Live Photos and shared or restricted items are
  turned down from the list, and HDR and ProRes are turned down when the app opens them.
- No "your videos are safe" as a flat statement. Say what is true: the original is not touched
  unless deletion is switched on, and anything deleted sits in Recently Deleted for 30 days before
  the space comes back, and only after the devices sync.
- No pretending the app is out. No App Store link, no "download it", no countdown, no release date
  until one exists.
- No stock footage of a phone showing empty storage or an anonymous clean library presented as
  your result. Use your own phone or use none.

Also avoid:

- Delete-bait framing. "You should delete these" is a different app than yours and it attracts
  people who will be angry when the app does not do that.
- Anything that shows a real filename, location, face or thumbnail belonging to someone else.
  Shrink your own library or blur it.
- Emoji. None of it is needed for this product. If one is ever genuinely load-bearing, justify it
  in the caption copy before using it.
- Exclamation marks. They read as a storage app, which is the thing you are trying not to be.

## 7. Report

### 7.1 The formats, and why they suit this product

The settings walkthrough works because the product's problem is already on the viewer's phone, in a
screen they have seen, and it can be filmed today with no app involved. It also gives a storage app
the one thing it usually lacks in short form: a visual proof of the annoyance that is not a
manufactured graphic.

Face to camera works because on-device tools are bought on trust, and the audience is a person who
has been burned by a storage app or is about to be. It is also the only format where "this has not
shipped and has not run on a phone" is on-message instead of a weakness, which is exactly the state
of this project. It needs no device, no screen recording and no editing, so it is the format that
still exists on the days the other two are blocked.

The screen demo works because everything that makes this product interesting is on-device: the scan
that downloads nothing, the measured bytes, the gate before a delete. It is the strongest format
and the most dangerous to post early, so the pack puts it behind the device run rather than
dropping it.

### 7.2 Hooks I wrote and cut

- "Your iPhone is lying to you about storage." Cut. It accuses the phone, which nobody believes, and
  it is a fake-stakes opening. The viewer's suspicion lands on the app instead.
- "The one setting Apple does not want you to find." Cut. There is no such setting. This is the
  shape of the "doctors hate this" family, which the brief rules out and which the audience for a
  privacy-sensitive utility punishes.
- "I built an app that saves you 50 GB." Cut. A made-up number, in the hook, for an app that has
  never run. It would be the single most damaging sentence on the account.
- "Delete 100 videos in one tap." Cut. It describes a different product and would attract people
  who want bulk deletion, then disappoint them.
- "You will never run out of storage again." Cut. Unknowable, unsupportable, and it sets the app up
  to fail on the first user with a two-hour 4K library.
- "This is why your phone is slow." Cut. Storage pressure is a real thing but the causal claim is
  unverified, so the hook would be building on something the developer cannot stand behind.
- "The app Apple should have built." Cut. Arrogant, and it invites an argument about Apple rather
  than about the product.
- "Count how many videos you have never opened. It will hurt." Cut. The instruction is good; the
  last three words are manufactured feeling. Kept the instruction as hook 6.
- "Storage is full but you have nothing to delete." Cut. Contradicts itself in a way that makes the
  hook do the explaining, and the interesting version of that thought is hook 1.
- "I spent four months building this for one video." Cut. The developer's effort is not a reason for
  anyone to care, and the brief's audience is annoyed about a warning bar, not about a
  backstory.

### 7.3 Claims I deliberately avoided

- Any number for space saved, freed, reclaimed or recovered. No device run, so no measurement
  exists, and the estimate is a range built on a published planning band rather than a quote.
- Any number for time saved, videos processed, installs, users or retention.
- Any testimonial, review, comment quote or "people are saying".
- Any statement that iCloud storage is freed or a tier is lowered. The app does not touch that, and
  a second copy initially uses more space.
- Any suggestion that deleting an original returns space immediately. It goes to Recently Deleted
  for 30 days, and only after the devices sync.
- Any "no quality loss" claim. The copy is a smaller re-encode, and the honest framing is that the
  original is kept and the copy is checked, not that the two are identical.
- Any claim that it handles HDR or ProRes. Both are refused, but discovered only when the app
  opens the video rather than in the list, so never imply that everything in the list is
  processable or that the check happens up front.
- Any claim about Live Photos other than that the app does not work on them.
- Any claim that the scan, the app or anything else has been verified on a phone. The test suite
  passing is stated as exactly that, and never as a device result.
- Any claim that the app is available, free-download, coming on a date, or waiting for a review. The
  CTA in this pack is follow, or comment, and nothing else.

### 7.4 What must not be said until a device run exists

Until there is a real iPhone run with a result written down beside it, none of the following leave
the developer's head:

- Any measured saving. Not from the summary screen, not from a percentage, not from a range
  presented as a result.
- Any statement that the scan did or did not download anything, presented as observed rather than
  as intent. "The scan is built so it does not download your originals" is fine. "The scan does not
  download your originals, I checked" is not, yet.
- Any description of a screen as it behaves. The estimate band, the run counter, the thermal stop,
  the heat message, the finished summary and the read-back line are all source and tests, not
  observed behaviour, and none of them should be narrated as if it were watched.
- Any claim that a copy plays correctly, sounds right, keeps orientation, keeps dates, keeps
  location, or uploads to iCloud. Each of those needs a phone.
- Any claim about deletion having been exercised at all. Nobody has seen this app delete anything,
  and the deletion path is the part with the strictest gate and the highest cost if it is wrong.
- Any version of "it works". There is no "it works" yet. There is "it compiles, its tests pass, and
  it has never run".

The line that is always safe, and that this pack uses throughout, is the sentence the project has
been consistent about since the beginning: the source compiles, the tests pass, and the app has not
run on a device. Say that and there is nothing to walk back later.
