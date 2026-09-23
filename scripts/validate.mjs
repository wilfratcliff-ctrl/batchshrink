// Portable repository guardrails, NOT a Swift compiler, XCTest runner, or runtime safety proof.
import { readFileSync, readdirSync, existsSync } from 'node:fs';
import { resolve, relative, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import assert from 'node:assert/strict';
import { inflateSync } from 'node:zlib';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const read = path => readFileSync(resolve(root, path), 'utf8');
const walk = path => readdirSync(path, { withFileTypes: true }).flatMap(entry => {
  const full = resolve(path, entry.name);
  return entry.isDirectory() ? walk(full) : [full];
});
const appFiles = walk(resolve(root, 'VideoShrink'));
const swift = appFiles.filter(path => path.endsWith('.swift'));
const source = swift.map(path => readFileSync(path, 'utf8')).join('\n');
const tests = walk(resolve(root, 'VideoShrinkTests')).filter(path => path.endsWith('.swift'));
for (const path of ['README.md', 'project.yml', '.gitignore', 'docs/CLOUD_MAC_SETUP.md',
  'docs/PHYSICAL_DEVICE_TEST_PLAN.md', 'docs/OVERNIGHT_PROCESSING_SPIKE.md', 'docs/NEXT_PHASE.md',
  'docs/BATCH_PHASE.md']) {
  assert(existsSync(resolve(root, path)), `Missing ${path}`);
}
for (const forbidden of [/\bPHAssetCollectionChangeRequest\b/, /\bPHCollectionListChangeRequest\b/,
  /\bURLSession\b/, /\bWKWebView\b/, /\bData\s*\(\s*contentsOf:/,
  /\btry!\b/, /\bas!\s/, /value\(forKey:\s*"fileSize"/]) {
  assert(!forbidden.test(source), `Forbidden application pattern: ${forbidden}`);
}
// Deleting an original is allowed now, but only from one place and only behind the policy gate.
for (const path of swift) {
  const text = readFileSync(path, 'utf8');
  if (/\bdeleteAssets\s*\(/.test(text)) {
    assert.equal(relative(root, path).replaceAll('\\', '/'),
                 'VideoShrink/Services/PhotoLibraryService.swift',
                 'Photos deletion must live in one service');
  }
  if (/\bPHAssetChangeRequest\b/.test(text)) {
    assert.equal(relative(root, path).replaceAll('\\', '/'),
                 'VideoShrink/Services/PhotoLibraryService.swift',
                 'Photos change requests must live in one service');
  }
}
const deletionPolicy = read('VideoShrink/Models/DeletionPolicy.swift');
assert(deletionPolicy.includes('readBack: CopyReadBack?'),
  'Deleting an original must depend on a confirmed read-back');
assert(deletionPolicy.includes('saving.isSmaller'),
  'Deleting an original must depend on a smaller saved copy');
assert(read('VideoShrink/Models/ShrinkSettings.swift').includes('?? .off'),
  'Deleting originals must be off until the user turns it on');
assert(source.includes('Recently Deleted'),
  'The interface and the policy must say what Photos does with deleted items');
// The library scan must never download an original, and reported sizes must come from the
// documented Photos property rather than an undocumented lookup.
const scanner = read('VideoShrink/Services/PhotoLibraryScanService.swift');
assert(!source.includes('value(forKey:'), 'Media metadata must not be read through key-value coding');
assert(scanner.includes('NSSelectorFromString("dataSize")'),
  'Reported original sizes must come from the documented Photos dataSize property');
assert(scanner.includes('isNetworkAccessAllowed = false'),
  'The library scan must ask PhotoKit for on-device originals only');
assert(!/isNetworkAccessAllowed\s*=\s*true/.test(scanner),
  'The library scan must never allow a network request');
for (const path of swift) {
  const text = readFileSync(path, 'utf8');
  if (/\bremoveItem\s*\(/.test(text)) {
    assert.equal(relative(root, path).replaceAll('\\', '/'), 'VideoShrink/Services/TemporaryFileManager.swift');
    assert(text.includes('removeItem(at: root)'), 'Cleanup must only target the owned temporary root');
    assert(text.includes('standardizedFileURL.path == root.standardizedFileURL.path'),
      'Per-file removal must be confined to the owned temporary root');
  }
}
assert(source.includes('PHAssetCreationRequest.forAsset()'));
assert(source.includes('options.shouldMoveFile = false'));
assert(source.includes('AVAssetExportPresetHEVC1920x1080'));
assert(source.includes('AVAssetExportPresetHEVC3840x2160'), 'The 4K HEVC preset must be the documented one');
assert(source.includes('AVAssetExportPreset1280x720'), '720p must use Apple\'s documented preset');
assert(source.includes('output.longEdge <= source.longEdge'), 'A copy must never be larger than its original');
assert(source.includes('needsComposition'), 'A video composition must be requested explicitly');
assert(source.includes('perFrameHDRDisplayMetadataPolicy'),
  'Composed exports must keep HDR display metadata');
const thumbnails = read('VideoShrink/Services/ThumbnailService.swift');
assert(thumbnails.includes('isNetworkAccessAllowed = true'),
  'Only thumbnails may let Photos use the network, and they must say so');
assert(thumbnails.includes('Originals are never downloaded here'),
  'The thumbnail service must record that it never fetches originals');
const queue = read('VideoShrink/Services/BatchQueueStore.swift');
assert(queue.includes('applicationSupportDirectory'),
  'The stored queue must live in the app\'s own Application Support directory');
assert(queue.includes('isExcludedFromBackup = true'), 'The stored queue must be excluded from backup');
assert(queue.includes('completeFileProtectionUntilFirstUserAuthentication'),
  'The stored queue must use file protection');
assert(!/removeItem\s*\(/.test(queue), 'Clearing the stored queue must not delete anything');
assert(source.includes('BatchQueueReconciliation'),
  'A stored queue must be reconciled before it is used again');
assert(source.includes('case needsCheck'),
  'A copy that may already have been saved must be flagged, not repeated');
const verification = read('VideoShrink/Services/VideoVerificationService.swift');
assert(verification.includes('for fraction in [0.1, 0.5, 0.9]'),
  'Verification must decode frames from more than one point in the file');
assert(verification.includes('confirmAudioIsPresent'),
  'A copy of a video with sound must be checked for sound');
assert(read('VideoShrink/Services/PhotoLibraryService.swift').includes('isNetworkAccessAllowed = false'),
  'Reading a copy back must never fetch it');
assert(source.includes('DeviceConditions.pacing()'),
  'A batch must stop before it overheats the device');
assert(source.includes('localFileURL(identifier:'),
  'A saved copy must be read back from Photos');
assert(source.includes('isNetworkAccessAllowed = true'));
assert(source.includes('states(updateInterval: 0.25)'));
assert(source.includes('CMSampleBufferGetImageBuffer(sample)'));
assert(!read('VideoShrink/Resources/Info.plist').includes('UIBackgroundModes'));
// Keeping the display awake is opt-in, confined to one service, and released by the view model.
for (const path of swift) {
  const text = readFileSync(path, 'utf8');
  if (/isIdleTimerDisabled/.test(text)) {
    assert.equal(relative(root, path).replaceAll('\\', '/'),
                 'VideoShrink/Services/ScreenAwakeController.swift',
                 'The idle timer may only be touched in one place');
  }
}
assert(read('VideoShrink/Services/ScreenAwakeController.swift').includes('isIdleTimerDisabled'));
assert(read('VideoShrink/Models/ShrinkSettings.swift').includes('defaults.bool(forKey: screenAwakeKey)'),
  'Keeping the screen awake must default to off');
assert(source.includes('func deleteOriginals(identifiers:'),
  'Deleting originals must batch into one Photos transaction');
assert(read('VideoShrink/Services/PhotoLibraryService.swift').includes('requestPlayerItem'),
  'A preview must ask PhotoKit for a player item rather than fetching an export-grade original');
assert(read('VideoShrink/Resources/Info.plist').includes('NSPhotoLibraryAddUsageDescription'));
assert(read('VideoShrink/Resources/Info.plist').includes('NSPhotoLibraryUsageDescription'));
assert(read('VideoShrink/Resources/PrivacyInfo.xcprivacy').includes('E174.1'));
assert(!read('project.yml').includes('packages:'));
assert(!read('project.yml').includes('DEVELOPMENT_TEAM:'));
const testCount = tests.reduce((n, path) => n + [...readFileSync(path, 'utf8').matchAll(/func test\w+\(/g)].length, 0);
assert(testCount >= 20);
for (const path of appFiles.filter(path => path.endsWith('.json'))) JSON.parse(readFileSync(path, 'utf8'));
const png = readFileSync(resolve(root, 'VideoShrink/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png'));
assert.equal(png.readUInt32BE(16), 1024); assert.equal(png.readUInt32BE(20), 1024);
assert.equal(png[25], 2, 'Icon must use opaque RGB');
let offset = 8; const idat = [];
while (offset < png.length) {
  const length = png.readUInt32BE(offset);
  if (png.toString('ascii', offset + 4, offset + 8) === 'IDAT') idat.push(png.subarray(offset + 8, offset + 8 + length));
  offset += length + 12;
}
assert.equal(inflateSync(Buffer.concat(idat)).length, (1024 * 3 + 1) * 1024);
console.log(`PASS: repository guardrails; ${swift.length} app Swift files; ${testCount} XCTest cases present; icon/JSON valid.`);
console.log('NOT RUN: XcodeGen generation, Swift compilation, XCTest execution, simulator, signing, Photos/iCloud/device tests.');
