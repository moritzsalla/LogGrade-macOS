# Pipeline findings

Measured findings that are not already a comment beside the code. The ffprobe misreports, the float
clamps, `gblur` and the halation cost live in `scripts/lib.sh`. The `lut1d` round trip lives in
ADR 0003.

## Stages

- **Baseline:** the conversion `convert.cube` names (65³, `interp=tetrahedral`) plus colour tags,
  and nothing else. No sharpening before the grade: log looks soft only because it is flat, and
  early sharpening bakes in halos. The log denoise is the one exception, and it runs before the
  conversion, where the noise is still the sensor's.
- **Master:** the graded ProRes. Re-export from it, never from a delivered MP4.
- **Final:** Lanczos downscale, then sharpen (mild, luma only), then grain (a half-resolution plate,
  after the sharpener). Grain before the sharpener gets rung by it. The one-pass render downscales
  BEFORE the grade (`delivery_geometry`): twice as fast on IMG_0609, and against grading at 4K the
  final measured 41.7 dB luma / 50 dB chroma PSNR with mean level and saturation within 0.1.
  A clip's deliverables share that pass (`render_deliverables`): reels and feed of 3s of IMG_0609
  went 33.5s to 27.2s. The two x264 encoders then take most of the time.

### Encode

H.264 High, yuv420p with the 10→8 bit reduction dithered by `zscale`, CRF 18, AAC 192k,
`+faststart`. The platform recompresses everything, so feed it quality. Verify colour tags after
every encode: `prores_ks` and `libx264` both ignored the encode-time flags, and a Rec.709 file
tagged BT.2020 gets transformed twice by players (*bleached*). Remux with `-c copy` to set the
tags.

### Audio high-pass, 60 Hz

2-pole `highpass` on delivery only. Over all of IMG_0607, below 40 Hz is the quietest band (−50.1
dBFS), not the loudest; 80–120 Hz is as loud as anything (−39.0). 60 Hz takes −9.0 dB below 40 Hz
and −1.8 dB off the peak while leaving 80–120 Hz within −0.7 dB. 70/80 Hz cut more of the loud band.
Bands were measured with `firequalizer` band-passes into `astats`, which leak within 3 Hz of an edge.

## Sharpen and grain at other heights

IMG_0607 frame 12, luma, code values, not yet judged by eye. Grain = default − `GRAIN_STRENGTH=0` in
flat sky; sharpen = that − delivery `unsharp` amount 0; corr/hw = lag where horizontal
autocorrelation falls below 0.5.

| Height | r | Grain RMS | Grain corr px | Sharpen RMS | Sharpen hw %h |
|---|---|---|---|---|---|
| 960 | 3 | 3.14 | 1.03 | 3.17 | 0.070 |
| 1280 | 3 | 3.06 | 1.10 | 2.92 | 0.053 |
| 1920 | 5 | 3.00 | 1.21 | 3.04 | 0.043 |
| 2560 | 7 | 2.94 | 1.26 | 2.95 | 0.038 |

Measured when grain was a fixed half-resolution plate and the radius followed height: grain stayed
about one output pixel, 1.7× coarser relative to the picture at 960 than at 1920. Both now scale
with the short edge against 1080 (`grain_plate`, `delivery_image_chain`). About 1.6
of each sharpen RMS is sky noise and encode disagreement.

## Tone shaping

A generated 1D LUT (`make-tone-lut.py`) rather than `curves`, because `curves` is a cubic spline and
overshoots. The curve is applied to luma and the original chroma is kept, via `mergeplanes`
(ADR 0003). A per-channel curve turns saturated signage *neon*.

- Contrast pivoted below the image's average brightens it. The generator applies `--gamma` first,
  to bring the level down to the pivot.
- Luma-only shaping raises apparent saturation as it darkens: red purity went 0.33 / 0.30 / 0.27 at
  gamma 1.85 / 1.95 / 2.05. Gamma is the dial between "darker" and "less neon".
- `format=yuv444p10le` on both `mergeplanes` branches is required. Without it the error is a bare
  `Invalid argument`.

## Where the picture is lost

One frame of IMG_0625 through the shipped rendering, each stage measured on its own as PSNR in dB
against the same frame carried in 16 bits. Higher is better; the delivery step dominates everything
upstream of it.

| Stage | dB | What it means |
|---|---|---|
| 4:2:0 against 4:4:4, 8-bit | 42.3 vs 48.9 | chroma subsampling is the largest single loss, and no delivery format avoids it |
| H.264 CRF 18, 8-bit | 38.2 | the shipped encode, subsampling included |
| HEVC CRF 18, 10-bit | 40.7 | `DELIVERY_CODEC=hevc10`, +2.5 dB for a similar bitrate |
| 1080p against the 4K master | 38.0 vs 40.1 | `HEIGHT=3840` delivers the full frame, at 2.4x the file |
| the 65-point cube against the rendering it samples | mean 0.16, worst 8.5 code values | the conversion itself is no longer a bottleneck |

Rejected on these numbers: subsampling chroma in 16 bits before the dither rather than after it
(0.02 dB on the real chain, against 1.35 dB on a synthetic 8-bit input — the gain was the test's,
not the chain's).

## Tried and rejected

- **Colour correction toward spec.** Apple's cube landed the colour on its own: traffic blue
  measured B/G 1.99 against a 1.98 spec with nothing applied, and every correction tried moved a
  reference off spec. The flatness was tone, not colour. Measured on one shoot's signage.
- **The filmic route** (log → linear → filmic → Rec.709). It gave a better
  tone range, but lost on colour. A per-channel curve cannot do a BT.2020 gamut matrix, so it
  desaturated, and the compensating saturation overshot blue to 2.45.
- **Apple's `AppleLogToRec709` cube, and grading after it.** It lands log 0.75–1.0 on output
  0.89–1.0, so anything after it works on highlights already squeezed; a scene-referred rendering
  of the same frame measured 38% more sky contrast at matched colour. Its licence also forbade
  redistribution, so every install had to fetch it by hand. Dropped: `luts/rendering/neutral.cube`
  renders the log picture instead (`scripts/make-rendering-lut.py`), and the film cubes do the same
  through a stock.
- **A hard gamut fit** (scale chroma back only once a colour crosses the Rec.709 boundary). It
  leaves a kink exactly where it engages: along a ramp into saturated green the rendering stepped
  10.5× its own average there, and a 65-point cube cannot carry that shape — tetrahedral
  interpolation read up to 23 code values from the exact rendering, against 8.5 once the fit eased
  smoothly toward the boundary instead.
- **A two-point scanner balance** (mid grey and +2 stops) left a stock's fogged toe magenta. The
  scan balances every channel onto the green layer's grey curve, then adds back crossover measured
  from −5 stops and mid grey.
- **Other denoisers for the log denoise.** `hqdn3d` chroma tinted static colour and smeared red
  while panning; `nlmeans`, `removegrain` and `dctdnoiz` negotiate 8-bit.
- **A uniform saturation boost.** `hue=s` 1.2→1.3 took red purity from 0.33 to 0.22: neon again. A
  multiplier amplifies whatever is already most saturated.
- **`curves` with more than about 3 uneven points.** The spline overshoots above identity: a
  5-point "darken shadows" curve made the image brighter (YAVG 666 → 670).
- **A wrong conversion matrix after the LUT.** Tested with and without
  `setparams=colorspace=bt709` after the cube: brick R−B 3.5 against 3.2. Not the cause of
  desaturation.
- **Warmth as a correction.** Locked white balance neutralises golden-hour light at capture. Adding
  warmth back is a creative choice that moves references off spec, not a fix. Lock white balance
  warm at capture to keep it.
- **A range mismatch as the cause of "too bright".** Ruled out: the tags are consistent and the
  pixel values are inside TV range. The brightness was the Portra LUT's lifted shadows.

## Filters

Check every new filter with `-v debug`, looking for `picking yuv...`, and measure its output.

- **`eq`: banned.** It has no 10-bit path, so ffmpeg silently inserts an 8-bit conversion. The
  give-away was YAVG going 622 → 156, which is the same picture on an 8-bit scale.
- **`colorlevels`: banned.** It produces a solid-black frame on this input.
- **Safe at 10 bits:** `curves` (3 points or fewer), `hue=s`, `vibrance`, `colorchannelmixer`.
  `colorbalance` goes through RGB.
- **An untagged branch poisons the graph.** A `lavfi` source or `mergeplanes` output has no colour
  tags, and `zscale` then fails with `code 3074: no path between colorspaces` on a *different*
  branch several filters upstream. Tag synthesised branches with `setparams`. Bisecting single
  filters finds nothing, because only the pairing fails.
- **Dither at the 10→8 reduction, not after a blend.** `format=yuv420p` and `-sws_dither ed` are
  byte-identical, so only `zscale` dithers.
- **Preview vs render with a print.** The preview resamples and then grades; the render grades and
  then resamples. On IMG_0607 the two orders differ by 19 code values at the 99.9th percentile
  without a print, and by 49 with the 2383 print. The print roughly doubles edge contrast.

## Shell mistakes that destroyed output

- **An unconditional `mv` after an `ffmpeg` that failed** moved a 0-byte file over a finished
  export. Check `[ -s "$OUT" ]` or the exit status first.
- **`-map 0` copies the ProRes timecode data track,** which mp4 cannot hold. Map
  `0:v:0` and `0:a:0?` explicitly.

## Disk space policy

A clip's baseline and master together are 4.6 GB. Keep them only while that clip is being worked
on, and regenerate them from `src/` if a finished clip needs re-grading. A master takes 10–15
minutes to regenerate, so don't delete it the moment finals are exported.

## Measurement cookbook

Measure before forming an opinion about an image. Several confident visual calls here were wrong.

Tonal stats (10-bit, 0–1023; TV black is 64 and white 940). Add `crop=W:H:X:Y,` to measure one
region:

```bash
ffmpeg -i FILE -frames:v 1 -vf "signalstats,metadata=print" -f null - 2>&1 \
  | grep -E "YMIN=|YAVG=|YMAX=" | head -3
```

`-v info` is required: `metadata=print` and `showinfo` log at INFO.

Average RGB of a patch:

```bash
ffmpeg -y -i FILE -frames:v 1 -vf "crop=300:300:1500:600" -pix_fmt rgb24 -f rawvideo /tmp/p.raw
python3 -c "
d=open('/tmp/p.raw','rb').read(); n=len(d)//3
print('R %.1f G %.1f B %.1f'%(sum(d[0::3])/n,sum(d[1::3])/n,sum(d[2::3])/n))"
```

For a saturated reference (a sign, a plate), average only the top 20–30% of pixels by target hue.
Crop the patch to a PNG and look at it before trusting the number. Measure the decoded frame, never
the container: this camera stores rotation as a display-matrix flag.

The negotiated pixel format:

```bash
ffmpeg -i FILE -frames:v 1 -vf "SOMEFILTER" -f null - -v debug 2>&1 | grep -oE "picking yuv[0-9a-z]+"
```

Whether two renders differ: `md5` the raw output. That is how `-sws_dither ed` was shown to be a
no-op.

Filter cost: compare single-threaded CPU time, never wall clock. This Intel laptop throttles.

```bash
ffmpeg -benchmark -threads 1 -filter_threads 1 -filter_complex_threads 1 \
  -i FILE -frames:v 24 -vf "SOMEFILTER" -f null - 2>&1 | grep -oE "utime=[0-9.]+s"
```
