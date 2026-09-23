# BatchShrink - where the first users come from

A prioritised plan for getting a free, unreleased iPhone app its first users, judged on effort
against realistic return. Written 23 September 2026 against commit `81ab92c`.

The app is one person's work. There is no Mac, no budget for paid acquisition, no existing
audience, and no device result: build 10 is the last build known to have reached anyone, and
every build since has targeted a simulator.

## 0. How to read this document

Three kinds of statement appear here, and each one is labelled:

- **Repo** - read out of this repository, with the file named.
- **Looked up** - retrieved from an outside source in this session, with the source named.
  Competitor data is from Apple's public iTunes Search and Lookup API and from App Store product
  pages on 23 September 2026 (GB storefront). Apple's own behaviour comes from Apple support
  pages and Apple's App Store Review Guidelines.
- **Inferred** - my judgement. Not verified. Where the whole argument rests on an inference, I
  say so.

The one-sentence verdict, and everything below is the argument for it: this app's competitive
advantage is not that it shrinks videos, and not that it batches, and not that it deletes, and not
even that it works on the device. Competitors already do all four, mostly for free, and several of
them have thousands of ratings. Its advantage is that it refuses to lie and refuses to mangle:
no subscription trap, a deletion gate nobody else ships, and an honest claim set. Those are real,
but they are trust features, and trust features need a channel where trust is the thing being
sold. Most of the channels available to a solo developer with no audience do not sell trust. They
sell novelty, or they sell volume, and this product has neither yet.

## 1. The competitive map

### 1.1 The three things competing for the same job

"My phone or my iCloud is full of videos" is solved today by three different things, and the app
is only competing with one of them head-on.

1. **Apple's own settings, which are free and already installed.** Looked up, and this is the
   strongest competitor in the list.
2. **Other App Store apps, which are numerous, cheap and often free to start.** Looked up.
3. **Workarounds people do without any app at all.** Mostly inferred.

### 1.2 What Apple already does for free

| Apple's own option | What it actually does | What it does not do | Source |
| --- | --- | --- | --- |
| Optimise iPhone Storage (on by default when iCloud Photos is on) | Keeps full-resolution originals in iCloud and stores space-saving copies on the device | Does not reduce iCloud usage at all. It moves the bytes to iCloud, and the device is only relieved while there is iCloud capacity to hold them | Looked up: support.apple.com/en-gb/105061 |
| iCloud+ storage: 5 GB free, then GBP 0.99 for 50 GB, GBP 2.99 for 200 GB, GBP 8.99 for 2 TB, GBP 26.99 for 6 TB, GBP 54.99 for 12 TB per month | Buys capacity | It is a recurring cost, and it rescues the symptom rather than the cause. The library keeps growing | Looked up: apple.com/uk/icloud and support.apple.com/en-gb/108047 |
| Recommended for You (iOS 17 and later) | Suggests photos, large files and old backups that can be deleted | It deletes, it does not shrink | Looked up: support.apple.com/en-gb/108922 |
| Settings > General > [Device] Storage | Per-app usage, storage recommendations, offload and delete an app | Treats Photos as one block. There is no per-video action | Looked up: support.apple.com/en-gb/108429 |
| Deleting duplicate photos, and Messages texts and attachments | Apple's own listed routes to free iCloud space | Removes content | Looked up: support.apple.com/en-gb/108922 |
| Transferring videos to a computer | Apple's own suggestion when device storage is short | Needs a computer and a decision about what to keep | Looked up: support.apple.com/en-gb/105061 |

The honest reading: **Apple already solves the "my iPhone is full" half of this problem for
free**, for the majority of users who have iCloud Photos on, and it solves it without the user
understanding what happened. This is the single most important fact in this document, and it is
the reason the app must not position itself as "free up space on your phone". What Apple does not
do is reduce what the library costs *in iCloud*, and BatchShrink does not do that either (Repo:
README, "Nothing here lowers an iCloud bill"). The gap BatchShrink actually fills is narrower
than the category language suggests: how big the archived files are, measured, with the original
kept.

### 1.3 Non-app workarounds people use

All inferred unless noted. These matter because they are what the target user does *instead* of
installing anything, and they set the bar for how much effort a new app may ask for.

- Send the video to yourself in a messaging app and save the recompressed version back. Every
  major messenger shrinks video to fit its own limit. Costs nothing, needs no trust in a new
  developer.
- Lower the camera's recording resolution so future clips are smaller. Prevents the problem
  instead of treating it.
- Move the library to a computer or an external drive (Looked up as Apple's suggestion,
  support.apple.com/en-gb/105061).
- Offload to a second cloud (Google Photos, OneDrive and similar) and delete locally. Several
  competitor listings sell themselves on exactly this (Looked up: the Brachmann listing names
  iCloud, Google Photos, Dropbox, OneDrive and Google Drive).
- Use a Shortcut that re-encodes media (Inferred - Apple's Shortcuts has media-encoding actions,
  but I did not verify a specific published shortcut in this session).
- Pay for iCloud+ and stop thinking about it (Looked up pricing above).

### 1.4 The App Store competitors, with numbers

The category is crowded and the head terms are held by apps with years of history. Looked up on
23 September 2026 via Apple's iTunes Search API, GB storefront:

| Query | Apps returned | With 100+ ratings | With 1,000+ ratings |
| --- | --- | --- | --- |
| "video compressor" | 189 | 28 | 7 |
| "compress video" | 194 | 36 | 10 |
| "shrink video" | 186 | 38 | 11 |
| "video resize" | 193 | 63 | 33 |
| "storage cleaner" | 190 | 59 | 17 |

Across four near-synonym video queries there were **142 unique apps**. Of their listing
descriptions, looked up and counted in that same sweep:

| Claim or feature in the listing description | Apps |
| --- | --- |
| Mentions a subscription | 55 of 142 |
| Mentions batch or multi-video processing | 52 of 142 |
| Claims privacy, on-device or no-upload processing | 53 of 142 |
| Claims "no quality loss" or "without losing quality" | 31 of 142 |
| Mentions deleting the original | 24 of 142 |
| Mentions iCloud | 14 of 142 |
| Mentions Live Photos at all | 3 of 142 |

The named leaders, with what their listings actually promise:

| App (seller) | GB ratings | Price and monetisation | What stands out |
| --- | --- | --- | --- |
| Compress Videos & Resize Video (New Marketing Lab, Inc) | 4.66, 4,317 ratings | Free with ads and In-App Purchases: GBP 4.99/month, GBP 5.99/year, GBP 12.99 lifetime | Batch is a Pro feature. Claims up to 90% smaller "without reducing their quality", shows before/after examples, free tier is one video at a time |
| Video Compress - Shrink Vids (Brachmann Online Marketing) | 4.57, 1,375 ratings | Free (In-App Purchase flag set on the page) | Batch, a bitrate slider, before/after preview, keeps date/time/GPS metadata, and an **optional delete of the original** with an explicit note that it may still sit in Recently Deleted. Also warns that previously edited videos may not compress |
| Compress Videos - Shrink Videos (Shenzhen Jinxixi) | 4.47, 530 ratings | Free, In-App Purchase "Remove Ads" GBP 1.99 | A target-file-size slider; says all processing is local |
| Compress Videos: Free Up Space / TinyVid (Island Palm Mobile) | 4.44, 409 ratings | Free with a subscription: 6.99 USD per week after a 3-day trial | "Compress videos without losing quality (using AI)"; claims it opens up "TONS of free space" |
| Video Compressor - resize all (LANARS) | 4.74, 221 ratings | Free; no In-App Purchase stated on the page | One video or up to 20 at a time; claims "no quality loss"; keeps both files |
| Compress Videos (LightByte) | 4.81, 224 ratings | Free, In-App Purchases present with annual periods | Compact listing, high rating, small rating base |
| Easy Video Compressor - Resize (Osawa Shunsuke) | 4.73, 127 ratings | Free; batch and fine settings are a one-time Pro purchase | Targets by size (10/25/50 MB) or quality; explicitly pitches kids and pets videos and "storage almost full" |
| Video Compressor - Reduce Size (out thinking) | 4.02, 104 ratings | Free with a subscription | Older listing, weaker rating, same promise set |

### 1.5 What BatchShrink does the same, better, and worse

Hard assessment. The first list is the longest, and that is the point.

**The same, and there is no advantage in any of it (Repo plus Looked up above).**

- Transcodes a video to a smaller copy on the device with no upload, and saves it as a new Photos
  item. This is the commodity. Fifty-three of the 142 apps sampled make the same on-device,
  no-upload claim, and it is true of most of them.
- Offers resolution and frame-rate choices, and HEVC or H.264 output. Competitors offer the same
  levers, several with more granularity (target file size, bitrate sliders, format conversion).
- Estimates before and reports measured bytes after. Good practice, not a differentiator.
- Batch selection. Fifty-two of 142 apps claim it. The leading app gates it behind Pro; BatchShrink
  does not, which is a small plus, not a position.
- Optional deletion of originals. Twenty-four of 142 apps mention deleting, and at least one
  (Brachmann) ships it with the same Recently Deleted caveat BatchShrink uses.
- Free to download. Nearly the whole category is free to download.

**Genuinely better, and defensible.**

- **No subscription, no In-App Purchase, no ads.** Verified in the repository (no StoreKit,
  purchase or analytics code anywhere in the tree) and verified against the category, where the
  leading app charges GBP 4.99/month or GBP 12.99 for a lifetime unlock, and another charges
  6.99 USD **per week**. This is the clearest single purchase reason the product has.
- **The deletion gate.** Repo: deletion is off by default, it needs a stored receipt naming the
  copy this run created, and both the copy and the original are looked up again and compared
  immediately before Photos is asked. A stale or missing receipt can never authorise a delete.
  No competitor listing sampled describes anything like this; the closest is a plain
  "optional: delete the original" toggle.
- **Verification stated as a specific method.** Repo: every applicable sample window must decode,
  audio is decoded rather than inferred, and the copy Photos hands back is compared against the
  output the run measured. Competitors say "without losing quality" (31 of 142) and do not say how
  they know.
- **It refuses what it cannot preserve.** Repo, and the split matters: Live Photos, time-lapse,
  spatial, slow-motion, edited videos, cinematic and shared or restricted items are refused at
  listing time (seven classes, all detectable from library metadata), and HDR and ProRes are
  refused once the file itself can be read (two more, invisible to PhotoKit): the scan reads the
  newest 400 on-device originals, and the run reads the whole selection before the first export.
  Looked up: only 3 of 142 competitor listings even mention Live Photos.

**Genuinely worse, and this is the part a strategy built on wishful thinking would skip.**

- **Coverage.** This is the big one. BatchShrink refuses nine classes of video. Real libraries
  are full of them: every clipped video is "edited", every iPhone Live Photo is unsupported,
  anything Photos tags as high-frame-rate is treated as slow-motion, and HDR capture is the
  default on recent iPhones (Inferred). Competitors mostly process those files anyway, and
  several do it badly; some tell you afterwards. BatchShrink tells you first, which is better
  behaviour and a worse product experience for exactly the person who installs it to fix a full
  library.
- **Time to visible benefit.** A smaller copy is an *extra* file. Nothing is reclaimed until the
  original is deleted, and then only after 30 days in Recently Deleted and after the devices
  sync (Repo: README and the deletion copy). Competitors that offer immediate deletion and say
  "opens up TONS of free space" give the user a win in the first five minutes. BatchShrink
  deliberately does not.
- **Features.** No trimming, no format conversion, no file management, no built-in camera, no
  photo compression. Several competitors are converters, editors and compressors in one, which
  makes them easier to justify installing.
- **Reach and social proof.** The leader has 4,317 ratings. BatchShrink has none, no reviews, no
  press history and no brand recognition. During the first months, a competitor's listing is
  strictly more persuasive than this one, whatever is true about the engineering.
- **Platform.** iPhone only, iOS 18 or later, no validated iPad interface (Repo: `app.json`,
  `supportsTablet: false`). Several competitors are iPad apps.
- **No measurement.** No account, no backend and no analytics (Repo) means no in-app funnel, no
  run counts, no crash breadcrumbs from users. That is a trust win and a marketing handicap.
- **Nothing has run on a phone** (Repo). Every claim above is source and simulator tests.

### 1.6 The honest conclusion about the differentiator

Anyone reading the tables above can see the trap. The four things that feel like advantages -
smaller copies, batching, on-device processing, optional deletion - are all commodity. The
differentiators that survive contact with the category are:

1. it is genuinely free, in a category that mostly is not once you try to use it;
2. it refuses rather than guesses, and says so before it starts;
3. it will not touch an original without a re-verified receipt.

That is a product for someone who has been burned: by a subscription, by a 3-day trial that
became a weekly charge, or by an app that quietly degraded a video they cared about. That
customer exists. They are also, by definition, not browsing the App Store for "video
compressor" - they are reading reviews and forum threads about which app is a scam. Which
channel can reach them is the subject of the rest of this document, and it is a short list.

## 2. The channels, ranked

Ranked by effort against realistic return for one developer with no budget, no audience and a
product that is not yet on the storefront.

| # | Channel | Who is reachable | Effort to do it properly | Realistic return, no audience | Time until you know |
| --- | --- | --- | --- | --- | --- |
| 1 | Apple search / ASO | People already typing the intent into the App Store | Low, front-loaded, then a little upkeep | Modest but compounding. Head terms are out of reach for months; the long tail and the brand term are winnable | 4-6 weeks after release |
| 2 | Short-form video, search-led | People with the problem, found through in-app search rather than hashtags | High and continuous. No app screen until a device run exists | Low base rate, free, unbounded ceiling | 2-6 weeks of consistent posting |
| 3 | Apple featuring nomination and Apple-focused newsletters/blogs | Apple power users, who skew toward large photo and video libraries | Low per pitch, high per acceptance | High value if it lands, low probability | 2-8 weeks |
| 4 | Direct communities with the problem | Photography, videography, new-parent and travel forums and groups | High, and you must be a real member first | Highest intent per person, smallest volume | Weeks |
| 5 | Reddit and forums | r/iphonehelp, r/applehelp, r/iosapps and the MacRumors forums | Medium per post, but the rules differ per subreddit | High variance. Real removal and ban risk | Days |
| 6 | Product-discovery sites | Product Hunt, BetaList and similar | Medium, one-off | A traffic spike with weak intent. Worth it for a link and a page, not for users | About a week |

### 2.1 Apple search / ASO - rank 1

**What it is.** The App Store's own search, plus the browse and category surfaces, plus your
product page. It is the only channel where the user has already decided to solve this problem.

**Who is reachable.** Everyone who types "video compressor", "compress video", "free up storage"
or "iphone storage full". Apple indexes the name, the subtitle, the keyword field and the
description text that is visible on the page.

**Effort.** Low and front-loaded. The listing work is already drafted in
`marketing/app-store-listing.md`, including a 98-character keyword string that deliberately
excludes "icloud" because the app does not reduce an iCloud bill. After launch the upkeep is
reading the Search terms report in App Store Connect and adjusting once, not constantly.

**Realistic return.** Modest and compounding, and it should be judged on the long tail only.
Looked up: the head terms return 186 to 194 apps, and 28 of the 189 apps for "video compressor"
have 100 or more ratings. A new app with zero ratings does not rank for those. What is winnable
is the brand term ("BatchShrink" is uncontested) and phrased long-tail queries that the big apps
index badly. This is the one channel that keeps working while you sleep, and the only one where
the cost of being late is low but the cost of having no ratings is high.

**Time until you know.** Four to six weeks after release, once the store has indexed everything
and the Search terms report has accumulated. Before that, the sample is too small.

**Why it is ranked first despite the small numbers.** Every other channel on this list is either
gated on a device result, or requires an audience, or is a volume game that a single person
cannot sustain. This one requires none of those. It is the floor under the whole plan.

### 2.2 Short-form video, search-led - rank 2

**What it is.** TikTok, Reels and Shorts, but entered through the platform's search box rather
than the hashtag pool: the on-screen text and the caption use the phrases people actually type
("why is my iphone storage full", "how to free up space on iphone"). The
`marketing/social-pack.md` pack already contains three formats, ten hooks, ten captions and a
two-week plan built for exactly this account's state.

**Who is reachable.** People searching for the problem in the place they already are, which is
the only place a person with 60 GB of videos and no interest in technology is likely to be
reachable by a stranger with no budget.

**Effort.** High, and continuous. This is the most expensive channel on the list in hours. Two of
the three formats need no app screen and no device at all, so it is not gated on the device run.

**Realistic return.** Low base rate, unbounded ceiling. Inferred, but grounded: a new account
with no audience should expect tens of views per post for weeks, with an occasional post doing
several hundred. The honest value in the first 30 days is not installs - there is nothing to
install yet - it is evidence about whether the message lands at all, and a comment box that
tells you which sentence people repeat.

**Time until you know.** Two to six weeks of posting twice a week. Judge it on two-second
retention, saves and shares, and questions in the comments. Do not judge it on views.

### 2.3 Apple featuring nomination, then Apple-focused newsletters and blogs - rank 3

**What it is.** Apple runs an editorial featuring process inside App Store Connect. Looked up:
the workflow is documented as "Manage featuring nominations - Nominate your app for featuring",
with Drafts and Submitted sections in App Store Connect
(developer.apple.com/help/app-store-connect/manage-featuring-nominations/nominate-your-app-for-featuring).
Separately, the Apple-focused outlets that cover small apps are MacStories, 9to5Mac, MacRumors,
Cult of Mac, iMore, Six Colors, The Sweet Setup, MacSparky and AppleVis for accessibility.

**Who is reachable.** Apple power users. These people are unusually likely to have large photo
and video libraries and unusually able to judge a claim about compression, so the audience fit
is genuinely the best of any channel here.

**Effort.** Low per pitch: one short, specific email per outlet, with no pitch-deck theatre. High
on the acceptance side, because an unknown free utility with no ratings and no design story is
not news.

**Realistic return.** High value if it lands - an Apple featuring slot or a MacStories mention
would out-deliver every other channel combined in the first month - and a low probability of
landing. Inferred, and I want to be plain about this: I did not verify any outlet's submission
route in this session, and I would expect most cold pitches to be ignored.

**Time until you know.** Two to eight weeks. This is the long-shot channel: spend a day on it
once, during the release week, and then stop thinking about it.

### 2.4 Direct communities with the problem - rank 4

**What it is.** Places where the library is the topic and the size of the library is a running
joke: photography and videography forums, drone and action-camera communities, new-parent groups,
and travel communities, all of which accumulate video faster than their members expect. Also
AppleVis, where accessibility is the shared concern and where the app's VoiceOver work would be
relevant.

**Who is reachable.** The highest-intent people on this list. Someone in a videography community
asking what to do with 400 GB of footage is the product's actual customer, and they are asking a
question the app answers.

**Effort.** The highest per person on this list, and it is not close. These communities can tell
instantly whether you belong. The only version of this that works is participating for weeks
first and answering the storage question - about the Settings route, about iCloud, about what
actually frees space - before the app exists to mention.

**Realistic return.** Highest intent, smallest volume. Ten real members of a photography forum
who try it and say so publicly are worth more than a thousand Product Hunt upvotes, and they are
also the hardest ten users to get.

**Time until you know.** Weeks, because you have to be a member before you can be a contributor.
Start now, during the device-blocked period, so the account has a history by launch.

### 2.5 Reddit and forums - rank 5

**What it is.** The general help subs (r/iphonehelp, r/applehelp, r/iosapps) plus the MacRumors
forums and Apple's own Support Communities. The topics come up constantly.

**Who is reachable.** Large volumes of people who have the problem right now, plus a much larger
volume of people who will read the thread for years.

**Effort.** Medium per post, but the rules are the work: most help subreddits treat a developer
posting their own app as spam, whether or not it answers the question.

**Realistic return.** High variance. One well-answered thread can produce more qualified traffic
than a month of posting, and one promotional post gets removed, or gets the account banned.

**Time until you know.** Days, which is the appeal and the danger: the feedback arrives before
you have had a chance to be careful.

**Honest note on the evidence.** I could not verify any subreddit's self-promotion rules in this
session - every attempt to fetch Reddit's rules endpoint returned HTTP 403. So the specific rules
for r/iosapps, r/iphonehelp and r/VideoEditing are **not verified here**, and the general claim
that these communities punish drive-by promotion is **inferred**, not looked up. Read each
subreddit's own rules before posting anywhere, and assume the strict reading.

### 2.6 Product-discovery sites - rank 6

**What it is.** Product Hunt, BetaList, "new app" newsletters and aggregator sites. Looked up: a
Product Hunt launch guide exists at producthunt.com/launch, and the site runs a public help
centre. The mechanics of a launch - needing an account, launch-day voting behaviour, the value of
featuring - are Inferred; I did not verify them.

**Who is reachable.** People who collect and try new apps. That is a real and useful audience,
but it is not specifically people with a full iCloud library, and install-to-use rates are
typically worse than any channel above.

**Effort.** Medium, and mostly one-off: assets, a first comment, a day of attention.

**Realistic return.** A spike of low-intent traffic, a permanent backlink, and a page that can be
linked from the landing page. Worth doing as a release-week formality. Not a plan.

**Time until you know.** About a week.

### 2.7 Channels I would not do, and why

- **Paid acquisition of any kind, including Apple Search Ads.** No budget, and - worse than no
  budget - no monetisation. The app is free with no In-App Purchase and no subscription (Repo),
  so there is no revenue to repay a cost per install. With zero ratings the click-through and
  conversion will be poor on top of that. This is not a cheap-channel-to-start position; it is a
  channel with no return at all.
- **Paid creator placements and influencer deals.** Same arithmetic, with an invoice.
- **Buying installs, review swaps, incentivised reviews, or any "get 50 reviews" service.**
  Looked up in Apple's App Store Review Guidelines: attempting to manipulate reviews or inflate
  chart rankings with paid, incentivised, filtered or fake feedback can lead to removal from the
  store and expulsion from the Apple Developer Program. A free app with no users has nothing to
  gain and everything to lose.
- **Writing or soliciting a friendly review, or a review in someone else's voice.** The same
  guideline, plus it destroys the only asset this product has.
- **Cold DMs, mass outreach and unsolicited posting in communities you do not belong to.** It
  fails, it gets the account removed, and it burns the small number of forums where this product
  would genuinely be welcome.
- **Press-release wire services and mass app-directory submission.** Money for links nobody reads.
- **Building an audience first: a YouTube channel, an email list, a newsletter.** All of these
  need months of content before they return anything, and the app has nothing to announce yet.
  Start a channel because the first video is cheap, not because a channel is the plan.
- **Claiming the head ASO terms.** Chasing "video compressor" or "free up space" with paid keywords
  or repetition is unwinnable against apps with thousands of ratings, and the "free up space"
  framing is the one claim the app cannot honestly make anyway (Repo: README).
- **Any channel that requires a lie.** No freed-space screenshots, no invented numbers, no
  testimonial that does not exist, no claim that HDR or Live Photos are supported. The reasoning
  is in `marketing/social-pack.md` and `marketing/app-store-listing.md`, and it is not squeamishness:
  the only durable advantage here is that the app tells the truth, and a single contradictory post
  spends it.
- **Android, iPad or a React-Native rewrite as a growth move.** All of them are months of work in
  service of a product that has no users yet. Not a channel.

## 3. The single best first move, and the second

The product cannot claim a device result. That is not a marketing inconvenience; it is the
blocker, and it should shape the first two moves.

**Move 1: end the state of having no device result, and do it in front of 10 to 25 people who
actually have the problem.**

Not a device test for its own sake. A device test that is also the first cohort. Concretely:
produce the build that installs on a phone (build 11 is the first build that carries the
reliability work, Repo: `docs/PHYSICAL_DEVICE_TEST_PLAN.md`), put it on the owner's iPhone 15 Pro
Max and on the phones of a handful of people chosen because their libraries are large, run the
acceptance cases already written in `docs/PHYSICAL_DEVICE_TEST_PLAN.md`, and write the result
down. Why this is first, in order of weight:

1. Every other channel needs it. Screenshots cannot honestly exist without it (Repo:
   `marketing/app-store-listing.md`), the screen-demo video cannot be shot without it, and no
   reviewer or blogger will look at an app that has never run.
2. The first cohort is also the first ratings. Ratings are the gate on the one channel that
   compounds. Ten people who use it and rate it honestly is worth more than a launch-day spike of
   strangers who do not.
3. A real library is the only way to find out how bad the coverage problem is. The app refuses
  nine video classes, and the honest question - "what fraction of a real 400 GB library does
   this actually accept?" - cannot be answered from the test suite. If the answer is "a fifth of
   it", that changes the positioning in section 1 and must be known before a single channel is
   worked.

If the EAS free-plan iOS minutes are still exhausted (Repo: `AGENT_LOOP.md` - they reset on
1 October 2026), this move starts the day they return, and the intervening week is spent on
Move 2 and on the release blockers in section 4.

**Move 2: shoot the one video that needs no device, and post it as a reachability test rather
than a launch.**

Format A in `marketing/social-pack.md` - the Settings walkthrough, "there is a third option
besides keep it or delete it" - is the only marketing asset this product can produce today that
is not a lie, does not need a device, does not need an audience, and does not cost money. Its
value in the first two weeks is not installs (there is nothing to install). It is the cheapest
possible answer to the question the whole strategy rests on: **is the person with a full iCloud
library reachable from where I can reach?** If nobody with the problem shows up in the comments
after ten posts, the channel list in section 2 needs shrinking before launch, not after.

The ordering is deliberate. Short-form is not move 1 because it needs a destination and the
study group does not exist yet; the device result plus the cohort creates both. ASO is not move 1
because it cannot be evaluated before the app is published, and it is the channel that will
still be working in month six.

## 4. Sequencing: what must happen before any of this

All of this is taken from the repository, not guessed, and the order matters.

**1. A build that installs on a device.** Repo: the EAS free-plan iOS build minutes are exhausted
until 1 October 2026 (`AGENT_LOOP.md` quota section), and the owner has no Mac. Nothing that
needs a phone can happen before this, and it is the first thing on the critical path. Either wait
for the reset or pay for minutes; there is no third route.

**2. The physical acceptance test.** Repo: `docs/PHYSICAL_DEVICE_TEST_PLAN.md` is entirely
unexecuted. Its opening prerequisite is an installed internal build plus a passing simulator
suite. The plan's pass condition is specific: iCloud retrieval, a smaller HEVC output,
verification, a separate Photos save, and an unchanged original. Until that is recorded, the app
cannot honestly be described as working, and this document treats it as release day minus
everything.

**3. Write the result down.** Repo: the plan says to record build, OS, source characteristics,
measured bytes and outcome, and to store sanitized failures in `docs/DEVICE_RESULTS.md`. Several
business decisions here depend on that file existing: which claims the listing may make, whether
the coverage problem is fatal, and whether the deletion gate survives a real library.

**4. Decide the exact claim set, including the HDR and ProRes wording.** Repo, and this one is
subtle enough that it needs a decision rather than copy-editing. HDR and ProRes refusal is
implemented and reachable (`VideoShrink/Models/AssetRules.swift`,
`VideoShrink/Services/VideoVerificationService.swift`). PhotoKit reports neither trait, so the
library listing cannot see them; instead the scan reads the codec and colour details from the
header of videos already on the phone, newest 400 first, and `BatchViewModel.start()` reads every
video the user actually chose before the first export, so the refused ones are taken out and named
(`VideoShrink/Services/PhotoLibraryScanService.swift`). Consequence: only a video the app could
not read - one still in iCloud, one the scan did not reach, or one whose read failed - can be
selected, start, and *then* be refused, with the reason shown at that point. That is the remaining
bad surprise. The listing and the onboarding must say that a refused video is caught as the app
reads your videos, rather than implying every video in the list is processable. Some existing
documents in this folder were written when these rules could not fire at all; the code is the
current truth (`AGENT_LOOP.md` says so explicitly in "Keeping this file honest").

**5. Close or formally defer the open reliability items.** Repo, `AGENT_LOOP.md` backlog:
exactly-once save reconciliation is still open (N16); one shared cancellation flag is a known
latent issue (N13); a deprecated concurrency overload is outstanding (N15). N16 is the one worth
deciding about before a public release, because it is the difference between "a crash during
save may leave a copy the app cannot account for" and a re-runnable state.

**6. Resolve the expo-doctor contradiction.** Repo: the backlog row N18 still says one failed
check, while the round 8 notes say expo-doctor passes 21/21. That needs one command run and one
row updated, not a marketing decision - but a release should not ship with a known warning
whose status nobody can state.

**7. Submission blockers that exist today.** Repo: `docs/DEVELOPMENT_REVIEW.md` lists "finish
icon, store assets, privacy/support pages" as outstanding, and the App Store Connect submission
requires a privacy policy URL and a support URL. The icon and the privacy manifest exist in the
tree; the hosted pages and a support address do not, and no support inbox exists anywhere in the
repository (Repo: `marketing/app-store-listing.md`, "Outstanding before submission"). This is
the cheapest item on the list and it blocks submission outright.

**8. Decide what "free" means before publishing it.** Repo: there is no purchase, subscription
or StoreKit code in the tree, and the purchase model is listed as later work
(`docs/DEVELOPMENT_REVIEW.md`). Shipping free with no way to earn is a legitimate choice, and it
is the strongest purchase reason in section 1.5. It also means every marketing hour has to be
worth something other than revenue. Make it a decision rather than a default.

**9. Only then: publish, then work the channel list.** Nothing on the channel list produces
judgeable numbers before step 1 through step 3 are done, because there is nothing to send anyone
to.

## 5. What would make this fail

Named plainly, hardest risk last because it is the one I would bet on.

- **A free utility with no ratings, competing against free operating-system features.** Apple
  already gives most of this audience their space back, on by default, before they open the App
  Store (section 1.2). The App Store's own search is 142-plus apps deep. A first release with
  zero reviews is invisible at exactly the moment when a review is the only thing that would make
  someone tap. This risk is real but survivable, because it is a rank problem rather than a
  product problem.
- **The trust problem every storage app has.** The category is full of weekly subscriptions and
  "TONS of free space" claims (section 1.4, looked up). Users have learned to distrust the
  category, and a new app with no history is not obviously different from a scam on the product
  page. Being honest does not fix this at the point of install; it only pays off after use. That
  is why the no-subscription fact needs to be *on the App Store listing*, not only in a blog post.
- **The caution is a conversion tax.** Refusing nine video classes is the ethically right call
  and the wrong first impression. Someone installs this to fix a library, watches it decline
  their Live Photos, edited clips and HDR footage, and concludes it does not work, without
  reading why. The refusal is defensible; the ordering of that experience needs to be designed
  deliberately.
- **The measurement gap.** With no analytics, no backend and no account (Repo), the developer
  cannot see where users drop out, cannot tell a failed run from an unused app, and cannot count
  cancellations. Every decision in section 6 has to be made from App Store Connect plus ratings
  plus whatever users happen to type. That is workable, and it is a real cost.
- **The customer may not be in any of these channels.** This is the quiet risk that the whole
  plan rests on. The person with a 400 GB iPhone library who has hit the storage wall is
  frequently a mainstream user: a parent, a traveller, someone with a job that is not technology.
  They do not read MacStories, they do not read r/iphonehelp, they do not browse Product Hunt,
  and they may not search the App Store at all - they ask a friend, or they pay Apple GBP 2.99 a
  month and stop noticing. If that is who the customer is, then the reachable channels and the
  reachable customer are different populations, and no amount of good execution on the channel
  list fixes it. `marketing/social-pack.md` treats short-form search as the partial answer,
  because that platform's search box is where mainstream users do ask; I am not certain it is
  enough, and I have not verified it.
- **THE MOST LIKELY KILLER: the app may refuse a large share of the library it was installed to
  fix, and it does not free anything even when it succeeds.** Put the two together. Real
  libraries are dominated by Live Photos, edited clips, clips Photos tags as high-frame-rate and
  HDR footage - and most of those refusals now surface before a copy is made, though a video the
  app cannot read is still refused mid-run. So the modal first run for the target user is: several
  of the videos are refused, the ones that are processed produce extra copies rather than freed
  space, and nothing is actually reclaimed unless they turn on
  deletion, understand Recently Deleted, and wait 30 days. Repo: the README states this outcome bluntly
  ("Nothing here lowers an iCloud bill", and a second item initially consumes more storage).
  A user who experiences "it refused half of it, and my storage went up" writes a one-star review
  and tells nobody. That single experience is what ends this product, and it is a coverage and
  sequencing problem, not a marketing problem. It is also measurable before launch, in Move 1,
  by running the app against a real large library and counting what it accepts. If that count is
  bad, the product needs the ordering fixed - the videos it cannot read are still refused only
  once a run reaches them - before a single user is invited.

## 6. A measurable definition of working for the first 90 days

Two rules first. **Day 0 is the date of the first public App Store release, not today**, and it
must not arrive before the device acceptance test has passed (section 4). And nothing here counts
views, likes, impressions on their own, hashtag reach, Product Hunt position or follower count:
all of them can be produced without a single user with the problem, and this product cannot
afford to be told a comfortable story.

Everything below is visible in App Store Connect's Analytics (free with the developer account, no
in-app SDK required), plus the ratings and reviews, plus anything a user types. Nothing else is
measured, because there is no in-app analytics to measure it with.

| # | Measure | Target by day 90 | Why this number is defensible |
| --- | --- | --- | --- |
| 0 | Device evidence | `docs/DEVICE_RESULTS.md` exists, with at least one full acceptance run recorded | A precondition, not a metric. Everything else is uninterpretable without it |
| 1 | First-time downloads | 300 or more | About 3.3 a day. A free long-tail utility with a decent listing can reach this without any channel working well. It is a floor, not a stretch |
| 2 | Downloads attributed to App Store search, browse or a referral you did not create | 100 or more (a third of total) | This is the pull test. If every install came from a link you posted, ASO is not working and the product has no gravitational pull |
| 3 | Product page conversion rate | 20% or more, once impressions pass 2,000 | Free, low-risk, no subscription warning. Below 20% after 2,000 impressions means the listing or the screenshots are the problem, not the traffic |
| 4 | Ratings | 12 or more, mean 4.2 or higher | Ratings are the leading indicator for ASO rank at this size. Note the honest arithmetic: ratings are typically a low single-digit percentage of installs (Inferred), so 300 installs might yield only 3 to 15 ratings. 12 is the optimistic end of plausible, and if ratings lag while downloads are fine, the fix is a rating prompt after a successful run - a code task - not more posting |
| 5 | Repeat complaints | No single complaint cause appearing three or more times | One complaint is noise. Three is the product. This is the check that catches the killer in section 5 before it becomes the app's written reputation |
| 6 | Inbound messages naming a specific library or video | 10 or more, across short-form comments, forum replies, reviews and email | The only real evidence that the message reached people who actually have the problem, rather than other developers being encouraging |
| 7 | Still in use | 150 or more active devices in month 3, covering at least half of installs, or 250 or more sessions in month 3 | The weakest number on this list, because Apple suppresses cohort retention for small apps (Inferred) and this app has no other way to measure it. Treat it as a direction, not a decimal |

**The failure definition, stated as clearly as the success one.** If, 90 days after release, there
are fewer than 100 downloads, **and** no single channel has produced 20 or more, **and** there is
no repeating complaint theme, then the problem is not the amount of posting. It is the offer or
the reachability of the audience. Change one of them - the pitch, the positioning against Apple's
free option, or the channel list - rather than posting more of the same.

**Check at 30, 60 and 90 days**, not only at 90. At day 30 expect roughly 50-100 installs and one
or two ratings; the interesting reading is which search terms are producing impressions, because
that is the earliest honest signal that the long-tail strategy is real. At day 60 the
conversion rate becomes meaningful. At day 90 the pull test (measure 2) is the one to read first,
because it is the only number that says the product can find users without being pushed.

## 7. What I could not verify

Listed so that nothing above is mistaken for a checked fact.

- **Subreddit self-promotion rules.** Every attempt to read Reddit's rules endpoints for r/iosapps,
  r/iphonehelp, r/applehelp and r/VideoEditing returned HTTP 403 in this session. The specific
  rules are unverified, and the general claim about those communities punishing drive-by
  promotion is inferred.
- **Product Hunt launch mechanics** - account requirements, launch-day behaviour, how much a
  ranking is worth - are inferred. Only that a launch guide and help centre exist was verified.
- **Submission routes for Apple blogs and newsletters.** I named the plausible outlets and did not
  verify how any of them takes a tip, or whether they cover apps of this kind.
- **Whether the App Store's editorial team would feature this app.** The nomination workflow
  exists (verified); the odds for an unknown free utility are a guess.
- **In-app purchase details for most competitors.** One leading app's In-App Purchase prices
  (GBP 4.99/month, GBP 5.99/year, GBP 12.99 lifetime) and one "Remove Ads" purchase (GBP 1.99)
  were read from Apple product pages. For the rest, only the presence of the In-App Purchase flag,
  or a subscription paragraph in the listing text, was verified.
- **The iTunes Search API is a search index, not the whole store.** The counts in section 1.4 are
  what that API returned for those queries on that day (up to its own limit of 200 per query), not
  a census of the category.
- **The Shortcuts re-encoding workaround.** Apple's Shortcuts does have media-encoding actions, but
  I did not verify a specific published shortcut for this job.
- **The current state of some backlog rows.** `AGENT_LOOP.md` is being edited while this is written
  and explicitly warns that its status column goes stale; where the row and the code disagreed, I
  read the code and said so in section 4.
- **Everything about how the app behaves on a phone.** Nothing here is changed by that, and it is
  the reason Move 1 comes first.

## 8. Report

**Ranked channels.** (1) Apple search and ASO, because it needs no audience, no budget and no
device, the intent already exists, and it is the only channel that compounds. (2) Short-form video
entered through platform search, because it is the one place a mainstream user with a full library
may actually be reachable, it is free, and two of its three formats need no device. (3) Apple's
featuring nomination and the Apple-focused outlets, high value if it lands and unlikely to. (4)
Direct communities with the problem, the highest intent and the slowest and hardest to earn. (5)
Reddit and help forums, high volume with a real risk of removal. (6) Product-discovery sites, worth
a day in release week for a link, not a plan.

**What I would not do.** Any paid acquisition (no budget and, because the app is free, no return),
paid creator placements, buying or incentivising installs and reviews (Apple may expel a developer
for it, verified in the Review Guidelines), friendly or fabricated reviews, cold outreach and
posting in communities I do not belong to, press-release wires and mass directory submissions,
audience-building before there is anything to announce, chasing the head App Store terms, Android
or iPad work as a growth move, and any channel that requires a claim the app cannot support.

**The risk most likely to kill it.** That the app refuses a large share of the very library it was
installed to fix - Live Photos, edited clips, slow-motion, 60 fps and HDR dominate real libraries,
and most of those refusals are now caught before a copy is made - while a successful run adds copies
instead of freeing space, so the modal first experience is "it refused half of them and my storage
went up". That produces the one-star review, and the one-star review is what stops the next user.
It is measurable before launch, and it should be measured, by running the app against a real large
library and counting what it accepts.

**What I could not verify.** Reddit's subreddit rules (403 on every attempt), Product Hunt's launch
mechanics, any outlet's tip-submission route, Apple's appetite for featuring this app, most
competitors' purchase prices, whether the Search API counts are a census, a specific published
compression shortcut, the current truth of a few `AGENT_LOOP.md` rows, and anything at all about
how the app behaves on a phone. Section 7 lists them in full.
