#!/usr/bin/env node
// Compile the VideoShrinkTests target on the EAS macOS builder. Opt-in only.
//
// This script COMPILES the test target and does NOT execute the tests.
// `xcodebuild ... build-for-testing` builds the test bundle and stops; no XCTest
// body runs here. After a pass the 162 cases are known to compile and still have
// never been run. Running them needs a simulator or a macOS runner (see
// docs/VERIFICATION_HANDOFF.md, section 6).
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
      'This step compiles them; it does NOT run them.'
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
      'The tests were NOT executed: nothing in this step runs a test body.'
  );
}

if (process.env[OPT_IN_VARIABLE] !== '1') {
  console.log(
    `${OPT_IN_VARIABLE} is not 1, so the XCTest target compile is skipped. ` +
      'It is opt-in: run the verify-tests EAS profile to compile the 162 test cases.'
  );
} else {
  try {
    compileTestTarget();
  } catch (error) {
    banner(`${BANNER} FAILED`);
    if (error instanceof VerificationFailure) {
      console.error(error.message);
      process.exitCode = error.exitCode;
    } else {
      console.error(error?.stack ?? String(error));
      process.exitCode = 1;
    }
  }
}
