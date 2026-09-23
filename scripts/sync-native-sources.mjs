// Keep the original Swift project as the single source of truth.
// The local Expo pod compiles generated copies; no personal media is copied.
import { copyFileSync, existsSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createHash } from 'node:crypto';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const destination = resolve(root, 'modules/videoshrink-native/ios/VideoShrinkCore');
const check = process.argv.includes('--check');
const manifest = {};
const sourcePaths = ['Models', 'Services', 'Presentation'].flatMap(folder =>
  readdirSync(resolve(root, 'VideoShrink', folder))
    .filter(name => name.endsWith('.swift'))
    .map(name => `${folder}/${name}`)
).sort();
sourcePaths.push('Resources/PrivacyInfo.xcprivacy');

for (const sourcePath of sourcePaths) {
  const source = resolve(root, 'VideoShrink', sourcePath);
  const target = resolve(destination, sourcePath);
  const contents = readFileSync(source);
  manifest[sourcePath] = createHash('sha256').update(contents).digest('hex');
  if (check) {
    if (!existsSync(target) || !contents.equals(readFileSync(target))) {
      throw new Error(`Native source copy is missing or stale: ${sourcePath}. Run npm run sync:native.`);
    }
  } else {
    mkdirSync(dirname(target), { recursive: true });
    copyFileSync(source, target);
  }
}
const manifestPath = resolve(destination, 'source-manifest.json');
const expectedManifest = JSON.stringify(manifest, null, 2) + '\n';
if (check) {
  if (!existsSync(manifestPath) || readFileSync(manifestPath, 'utf8') !== expectedManifest) {
    throw new Error('Native source manifest changed. Run npm run sync:native.');
  }
} else {
  writeFileSync(manifestPath, expectedManifest);
}
console.log(`${check ? 'Verified' : 'Synced'} ${sourcePaths.length - 1} Swift source files and the privacy manifest for Expo.`);
