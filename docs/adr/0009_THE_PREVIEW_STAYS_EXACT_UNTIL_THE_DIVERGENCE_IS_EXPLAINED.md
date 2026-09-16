# The whole chain runs in the app, and the preview is that grade

The title records an older decision; the README links this filename. What the app does today:

The preview is graded in-process, always: while a control moves, after a release, on selection, on a
preset or a reset, and for hold-C compare. No engine render replaces it (the 1440-line
`grade.sh FRAME` render took 2–4 s on the Intel Mac). `GradeModel` decodes the clip with
`NativeSource` at 1080 lines, meters it with the engine's own `probe_scene_exposure`
(`ExposureMeter`, keyed by clip and `match.reference_stops`), and `GradeKit/LiveChain.swift` puts it
through the correction, halation, Apple's conversion or the film look, and the hue curves, then
`LiveGrade` for the tone curve and trims. Decoded frames (8) and settled pictures (24) are cached, so
switching back to a clip neither decodes nor grades. Starting from an already converted frame made
the correction stage impossible to preview, so don't go back to that.

`PreviewRenderer` and `FRAME_STAGE=source|graded` stay: they are what the tests hold the app to.

**Against the engine's render of IMG_0607 at the shipped look: mean ~1.3 code values, 99.9th
percentile 13–18, worst 56.** The worst pixels sit on hard edges, because the preview resamples and
then grades while the render grades and then resamples. `LiveChainTests` therefore asserts on the
percentile, at 480 lines and, for halation computed reduced as a 1080-line landscape preview does,
at 1920.

## Cost (Intel i7, release)

| | cost |
|---|---|
| decode, any height | 0.35–1.3 s, cached |
| colour stages, 1920x1080 | ~55 ms; ~125 ms with halation |
| colour stages, 608x1080 portrait | ~22 ms; ~128 ms with halation |
| tone and trims only | 6–25 ms |

No subprocess is on the grade path. Three generators were transcribed into Swift, and each is held
by an exact-equivalence test, not a tolerance:

- **`CorrectionCube`** replaces a 419ms `make-correct-lut.py` call (1.4ms). All 107,811 numbers
  agree to the last `Float` unit.
- **`ToneCurve.generated`** replaces `make-tone-lut.py` (~100ms → 0.12ms), across all 4096 entries.
- **The exposure meter** is the engine's function, sourced from `lib.sh` and run beside the decode
  (`NativeSourceTests`).

The cubes stay data, read from the same files the render hands to `lut3d`. `Cube3D` does tetrahedral
interpolation, and `Cube3DTests` measures it against ffmpeg on a deliberately non-smooth cube: on a
smooth cube, deleting a whole tetrahedron branch left every test green.

## A debug build is broken, not slow

The same frame takes 1.5s unoptimised against 12.7ms optimised, because bounds and overflow checks
dominate the pixel loop. `make-app.sh` builds release by default. There is no timing assertion: one
asserted 0.1s and passed in a build whose real cost was fifteen times that.
