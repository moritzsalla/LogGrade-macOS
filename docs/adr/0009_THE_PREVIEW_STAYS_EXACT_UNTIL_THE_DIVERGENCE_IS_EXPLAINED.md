# The whole chain runs in the app, and every control is live

The title records an older decision; the README links this filename. What the app does today:

`FRAME_STAGE=source` gives the decoded Apple Log frame with no chain applied, resampled exactly as a
graded frame is. `GradeKit/LiveChain.swift` puts it through the correction, Apple's conversion and
the film look, then hands it to `LiveGrade` for the tone curve and the trims. The source frame does
not depend on the look, so it is fetched once per clip and timecode. Starting from an already
converted frame made the correction stage impossible to preview, so don't go back to that.

**Against the engine's render of IMG_0607 at the shipped look: 1.28 code values mean, 13 at the
99.9th percentile, 56 at the worst pixel.** The worst pixels sit on hard edges, because the preview
resamples and then grades while the render grades and then resamples. The test therefore asserts on
the percentile.

## Cost per control change (270×480, release build)

| what moved | cost |
|---|---|
| midtone, contrast, saturation, warmth | 4.1ms |
| exposure, white balance, the CDL, the film look | 15.3ms |

No subprocess is on that path. Three generators were transcribed into Swift, and each is held by an
exact-equivalence test, not a tolerance:

- **`CorrectionCube`** replaces a 419ms `make-correct-lut.py` call (1.4ms). All 107,811 numbers
  agree to the last `Float` unit.
- **`ToneCurve.generated`** replaces `make-tone-lut.py` (~100ms → 0.12ms), across all 4096 entries.
- **The exposure meter** is the engine's: the app reads what `grade.sh` metered off the event
  stream rather than measuring the frame twice, and adds it to the correction exactly as the render
  does (`LiveChainTests`).

The cubes stay data, read from the same files the render hands to `lut3d`. `Cube3D` does tetrahedral
interpolation, and `Cube3DTests` measures it against ffmpeg on a deliberately non-smooth cube: on a
smooth cube, deleting a whole tetrahedron branch left every test green.

## A debug build is broken, not slow

The same frame takes 1.5s unoptimised against 12.7ms optimised, because bounds and overflow checks
dominate the pixel loop. `make-app.sh` builds release by default. There is no timing assertion: one
asserted 0.1s and passed in a build whose real cost was fifteen times that.
