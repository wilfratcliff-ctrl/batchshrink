# BatchShrink interface — 21 September 2026

## Visual direction

A dark, quiet canvas with luminous mint actions and lilac comparison accents. Inspired by the supplied Cleanup screenshots: clear hierarchy, generous spacing, media-led selection, reachable bottom actions. Original layered video artwork and a compact inward-arrow brand mark give BatchShrink its own identity.

Native San Francisco typography uses system text styles for Dynamic Type. Large headings have restrained negative tracking; storage values use monospaced digits. Cards have continuous corners and subtle borders. Primary buttons have a 58-point minimum height, explicit disabled states, and a small press response that respects Reduce Motion. No new fonts, image downloads, or dependencies.

## Flow

- First launch: three manually advanced introduction pages, with progress segments, Back and Skip. The final button opens the home screen. Photos access is requested only when the user scans or chooses a video. Completion is stored under `batchShrink.onboarding.v1`. An existing active or recovered run takes precedence over onboarding.
- Home: branded toolbar, concise headline, custom artwork, library explanation, original-handling preference, and Find my videos. Just one video opens the existing preview-before-save flow.
- Scan: existing live counts and cancellation, using the shared dark styling.
- Library summary: potential reduction is the hero value, explicitly estimated. Lilac original-size and mint copy-size bars explain the difference. Estimate methodology is expandable. The screen distinguishes smaller files from reclaimed storage.
- Selection: lazy two-column thumbnail gallery, largest first; switches to one column at accessibility text sizes. Tap a picture to preview. Tap the information area to select, with a visible check and border. Dates, sizes, duration badges, prior-compression markers and estimated reduction remain available. Sorting, selection shortcuts and quality remain accessible.
- Quality: full-height sheet with strong selected states. Resolution and frame rate use separate animation namespaces. Choices stack vertically at accessibility text sizes. Estimates respect Reduce Motion.
- Processing: circular per-operation progress when known; indeterminate native activity otherwise. Existing time estimates, completed counts, pause and finish behavior remain. The ring is not a fabricated whole-batch percentage.
- Results: measured reduction, proportionate original/copy bars, confirmation state, original-handling outcomes and recovery actions.
- Settings: unified dark appearance and an option to replay the introduction without changing onboarding persistence.

## Implementation

`ShrinkStyle.swift` owns tokens and shared controls. `ShrinkOnboarding.swift` owns onboarding and vector artwork. `ContentView.swift` gates the introduction and applies the dark appearance. The existing batch and single-video views retain their view-model actions. Display branding is BatchShrink; project, module and bundle identifiers remain compatible with the existing native integration.

The Expo host and fallback use the same dark background. Photos permission descriptions cover both manual saving and batch saving. Original deletion remains opt-in and retains its confirmation and verification policy.

## Validation for this pass

No build was requested or performed for this pass. Portable repository guardrails and TypeScript checking pass. Native source copies are synchronized and checked against their manifest. These checks do not compile Swift or execute XCTest. Historical: the redesign was later compiled into the production build 10 recorded in [RELEASE_10.md](RELEASE_10.md); that is compilation evidence, not a rendered-layout or accessibility result.

When the user requests a build, review on iPhone:

- First launch, Back, Skip, completed onboarding, relaunch and introduction replay.
- Recovery of a persisted batch without onboarding interrupting it.
- Small portrait and landscape screens, larger text, VoiceOver and Reduce Motion.
- Largest/newest sorting, selection border, thumbnails, rotation and preview playback.
- Quality changes, estimated sizes, selection shortcuts and disabled start action.
- Processing, pause/resume, failed/skipped results, read-back and deletion confirmation.
- Empty/limited/denied Photos access and cloud-backed thumbnails.
