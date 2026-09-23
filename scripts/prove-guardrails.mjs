#!/usr/bin/env node
// Prove that the local gates actually guard, by injecting one fault at a time into a throwaway copy
// of the tree and checking that the gate aimed at it refuses it.
//
// WHY THIS EXISTS
// Three gates are covered here, because all three make claims that read as coverage:
//
//   guardrails  scripts/validate.mjs - forty-odd assertions about this repository: "Photos deletion
//               lives in one service", "no original is read through key-value coding", "the scan
//               never allows a network request";
//   mirror      scripts/sync-native-sources.mjs --check - the pod compiles the same Swift as the
//               app target, and nothing stale is committed;
//   prebuild    scripts/verify-expo-build.mjs --check-only - what `expo prebuild` will read out of
//               app.json, and that no generated ios/ directory is in the way.
//
// A claim that cannot fail is worse than no claim at all, because it reads as coverage. The loop
// already made this argument for the other checker - "Rules C and D were proved against injected
// mutations of the real tree in a temp directory, because no broken state survives in git history"
// - and this is the same proof, for the scripts that ran at the time it was written, made
// repeatable instead of remembered.
//
// It matters more than usual right now: this is the only gate that runs while the account's
// GitHub Actions minutes are spent (see AGENT_LOOP.md), so it is the only thing standing between
// a mistake and `main`.
//
// HOW IT WORKS
// Each mutation names a file, a find-and-replace that should break exactly one assertion, and a
// distinctive fragment of the message that assertion should print. For each one, in order:
//   1. copy the tree to a directory of its own under the system temporary directory;
//   2. apply the mutation;
//   3. run `node scripts/validate.mjs` there;
//   4. require that it FAILED and that the failure names the right assertion.
//
// Four outcomes are reported, and only the first is good:
//   CAUGHT     the gate failed with the expected message;
//   MISSED     the gate passed, so that assertion is vacuous;
//   WRONG      the gate failed, but not with that message, so the mutation proved something else;
//   NO MATCH   the find-and-replace did not apply, so the assertion is testing a pattern the
//              source no longer contains in that shape and this mutation proves nothing.
//
// This is not part of `npm run validate:native` and should not be: it copies the tree once per
// mutation and takes about a minute. Run it when an assertion is added, changed or doubted.
//
// WHAT IS NOT INJECTED, SO THAT "67 OF 67" IS NOT READ AS "EVERY ASSERTION"
// Three assertions in `validate.mjs` have no mutation here, and each for its own reason:
//
//   - the icon's inflated byte length. Proving it would mean re-encoding a valid PNG with one
//     wrong length, which is a different kind of work from editing a file;
//   - `!removeItem(` in the queue store, which is *unreachable* rather than unproven: the
//     temporary-file confinement check runs earlier and fails first for any file but
//     `TemporaryFileManager.swift`. The property it protects is protected; that line cannot be the
//     thing that protects it, and `AGENT_LOOP.md` records it rather than changing it;
//   - the source-wide `isNetworkAccessAllowed = true`, which is *redundant* rather than unprovable:
//     it is the same string the thumbnail assertion guards, and the string cannot go missing from
//     the tree without that earlier assertion failing first, so no mutation can isolate it.
//
// A mutation that does not apply, or that fails for a reason other than the one it names, is
// reported as such rather than counted.
//
// PLATFORM
// Node only, no Xcode, so it runs anywhere validate.mjs runs - including the Windows machine this
// repository is normally edited on.

import { spawnSync } from 'node:child_process';
import { cpSync, existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const gate = 'scripts/validate.mjs';

// Not copied: the dependency tree, the version-control database and every build product. None of
// them is read by the gate, and copying them would turn a minute into an hour.
const excludedDirectories = new Set(['node_modules', '.git', '.expo', 'build', 'ios', 'android']);
const excludedFiles = new Set(['package-lock.json']);

// One entry per assertion worth proving. `find` and `replace` are applied to `file` as a single
// literal replacement - deliberately not a regular expression, so a mutation can be read at a
// glance and cannot quietly match more than it says.
//
// `expect` is a fragment of the assertion's own message. It is checked so that a mutation that
// breaks several assertions at once cannot be mistaken for proof of the one it names.
const mutations = [
  // --- A required file that a reader is told to read ---
  {
    id: 'a required document is missing',
    file: 'docs/CLOUD_MAC_SETUP.md',
    find: null,
    expect: 'Missing docs/CLOUD_MAC_SETUP.md',
    delete: true
  },

  // --- The forbidden-pattern list, one mutation per pattern ---
  {
    id: 'a collection change request appears',
    file: 'VideoShrink/Models/PipelineModels.swift',
    find: 'import Foundation',
    replace: 'import Foundation\n// PHAssetCollectionChangeRequest',
    expect: 'Forbidden application pattern'
  },
  {
    id: 'a network session appears',
    file: 'VideoShrink/Models/PipelineModels.swift',
    find: 'import Foundation',
    replace: 'import Foundation\n// URLSession',
    expect: 'Forbidden application pattern'
  },
  {
    id: 'a web view appears',
    file: 'VideoShrink/Models/PipelineModels.swift',
    find: 'import Foundation',
    replace: 'import Foundation\n// WKWebView',
    expect: 'Forbidden application pattern'
  },
  {
    id: 'a whole video is read as Data',
    file: 'VideoShrink/Models/PipelineModels.swift',
    find: 'import Foundation',
    replace: 'import Foundation\n// Data(contentsOf:',
    expect: 'Forbidden application pattern'
  },
  {
    id: 'a force try appears',
    file: 'VideoShrink/Models/PipelineModels.swift',
    find: 'import Foundation',
    replace: 'import Foundation\n// try!',
    expect: 'Forbidden application pattern'
  },
  {
    id: 'a force cast appears',
    file: 'VideoShrink/Models/PipelineModels.swift',
    find: 'import Foundation',
    replace: 'import Foundation\n// as!',
    expect: 'Forbidden application pattern'
  },
  {
    id: 'a key-value lookup for a file size appears',
    file: 'VideoShrink/Models/PipelineModels.swift',
    find: 'import Foundation',
    replace: 'import Foundation\n// value(forKey:"fileSize")',
    expect: 'Forbidden application pattern'
  },
  {
    id: 'any key-value lookup appears',
    file: 'VideoShrink/Models/PipelineModels.swift',
    find: 'import Foundation',
    replace: 'import Foundation\n// value(forKey:',
    expect: 'Media metadata must not be read through key-value coding'
  },

  // --- Confinement: the pattern exists but in the wrong file ---
  {
    id: 'Photos deletion escapes its one service',
    file: 'VideoShrink/Models/PipelineModels.swift',
    find: 'import Foundation',
    replace: 'import Foundation\n// deleteAssets(',
    expect: 'Photos deletion must live in one service'
  },
  {
    id: 'a Photos change request escapes its one service',
    file: 'VideoShrink/Models/PipelineModels.swift',
    find: 'import Foundation',
    replace: 'import Foundation\n// PHAssetChangeRequest',
    expect: 'Photos change requests must live in one service'
  },
  {
    id: 'file removal escapes the temporary-file manager',
    file: 'VideoShrink/Models/PipelineModels.swift',
    find: 'import Foundation',
    replace: 'import Foundation\n// removeItem(at:',
    // That confinement assertion carries no message of its own, so the path it names in the
    // failure is what identifies which assertion fired; the mutation is in PipelineModels.swift.
    expect: 'VideoShrink/Models/PipelineModels.swift'
  },
  {
    id: 'the idle timer escapes its one service',
    file: 'VideoShrink/Models/PipelineModels.swift',
    find: 'import Foundation',
    replace: 'import Foundation\n// isIdleTimerDisabled',
    expect: 'The idle timer may only be touched in one place'
  },

  // --- The scan's own promises ---
  {
    id: 'the documented size property is no longer used',
    file: 'VideoShrink/Services/PhotoLibraryScanService.swift',
    find: 'NSSelectorFromString("dataSize")',
    replace: 'NSSelectorFromString("somethingElse")',
    expect: 'Reported original sizes must come from the documented Photos dataSize property'
  },
  {
    id: 'the scan asks PhotoKit for network access',
    file: 'VideoShrink/Services/PhotoLibraryScanService.swift',
    find: 'isNetworkAccessAllowed = false',
    replace: 'isNetworkAccessAllowed = true',
    expect: 'The library scan must ask PhotoKit for on-device originals only'
  },

  // --- The deletion gate ---
  {
    id: 'deletion no longer depends on a read-back',
    file: 'VideoShrink/Models/DeletionPolicy.swift',
    find: 'readBack: CopyReadBack?',
    replace: 'readBack: Int?',
    expect: 'Deleting an original must depend on a confirmed read-back'
  },
  {
    id: 'deletion no longer depends on a smaller copy',
    file: 'VideoShrink/Models/DeletionPolicy.swift',
    find: 'saving.isSmaller',
    replace: 'true',
    expect: 'Deleting an original must depend on a smaller saved copy'
  },
  {
    id: 'deleting originals is on by default',
    file: 'VideoShrink/Models/ShrinkSettings.swift',
    find: '?? .off',
    replace: '?? .automatic',
    expect: 'Deleting originals must be off until the user turns it on'
  },
  {
    id: 'the interface stops saying where deleted originals go',
    directory: 'VideoShrink',
    find: 'Recently Deleted',
    replace: 'the bin',
    expect: 'The interface and the policy must say what Photos does with deleted items'
  },
  {
    id: 'a stored queue stops being reconciled',
    directory: 'VideoShrink',
    find: 'BatchQueueReconciliation',
    replace: 'BatchQueueReading',
    expect: 'A stored queue must be reconciled before it is used again'
  },
  {
    id: 'a mid-save copy stops being flagged',
    directory: 'VideoShrink',
    find: 'case needsCheck',
    replace: 'case notNeeded',
    expect: 'A copy that may already have been saved must be flagged, not repeated'
  },
  {
    id: 'deletions stop being batched into one transaction',
    file: 'VideoShrink/Services/PhotoLibraryService.swift',
    find: 'func deleteOriginals(identifiers:',
    replace: 'func deleteOneOriginal(identifiers:',
    expect: 'Deleting originals must batch into one Photos transaction'
  },
  {
    id: 'reading a copy back starts fetching it',
    file: 'VideoShrink/Services/PhotoLibraryService.swift',
    find: 'requestPlayerItem',
    replace: 'requestPlayerThing',
    expect: 'A preview must ask PhotoKit for a player item'
  },

  // --- Verification's stated coverage ---
  {
    id: 'verification stops sampling more than one window',
    file: 'VideoShrink/Services/VideoVerificationService.swift',
    find: 'for fraction in [0.1, 0.5, 0.9]',
    replace: 'for fraction in [0.5]',
    expect: 'Verification must decode frames from more than one point in the file'
  },
  {
    id: 'verification stops checking for audio',
    file: 'VideoShrink/Services/VideoVerificationService.swift',
    find: 'confirmAudioIsPresent',
    replace: 'confirmAudioIsNotChecked',
    expect: 'A copy of a video with sound must be checked for sound'
  },

  // --- The transcoder's promises ---
  {
    id: 'the 4K preset is no longer the documented one',
    file: 'VideoShrink/Models/VideoQuality.swift',
    find: 'AVAssetExportPresetHEVC3840x2160',
    replace: 'AVAssetExportPresetHighestQuality',
    expect: 'The 4K HEVC preset must be the documented one'
  },
  {
    id: '720p stops using a documented preset',
    file: 'VideoShrink/Models/VideoQuality.swift',
    find: 'AVAssetExportPreset1280x720',
    replace: 'AVAssetExportPresetMediumQuality',
    expect: "720p must use Apple's documented preset"
  },
  {
    id: 'a copy may be larger than its original',
    file: 'VideoShrink/Models/PipelineModels.swift',
    find: 'output.longEdge <= source.longEdge + 2',
    replace: 'output.longEdge >= 0',
    expect: 'A copy must never be larger than its original'
  },
  {
    id: 'a video composition is no longer requested explicitly',
    directory: 'VideoShrink',
    find: 'needsComposition',
    replace: 'needsNothing',
    expect: 'A video composition must be requested explicitly'
  },
  {
    id: 'composed exports stop keeping HDR display metadata',
    file: 'VideoShrink/Services/VideoTranscodingService.swift',
    find: 'perFrameHDRDisplayMetadataPolicy',
    replace: 'someOtherPolicy',
    expect: 'Composed exports must keep HDR display metadata'
  },

  // --- The batch's own limits ---
  {
    id: 'a batch stops checking the device temperature',
    file: 'VideoShrink/Presentation/BatchViewModel.swift',
    find: 'DeviceConditions.pacing()',
    replace: 'DeviceConditions.always()',
    expect: 'A batch must stop before it overheats the device'
  },

  // --- Settings that must default a particular way ---
  {
    id: 'keeping the screen awake is on by default',
    file: 'VideoShrink/Models/ShrinkSettings.swift',
    find: 'defaults.bool(forKey: screenAwakeKey)',
    replace: 'true',
    expect: 'Keeping the screen awake must default to off'
  },

  // --- Declarations the manifest and the project must keep ---
  {
    id: 'background modes appear in the Info.plist',
    file: 'VideoShrink/Resources/Info.plist',
    find: '</dict>',
    replace: '\t<key>UIBackgroundModes</key>\n\t<array/>\n</dict>',
    expect: 'UIBackgroundModes'
  },
  {
    id: 'the Photos add permission string is gone',
    file: 'VideoShrink/Resources/Info.plist',
    find: 'NSPhotoLibraryAddUsageDescription',
    replace: 'NSPhotoLibraryWriteUsageDescription',
    expect: 'NSPhotoLibraryAddUsageDescription'
  },
  {
    id: 'the privacy manifest loses its disk-space reason',
    file: 'VideoShrink/Resources/PrivacyInfo.xcprivacy',
    find: 'E174.1',
    replace: 'E999.9',
    expect: 'E174.1'
  },
  {
    id: 'the project gains a Swift package dependency',
    file: 'project.yml',
    find: 'targets:',
    replace: 'packages: {}\ntargets:',
    expect: 'packages:'
  },
  {
    id: 'the project pins a development team',
    file: 'project.yml',
    find: 'CODE_SIGN_STYLE: Automatic',
    replace: 'CODE_SIGN_STYLE: Automatic\n    DEVELOPMENT_TEAM: ABCDE12345',
    expect: 'DEVELOPMENT_TEAM:'
  },
  {
    id: 'the product version drifts between the two surfaces',
    file: 'app.json',
    find: '"version": "0.1.0"',
    replace: '"version": "0.2.0"',
    expect: 'are the same fact and must agree'
  },

  // --- The suite, and the icon ---
  {
    id: 'the XCTest suite shrinks below its floor',
    directory: 'VideoShrinkTests',
    find: 'func test',
    replace: 'func xtest',
    expect: 'testCount >= 20'
  },
  {
    id: 'an app JSON file stops parsing',
    file: 'app.json',
    find: '"slug": "videoshrink"',
    replace: '"slug": ',
    expect: 'SyntaxError'
  },
  {
    id: 'the app icon stops being opaque',
    file: 'VideoShrink/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png',
    find: null,
    replace: null,
    expect: 'Icon must use opaque RGB',
    patchByte: { offset: 25, value: 6 }
  },

  // --- The remaining claims that carry weight rather than wording ---
  {
    id: 'a copy stops being created through the documented request',
    directory: 'VideoShrink',
    find: 'PHAssetCreationRequest.forAsset()',
    replace: 'PHAssetCreationRequest()',
    expect: 'PHAssetCreationRequest.forAsset()'
  },
  {
    id: 'saving a copy starts moving the file instead of copying it',
    directory: 'VideoShrink',
    find: 'options.shouldMoveFile = false',
    replace: 'options.shouldMoveFile = true',
    expect: 'shouldMoveFile = false'
  },
  {
    id: '1080p stops using the documented HEVC preset',
    directory: 'VideoShrink',
    find: 'AVAssetExportPresetHEVC1920x1080',
    replace: 'AVAssetExportPreset1920x1080',
    expect: 'AVAssetExportPresetHEVC1920x1080'
  },
  {
    id: 'a service other than thumbnails starts using the network',
    file: 'VideoShrink/Services/ThumbnailService.swift',
    find: 'isNetworkAccessAllowed = true',
    replace: 'isNetworkAccessAllowed = false',
    expect: 'Only thumbnails may let Photos use the network'
  },
  {
    id: 'the thumbnail service stops recording that it fetches no originals',
    file: 'VideoShrink/Services/ThumbnailService.swift',
    find: 'Originals are never downloaded here',
    replace: 'Originals may be downloaded',
    expect: 'The thumbnail service must record that it never fetches originals'
  },
  {
    id: 'the stored queue leaves the app support directory',
    file: 'VideoShrink/Services/BatchQueueStore.swift',
    find: 'applicationSupportDirectory',
    replace: 'documentDirectory',
    expect: 'Application Support directory'
  },
  {
    id: 'the stored queue stops being excluded from backup',
    file: 'VideoShrink/Services/BatchQueueStore.swift',
    find: 'isExcludedFromBackup = true',
    replace: 'isExcludedFromBackup = false',
    expect: 'The stored queue must be excluded from backup'
  },
  {
    id: 'the stored queue loses its file protection',
    file: 'VideoShrink/Services/BatchQueueStore.swift',
    find: 'completeFileProtectionUntilFirstUserAuthentication',
    replace: 'noFileProtection',
    expect: 'The stored queue must use file protection'
  },
  {
    id: 'a saved copy stops being read back from Photos',
    directory: 'VideoShrink',
    find: 'localFileURL(identifier:',
    replace: 'localURL(identifier:',
    expect: 'A saved copy must be read back from Photos'
  },
  {
    id: 'device conditions stop being sampled',
    directory: 'VideoShrink',
    find: 'states(updateInterval: 0.25)',
    replace: 'states(updateInterval: 1)',
    expect: 'states(updateInterval: 0.25)'
  },
  {
    id: 'verification stops looking at decoded frames',
    directory: 'VideoShrink',
    find: 'CMSampleBufferGetImageBuffer(sample)',
    replace: 'CMSampleBufferGetImageBuffer(other)',
    expect: 'CMSampleBufferGetImageBuffer(sample)'
  },
  {
    id: 'the Photos read permission string is gone',
    file: 'VideoShrink/Resources/Info.plist',
    find: 'NSPhotoLibraryUsageDescription',
    replace: 'NSPhotoLibraryReadUsageDescription',
    expect: 'NSPhotoLibraryUsageDescription'
  },
  {
    id: 'the app icon stops being 1024 pixels wide',
    file: 'VideoShrink/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png',
    find: null,
    replace: null,
    expect: '1024',
    patchByte: { offset: 19, value: 1 }
  },

  // --- The mirror that keeps the pod compiling the same Swift as the app target ---
  {
    id: 'the app source is edited without regenerating the pod mirror',
    file: 'VideoShrink/Models/DeletionPolicy.swift',
    find: 'import Foundation',
    replace: 'import Foundation\n// edited after the mirror was written',
    gate: 'mirror',
    expect: 'Native source copy is missing or stale'
  },
  {
    id: 'the pod mirror is edited behind the app source\'s back',
    file: 'modules/videoshrink-native/ios/VideoShrinkCore/Models/DeletionPolicy.swift',
    find: 'import Foundation',
    replace: 'import Foundation\n// edited after it was mirrored',
    gate: 'mirror',
    expect: 'Native source copy is missing or stale'
  },
  {
    id: 'the mirror\'s manifest stops matching what it copied',
    file: 'modules/videoshrink-native/ios/VideoShrinkCore/source-manifest.json',
    find: '"Models/DeletionPolicy.swift": "',
    replace: '"Models/DeletionPolicy.swift": "0',
    gate: 'mirror',
    expect: 'Native source manifest changed'
  },

  // --- The Expo build's own preflight, which reads app.json the way `expo prebuild` will ---
  {
    id: 'app.json stops naming the app',
    file: 'app.json',
    find: '    "name": "BatchShrink",\n',
    replace: '',
    gate: 'prebuild',
    expect: 'does not set "expo.name"'
  },
  {
    id: 'app.json stops carrying a bundle identifier',
    file: 'app.json',
    find: '      "bundleIdentifier": "com.wilfr.videoshrink",\n',
    replace: '',
    gate: 'prebuild',
    expect: 'does not set "expo.ios.bundleIdentifier"'
  },
  {
    id: 'app.json is not valid JSON for the prebuild to read',
    file: 'app.json',
    find: '    "slug": "videoshrink",',
    replace: '    "slug": ',
    gate: 'prebuild',
    expect: 'app.json is not valid JSON'
  },
  {
    id: 'a generated ios directory is left where the build expects a clean tree',
    addFile: { path: 'ios/.keep', content: '' },
    gate: 'prebuild',
    expect: 'already exists'
  },

  // --- The version facts, one assertion each ---
  {
    id: 'the product version stops being a semantic version',
    file: 'app.json',
    find: '"version": "0.1.0"',
    replace: '"version": "0.1"',
    expect: 'must be a semantic version'
  },
  {
    id: 'the shipping build number stops being declared',
    file: 'app.json',
    find: '    "buildNumber": "11",\n',
    replace: '',
    expect: 'must declare expo.ios.buildNumber'
  },
  {
    id: 'the shipping build number stops being digits',
    file: 'app.json',
    find: '"buildNumber": "11"',
    replace: '"buildNumber": "11a"',
    expect: 'buildNumber must be digits'
  },
  {
    id: 'a target-level override hides the harness version from the check',
    file: 'project.yml',
    find: '    MARKETING_VERSION: "0.1.0"\n',
    replace: '    MARKETING_VERSION: "0.1.0"\n    MARKETING_VERSION: "0.1.0"\n',
    expect: 'must declare MARKETING_VERSION exactly once'
  },
  {
    id: 'the harness build number stops being digits',
    file: 'project.yml',
    find: 'CURRENT_PROJECT_VERSION: "1"',
    replace: 'CURRENT_PROJECT_VERSION: "one"',
    expect: 'CURRENT_PROJECT_VERSION must be digits'
  },
  {
    id: 'the app icon stops being 1024 pixels tall',
    file: 'VideoShrink/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png',
    find: null,
    replace: null,
    expect: '1024',
    patchByte: { offset: 23, value: 1 }
  },

  // --- The Swift call-site checker. Rules C and D were proved against injected faults in an
  // earlier round and are not repeated here; these two prove Rule A on the shape that used to be
  // invisible, and Rule E, which is new.
  {
    id: 'an enum case with an associated value is called with its labels out of order',
    file: 'VideoShrinkTests/RulesTests.swift',
    find: 'import XCTest',
    replace: 'import XCTest\nprivate let ruleAProbe = BatchQueueRecord.State.saved(copyBytes: 2, originalBytes: 1)',
    gate: 'callsites',
    // The call has to be *qualified* - `BatchQueueRecord.State.saved(...)` rather than
    // `.saved(...)` - because this scan deliberately leaves a leading-dot member call alone, since
    // resolving one needs type inference it does not have. That is why the fault is written as a
    // qualified call rather than by perturbing an existing one: the two calls to this case in the
    // tree are both written with a leading dot.
    //
    // `saved` is declared only as a case with associated values, and until round 22 this scan
    // collected none of those, so before the fix this call resolved to nothing at all and the
    // fault was silent. That is what makes this a proof of the case-collection fix and not only of
    // Rule A.
    expect: 'must precede'
  },
  {
    id: 'a leading-dot constructor is called with its labels out of order',
    file: 'VideoShrink/Models/LibraryModels.swift',
    find: '.planning(resolution: resolution, frameRate: frameRate)',
    replace: '.planning(frameRate: frameRate, resolution: resolution)',
    gate: 'callsites',
    // This is the mutation that was MISSED first: a leading-dot member call used to be dropped by
    // the collector entirely, so the fault was invisible even though `planning` was declared as a
    // case. Round 22 collects that shape, and this is the proof of it - a call this codebase writes
    // far more often than any other.
    expect: 'must precede'
  },
  {
    id: 'a static member that no declaration supplies is referenced',
    file: 'VideoShrink/Presentation/BatchScreens.swift',
    find: 'import SwiftUI',
    replace: 'import SwiftUI\nprivate let ruleEProbe: String = BatchSelectionScreen.unaccountedHeading2',
    gate: 'callsites',
    expect: 'names a member that is declared nowhere in the scanned tree'
  }
];

function copyTree(destination) {
  cpSync(root, destination, {
    recursive: true,
    filter: source => {
      const name = source.slice(root.length).replace(/^[\\/]+/, '').split(/[\\/]/)[0];
      if (excludedDirectories.has(name)) return false;
      if (excludedFiles.has(source.slice(root.length + 1))) return false;
      return true;
    }
  });
  // The pod's mirror is generated and git-ignored, so a clean checkout does not have one and a
  // developer's tree may have a stale one. Every copy gets a fresh one, which is what `npm ci`'s
  // postinstall does for CI, so this harness gives the same answer on any machine.
  const sync = spawnSync(process.execPath, ['scripts/sync-native-sources.mjs'], {
    cwd: destination,
    encoding: 'utf8',
    env: process.env
  });
  if (sync.status !== 0) {
    throw new Error(`could not generate the pod mirror in ${destination}: ${sync.stderr}`);
  }
}

function applyMutation(directory, mutation) {
  // Creating something where there was nothing is the one mutation with no file to start from.
  if (mutation.addFile) {
    const target = resolve(directory, mutation.addFile.path);
    mkdirSync(dirname(target), { recursive: true });
    writeFileSync(target, mutation.addFile.content ?? '');
    return null;
  }

  // A mutation either names one file or a directory whose every Swift file it applies to. The
  // directory form exists for the assertions that are about the app as a whole - a phrase that
  // must appear somewhere in it, or a condition that must hold everywhere - because removing the
  // phrase from one file of ten would prove nothing.
  if (mutation.directory) {
    const files = swiftFilesUnder(resolve(directory, mutation.directory));
    if (files.length === 0) return `${mutation.directory} holds no Swift files`;
    let applied = 0;
    for (const file of files) {
      const text = readFileSync(file, 'utf8');
      if (!text.includes(mutation.find)) continue;
      writeFileSync(file, text.replaceAll(mutation.find, mutation.replace));
      applied += 1;
    }
    return applied === 0
      ? `the pattern ${JSON.stringify(mutation.find)} is not in any file under ${mutation.directory}`
      : null;
  }

  const path = resolve(directory, mutation.file);
  if (!existsSync(path)) {
    return 'the file does not exist in a clean checkout';
  }
  if (mutation.patchByte) {
    const bytes = readFileSync(path);
    const { offset, value } = mutation.patchByte;
    if (offset >= bytes.length) return 'the file is shorter than the byte this mutation patches';
    bytes[offset] = value;
    writeFileSync(path, bytes);
    return null;
  }
  if (mutation.delete) {
    rmSync(path, { force: true });
    return null;
  }

  const text = readFileSync(path, 'utf8');
  if (!text.includes(mutation.find)) {
    return `the pattern ${JSON.stringify(mutation.find)} is not in ${mutation.file}`;
  }
  writeFileSync(path, text.replaceAll(mutation.find, mutation.replace));
  return null;
}

function swiftFilesUnder(target) {
  const found = [];
  const walk = path => {
    for (const entry of readdirSync(path, { withFileTypes: true })) {
      const full = join(path, entry.name);
      if (entry.isDirectory()) walk(full);
      else if (entry.name.endsWith('.swift')) found.push(full);
    }
  };
  walk(target);
  return found;
}

// Some claims live in a different local gate. `guardrails` is scripts/validate.mjs - forty-odd
// assertions about the repository; `mirror` is the check that keeps the pod compiling the same
// Swift as the app target; `prebuild` is the Expo build's own preflight, which reads app.json the
// way `expo prebuild` will. A mutation names the gate it is aimed at, and each gate is proved to
// pass on an untouched copy before any mutation is believed.
const gates = {
  guardrails: { args: ['scripts/validate.mjs'] },
  mirror: { args: ['scripts/sync-native-sources.mjs', '--check'] },
  prebuild: { args: ['scripts/verify-expo-build.mjs', '--check-only'] },
  callsites: { args: ['scripts/swift-call-site-check.mjs'] }
};

function runGate(directory, name) {
  const result = spawnSync(process.execPath, gates[name].args, {
    cwd: directory,
    encoding: 'utf8',
    env: process.env
  });
  return { status: result.status ?? -1, output: `${result.stdout ?? ''}${result.stderr ?? ''}` };
}

const results = [];
let scratchRoot = null;

try {
  scratchRoot = mkdtempSync(join(tmpdir(), 'videoshrink-guardrails-'));
  console.log(`[prove-guardrails] One copy of the tree per mutation, under ${scratchRoot}\n`);

  // Every gate must pass on an untouched copy first, or the mutations aimed at it prove nothing: a
  // gate that failed on everything would report fifty CAUGHTs and mean nothing at all.
  const unusable = [];
  for (const name of Object.keys(gates)) {
    const baseline = join(scratchRoot, `baseline-${name}`);
    copyTree(baseline);
    const baselineRun = runGate(baseline, name);
    rmSync(baseline, { recursive: true, force: true });
    if (baselineRun.status !== 0) {
      unusable.push(name);
      console.error(`[prove-guardrails] The ${name} gate fails on an untouched copy of this tree,`);
      console.error('[prove-guardrails] so no mutation aimed at it could mean anything. It said:\n');
      console.error(baselineRun.output);
    } else {
      console.log(`[prove-guardrails] Baseline: ${name} passes on an untouched copy.`);
    }
  }
  if (unusable.length > 0) {
    process.exitCode = 1;
  } else {
    console.log('');

    for (const [index, mutation] of mutations.entries()) {
      const directory = join(scratchRoot, `m${String(index).padStart(3, '0')}`);
      copyTree(directory);
      const applyFailure = applyMutation(directory, mutation);
      if (applyFailure) {
        results.push({ mutation, outcome: 'NO MATCH', detail: applyFailure });
        console.log(`NO MATCH   ${mutation.id}: ${applyFailure}`);
        continue;
      }

      const run = runGate(directory, mutation.gate ?? 'guardrails');
      if (run.status === 0) {
        results.push({ mutation, outcome: 'MISSED', detail: 'the gate passed' });
        console.log(`MISSED     ${mutation.id}: the gate passed, so that assertion is vacuous`);
      } else if (!run.output.includes(mutation.expect)) {
        const firstFailure = (run.output.match(/^(?:AssertionError.*|FAIL.*)$/m) ?? [run.output.split('\n')[0]])[0];
        results.push({ mutation, outcome: 'WRONG', detail: firstFailure.slice(0, 200) });
        console.log(`WRONG      ${mutation.id}: failed, but not with "${mutation.expect}"`);
        console.log(`           it said: ${firstFailure.slice(0, 200)}`);
      } else {
        results.push({ mutation, outcome: 'CAUGHT', detail: '' });
        console.log(`CAUGHT     ${mutation.id}`);
      }
      rmSync(directory, { recursive: true, force: true });
    }
  }
} finally {
  if (scratchRoot) rmSync(scratchRoot, { recursive: true, force: true });
}

if (results.length > 0) {
  const count = outcome => results.filter(result => result.outcome === outcome).length;
  console.log('');
  console.log(
    `[prove-guardrails] ${count('CAUGHT')} caught, ${count('MISSED')} missed, ` +
      `${count('WRONG')} wrong reason, ${count('NO MATCH')} not applicable, of ${results.length} mutations.`
  );
  if (count('CAUGHT') !== results.length) {
    console.log(
      '[prove-guardrails] Only CAUGHT is proof. A MISSED assertion guards nothing; a WRONG one is '
        + 'about a different assertion than it names; a NO MATCH means the pattern it looks for has '
        + 'moved and the mutation needs rewriting before it proves anything.'
    );
    process.exitCode = 1;
  }
}
