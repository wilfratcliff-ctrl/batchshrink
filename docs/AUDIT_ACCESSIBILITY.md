# Audit of record — accessibility, Dynamic Type and layout

Read-only audit performed on 2026-09-23, round 18, against the tree before that round's fixes. It
covers every file in `VideoShrink/Presentation/`, plus `VideoShrinkApp.swift`, `ContentView` and
the Expo host that renders it. It could not run the app, so every finding is a reading of the
source; the "not determined" section at the end says which of them a render would settle.

**This document is a finding list, not a defect list that has been fixed.** The summary table in
`AGENT_LOOP.md` carries the same IDs and is the only place that records status.

Line numbers were correct when the audit was taken. Read the code before acting on one.

## Findings

### A1 — [P1] The working screen's saved-so-far figure is hidden from VoiceOver
`VideoShrink/Presentation/BatchScreens.swift:820-836` (value at 822-824, container at 832)

On the batch working screen the running total is the only evidence the app is saving anything,
and VoiceOver reads it as "smaller so far, 3 copies saved" — the number never arrives.
`.monospacedDigit().accessibilityHidden(true)` sits on the value and the container closes with
`.accessibilityElement(children: .combine)`; a hidden descendant is removed from the
accessibility tree, and `combine` only merges what remains. The comment at 833-834 claims the
opposite of what the modifiers do. The right pattern is 50 lines below: `BatchFinishedRow` gives
its figure an `.accessibilityLabel("\(ShrinkFormat.bytes(saving.bytesSaved)) saved")`.

**Narrowest fix:** swap `accessibilityHidden(true)` for that label.

### A2 — [P1] The finished screen's action bar can take the whole landscape viewport
`VideoShrink/Presentation/BatchScreens.swift:1160-1186`; the bar itself at
`VideoShrink/Presentation/ShrinkStyle.swift:145-159`

`BatchFinishedScreen` can stack five controls — primary (58pt), "Delete N originals", "Try the
failed ones again", "I checked Photos — run them again" and "Done", all at least 44pt, plus 4×10
spacing and 30pt padding. That is roughly a 304pt bottom inset. Both landscape orientations are
declared (`app.json`, `VideoShrink/Resources/Info.plist`) and a landscape iPhone offers about
330pt below the bar, so the `ScrollView` gets what is left and the totals card, read-back line,
failure list and deletion note — the reason the screen exists — are reduced to a sliver. At
accessibility text sizes the same bar needs roughly 450pt and overflows.

`ShrinkActionBar` is used by 10 screens. The finished screen is the one that overflows at default
text; the paused screen (3 controls) and the selection screen follow at large text.

**Narrowest fix:** keep the primary and one secondary visible and move the rest into a single
overflow `Menu`, each item keeping its label.

### A3 — [P2] The quality estimate reads as a bare number
`VideoShrink/Presentation/QualitySelector.swift:109-129`

VoiceOver reaches "1.2 to 2.4 gigabytes" with no label, and the explanation is a separate
element. The identical shape at `ShrinkStyle.swift:128-140` (`ShrinkStat`) and
`ShrinkScreens.swift:132-141` (`ShrinkResult`) both combine their children, so the convention is
already established twice.

**Narrowest fix:** add `.accessibilityElement(children: .combine)` to that `VStack`.

### A4 — [P2] The word mark cannot fit at accessibility sizes
`VideoShrink/Presentation/ShrinkStyle.swift:193-206`, drawn at `ShrinkOnboarding.swift:19-27` and
`BatchScreens.swift:55`

"BatchShrink" is one unbreakable word at `.headline` — roughly 53pt at AX5, so about 320pt wide
— sharing a row with the Skip button in the onboarding header, and inside a fixed-height
navigation-bar item on the start screen. It truncates on the first screen a large-text user sees.

**Narrowest fix:** `.lineLimit(1).minimumScaleFactor(0.6)` on the word mark. Its spoken name is
already supplied by `.accessibilityLabel("BatchShrink")`, so shrinking it costs nothing.

### A5 — [P2] The selection header keeps the sort pill beside the headline at accessibility sizes
`VideoShrink/Presentation/BatchScreens.swift:385-407`

"Make room." at `.largeTitle` and the sort pill share one row with an 8pt spacer against about
327pt of usable width. The headline can wrap; the pill's single word cannot, so it truncates and
the user can no longer read which order the grid is in. The file already holds
`@Environment(\.dynamicTypeSize)` and the project's own answers to this exist in four places.

**Narrowest fix:** stack the pill under the headline, or show the symbol alone, when
`dynamicTypeSize.isAccessibilitySize`.

### A6 — [P3] Section headings inside cards are not VoiceOver headers
`QualitySelector.swift:103-107`, `BatchScreens.swift:614`, `842`, `1280`

The app marks its large titles as headers, so the rotor is useful — until "Picture size",
"Smoothness", "Not supported", "Just finished" and "Needs attention".

**Narrowest fix:** add the trait at those five sites; `sectionTitle(_:)` covers two of them.

### A7 — [P3] The working screen can announce the same percentage up to three times
`BatchScreens.swift:776`, `791-796`

The orb announces the stage and percentage (`ShrinkStyle.swift:232-233`), the bar announces the
stage again as its label with its own percentage (793), and a separate `Text` announces "42%" as
a third element (794-795). `batch.currentStage?.title` is both labels.

**Narrowest fix:** drop or hide the separate percentage `Text`.

### A8 — [P3] Two surfaces bypass `ShrinkHairline`, so Increase Contrast misses them
`QualitySelector.swift:50`, `DeletionSheet.swift:23`

`ShrinkStyle.hairline` exists so a border becomes a real line when the setting is increased, but
the unselected quality pills keep a hardcoded `Color.primary.opacity(0.07)` and the originals
list has no border at all — so the two things a user must distinguish are the two that do not
respond.

**Narrowest fix:** use `ShrinkStyle.hairline` for the unselected stroke, and add one over the
originals list.

### A9 — [P3] The app's haptics switch does not cover the quality pills
`QualitySelector.swift:99-100`; the preference at `BatchFlow.swift:29` and
`SingleVideoFlow.swift:29`, read at `:40` and `:110`, offered as "Completion haptics" at
`ShrinkScreens.swift:264`

A user who turns the app's haptics off still gets a haptic on every quality pill — the two
most-tapped controls. Reduce Motion is correctly not involved; haptics are not motion. The
system-level Haptics switch is the remaining escape hatch.

**Narrowest fix:** widen the preference's name to "Haptics" and gate these two triggers on it.

### A10 — [P3] Two numeric transitions are inert
`BatchScreens.swift:488` and `759`

Both ask for `.contentTransition(.numericText())` with no enclosing `.animation(_:value:)`, so
they snap. The two that work (`:825` with `.animation` at `:835`; `QualitySelector.swift:116,119`
with `.animation` at `:124`) show the intended pattern. It also means a reader cannot tell the
live modifiers from the dead ones.

**Narrowest fix:** add a Reduce Motion-gated `.animation` as the other two have, or delete the two
modifiers.

## Already correct — do not re-walk

1. Reduce Motion gates every app-authored animation, and the `.transition(.opacity)` uses sit
   inside those gated `withAnimation` calls.
2. Decorative artwork and icons are hidden from VoiceOver throughout.
3. Hiding the thumbnail loses nothing: `rowLabel(_:)` puts date, duration and size into both the
   preview button and the row button.
4. Every icon-only control has a name. All 15 `accessibilityIdentifier` values sit on controls
   that also have a visible title or an explicit label.
5. Selection state is exposed, not only coloured, with a hint saying what the tap will do.
6. Figures are joined to their words in most places.
7. The progress orb is the model to copy: children ignored, label and value supplied.
8. Dynamic Type already reshapes layout at accessibility sizes in four places, and no text
   container has a fixed height except the orb.
9. Touch targets: no sub-44pt target was found, and there is no `onTapGesture` anywhere.
10. Increased Contrast has a real implementation for cards.
11. Nothing is conveyed by colour alone.
12. Hand-calculated contrast on the fixed pairs is comfortable (about 15:1 and 9:1 for the accent
    and lilac on the canvas; white at 60% stays above 6:1).

## Not determined without a render or a device

- Whether iOS truncates the brand, the sort pill and the inline titles at accessibility sizes, or
  compresses them some other way.
- Whether `safeAreaInset` clamps the finished screen's bar in landscape or lets it overflow.
- What VoiceOver actually says for units, the "·" separators and durations.
- Whether `.sensoryFeedback` is suppressed by the system Haptics switch on iOS 18, which sets A9's
  real severity.
- Real behaviour under Increase Contrast and Reduce Transparency, and whether the React Native
  container adds or blocks accessibility elements. Nothing in the repository sets a status-bar
  style.
- Whether the full-width thumbnail above each row at accessibility sizes makes the list
  unusably long.
