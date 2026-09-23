// Deterministic placeholder app icon; Node built-ins only. No remote assets or generators.
import { mkdirSync, writeFileSync } from 'node:fs';
import { deflateSync } from 'node:zlib';
import { fileURLToPath } from 'node:url';

const directory = fileURLToPath(new URL('../VideoShrink/Resources/Assets.xcassets/AppIcon.appiconset/', import.meta.url));
mkdirSync(directory, { recursive: true });
function crc32(buffer) {
  let crc = 0xffffffff;
  for (const byte of buffer) {
    crc ^= byte;
    for (let i = 0; i < 8; i++) crc = (crc >>> 1) ^ (crc & 1 ? 0xedb88320 : 0);
  }
  return (crc ^ 0xffffffff) >>> 0;
}
function chunk(type, data) {
  const name = Buffer.from(type);
  const size = Buffer.alloc(4); size.writeUInt32BE(data.length);
  const crc = Buffer.alloc(4); crc.writeUInt32BE(crc32(Buffer.concat([name, data])));
  return Buffer.concat([size, name, data, crc]);
}
const size = 1024;
const pixels = Buffer.alloc((size * 3 + 1) * size);
for (let y = 0; y < size; y++) {
  for (let x = 0; x < size; x++) {
    const shaft = x >= 458 && x <= 566 && y >= 235 && y <= 590;
    const head = y >= 480 && y <= 738 && Math.abs(x - 512) <= (738 - y);
    const base = x >= 285 && x <= 739 && y >= 787 && y <= 845;
    const rgb = shaft || head || base ? [245, 248, 255] : [39, 61, 137];
    const offset = y * (size * 3 + 1) + 1 + x * 3;
    pixels.set(rgb, offset);
  }
}
const header = Buffer.alloc(13);
header.writeUInt32BE(size, 0); header.writeUInt32BE(size, 4);
header[8] = 8; header[9] = 2; // RGB, opaque: App Store icons must not contain alpha.
const png = Buffer.concat([Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]), chunk('IHDR', header),
  chunk('IDAT', deflateSync(pixels)), chunk('IEND', Buffer.alloc(0))]);
writeFileSync(`${directory}/AppIcon.png`, png);
writeFileSync(`${directory}/Contents.json`, JSON.stringify({ images: [
  { filename: 'AppIcon.png', idiom: 'universal', platform: 'ios', size: '1024x1024' }
], info: { author: 'xcode', version: 1 } }, null, 2) + '\n');
writeFileSync(`${directory}/../Contents.json`, JSON.stringify({ info: { author: 'xcode', version: 1 } }, null, 2) + '\n');
console.log('Created opaque 1024×1024 placeholder AppIcon.png');
