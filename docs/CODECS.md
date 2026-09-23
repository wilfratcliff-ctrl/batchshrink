# Codec options on iPhone

The question was whether something more efficient than HEVC is available, AV1 in particular.
The short answer is no, not for encoding on iOS today, and the reason is a platform limit rather
than a preference.

## What Apple actually gives you

`AVVideoCodecType`, the list AVFoundation will write, contains:

`h264`, `hevc`, `hevcWithAlpha`, `jpeg`, `JPEGXL`, `proRes422`, `proRes422LT`, `proRes422HQ`,
`proRes422Proxy`, `proRes4444`, `proResRAW`, `proResRAWHQ`, `appleProRes4444XQ`.

There is no `av1` and no `vp9`. VideoToolbox, the framework underneath, exposes a hardware encode
path for H.264 and HEVC and a runtime encoder list; AV1 appears only as a format description
constant (`kCMVideoCodecType_AV1`), which is about reading media, not writing it.

HEVC decode and playback are supported on current Apple silicon, and AV1 playback has arrived on
recent chips, but playback support is not an encoder. Nothing in the platform lets this app write
an AV1 file.

## What that means for file size

At the same picture quality, the useful comparison is roughly:

| Codec | Practical size | Encode cost on iPhone |
| --- | --- | --- |
| H.264 | baseline | cheap, hardware |
| HEVC | about half of H.264 | cheap, hardware |
| AV1 | another 20-30% below HEVC | no hardware encoder on iOS |
| ProRes | far larger than H.264 | hardware, built for editing |

AV1's advantage is real on paper. Getting it would mean shipping a software encoder (libaom or
SVT-AV1). That would be many times slower than the hardware encoder, would heat the phone and
drain the battery, and would sit outside AVFoundation entirely. For a phone app that is meant to
run through a library in the background of someone's day, that is the wrong trade.

## Where the real savings are

Codec choice is fixed, so the levers that matter are the ones this app already exposes:

1. **Resolution.** 4K to 1080p is the single biggest reduction in almost every real library.
2. **Frame rate.** 60 to 30 fps halves the frames the encoder has to describe, and 24 fps goes
   further. Fast action looks worst for it.
3. **Bitrate, which the preset decides.** Apple's HEVC presets are quality-targeted, so simpler
   footage already comes out smaller without any setting to change.

HDR is worth separating from all of this. An HDR original keeps its look only if the copy keeps
its colour tags, which is why composed exports set `perFrameHDRDisplayMetadataPolicy` and why the
app tells you to watch an HDR copy before trusting it. Codec choice does not fix a lost transfer
function.

## What would change this answer

- Apple shipping an AV1 encoder in VideoToolbox. Then `AVVideoCodecType` would gain a case and the
  preset list would follow.
- Hardware AV1 encode on a future chip, which is the same thing from this app's point of view.
- A deliberate, documented decision to ship a software encoder for a niche workflow such as
  archiving a handful of very large files, accepting the time and heat.

Until then, HEVC at a sensible resolution and frame rate is the most efficient thing an iPhone
will actually encode.
