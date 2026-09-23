/**
 * Draws the app icon from the app's own brand.
 *
 * The icon shipped until now was a blue square with a download arrow on it. Nothing in the app
 * looked like that: the app is a dark canvas with a mint accent, and its own logo - the badge
 * `ShrinkBrand` draws and the hero artwork enlarges - is a mint rounded square carrying a dark
 * shrink mark. The icon is the most-seen surface the product has, it is the splash screen's own
 * image, and it disagreed with every screen behind it.
 *
 * This regenerates it as that badge on the app's canvas, so the icon, the splash, the toolbar
 * logo and the hero artwork are one mark rather than four unrelated pictures. It is a script
 * rather than a hand-made bitmap because the colours here are the ones in `ShrinkStyle.swift`,
 * and a picture nobody can regenerate is a picture that drifts the moment the palette moves.
 *
 * Deliberately dependency-free: a PNG is a header, one zlib stream and a checksum, and Node has
 * zlib. Adding an image library to redraw four shapes would be the larger cost.
 *
 *   node scripts/make-app-icon.mjs           # rewrite both images
 *   node scripts/make-app-icon.mjs --check    # fail if either file on disk differs
 *
 * The output is 1024x1024 opaque RGB, which is what `scripts/validate.mjs` asserts: iOS rejects
 * an icon with an alpha channel, and App Store Connect rejects anything but a true 1024 square.
 *
 * It also writes the splash screen's image, which is the same badge on transparency rather than
 * the icon itself. The splash sits on the app's own canvas, so a square snapshot of the icon puts
 * a visible tile edge in the middle of a screen that is otherwise one flat colour.
 */

import { deflateSync } from 'node:zlib';
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const iconPath = resolve(root, 'VideoShrink/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png');
const splashPath = resolve(root, 'VideoShrink/Resources/SplashMark.png');

const ICON_SIZE = 1024;
const SPLASH_SIZE = 512;
/** Samples per axis per pixel. 4 is 16 samples a pixel: enough for these edges, still instant. */
const SUPERSAMPLE = 3;

// The palette is transcribed from VideoShrink/Presentation/ShrinkStyle.swift, which is the source
// of truth for all of it. Read that file rather than this one if the two ever disagree.
const CANVAS = [6, 9, 17];       // ShrinkStyle.canvas      - the darkest surface, and the mark's ink
const BACKDROP_TOP = [34, 43, 64]; // ShrinkStyle.elevated, lifted for a gradient with depth
const MINT_TOP = [189, 251, 222];  // ShrinkStyle.accent, lifted at the top edge
const MINT_BOTTOM = [148, 230, 189]; // ShrinkStyle.accent, settled at the bottom edge
const MINT_GLOW = [168, 245, 209];   // ShrinkStyle.accent

/** How much of its own size the badge takes, and how round its corners are. Both are the ratio
 *  `ShrinkBrand` draws at 28 points, so the mark is the same shape at every size. */
const BADGE_FRACTION = 0.66;
const BADGE_RADIUS_FRACTION = 0.32;
/** The mark inside the badge, also a ratio, so nothing has to be re-tuned per size. */
const GLYPH_FRACTION_OF_BADGE = 0.62;

const lerp = (a, b, t) => a + (b - a) * t;
const mix = (a, b, t) => [lerp(a[0], b[0], t), lerp(a[1], b[1], t), lerp(a[2], b[2], t)];
const clamp01 = value => Math.min(1, Math.max(0, value));
const smoothstep = (edge0, edge1, value) => {
  const t = clamp01((value - edge0) / (edge1 - edge0));
  return t * t * (3 - 2 * t);
};

/** Signed distance to a rounded rectangle: negative inside, positive outside, zero on the edge. */
function roundedRectDistance(x, y, rect) {
  const { x0, y0, x1, y1, radius } = rect;
  const cx = (x0 + x1) / 2;
  const cy = (y0 + y1) / 2;
  const halfWidth = (x1 - x0) / 2 - radius;
  const halfHeight = (y1 - y0) / 2 - radius;
  const qx = Math.abs(x - cx) - halfWidth;
  const qy = Math.abs(y - cy) - halfHeight;
  const outside = Math.hypot(Math.max(qx, 0), Math.max(qy, 0));
  return outside + Math.min(Math.max(qx, qy), 0) - radius;
}

function insidePolygon(x, y, points) {
  let inside = false;
  for (let i = 0, j = points.length - 1; i < points.length; j = i++) {
    const [xi, yi] = points[i];
    const [xj, yj] = points[j];
    if (((yi > y) !== (yj > y)) && (x < ((xj - xi) * (y - yi)) / (yj - yi) + xi)) inside = !inside;
  }
  return inside;
}

/** A straight arrow: a shaft with a triangular head whose tip is exactly `tip`. */
function arrow(tail, tip, shaftWidth, headWidth, headLength) {
  const dx = tip[0] - tail[0];
  const dy = tip[1] - tail[1];
  const length = Math.hypot(dx, dy) || 1;
  const ux = dx / length;
  const uy = dy / length;
  const px = -uy;
  const py = ux;
  const baseX = tip[0] - ux * headLength;
  const baseY = tip[1] - uy * headLength;
  const s = shaftWidth / 2;
  const h = headWidth / 2;
  return [
    [tail[0] + px * s, tail[1] + py * s],
    [baseX + px * s, baseY + py * s],
    [baseX + px * h, baseY + py * h],
    [tip[0], tip[1]],
    [baseX - px * h, baseY - py * h],
    [baseX - px * s, baseY - py * s],
    [tail[0] - px * s, tail[1] - py * s],
  ];
}

/**
 * The mark itself: `arrow.down.right.and.arrow.up.left`, the shape `ShrinkBrand` and
 * `ShrinkHeroArtwork` both draw. Two arrows on the diagonal, heads meeting at the middle, which
 * is the "smaller" half of the product's whole idea.
 *
 * Drawn in a unit square and scaled by the caller, so the same geometry states the mark at 28
 * points in a toolbar and at 676 in an icon.
 */
function shrinkMarkGeometry() {
  return {
    inwardFromTopLeft: arrow([0.15, 0.15], [0.465, 0.465], 0.125, 0.36, 0.185),
    inwardFromBottomRight: arrow([0.85, 0.85], [0.535, 0.535], 0.125, 0.36, 0.185),
  };
}

/**
 * The badge and the mark as a function of size.
 *
 * Every dimension is a fraction of the canvas, so the icon and the splash mark are the same
 * picture at two sizes rather than two pictures that have to be kept in step by hand.
 */
function composition(size, badgeFraction = BADGE_FRACTION) {
  const side = size * badgeFraction;
  const inset = (size - side) / 2;
  const badge = { x0: inset, y0: inset, x1: inset + side, y1: inset + side, radius: side * BADGE_RADIUS_FRACTION };
  const glyphSide = side * GLYPH_FRACTION_OF_BADGE;
  const glyphOrigin = (size - glyphSide) / 2;
  const markPoint = ([ux, uy]) => [glyphOrigin + ux * glyphSide, glyphOrigin + uy * glyphSide];
  const mark = shrinkMarkGeometry();
  return {
    badge,
    glyphSide,
    polygons: [
      mark.inwardFromTopLeft.map(markPoint),
      mark.inwardFromBottomRight.map(markPoint),
    ],
  };
}

/** The ink at one sample: the badge, or the mark drawn in the canvas colour. */
function inkAt(x, y, { badge, polygons }) {
  const vertical = clamp01((y - badge.y0) / (badge.y1 - badge.y0));
  for (const polygon of polygons) {
    if (insidePolygon(x, y, polygon)) return CANVAS;
  }
  // The badge, lit from above so it reads as a surface rather than a swatch.
  return mix(MINT_TOP, MINT_BOTTOM, vertical);
}

/** The app icon: the badge on the app's canvas, with a glow behind it and a short shadow under. */
function sampleIcon(x, y, geometry) {
  // The backdrop: a diagonal gradient, so the tile is not a flat fill behind the badge.
  const t = clamp01((x + y) / (2 * ICON_SIZE));
  let colour = mix(BACKDROP_TOP, CANVAS, t);

  // A soft mint glow behind the badge, the same device the hero artwork uses to seat its frames.
  const centre = ICON_SIZE / 2;
  const glow = 1 - smoothstep(0, ICON_SIZE * 0.46, Math.hypot(x - centre, y - centre));
  colour = mix(colour, MINT_GLOW, glow * 0.10);

  const badgeDistance = roundedRectDistance(x, y, geometry.badge);
  if (badgeDistance < 0) return inkAt(x, y, geometry);

  // A short shadow under the badge so it sits above the backdrop instead of on it. Kept inside
  // the badge's own footprint plus a small margin, so the icon does not look vignetted.
  const shadow = 1 - smoothstep(0, ICON_SIZE * 0.025, badgeDistance);
  return [...mix(colour, CANVAS, shadow * 0.45), 255];
}

/**
 * The splash mark: the same badge on transparency.
 *
 * It carries a faint mint halo so the badge does not look cut out on a flat screen, and nothing
 * else - a shadow would be a shape the app never draws anywhere else.
 */
function sampleSplashMark(x, y, geometry) {
  const badgeDistance = roundedRectDistance(x, y, geometry.badge);
  if (badgeDistance < 0) return [...inkAt(x, y, geometry), 255];
  const halo = 1 - smoothstep(0, SPLASH_SIZE * 0.09, badgeDistance);
  return [...MINT_GLOW, Math.round(halo * 255)];
}

function render(size, sampler, channels) {
  const stride = size * channels + 1;
  const raw = Buffer.alloc(stride * size);
  const samples = SUPERSAMPLE * SUPERSAMPLE;
  const step = 1 / SUPERSAMPLE;
  for (let y = 0; y < size; y++) {
    raw[y * stride] = 0; // PNG filter: none. The validator asserts this row shape.
    for (let x = 0; x < size; x++) {
      const totals = new Float64Array(channels);
      for (let sy = 0; sy < SUPERSAMPLE; sy++) {
        for (let sx = 0; sx < SUPERSAMPLE; sx++) {
          const pixel = sampler(x + (sx + 0.5) * step, y + (sy + 0.5) * step);
          for (let c = 0; c < channels; c++) totals[c] += pixel[c];
        }
      }
      const offset = y * stride + 1 + x * channels;
      for (let c = 0; c < channels; c++) raw[offset + c] = Math.round(totals[c] / samples);
    }
  }
  return raw;
}

const crcTable = (() => {
  const table = new Uint32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    table[n] = c >>> 0;
  }
  return table;
})();

function crc32(buffer) {
  let c = 0xffffffff;
  for (const byte of buffer) c = crcTable[(c ^ byte) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}

function chunk(type, data) {
  const length = Buffer.alloc(4);
  length.writeUInt32BE(data.length);
  const name = Buffer.from(type, 'ascii');
  const crc = Buffer.alloc(4);
  crc.writeUInt32BE(crc32(Buffer.concat([name, data])));
  return Buffer.concat([length, name, data, crc]);
}

function png(raw, size, colourType) {
  const header = Buffer.alloc(13);
  header.writeUInt32BE(size, 0);
  header.writeUInt32BE(size, 4);
  header[8] = 8;  // bit depth
  header[9] = colourType; // 2: truecolour; 6: truecolour with alpha
  header[10] = 0; // deflate
  header[11] = 0; // adaptive filtering
  header[12] = 0; // no interlace
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk('IHDR', header),
    chunk('IDAT', deflateSync(raw, { level: 9 })),
    chunk('IEND', Buffer.alloc(0)),
  ]);
}

/** The app icon: 1024 square, opaque, because iOS and App Store Connect both require that. */
export function renderIcon() {
  const geometry = composition(ICON_SIZE);
  return png(render(ICON_SIZE, (x, y) => sampleIcon(x, y, geometry), 3), ICON_SIZE, 2);
}

/** The splash image: the same badge, with alpha, on no background of its own. */
export function renderSplashMark() {
  // A little more room than the icon's composition needs, so the halo is not clipped.
  const geometry = composition(SPLASH_SIZE, BADGE_FRACTION * 0.86);
  return png(render(SPLASH_SIZE, (x, y) => sampleSplashMark(x, y, geometry), 4), SPLASH_SIZE, 6);
}

const images = [
  { path: iconPath, bytes: renderIcon, describe: 'the app icon' },
  { path: splashPath, bytes: renderSplashMark, describe: 'the splash image' },
];

function main() {
  const checking = process.argv.includes('--check');
  let failed = false;
  for (const image of images) {
    const expected = image.bytes();
    if (checking) {
      let existing = null;
      try {
        existing = readFileSync(image.path);
      } catch {
        // Reported below, with the same sentence as a mismatch.
      }
      if (!existing || !existing.equals(expected)) {
        console.error(`FAIL: ${image.describe} does not match this script. Run \`node scripts/make-app-icon.mjs\`.`);
        failed = true;
      }
      continue;
    }
    mkdirSync(dirname(image.path), { recursive: true });
    writeFileSync(image.path, expected);
    console.log(`Wrote ${image.path} (${expected.length} bytes).`);
  }
  if (!checking) return;
  if (failed) process.exit(1);
  console.log('PASS: the app icon and the splash image both match scripts/make-app-icon.mjs.');
}

// Importable so scripts/validate.mjs can compare the bytes without spawning a process; the CLI
// behaviour is what `npm run icon` and `npm run icon:check` use.
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) main();
