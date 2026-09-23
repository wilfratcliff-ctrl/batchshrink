# BatchShrink - pricing and positioning

Decision record, 2026-09-23. This document decides what the product should be. It changes no
code, no price and no store listing. Nothing described here as a recommendation exists in the
tree today.

## How to read the claims in this file

Every statement below is one of three kinds, and they are labelled:

- **[repo]** - comes from this repository. The file and section are named.
- **[looked up]** - fetched from a public source on 2026-09-23, with the URL given in the
  appendix. These are the only facts in this document that could have changed since it was
  written.
- **[inference]** - my judgement, arithmetic or product reasoning. Not a fact about the world.

Two of these labels appear together where a looked-up number supports an arithmetic conclusion.

## What the product is right now

**[repo]** `README.md` (status block) and `docs/NEXT_PHASE.md` (status block) agree on the state
of the app, and it is a deliberate four-way split: historical builds, implemented source,
observed behaviour, and still-not-observed behaviour. **The observed column now contains two
entries, not one.** On 2026-09-23, CI run `35852961091` at commit `5d72357` compiled both targets
and ran its XCTest suite green; the last run observed to execute the suite was job 1 at
`31b6245`, green. The second entry is the launch job: at `780f14f` it installed the standalone app
on a simulator, waited for the introduction's Skip control, tapped it and reached the batch
screen, which is the first time anything in this project observed the app doing anything. That is
one navigation on a simulator with no photo library. No case count is quoted here, because the
number changes with every round; the local gate prints the current one.

**One correction to the source this paragraph cites.** It used to quote `README.md` as saying "No
screen has been rendered, no video has been exported, no original has been deleted and no queue
file has been written on a device." That sentence is now wrong in its first clause, and `README.md`
contradicts itself: line 11 records the rendered screen as the repository's second observed entry,
while line 165 still repeats the older sentence. `README.md` is not this document's file to edit;
the fix is a one-line correction in the README status block.

**[repo]** Everything else is unobserved. No video has been exported, no original has been deleted
and no queue file has been written on a device. `docs/PHYSICAL_DEVICE_TEST_PLAN.md` is entirely NOT
RUN, and it is still the thing this whole document waits on. Build 10 remains the last build that
reached anyone, and it predates every reliability change made since.

**[repo]** `docs/DEVELOPMENT_REVIEW.md` names the product shape in one line: it is free, there is
no purchase code, and monetisation is explicitly deferred. From its "Development hygiene and
later milestones" section: "After reliability acceptance, finish icon/store assets,
privacy/support pages and truthful storage/quality copy. Then select and implement the purchase
model, including entitlement restoration and interrupted transactions."

That sentence is the hinge for this whole document. The purchase model is deferred behind a named
gate, and this document's first job is to say honestly whether the gate is open.

## 1. The honest analysis of free

### 1.1 What free costs the owner

**Money.** **[repo]** `AGENT_LOOP.md` and `README.md` both record the two real bills:

- The Apple Developer Program membership, required to ship anything at all. **[looked up]** Apple
  lists it at 99 USD per membership year. This cost is incurred whether the app is free or paid,
  and it recurs for as long as the app is on the store. A free app that has been installed even
  once cannot be quietly stopped paying it without the app being removed.
- EAS build minutes. **[repo]** `AGENT_LOOP.md` records that the account's free-plan iOS builds
  for September were exhausted, resetting 1 October 2026, and that this blocked the one gate
  that can prove Swift behaviour. **[looked up]** Expo's current free tier is 15 iOS builds per
  month on a low-priority queue, with paid tiers starting at 19 USD per month. **[inference]** So
  the owner currently has two separate ceilings: a yearly cash floor of about 99 USD that cannot
  be avoided, and a monthly ceiling of 15 iOS builds that can be avoided for 19 USD per month but
  which is awkward enough (one device build per few weeks at a sensible working pace) that it
  will keep shaping the release rhythm.

**[inference]** The build ceiling is the more dangerous of the two, because it is not a money
problem but a verification problem. A free app that cannot be rebuilt is not a product being
maintained; it is a product decaying in place.

**Time.** **[inference]** Free users of a utility that deletes things generate support traffic
out of proportion to what they pay, because the marginal revenue of a free user is zero while the
marginal support cost is not. The specific questions this app will attract are the expensive
kind: "where did my video go", "my video is still there in Recently Deleted", "my storage did not
go down", "the app says it cannot process this file". Each of those needs a human who knows what
the app recorded and what Photos did. **[repo]** The app deliberately logs only fixed stage names
and generic failure categories, with no filenames, paths, identifiers or media contents. That is
the right privacy decision and it makes every support conversation harder, because the owner has
nothing to look at except what the user types back.

**[repo]** There is also a hard cadence cost already visible. `AGENT_LOOP.md` shows six rounds of
work in a week, three rounds of which had to be re-verified because the verification route was
wrong. **[inference]** A free app does not reduce that cadence; it just means the cadence is
funded entirely by the owner's unpaid hours.

**Support expectations.** **[inference]** Free raises expectations of unlimited patience rather
than of entitlement, but the response the user actually needs is identical. The realistic
obligation a free app creates is "someone will read this and answer", and with one person, no Mac
and no device test, that obligation is currently unfundable in time rather than in money. The
worst version of free is the one where the app is on the store and the owner has stopped reading
the address it publishes.

### 1.2 What free buys

**[inference]** Three things, and only the first is certain:

1. **Users who are willing to be the first device testers.** This is the real prize. The single
   most valuable artifact in this project's future is a sanitized `DEVICE_RESULTS.md` populated
   from a real library on a real iPhone. A paid app cannot ask strangers for that; a free app in
   TestFlight or in the store can. **[repo]** `docs/PHYSICAL_DEVICE_TEST_PLAN.md` is the
   instrument; free is what gets it filled in.
2. **A reputation that matches the pitch.** **[inference]** The product's whole claim is
   restraint - it refuses what it cannot preserve, it does not delete by default, it does not
   upload. A product that sells restraint and then charges at the anxious moment is telling two
   stories. Free at launch keeps the story single.
3. **An honest signal about whether anyone wants this.** **[inference]** Not downloads, but
   whether anyone completes a real run and comes back with a second video. That is worth more
   than early revenue at this stage, and it is only cheap to obtain while the app is free.

**[inference]** What free does not buy: evidence that anyone would pay. Those are different
questions, and passing the first does not answer the second. That is why the recommendation below
keeps a free tier rather than switching the whole app to paid.

### 1.3 Is the reliability milestone met?

**No - not in the sense the review meant it, although the logic half of it is now genuinely
strong.**

**[repo]** `docs/DEVELOPMENT_REVIEW.md` asked for a reliability release covering "safe saves,
deletion and recovery", with milestone 1 in `docs/NEXT_PHASE.md` being "Compile, run tests and
pass physical Phase 0 acceptance; retain sanitized evidence."

**[repo]** Taking the two halves separately:

- *Logic reliability: met, and better than most unreleased projects.* Persistence failures now
  block the next Photos mutation; deletion requires a stored original-to-copy receipt and
  revalidates both assets immediately before Photos is asked; verification requires every sample
  window to decode and decodes audio rather than trusting track duration; the library change
  monitor is constructed and tested; the suite ran green in CI. Four of the seven original test
  failures were one real bug and three faulty tests, and that bug - a Delete tap after the copy
  changed doing nothing and saying nothing - is exactly the class of silent failure this app
  cannot afford. The suite has not run since the account's Actions runners stopped starting on
  2026-09-23, so the newest changes in the tree are uncompiled.
- *Product reliability: not met.* **[repo]** N19 in `AGENT_LOOP.md` is the row that says so, and
  one clause of its own wording has gone out of date. It reads: "Runtime behaviour is still
  entirely unproven even though it compiles: no screen has been rendered, no export has run, no
  queue file has been written". The first clause is no longer true - the CI launch job rendered a
  screen on a simulator at `780f14f`, reaching the batch screen - and the rest stands. That is one
  navigation on a simulator with no library, so the substance of N19 is unchanged: no video has
  been exported, no original has been deleted and no queue file has been written on a device. The
  seven-failure round is behind the
  repository now: the suite first went green in CI at commit `5d72357`, and the last run observed
  green was job 1 at `31b6245`. One of those four fixes is behaviour-changing code in the deletion
  path, so the deletion cases in the device plan remain the ones nothing has exercised.
  **N16 and the remainder of N5 - exactly-once save reconciliation - were closed in rounds 6 and
  16**, not open: a restored mid-save record now looks for the copy it recorded rather than only
  flagging a question, and a save Photos was asked for but did not confirm is never a clean
  failure. What N16 still owes is the device result, which is N19. N12 is closed:
  `VideoVerificationService` reads an original's coded subtype and transfer function, so HDR and
  ProRes originals are genuinely refused, in `AssetRules`' own words - as the app reads the videos
  (in the scan, and over the whole selection before the first export), and never yet on a real
  original of either kind.

**[inference]** The distinction matters for pricing, not just for engineering pride. A test suite
proves that the code does what its authors intended against fakes. It cannot prove what PhotoKit,
AVFoundation and a 30-billion-pixel real library do. Those are precisely the interactions a
paying customer would be paying for: an iCloud download that actually completes, a copy that
actually plays, an original that is actually still there. So the milestone gate is still closed,
and the correct action on the gate is to wait rather than to charge.

**[inference]** One more argument for waiting that the review does not make. Charging before
device evidence exists would spend the product's only scarce asset - the benefit of the doubt
a user extends to a free, careful tool - on a version of the app whose central promise has never
been observed to hold. It is cheap to be free now and expensive to be wrong about a deletion
flow later, because the store rating and the word of mouth are one-way.

## 2. The realistic models

**[inference]** for the whole of this section except where a label says otherwise. The
implementation notes are grounded in **[repo]** `docs/NEXT_PHASE.md` (StoreKit and commercial
release) and `docs/DEVELOPMENT_REVIEW.md` (later milestones).

The framing that matters for this product is not "how do I make money" but "where does the
exchange happen relative to the risky moment". The app has one anxious moment - the point where a
user considers letting it remove an original - and every model below is judged by whether the
payment lands near that moment or far from it.

### 2.0 The paywall risk taxonomy, before the models

**[inference]** Not all paywalls in this app are equivalent. Ranked from harmless to unacceptable:

1. **Paywall in front of the extra copies.** A free user shrinks a video, gets a smaller Photos
   item, and hits a limit on how many more they can do per run. The failure mode is "I have to
   come back tomorrow". Nothing was created that cannot be finished, no original is at risk, and
   the free tier's output is still a genuine complete result for the videos it did process.
   **Acceptable.**
2. **Paywall in front of a convenience feature.** Unlimited queue across app restarts, longer
   history, an extra preset, bulk selection. The user loses a comfort, not an outcome.
   **Acceptable, with one caveat** - see the recommendation: never take away something the free
   tier already had.
3. **Paywall in front of verification detail.** "Upgrade to see the full verification report."
   **Reject.** **[inference]** It implies the free version might not have checked the copy
   properly, which attacks the single claim the product is built on. If verification is
   conditional, the product's premise is conditional.
4. **Paywall in front of export at all.** The user pays before receiving anything. This is a
   normal paid app, and it is only unacceptable *at launch*, for the sequencing reason in 1.2 -
   paying customers cannot be the first device testers of a deletion feature.
5. **Paywall in front of deleting an original.** **Unacceptable, and it is a different category
   from number 1, not a stronger version of it.** Two distinct problems compound here. First,
   incentive: the app would earn only at the moment the user removes a file, which quietly bends
   design and copy toward encouraging removal, in a product whose entire value is that it does
   not do that. Second, a "pay to finish" gate lands immediately after the user has been told
   "your copy is verified and safe", which trains them to pay at their most anxious moment and
   teaches them that the app's caution was a sales technique. **[repo]** The app already goes to
   unusual lengths to make deletion evidence-based; a price on that step undoes more trust than
   the revenue is worth.
6. **A free tier that creates duplicates with no way to clean them up.** Closely related: if a
   free user can make copies but not remove originals, their storage gets *worse* than before
   they used the app, and the app has charged them in space. This is a half-broken flow, and it
   is the specific failure the recommendation has to avoid.

### 2.1 One-off purchase

What the user gets: everything, once, with no renewal. Usually a paid-up-front app, or a free
download with a single non-consumable unlock.

What it takes to implement: StoreKit 2 with a verified-transaction path, a restore/current
entitlement path, revoked-refund handling, and interrupted-purchase handling - the full list
already written in `docs/NEXT_PHASE.md`. Plus, because the app has no account and no backend, the
entitlement has to live entirely in StoreKit and be re-checked offline.

App Store review: **[looked up]** guideline 3.1.1 requires in-app purchase for unlocking features
or functionality; no licence keys or own-mechanism unlocks. A clean non-consumable is
well-trodden and low risk.

Effect on promises: **[repo]** `README.md` states there is "no subscription, user account,
product analytics, advertisement, backend or app-managed media upload". An unlock does not break
that ("no subscription, no account, no backend" survives), but it does make the literal phrase
"no purchase" false if it appears anywhere. The sibling marketing files currently assert the app
is free with no purchase and no StoreKit; that is a documentation debt this decision creates and
those files are not mine to edit.

Verdict: **[inference]** the right *payment shape*, and the wrong *launch* shape on its own.
Charging up front means the first people who touch the delete flow have paid for the privilege of
finding out whether it works.

### 2.2 Subscription

What the user gets: ongoing access for as long as they keep paying.

What it takes to implement: everything in 2.1, plus a subscriptions group, renewal and expiry
handling, grace periods, price-change consent, billing-retry flows and a support burden that
recurs monthly.

App Store review: **[looked up]** guideline 3.1.2(a) requires that an auto-renewable subscription
"provide ongoing value to the customer", with the given examples being new content, episodic
content, multiplayer, consistent substantive updates, large media collections, SaaS and cloud
support.

Effect on promises: **[repo]** `README.md` states the product has no subscription and no account.
A subscription makes that false, and would require rewriting the promise rather than extending
it.

Verdict: **[inference]** reject. This is an offline transcoder. It has no server, no marginal cost
per user, no content to keep fresh and no account to justify. A subscription would be asking the
user to pre-pay for updates to code that already does its job, which is the least defensible
version of a recurring charge; and the guideline's own example list, apart from "consistent,
substantive updates", has nothing this app can point at. A solo developer also cannot staff the
renewal and billing-support surface it creates. If the owner ever wants recurring revenue, the
honest route is a new product with a real continued service attached, not a tax on this one.

### 2.3 Freemium with a paid unlock

What the user gets: a genuinely complete core experience for free, and a one-time (or
optional-recurring, but here one-time) purchase that removes a scale or convenience limit.

What it takes to implement: the StoreKit work from 2.1, plus a decision about exactly what the
free tier withholds, plus - the part that is easy to underestimate - copy that tells the user
where the limit is *before* they hit it. The app also needs to keep working fully offline and
without an account, so the entitlement check must degrade to "last known entitlement" rather than
"sign in to confirm".

App Store review: **[looked up]** same 3.1.1 requirement as 2.1, plus a completeness expectation:
an app whose free tier is a stub that only makes sense after purchase is the kind of thing review
pushes back on. **[inference]** The safest construction is the reverse of a demo: the free tier
should be something the product would be proud to ship on its own, with the paid tier adding
capacity.

Effect on promises: **[repo]** The "no subscription" and "no account" promises survive. The "no
in-app purchase" phrasing in the sibling marketing files does not, and would need updating.

**[inference]** Regarding the risk taxonomy: this is the only model that lets the exchange happen
in category 1 or 2, away from the delete flow, while still collecting free-user device evidence
first. That combination is the whole reason it is the recommendation.

### 2.4 Tip jar

What the user gets: the full app, unchanged. The tip buys nothing.

What it takes to implement: the least of any option - a consumable in-app purchase and a
thank-you screen. **[looked up]** Apple's guidelines explicitly permit in-app purchase currencies
"to enable customers to tip the developer", so this is a legitimate and low-risk construction.

App Store review: low risk. No entitlement, no restore obligation for consumables, no ongoing
value test.

Effect on promises: minimal, but it does introduce StoreKit and therefore the "no purchase"
documentation debt.

Verdict: **[inference]** reject as the revenue model, keep as a possible optional extra. A tip
jar on a free app converts very few users, and it asks for money without a stated exchange. For a
product whose credibility rests on restraint, "would you like to pay for nothing in particular"
is not the problem; the problem is that it raises no money and answers no question. Its one real
advantage is that it cannot damage anything, which makes it a fine thing to add a year later
beside an unlock that already works.

### 2.5 Free forever

What the user gets: everything, permanently.

What it takes to implement: nothing new. It is the current state. **[repo]** There is no StoreKit
code, no account, no backend and no analytics in the tree.

App Store review: nothing to review regarding payments. **[inference]** The review risk moves
elsewhere and becomes larger: a free app that can remove photos will face questions about its
Photos usage descriptions and its App Privacy answers, all of which `docs/NEXT_PHASE.md` already
lists as pre-review work.

Effect on promises: it is the only model that requires no rewrite of anything.

Verdict: **[inference]** reject as the *destination*, accept as the *starting position*. Free
forever commits the owner to paying the 99 USD membership indefinitely, absorbing unbounded
support time, and never testing whether anyone values the product enough to fund its upkeep. It
is, however, exactly the right state to be in until the evidence list in section 5 is satisfied,
because it is the state that generates that evidence.

### 2.6 Summary table

**[inference]** throughout; the guideline references are **[looked up]**.

| Model | User gets | Implementation cost | Review risk | Effect on the trust pitch |
| --- | --- | --- | --- | --- |
| One-off purchase | Everything, once | StoreKit 2, restore, refunds, offline entitlement | Low (3.1.1) | Neutral if the gate is not on deletion; blocks pre-charge device evidence |
| Subscription | Ongoing access | StoreKit 2 plus renewal, grace, retry, recurring support | Medium (3.1.2a needs ongoing value) | Damaging: contradicts "no subscription, no account" |
| Freemium unlock | Complete core, paid capacity | StoreKit 2 plus careful free-tier design | Low-to-medium (3.1.1 plus completeness) | Neutral if the gate is capacity, not safety |
| Tip jar | Nothing extra | One consumable | Low (tips allowed) | Neutral; raises almost nothing |
| Free forever | Everything, always | None | Low for payments, higher for Photos/privacy review | Preserves it exactly; costs the owner indefinitely |

## 3. Recommendation

**[inference]** Recommend freemium with a single one-time unlock, introduced only after the
evidence gate in section 5 is met. Launch free, in the store, with the paid tier added in a later
version once real device results exist.

### 3.1 The price

**4.99 USD one-time, non-consumable, unlimited. Named as an unlock, not a "Pro" tier, and with
no expiry.** Regional tiers are set in App Store Connect; the number here is a decision, not a
change to any live price, and nothing in the app or its listing currently carries a price at all.

Reasoning:

- **[inference]** A single-purpose iPhone utility that processes files locally and forever is
  priced by comparison with other local utilities, not with services. One-off utility apps of
  this class sit roughly in the 2.99-9.99 USD band; 4.99 sits in the middle and reads as
  "considered" rather than "cheap" or "grabby" for a tool that touches the photo library.
- **[inference]** The work below the surface is real - receipt-based deletion, revalidation,
  all-window decode verification, durable queue - and a price in the low-single digits is
  consistent with that without inviting the scrutiny a 9.99 or 14.99 price would draw for a
  feature set this small and this unproven at launch.
- **[inference]** It avoids the awkwardness of a 0.99 or 1.99 price, which on a product whose
  pitch is care can read as either an impulse purchase or a signal that the app is trivial.
- **[looked up]** Apple's App Store Small Business Program reduces the commission to 15 percent
  for developers making up to 1 million USD in proceeds in the prior calendar year; 30 percent is
  otherwise standard. **[inference]** At 4.99 with 15 percent commission, proceeds are about 4.24
  USD before tax, so the 99 USD annual membership alone needs roughly 24 sales a year to break
  even - about two a month. That is the floor to clear, not a target, and it ignores the recorded
  EAS tier. If the owner moves to the 19 USD per month EAS plan, the yearly floor becomes about
  327 USD, needing roughly 78 sales a year.
- **[inference]** Price is not the lever here. Going to 9.99 changes the break-even from about 24
  sales a year to about 12, which is not the difference between a viable project and a dead one.
  Getting the trust right and the release rhythm sustainable is.

**[inference]** One addition worth considering rather than assuming: give the unlock free to
anyone who used the app before the paid tier existed. It costs little, matches the product's
character, and removes the single most likely source of a bad early review - "the app was free
and now it charges me for what I already had". The rule that follows from it is firmer than the
gesture: **never move something a free user already had behind the paywall.** The paid tier may
only ever add.

### 3.2 What the free tier must still do

**[inference]** The free tier is not a demo. It must be a complete, honest, self-consistent
product that a person could use indefinitely without ever feeling misled:

1. **The full pipeline, end to end.** Retrieve (including from iCloud), export, verify, preview,
   save. No step is ever disabled for a free user.
2. **Full verification and full refusal.** Every sample window decoded, audio decoded, imported
   copy compared. If a video cannot be preserved, the app refuses it with the same reason a
   paying user would see. Verification is never a paid feature.
3. **Opt-in deletion, in full and correctly gated.** This is the point most worth arguing, and I
   will argue it: deletion must be free. If the free tier makes a copy but cannot remove the
   original, the user finishes the run with duplicate videos and less free space than they
   started with - the app has made their stated problem worse. That is exactly the half-broken
   flow to avoid. Deletion is also the app's most dangerous feature and its most trust-dependent
   one; putting a price on it creates the incentive described in 2.0, item 5.
4. **The safety defaults, unchanged in both tiers.** Deletion off by default, one-video flow
   never deletes, no bulk delete-everything, Recently Deleted stated wherever the choice is
   offered, the receipt and revalidation gate identical. A paying user must not get a looser
   gate than a free user.
5. **A stated, visible limit.** A small per-run cap - something in the region of five videos per
   run, unlimited runs - shown on the selection screen before the user starts, not discovered as
   an error at the end. Unlimited runs matter: a lifetime cap on a storage app is a cap on the
   exact thing the user came for, and it turns a free user into someone who can never finish.
6. **No account, no network, no analytics in either tier.** The unlock is checked through
   StoreKit and cached; the app never becomes dependent on a server.

### 3.3 What the paid tier adds

**[inference]** Capacity and comfort only:

- unlimited videos per run;
- the durable queue surviving app restarts mid-run (the free tier can still finish a run, it just
  does it in smaller batches);
- longer shrink history;
- the higher-quality preset if a defensible quality case is ever made for it;
- and, optionally later, a tip jar beside it for people who want to give more.

### 3.4 What I would not put behind the paywall

**[inference]** Stated as a list because it is the part most likely to drift: verification and its
report; the refusal behaviour; deletion of an original; the safety gate itself; the iCloud
retrieval path; and anything currently free. A paywall on any of those converts a trust product
into a toll booth.

### 3.5 Sequencing

1. **[inference]** Ship the app free. Fill in `docs/PHYSICAL_DEVICE_TEST_PLAN.md`.
2. **[inference]** Fix what the device finds. This is not a formality: the app's most dangerous
   path has never executed.
3. **[inference]** Add the free-tier cap and the unlock in the same release, so no user ever
   experiences a feature being taken away.
4. **[inference]** Update `README.md` and the marketing files' "free with no purchase" statements
   in that release, because they will by then be false.

## 4. Positioning

### 4.1 The sentence

**BatchShrink makes smaller copies of the videos that are filling an iPhone owner's iCloud
storage - on the device, one video at a time, each copy proved good before the app ever asks
whether to remove the original - and it is not a backup tool, not an automatic cleaner, and no
promise that your iCloud bill will drop.**

**[inference]** Every element earns its place: "smaller copies" is the literal function;
"on the device" is the differentiator against anything that uploads; "one video at a time" is
honest about the refusal behaviour, which is a feature but would read as a limitation if
discovered; "proved good before ... asks" is the safety ordering, which is the product; the three
negations are section 4.2.

### 4.2 The three things it must never be positioned as

**Trap 1 - a backup tool.** **[inference]** The pitch "your videos, made smaller and kept safe"
sounds like backup and is not. What the app produces is a re-encoded file: lossy, codec-changed,
with album membership, captions, keywords, ratings and edit history deliberately not carried
over. It refuses whole categories of video it cannot preserve, which a backup tool cannot do,
because refusing to back something up is a failure of the product. It has no restore, no
versioning, no cross-device guarantee and no server. **[repo]** `README.md` is explicit that a
saved item means the local PhotoKit change succeeded, not that iCloud finished uploading. **[inference]**
The trap is the user who treats the copy as their safety net and then removes the original: they
have converted a reversible re-encode into their only copy of a memory. This is also why the
product must never say "safe" without saying what it checked.

**Trap 2 - a cleaner that deletes things for you.** **[inference]** The word "cleaner" implies
unattended, aggressive, decisive behaviour, and the app is the opposite by construction:
deletion is off by default, the one-video flow never deletes, there is no bulk delete-everything,
and every individual delete needs a stored receipt plus a fresh look at both assets immediately
before Photos is asked. **[repo]** `docs/NEXT_PHASE.md` records that the gate was made stricter
for exactly this reason. **[inference]** The trap is twofold. Users who come for a cleaner will
ask for the feature the app deliberately does not have, and the app's restraint will read to them
as incompleteness rather than care; and the support and liability profile of an automatic cleaner
- "it deleted 400 videos overnight and 3 were wrong" - is not survivable for one person. Selling
the refusal is the positioning; selling the deletion is the trap.

**Trap 3 - a storage-tier downgrade guarantee.** **[repo]** The docs warn about this explicitly
and repeatedly, so this one is not my judgement. `docs/NEXT_PHASE.md`: "Do not promise to lower
an iCloud subscription tier from estimated media ratios." `README.md`: "**Nothing here lowers an
iCloud bill.**" The same README paragraph explains why in one sentence: adding a second item
initially consumes more storage, and deleting an original only moves it to Recently Deleted for
30 days before the space comes back. `README.md` also limits what the number on screen even means:
the displayed byte difference is a measured difference between two files, not a Photos or iCloud
allocation. **[inference]** The trap has several teeth. The app can measure file bytes, not the
user's plan. A new copy occupies space immediately, so the first run may make things look worse
before they get better. Recently Deleted holds the space for a month, so the change the user
paid for can be invisible for weeks. Apple's Optimize iPhone Storage, caches, other devices,
shared libraries and the user's own later behaviour all move the real number in ways the app
cannot see. A user who downgrades their plan on the strength of the app's number and then runs
out of space blames the app, correctly, because the app implied the guarantee. If the app ever
shows a plan or a tier alongside its measurements, that is the moment the promise it cannot keep
has been made.

**[inference]** The unifying rule behind all three traps: the app may only claim what it observed.
It observes bytes, decodes, tracks and its own Photos operations. It does not observe the user's
bill, the state of iCloud, or the future.

## 5. What has to be true before charging

**[repo]** and **[inference]** together. Each item names the repo artifact that would be its
evidence. The order is deliberate: item 1 is upstream of almost everything else, because nothing
below it can be honestly assessed while the app has never executed.

1. **The app has run on a device at all.** **[repo]** N19. Evidence: a completed pass of
   `docs/PHYSICAL_DEVICE_TEST_PLAN.md`, starting with the acceptance criteria in `README.md` - a
   TestFlight build on the iPhone 15 Pro Max selects a video whose original must download from
   iCloud, exports a smaller HEVC file, passes verification, saves a separate playable Photos
   item, and leaves the original unchanged. Nothing here is optional, and no arguing from the
   green test suite substitutes for it.
2. **The build that runs it is build 11 or later.** **[repo]** `docs/PHYSICAL_DEVICE_TEST_PLAN.md`
   states that any next upload must be 11 or later, and that build 10 predates every round 1-5
   change. Evidence: the recorded build number in the results, not just "a build".
3. **The deletion path has been observed, not just unit-tested.** **[repo]** The first half is
   done: the fix for the seven failing cases, whose four parts include behaviour-changing code in
   the deletion path, has turned the suite green in CI, first at commit `5d72357`. The half that
   has not happened is the device run, where the deletion cases in the plan must actually pass -
   copy edited or removed after a run, access revoked, an old queue restored, both deletion modes,
   a cancelled system prompt, counts of five and seven, and the interruption windows between save
   and delete. Evidence: a sanitized `docs/DEVICE_RESULTS.md`. **[inference]** The reason this
   outranks everything is that the known bug this must disprove is a *silent* one: tapping Delete
   after the copy changed did nothing and said nothing. Silent failure in a deletion path is
   incompatible with charging.
4. **Exactly-once save reconciliation is either implemented or explicitly surfaced.** **[repo]**
   N16 and the open remainder of N5. Evidence: either the reconciliation itself, or a documented,
   user-visible statement of what happens when Photos accepts a save whose follow-up record was
   not written. **[inference]** Duplication is the most likely bad outcome for a paying user, and
   it is the one failure that directly contradicts "no duplicate Photos items".
5. **HDR and ProRes are genuinely refused, and the refusal has met a real original.** **[repo]**
   N12 is closed: `VideoVerificationService` reads an original's coded subtype and transfer
   function and refuses any Apple ProRes subtype and both HDR curves, in `AssetRules`' own words.
   The scan reads them for videos already on the phone, and the run reads every chosen video before
   the first export, so an HDR or ProRes original is stopped before anything is exported unless its
   original could not be read. Evidence still owed: a device result for a real HDR clip and a real
   ProRes clip, because the detection has never met one. **[inference]** Charging for a copy of an
   HDR video whose appearance was never inspected is charging for an unverified promise.
6. **The savings numbers have survived a real library.** **[repo]** The device plan requires
   recording source and output byte counts and checking that negative or zero savings display and
   disable Save. Evidence: recorded byte counts across a spread of real clips, including
   already-HEVC and low-bitrate inputs that may grow. **[inference]** The report must match
   reality on a device before it is sold, or every paying user's first run is a minor
   disappointment.
7. **StoreKit is implemented to the standard the review already set.** **[repo]**
   `docs/NEXT_PHASE.md` and `docs/DEVELOPMENT_REVIEW.md` both require sandbox/StoreKit
   Configuration tests, verified transactions, restore and current entitlements, refunds and
   revocations, and interrupted purchases. Evidence: those paths exist, are tested, and work with
   no network and no account.
8. **The free tier is not a stub.** **[inference]** Evidence: a written statement of the free
   tier's limit and what it includes, checked against section 3.2 point by point. If a free user
   can reach a state their tier cannot resolve, the tier is not ready.
9. **Support is answerable.** **[inference]** Evidence: a working support address or page that
   someone actually reads, a truthful privacy policy, App Privacy answers matching the manifest,
   and - given that the app logs no identifiers by design - a written procedure for turning a user
   report into a reproduction. Without that last item, every report costs more than the sale is
   worth.
10. **The arithmetic is known.** **[inference]** Evidence: the owner has written down the yearly
    floor - 99 USD membership, 228 USD a year if EAS Starter is kept - and the number of sales at
    4.99 needed to clear it (about 24 a year, about 78 with EAS Starter; **[looked up]** the
    commission rate and tier prices behind those figures, with the arithmetic marked as
    inference). This is the last item because it is the least important one, and the easiest to
    mistake for progress.

**[inference]** A shorter form, if only one sentence survives: charge when the app has been
observed to keep the original, and not one day before.

## 6. The 12-month shape

**[inference]** throughout. The constraint that shapes everything here: a solo owner with no Mac,
who cannot buy more hours. Every milestone below is stated as a decision the owner can make or an
artifact the owner can produce alone, and none of them is a download, revenue or rating number,
because those are not things the owner controls.

**[repo]** Two existing facts constrain the rhythm: EAS is only needed for device builds, and
**[looked up]** the free EAS tier allows 15 iOS builds a month, so device builds should be
reserved for milestones rather than commits; CI verification is free and should carry everything
else.

### At three months (by roughly December 2026)

"Working" means:

- **[inference]** A build numbered 11 or later has been installed on the physical iPhone, and the
  acceptance test has been run and written down in a sanitized results file.
- **[repo]** N21 is closed - a push has turned the suite green, so the deletion-path fix is
  verified rather than believed - and `main` is green.
- **[inference]** Every failure the device found is either fixed and re-verified, or written down
  as a known limitation with the app refusing to do the thing it cannot do. A limitation the app
  states is worth more than a feature it claims.
- **[inference]** The test plan's first five cases plus the original-safety case are complete.

The owner-no-control version of this milestone, to be explicit: none of it depends on anyone
downloading the app. It depends on one build, one phone and one afternoon of recorded results.

**[inference]** Honestly, at the current pace, three months may be generous. That is fine; the
milestone is a checklist, not a deadline, and the whole point is that it is measurable without an
audience.

### At six months (by roughly March 2027)

"Working" means:

- **[inference]** The deletion matrix has been run on expendable clips, including the
  interruption windows between save and delete, and the results are recorded. This is the case
  that decides whether deletion stays in the product.
- **[repo]** The HDR and ProRes refusal (N12) has met a real original of each kind on a device, so
  the detection is observed rather than only unit-tested.
- **[inference]** The free tier and its stated limit exist in a shipped version, and the one-time
  unlock exists behind it with a tested restore path. The app has been free and in the store for
  long enough that the "was free, now charges" problem has been handled deliberately - by
  grandfathering or by only ever adding.
- **[inference]** The documentation debt is paid: the "free, no purchase, no StoreKit" claims in
  the repository and the store listing match what the app actually does. **[repo]** That debt is
  created by this decision and is already visible in the sibling marketing files and in
  `README.md`.
- **[inference]** Exactly-once save reconciliation is either done or surfaced in the interface.

### At twelve months (by roughly September 2027)

"Working" means:

- **[inference]** The app has been in the store with a stable release for several months, and the
  supported-format matrix is a written, current list of what it accepts, what it refuses and why -
  maintained, because that list is the product.
- **[inference]** Support is a routine the owner can keep: an address that is read, a stated
  response window that is realistic for one person (weeks, not hours, and said so), and enough
  recorded reproductions that a report can be answered without a phone call.
- **[inference]** The EAS question has been decided on evidence rather than mood: whether the
  monthly free allowance is enough, or the paid tier is worth about 228 USD a year given the
  actual release rhythm.
- **[inference]** The financial question has been answered honestly, using sales rather than
  downloads: is the app covering its own floor? If yes, the decision is whether to invest more.
  If no, the options are to accept it as a maintained free tool with a public cost, or to stop -
  and both are legitimate, provided the choice is made rather than allowed to happen.
- **[inference]** Every deferred sibling has been re-decided and written down, not carried
  silently: background or overnight processing, photo and RAW compression, the broader
  special-format matrix, and the React Native front-end proposal that
  `docs/DEVELOPMENT_REVIEW.md` already says needs a concrete product benefit. A solo project's
  roadmap should be a list of decisions made, not intentions accumulated.

**[inference]** The shape across the three dates is deliberately the same: one artifact, verified,
per window. A device result at three months, a deletion answer at six, a maintained product with a
settled economics question at twelve. None of those requires an audience, and all of them are
things one person can do.

## Appendix - the looked-up facts and their limits

Fetched 2026-09-23. These are the only claims in this document that are not from the repository or
my own reasoning, and they are the ones most likely to have changed.

| Fact | Source |
| --- | --- |
| Apple Developer Program membership is 99 USD per membership year, prices vary by region | https://developer.apple.com/programs/enroll/ |
| App Store Small Business Program reduces commission to 15 percent for developers making up to 1 million USD in proceeds in the prior calendar year; 30 percent is otherwise standard | https://developer.apple.com/app-store/small-business-program/ |
| Guideline 3.1.1: unlocking features or functionality must use in-app purchase; in-app purchase currencies may be used to tip the developer | https://developer.apple.com/app-store/review/guidelines/ |
| Guideline 3.1.2(a): auto-renewable subscriptions must provide ongoing value, and the guideline's examples are content, updates, media collections, SaaS and cloud support | https://developer.apple.com/app-store/review/guidelines/ |
| Expo EAS free tier: 0 USD per month, 15 Android and 15 iOS builds, low-priority queue; Starter tier 19 USD per month | https://expo.dev/pricing |

Two deliberate omissions. No App Store Connect record was read, so nothing here states what the
app's store listing or price currently is; the sibling marketing files are the authority on that
and they are not mine to edit. And no current price for any competitor was surveyed, so the
4.99 USD figure rests on the reasoning in section 3.1 rather than on a comparison table.
