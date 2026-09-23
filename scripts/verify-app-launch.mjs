#!/usr/bin/env node
// Launch the app on a simulator and demand to see its first screen. Run on macOS.
//
// WHY THIS EXISTS
// Every status statement in this repository says the same thing: the app has never run, no
// screen has ever been rendered, no video has been exported. That is true, and it is the
// largest gap in the project. It is not, however, unobservable.
//
// The shipping product is the Expo app, and launching that in CI would need Metro running or a
// Release build with an embedded JavaScript bundle. The *standalone* harness described by
// project.yml is a different matter: it is pure SwiftUI, it carries no React Native at all, and
// it renders the same `ContentView` and the same screens through the same view models, because
// modules/videoshrink-native/ios/VideoShrinkCore/ is generated from
// VideoShrink/{Models,Services,Presentation}. So a macOS runner can build it, install it on a
// simulator, launch it and ask it what is on screen -- for no EAS build minutes and no device.
//
// WHAT IT PROVES, EXACTLY
// A pass means: the app installed, launched, drew its introduction, and then answered a tap on
// that screen by drawing the batch screen with its first control present. That is a real
// observation of a rendered screen and of one working navigation, and it is worth having. It is
// NOT a device result. The simulator has no Photos library, no iCloud, no HEVC encoder worth
// trusting and no permission prompts that behave like the real thing, so retrieval, export,
// verification, saving, deletion and recovery are all still unexercised. It also proves nothing
// about the *Expo* app's own two bridge files; the build-expo-app job compiles those.
// docs/PHYSICAL_DEVICE_TEST_PLAN.md remains the gate for everything else.
//
// HOW IT TELLS "IT RENDERED" FROM "IT CRASHED"
// It does not guess from pixels. VideoShrinkUITests/LaunchSmokeUITests.swift asks the interface
// directly: it waits for the introduction's own controls to exist, taps Skip, and then waits for
// the batch screen's first control. A crash, a blank view, a screen that never appears and a tap
// that does nothing are all failures of those waits, and XCTest reports which one failed and
// attaches the screen at that moment to the result bundle. That is a stronger and much less
// brittle instrument than comparing screenshots.
//
// WHY IT IS A SEPARATE SCHEME
// `project.yml` puts VideoShrinkUITests in a scheme of its own rather than adding it to the
// VideoShrink scheme's test action. Job 1 builds and runs the unit tests through that scheme on
// every push and is green; UI tests are slower and would make that job's meaning muddier. Two
// schemes, two questions, and neither can hide the other's failure.
//
// PLATFORM
// This needs macOS, Xcode and a simulator runtime. On any other platform it prints a clear skip
// line and exits 0 -- unless CI is set, where a non-macOS runner means the job was pointed at the
// wrong image, which is a misconfiguration worth failing for rather than a silent green.
//
// `--check-only` runs only what needs no Xcode: the native-source mirror check. That is the path
// that can be exercised on the Windows machine this repository is normally edited on.

import { spawnSync } from 'node:child_process';
import { existsSync } from 'node:fs';
import { delimiter, dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const BANNER = '===== VIDEOSHRINK APP LAUNCH =====';
const derivedDataPath = 'build/LaunchDerivedData';
const homebrewPaths = ['/opt/homebrew/bin', '/usr/local/bin'];

// Failures are thrown rather than exited on, and the process is ended by draining the event
// loop: process.exit() can truncate output still buffered on a pipe, and a CI log is a pipe.
class LaunchFailure extends Error {
  constructor(message, exitCode) {
    super(message);
    // Always a real non-zero code. A LaunchFailure that reached Node with an undefined exitCode
    // would end the process with status 0, which reads as a pass.
    this.exitCode = typeof exitCode === 'number' && exitCode !== 0 ? exitCode : 1;
  }
}

function banner(line) {
  console.log(`\n${line}\n`);
}

function fail(message, exitCode = 1) {
  throw new LaunchFailure(message, exitCode);
}

// Child processes must see Homebrew's bin directory; its prefix differs between Intel
// (/usr/local) and Apple Silicon (/opt/homebrew) runners.
const inheritedPath = process.env.PATH ?? process.env.Path ?? '';
process.env.PATH = inheritedPath
  ? `${homebrewPaths.join(delimiter)}${delimiter}${inheritedPath}`
  : homebrewPaths.join(delimiter);

// Run a child process with its output streamed into the log. A non-zero status is returned,
// never swallowed, so the caller can print the tool's own words and fail the run.
function run(command, args, step, cwd = root) {
  console.log(`[verify-app-launch] $ ${[command, ...args].join(' ')}`);
  const result = spawnSync(command, args, { cwd, env: process.env, stdio: 'inherit' });
  if (result.error) {
    fail(`${step} could not start: ${result.error.message}`);
  }
  return result.status ?? 1;
}

// Same child-process rules, but with the output captured instead of streamed, for the command
// whose output has to be read.
function runCaptured(command, args, step, cwd = root) {
  const result = spawnSync(command, args, {
    cwd,
    env: process.env,
    encoding: 'utf8',
    maxBuffer: 32 * 1024 * 1024
  });
  if (result.error) {
    fail(`${step} could not run: ${result.error.message}`);
  }
  if (result.stderr && result.stderr.trim()) {
    // Kept because simctl writes warnings here and one that explains a later failure is worth
    // having in the log.
    process.stderr.write(result.stderr);
  }
  if (result.status !== 0) {
    fail(`${step} exited with status ${result.status}. Its output is above.`, result.status);
  }
  return result.stdout ?? '';
}

function findOnPath(name) {
  const probe = spawnSync('/bin/bash', ['-c', `command -v ${name}`], {
    cwd: root,
    env: process.env,
    encoding: 'utf8'
  });
  if (probe.error) {
    fail(`could not look for ${name} on PATH: ${probe.error.message}. This step needs a macOS shell.`);
  }
  const found = (probe.stdout ?? '').trim();
  return probe.status === 0 && found ? found : null;
}

function findBrew() {
  const onPath = findOnPath('brew');
  if (onPath) {
    return onPath;
  }
  return homebrewPaths.map(prefix => `${prefix}/brew`).find(candidate => existsSync(candidate)) ?? null;
}

// The same assertion the other two scripts make, and the same one EAS makes from
// `eas-build-post-install`. This job builds the standalone project rather than the pod, so the
// mirror is not what it compiles -- but a stale mirror is a source-control mistake, and catching
// it in every job rather than in two of three is what keeps it from being committed.
function checkNativeSourceMirror() {
  const status = run(
    process.execPath,
    ['scripts/sync-native-sources.mjs', '--check'],
    'the native-source mirror check'
  );
  if (status !== 0) {
    fail(
      'the mirrored Swift under modules/videoshrink-native/ios/VideoShrinkCore/ is missing or stale. ' +
        'Run `npm run sync:native` and commit the sources that changed.',
      status
    );
  }
  console.log(
    '[verify-app-launch] The native-source mirror matches VideoShrink/{Models,Services,Presentation}.'
  );
}

// XcodeGen turns project.yml into VideoShrink.xcodeproj. It is not part of Xcode, and the runner
// images do not all carry it, so it is installed on demand -- the same arrangement
// scripts/verify-native-tests.mjs uses.
function ensureXcodeGen() {
  if (findOnPath('xcodegen')) {
    return;
  }
  console.log('[verify-app-launch] xcodegen is not installed; installing it with Homebrew.');
  const brew = findBrew();
  if (!brew) {
    fail(
      'xcodegen is missing and Homebrew was not found on PATH or at /opt/homebrew/bin/brew or ' +
        '/usr/local/bin/brew, so xcodegen cannot be installed.'
    );
  }
  const installStatus = run(brew, ['install', 'xcodegen'], 'brew install xcodegen');
  if (installStatus !== 0) {
    fail("'brew install xcodegen' failed. The output is above.", installStatus);
  }
  if (!findOnPath('xcodegen')) {
    fail("xcodegen is still not on PATH after 'brew install xcodegen'.");
  }
}

function generateProject() {
  const status = run('xcodegen', ['generate'], 'xcodegen generate');
  if (status !== 0) {
    fail('xcodegen generate failed. The output is above.', status);
  }
  if (!existsSync(resolve(root, 'VideoShrink.xcodeproj'))) {
    fail('xcodegen reported success but generated no VideoShrink.xcodeproj.');
  }
}

// iOS runtime identifiers look like `com.apple.CoreSimulator.SimRuntime.iOS-18-4`. Only the
// newest runtime is wanted, and only for an iPhone, because this app is iPhone-only
// (TARGETED_DEVICE_FAMILY is 1 and the store listing claims no iPad interface).
function parseIosVersion(text) {
  const labelled = /iOS[-\s](\d+)(?:[.-](\d+))?/.exec(text ?? '');
  if (labelled) {
    return { major: Number(labelled[1]), minor: Number(labelled[2] ?? 0) };
  }
  return null;
}

function formatIosVersion(version) {
  return version ? `${version.major}.${version.minor}` : 'unknown iOS';
}

// One bootable iPhone on the newest runtime. The device name is deliberately not hardcoded:
// runner images change their simulator sets between releases, and a name that rots would fail
// this job for a reason that has nothing to do with the app.
function discoverSimulator() {
  const stdout = runCaptured(
    'xcrun',
    ['simctl', 'list', 'devices', 'available', '--json'],
    'xcrun simctl list devices available'
  );

  let parsed;
  try {
    parsed = JSON.parse(stdout);
  } catch (error) {
    fail(`could not parse the simulator list from xcrun simctl: ${error.message}`);
  }

  const devicesByRuntime =
    parsed && typeof parsed.devices === 'object' && parsed.devices !== null ? parsed.devices : {};
  const candidates = [];
  for (const [runtimeIdentifier, devices] of Object.entries(devicesByRuntime)) {
    const version = parseIosVersion(runtimeIdentifier);
    if (!version || !Array.isArray(devices)) {
      continue;
    }
    for (const device of devices) {
      const name = device?.name ?? '';
      const deviceType = device?.deviceTypeIdentifier ?? '';
      const udid = device?.udid;
      if (typeof udid !== 'string' || !udid) {
        continue;
      }
      // `available` is already in the query, but the error field is checked too: a runtime can
      // be listed while its devices are not usable on this runner.
      if (device?.isAvailable === false || device?.availabilityError) {
        continue;
      }
      if (!deviceType.includes('iPhone') && !name.startsWith('iPhone')) {
        continue;
      }
      candidates.push({ udid, name: name || 'iPhone simulator', version });
    }
  }

  if (candidates.length === 0) {
    fail(
      'no available iPhone simulator was found. This job needs one to launch the app on: that is an ' +
        'environment fact about the runner image, not a defect in the app, and there is nothing to ' +
        'check without it. The runner images this workflow names all carry iOS simulator runtimes.'
    );
  }

  candidates.sort(
    (a, b) =>
      b.version.major - a.version.major ||
      b.version.minor - a.version.minor ||
      a.name.localeCompare(b.name)
  );
  return candidates[0];
}

// `simctl boot` fails on an already-booted device, which is a success for this purpose.
// `bootstatus -b` then blocks until the device is actually usable, so the test run below cannot
// race the boot -- and a boot that never finishes is reported as the environment problem it is,
// under its own sentence, rather than as a UI test failure.
function bootSimulator(udid) {
  const status = run('xcrun', ['simctl', 'boot', udid], 'xcrun simctl boot');
  if (status !== 0) {
    console.log(
      '[verify-app-launch] `simctl boot` returned non-zero. That is expected when the device is ' +
        'already booted, which is the only reason it is tolerated here; `bootstatus` below decides ' +
        'whether the device is actually usable.'
    );
  }
  const bootStatus = run('xcrun', ['simctl', 'bootstatus', udid, '-b'], 'xcrun simctl bootstatus');
  if (bootStatus !== 0) {
    fail('the simulator did not finish booting. Its output is above.', bootStatus);
  }
}

// The app target's bundle identifier, read from the generated project rather than copied from
// project.yml, so the two cannot drift. `xcodebuild -showBuildSettings` prints one `NAME = value`
// line per setting; the app's own identifier is the one the VideoShrink target reports.
function appBundleIdentifier() {
  const stdout = runCaptured(
    'xcodebuild',
    ['-project', 'VideoShrink.xcodeproj', '-target', 'VideoShrink', '-showBuildSettings'],
    'xcodebuild -showBuildSettings'
  );
  const match = /^\s*PRODUCT_BUNDLE_IDENTIFIER\s*=\s*(\S+)\s*$/m.exec(stdout);
  if (!match) {
    fail(
      'xcodebuild -showBuildSettings reported no PRODUCT_BUNDLE_IDENTIFIER for the VideoShrink ' +
        "target, so this script cannot clear the app's saved state before the test."
    );
  }
  return match[1];
}

// The test opens on the introduction, which is chosen by a default the app stores in its own
// container. A container left over from an earlier run on the same machine would start the test
// somewhere else, so it is removed first. This is the only reason this step exists: the app is
// installed afresh by the test run either way.
//
// `simctl uninstall` fails when the app is not installed, which is the honest state of a clean
// simulator and not an error here, so that one outcome is tolerated and everything else is not.
function clearStoredAppState(udid, identifier) {
  const status = run(
    'xcrun',
    ['simctl', 'uninstall', udid, identifier],
    'xcrun simctl uninstall'
  );
  if (status === 0) {
    console.log(`[verify-app-launch] Removed ${identifier}'s saved state from the simulator.`);
    return;
  }
  console.log(
    `[verify-app-launch] \`simctl uninstall ${identifier}\` returned non-zero, which is what it ` +
      'does when the app is not installed yet. That is the expected state of a clean simulator, ' +
      'so this continues; the test run installs the app itself.'
  );
}

// The UI test compiles the app and its own bundle and then runs them on the simulator. Signing is
// off for the same reason it is off in the other two jobs: the destination is a simulator, so no
// certificate, provisioning profile or registered device is involved and nothing is spent.
function runLaunchSmokeTest(udid) {
  const status = run(
    'xcodebuild',
    [
      '-project',
      'VideoShrink.xcodeproj',
      '-scheme',
      'VideoShrinkUITests',
      '-destination',
      `platform=iOS Simulator,id=${udid}`,
      '-derivedDataPath',
      derivedDataPath,
      'CODE_SIGNING_ALLOWED=NO',
      'test'
    ],
    'xcodebuild test'
  );
  if (status !== 0) {
    fail(
      'the launch test failed. The app either did not compile, did not launch, or did not draw the ' +
        'screen the test waits for -- XCTest output above names which, and the result bundle in ' +
        `${derivedDataPath}/Logs/Test carries the screen as it was at the moment of failure.`,
      status
    );
  }
}

function preflight() {
  checkNativeSourceMirror();
}

function reportFailure(error) {
  banner(`${BANNER} FAILED`);
  if (error instanceof LaunchFailure) {
    console.error(`[verify-app-launch] ${error.message}`);
    process.exitCode = error.exitCode;
  } else {
    console.error(error?.stack ?? String(error));
    process.exitCode = 1;
  }
}

const args = process.argv.slice(2);
const checkOnly = args.includes('--check-only');

if (checkOnly) {
  // The part that needs no Xcode and no macOS. This is the path that can be exercised on the
  // Windows machine the repository is normally edited on.
  banner(`${BANNER} CHECK ONLY`);
  try {
    preflight();
    banner(`${BANNER} CHECK ONLY PASSED`);
    console.log(
      '[verify-app-launch] Checked without Xcode: the native-source mirror is in sync. Nothing here ' +
        'built or launched anything, so this says nothing about whether a screen renders. Run the ' +
        'script without --check-only on a Mac, or push to run the app-launch-smoke CI job.'
    );
  } catch (error) {
    reportFailure(error);
  }
} else if (process.platform !== 'darwin') {
  const reason =
    'this step builds an iOS app and launches it in a simulator, which requires macOS, but the ' +
    `platform is ${process.platform}`;
  if (process.env.CI) {
    reportFailure(
      new LaunchFailure(
        `${reason}. CI is set, so this runner is not the macOS image the job asks for and this is a ` +
          'failure rather than a skip: a check that quietly passes on the wrong machine is worse than none.'
      )
    );
  } else {
    banner(`${BANNER} SKIPPED`);
    console.log(
      `[verify-app-launch] ${reason}. Run it on a Mac, or in CI on a macOS runner. \`--check-only\` ` +
        'performs the part that needs no Xcode.'
    );
  }
} else {
  banner(`${BANNER} START`);
  console.log(
    '[verify-app-launch] Building the standalone app, launching it on a simulator and asking the ' +
      'interface whether its first screen is there. This is the first observation of a rendered ' +
      'screen in this project; it is not a device result.'
  );
  try {
    preflight();
    ensureXcodeGen();
    generateProject();

    const simulator = discoverSimulator();
    console.log(
      `[verify-app-launch] Using ${simulator.name} (${formatIosVersion(simulator.version)}, ` +
        `${simulator.udid}) from \`xcrun simctl list devices available\`.`
    );
    bootSimulator(simulator.udid);
    clearStoredAppState(simulator.udid, appBundleIdentifier());
    runLaunchSmokeTest(simulator.udid);

    banner(`${BANNER} PASSED`);
    console.log(
      '[verify-app-launch] The app installed, launched, drew its introduction and answered Skip by ' +
        'drawing the batch screen. This is the first observation of a screen in this project, and it ' +
        'covers one navigation. It is not a device result: the simulator has no Photos library, no ' +
        'iCloud and no real encoder, so retrieval, export, verification, saving, deletion and ' +
        'recovery remain unexercised -- see docs/PHYSICAL_DEVICE_TEST_PLAN.md.'
    );
  } catch (error) {
    reportFailure(error);
  }
}
