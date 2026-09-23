#!/usr/bin/env node
// Compile and run the VideoShrinkTests target on the EAS macOS builder. Opt-in only.
//
// Phase 1 COMPILES the test target: `xcodebuild ... build-for-testing` builds the
// test bundle and stops.
//
// Phase 2 RUNS it, but only if phase 1 succeeded. It discovers an available iPhone
// simulator with `xcrun simctl list devices available --json` (falling back to
// `xcodebuild -showdestinations`), preferring the newest iOS runtime, then executes
// the 162 XCTest cases with `xcodebuild ... test-without-building` against that
// destination. Destination discovery is deliberate: builder images change, so a
// hardcoded device name would rot.
//
// If the builder has no simulator runtime at all, phase 2 prints a clear line and
// exits 0. A missing simulator is an environment fact, not a code defect, and the
// compile result is still worth having. If a destination *is* found and a test
// fails, the step exits non-zero so the EAS build fails visibly.
//
// It is a no-op unless VIDEOSHRINK_VERIFY_TESTS is exactly "1", so every existing
// EAS build profile behaves byte-for-byte as it did before this script existed.
// Only the `verify-tests` profile in eas.json sets that variable.
//
// The EAS builder is macOS with Xcode, but XcodeGen is not guaranteed to be
// installed, so this installs it with Homebrew when missing. Homebrew lives at
// /opt/homebrew on Apple Silicon and /usr/local on Intel, so both prefixes are
// added to PATH for every child process.

import { spawnSync } from 'node:child_process';
import { existsSync } from 'node:fs';
import { delimiter, dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const BANNER = '===== VIDEOSHRINK TEST TARGET COMPILE =====';
const RUN_BANNER = '===== VIDEOSHRINK TEST RUN =====';
const OPT_IN_VARIABLE = 'VIDEOSHRINK_VERIFY_TESTS';
const homebrewPaths = ['/opt/homebrew/bin', '/usr/local/bin'];

// The process ends by draining the event loop rather than calling process.exit(),
// because process.exit() can truncate output still buffered on a pipe, and an EAS
// build log is a pipe. Failures are thrown here and caught at the bottom of the file.
class VerificationFailure extends Error {
  constructor(message, exitCode) {
    super(message);
    this.exitCode = exitCode;
  }
}

function banner(line) {
  console.log(`\n${line}\n`);
}

function fail(message, exitCode = 1) {
  throw new VerificationFailure(message, exitCode === 0 ? 1 : exitCode);
}

// Child processes must see Homebrew's bin directory; its prefix differs between Intel
// and Apple Silicon builders. Assigning process.env.PATH is case-insensitive on Windows,
// so this stays a single entry wherever the script runs.
const inheritedPath = process.env.PATH ?? process.env.Path ?? '';
process.env.PATH = inheritedPath
  ? `${homebrewPaths.join(delimiter)}${delimiter}${inheritedPath}`
  : homebrewPaths.join(delimiter);

// Run a child process in the project root, with its output streamed straight into the
// build log. A non-zero status is returned, never swallowed, so the caller can print the
// compiler's own words and fail the build.
function run(command, args, step) {
  console.log(`[verify-native-tests] $ ${[command, ...args].join(' ')}`);
  const result = spawnSync(command, args, { cwd: root, env: process.env, stdio: 'inherit' });
  if (result.error) {
    fail(`${step} could not start: ${result.error.message}`);
  }
  return result.status ?? 1;
}

// `command -v` is a shell builtin, so it needs a shell. Output is captured, not streamed.
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

// Same child-process rules as run(), but the output is captured instead of streamed,
// for the two commands whose output has to be parsed. A failure here is reported and
// turned into null rather than thrown: destination discovery must be able to give up
// quietly, because "no simulator on this builder" is not a build failure.
function runCaptured(command, args, step) {
  const result = spawnSync(command, args, {
    cwd: root,
    env: process.env,
    encoding: 'utf8',
    maxBuffer: 16 * 1024 * 1024
  });
  if (result.error) {
    console.log(`[verify-native-tests] ${step} could not run: ${result.error.message}`);
    return null;
  }
  if (result.status !== 0) {
    console.log(`[verify-native-tests] ${step} exited with status ${result.status}; ignoring its output.`);
    return null;
  }
  return result.stdout ?? '';
}

// iOS runtime identifiers look like `com.apple.CoreSimulator.SimRuntime.iOS-17-4`,
// runtime names like `iOS 17.4`, and `-showdestinations` prints a bare `OS:17.4`.
// All three spellings are accepted so the parse survives either source.
function parseIosVersion(text) {
  const labelled = /iOS[-\s](\d+)(?:[.-](\d+))?/.exec(text ?? '');
  if (labelled) {
    return { major: Number(labelled[1]), minor: Number(labelled[2] ?? 0) };
  }
  const bare = /^\s*(\d+)(?:\.(\d+))?\s*$/.exec(text ?? '');
  return bare ? { major: Number(bare[1]), minor: Number(bare[2] ?? 0) } : null;
}

function formatIosVersion(version) {
  return version ? `${version.major}.${version.minor}` : 'unknown iOS';
}

function compareIosVersions(a, b) {
  if (!a && !b) {
    return 0;
  }
  if (!a) {
    return -1;
  }
  if (!b) {
    return 1;
  }
  return a.major - b.major || a.minor - b.minor;
}

// Only a tie-break, so that when one runtime offers several iPhone models the
// newest model wins. A name such as `iPhone-SE-3rd-generation` scores low and is
// never chosen over a numbered model, which is the intent; any available iPhone
// is a valid destination, so a miss here only changes which one is used.
function iphoneModelScore(text) {
  const numbered = /iPhone[-\s](\d+)/.exec(text ?? '');
  if (numbered) {
    return Number(numbered[1]);
  }
  const anyNumber = /(\d+)/.exec(text ?? '');
  return anyNumber ? Number(anyNumber[1]) : 0;
}

// `xcrun simctl list devices available --json` returns
// { devices: { "<runtime identifier>": [ { name, udid, state, isAvailable, deviceTypeIdentifier } ] } }.
function destinationFromSimctl() {
  const stdout = runCaptured(
    'xcrun',
    ['simctl', 'list', 'devices', 'available', '--json'],
    'xcrun simctl list devices available'
  );
  if (stdout === null) {
    return null;
  }

  let parsed;
  try {
    parsed = JSON.parse(stdout);
  } catch (error) {
    console.log(`[verify-native-tests] could not parse the simctl JSON: ${error.message}`);
    return null;
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
      // `available` is already in the query, but the flag and the error field are
      // checked too: a runtime can be listed while its devices are not usable.
      if (device?.isAvailable === false || device?.availabilityError) {
        continue;
      }
      if (!deviceType.includes('iPhone') && !name.startsWith('iPhone')) {
        continue;
      }
      candidates.push({
        udid,
        name: name || deviceType || 'iPhone simulator',
        runtimeIdentifier,
        version,
        modelScore: iphoneModelScore(deviceType || name),
        source: 'xcrun simctl list devices available'
      });
    }
  }

  if (candidates.length === 0) {
    return null;
  }

  // Newest iOS runtime first; the device model only breaks ties within a runtime.
  candidates.sort(
    (a, b) =>
      compareIosVersions(b.version, a.version) ||
      b.modelScore - a.modelScore ||
      a.name.localeCompare(b.name)
  );
  return candidates[0];
}

// Fallback source. `xcodebuild -showdestinations` prints one brace-wrapped line per
// destination, e.g.
// { platform:iOS Simulator, id:1A2B..., OS:17.4, name:iPhone 15 Pro }. The project
// exists by this point, because phase 1 ran `xcodegen generate` first.
function destinationFromShowDestinations() {
  const stdout = runCaptured(
    'xcodebuild',
    ['-project', 'VideoShrink.xcodeproj', '-scheme', 'VideoShrink', '-showdestinations'],
    'xcodebuild -showdestinations'
  );
  if (stdout === null) {
    return null;
  }

  const candidates = [];
  for (const line of stdout.split(/\r?\n/)) {
    if (!line.includes('platform:iOS Simulator')) {
      continue;
    }
    const fields = {};
    for (const match of line.matchAll(/([A-Za-z_]+):([^,{}\n]+)/g)) {
      fields[match[1]] = match[2].trim();
    }
    const udid = fields.id;
    const name = fields.name ?? '';
    if (!udid || !name.startsWith('iPhone')) {
      continue;
    }
    const version = parseIosVersion(fields.OS ?? name);
    candidates.push({
      udid,
      name,
      runtimeIdentifier: version ? `iOS ${formatIosVersion(version)}` : 'iOS (version unknown)',
      version,
      modelScore: iphoneModelScore(name),
      source: 'xcodebuild -showdestinations'
    });
  }

  if (candidates.length === 0) {
    return null;
  }

  candidates.sort(
    (a, b) =>
      compareIosVersions(b.version, a.version) ||
      b.modelScore - a.modelScore ||
      a.name.localeCompare(b.name)
  );
  return candidates[0];
}

function discoverSimulatorDestination() {
  const fromSimctl = destinationFromSimctl();
  if (fromSimctl) {
    return fromSimctl;
  }
  console.log(
    '[verify-native-tests] xcrun simctl yielded no available iPhone simulator; ' +
      'trying xcodebuild -showdestinations as a second source.'
  );
  return destinationFromShowDestinations();
}

function compileTestTarget() {
  if (process.platform !== 'darwin') {
    fail(
      `this step compiles a Swift test target with Xcode and requires macOS, but the platform is ${process.platform}. ` +
        'It is meant to run on the EAS macOS builder, not on this machine.'
    );
  }

  banner(`${BANNER} START`);
  console.log(
    '[verify-native-tests] Compiling the VideoShrinkTests target (162 XCTest cases). ' +
      'This phase compiles them; the run phase below executes them if a simulator is available.'
  );

  // 1. XcodeGen turns project.yml into VideoShrink.xcodeproj. It is not part of Xcode.
  if (!findOnPath('xcodegen')) {
    console.log('[verify-native-tests] xcodegen is not installed; installing it with Homebrew.');
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

  // 2. Generate the standalone Xcode project from project.yml, the source of truth.
  const generateStatus = run('xcodegen', ['generate'], 'xcodegen generate');
  if (generateStatus !== 0) {
    fail('xcodegen generate failed. The output is above.', generateStatus);
  }

  // 3. Build the app and the test bundle for the simulator without running anything.
  //    CODE_SIGNING_ALLOWED=NO and the generic simulator destination mean no Apple
  //    signing is needed. build-for-testing stops once the test bundle is built;
  //    `test` would run the suite and is deliberately not used here.
  const xcodebuildStatus = run(
    'xcodebuild',
    [
      '-project',
      'VideoShrink.xcodeproj',
      '-scheme',
      'VideoShrink',
      '-sdk',
      'iphonesimulator',
      '-destination',
      'generic/platform=iOS Simulator',
      '-derivedDataPath',
      'build/VerifyDerivedData',
      'CODE_SIGNING_ALLOWED=NO',
      'build-for-testing'
    ],
    'xcodebuild build-for-testing'
  );
  if (xcodebuildStatus !== 0) {
    fail('the VideoShrinkTests target did not compile. The compiler output is above.', xcodebuildStatus);
  }

  banner(`${BANNER} PASSED`);
  console.log(
    '[verify-native-tests] The VideoShrinkTests target compiled. ' +
      'Compilation only: nothing in this phase runs a test body.'
  );
}

// Phase 2. Never throws: a missing simulator is a skip (exit 0), a failing test run
// is a non-zero exit code. Both are reported under the RUN banner, so a test failure
// can never be mistaken for the compile failure reported under the COMPILE banner.
function runTests() {
  banner(`${RUN_BANNER} START`);

  const destination = discoverSimulatorDestination();
  if (!destination) {
    console.log(
      '[verify-native-tests] The 162 XCTest cases compiled, but they were NOT run: no available ' +
        'iPhone simulator destination was found on this builder. This is an environment fact, not a ' +
        'code defect, so the build continues and the compile result stands.'
    );
    banner(`${RUN_BANNER} SKIPPED`);
    return;
  }

  console.log(
    `[verify-native-tests] Running the 162 XCTest cases on ${destination.name} ` +
      `(${formatIosVersion(destination.version)}, ${destination.udid}) found via ${destination.source}.`
  );

  // Same project, scheme and derived data as the compile phase, so this reuses the
  // test bundle `build-for-testing` already produced instead of rebuilding it.
  const status = run(
    'xcodebuild',
    [
      '-project',
      'VideoShrink.xcodeproj',
      '-scheme',
      'VideoShrink',
      '-destination',
      `platform=iOS Simulator,id=${destination.udid}`,
      '-derivedDataPath',
      'build/VerifyDerivedData',
      'CODE_SIGNING_ALLOWED=NO',
      'test-without-building'
    ],
    'xcodebuild test-without-building'
  );

  if (status !== 0) {
    banner(`${RUN_BANNER} FAILED`);
    // Spelled out because two different failures look similar in a long log. The
    // compile banner above printed PASSED, so this is the run, not the compiler.
    console.error(
      '[verify-native-tests] The test bundle COMPILED (see the COMPILE banner above, which printed ' +
        'PASSED), but the test run failed: at least one XCTest case failed, or the simulator could not ' +
        'run the suite. The xcodebuild output is directly above this line. Failing the build.'
    );
    process.exitCode = status;
    return;
  }

  banner(`${RUN_BANNER} PASSED`);
  console.log(
    '[verify-native-tests] The 162 XCTest cases ran and passed on the simulator. This executes the ' +
      'unit-test bodies. It does not exercise device behaviour: real deletion, audio sync, HDR, ' +
      'interruptions and iCloud retrieval still need a physical iPhone (docs/PHYSICAL_DEVICE_TEST_PLAN.md).'
  );
}

function reportFailure(bannerLine, error) {
  banner(`${bannerLine} FAILED`);
  if (error instanceof VerificationFailure) {
    console.error(error.message);
    process.exitCode = error.exitCode;
  } else {
    console.error(error?.stack ?? String(error));
    process.exitCode = 1;
  }
}

if (process.env[OPT_IN_VARIABLE] !== '1') {
  console.log(
    `${OPT_IN_VARIABLE} is not 1, so compiling and running the XCTest target is skipped. ` +
      'It is opt-in: run the verify-tests EAS profile to compile and run the 162 test cases.'
  );
} else {
  // The two phases are reported under separate banners, and the run only happens if
  // the compile actually succeeded, so the log never shows a run failure caused by a
  // test bundle that did not build.
  let compiled = false;
  try {
    compileTestTarget();
    compiled = true;
  } catch (error) {
    reportFailure(BANNER, error);
  }

  if (compiled) {
    try {
      runTests();
    } catch (error) {
      reportFailure(RUN_BANNER, error);
    }
  }
}
