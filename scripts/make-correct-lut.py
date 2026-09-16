#!/usr/bin/env python3
"""
Generate a 3D .cube LUT for the input-correction stage: exposure, white balance and an ASC CDL
(slope/offset/power, which is what a colourist's lift/gamma/gain wheels are), with a luminance mix.

WHY A GENERATED CUBE RATHER THAN FILTERS
----------------------------------------
ffmpeg has no filter for this. `eq` is banned in this pipeline because it silently negotiates an
8-bit format, `colorlevels` was measured to flatten this input, and `colorbalance` is a
midtone-weighted RGB trim, not a CDL. Writing the maths here instead keeps it in one place that the
parity golden can drive directly, and leaves the render chain a `lut3d` like the two it already has.

WHY IT RUNS BEFORE APPLE'S CONVERSION, AND WHAT THAT MEANS
----------------------------------------------------------
Apple Log decodes to linear values up to 12.0, twelve times diffuse white (about 3.6 stops above it);
the Rec.709 conversion lands that on a display ceiling of 1.0. A correction applied AFTER the conversion therefore works on display-referred
pixels and clips highlights the log still holds. Applied before it, the same move is a log-domain
correction — which is what a colourist's log wheels are, and the standard managed-colour order:
correct in a wide space, display-transform last.

So the input and output of this cube are Apple Log code values. Exposure and white balance are
LINEAR operations, so they are done in linear: decoded with Apple's own published transfer function,
scaled, and re-encoded. The CDL is applied to the log values, where slope and offset behave the way
a wheel expects.

THE TRANSFER FUNCTION IS PUBLISHED, WHICH IS WHY THIS IS EXACT RATHER THAN FITTED
--------------------------------------------------------------------------------
Apple's Log Profile white paper gives the encoding and its inverse. It lives in scripts/applelog.py,
because the halation stage needs the same function and a second copy is one that drifts.
Note what is still NOT published: the Rec.709 conversion cube contains a display rendering, so
nothing here attempts to replace it.

WHAT IS APPROXIMATE, STATED RATHER THAN HIDDEN
----------------------------------------------
White balance is per-channel linear gain in the camera's own primaries. That is not a chromatic
adaptation transform: a proper one would adapt through a cone space with a Bradford matrix, and
would hold hues better at large corrections. Gain is what most simple tools do and it is honest at
small corrections. If large white-balance moves ever matter, that is the thing to replace.

USAGE
    ./make-correct-lut.py OUT.cube [--exposure 0] [--temp 0] [--tint 0]
                                   [--slope 1,1,1] [--offset 0,0,0] [--power 1,1,1]
                                   [--lum-mix 1] [--contrast 1] [--saturation 1] [--size 33]
    ./make-correct-lut.py --stdout ...          same cube, to stdout

    --exposure  stops, applied in linear. +1 is one stop brighter.
    --temp      warm/cool. Positive warms: gain up on red, down on blue.
    --tint      green/magenta. Positive goes green.
    --slope     per-channel multiply in log (gain wheel), as R,G,B.
    --offset    per-channel add in log (lift wheel), as R,G,B.
    --power     per-channel exponent in log (gamma wheel), as R,G,B. Applied as 1/power so that
                >1 lifts midtones, matching which way a gamma wheel turns.
    --lum-mix   1 keeps the per-channel result as computed. 0 restores the original luma, so the
                move becomes chroma-only. Resolve carries this control for the same reason: a
                per-channel move shifts saturation as a matter of arithmetic.
    --contrast  slope in log about mid grey's code value, so mid grey holds and each stop either side
                moves by the factor. >1 increases contrast.
    --saturation chroma about luma, in log. >1 increases saturation.
    --size      cube points per axis, 33 by default, 2..64.

WHY CONTRAST AND SATURATION ARE HERE, BEFORE THE RENDERING
----------------------------------------------------------
They are the panel's trims, and they used to act on the finished picture, after the preset's cube.
There a contrast push fought the rendering: the cube had already rolled highlights into its
shoulder, and a display-space curve pushed them back out towards clip. Done in log, before the
cube, the same move widens or narrows the scene the cube receives, and the cube's own shoulder and
toe shape the result, which is how contrast and saturation in a colourist's log working space
behave. They follow the luminance mix, which would otherwise undo the contrast.

MEASURED, so the defaults are not guesses
-----------------------------------------
encode(decode(p)) round-trips to 8e-17 across 0..1, and decode(1.0) is 12.0000 — twelve times
diffuse white, the headroom the Rec.709 conversion has to land on a display ceiling of 1.0. The
published formula is exact rather than fitted.

Generation cost and worst trilinear error against the exact function, sampled at 4000 random
points, in 8-bit code values. The size-65 column is one past the cap --size now enforces, so it
cannot be reproduced through this CLI as it stands:

    correction              size 17      size 33      size 65
    exposure +1, temp 0.5   3.69         1.62         -
    a strong CDL            2.18         0.96         -
    all of it, lum_mix 0    6.27         4.59         3.20
    generation              0.016s       0.11-0.20s   1.52s

So 33 is the default: about one to two code values for an ordinary correction, and a tenth of a
second, which is inside a slider's debounce. The hard case is not grid density — going to 65 costs
eight times as much for a third less error — it is the luminance mix at 0, whose division by output
luma is not something trilinear interpolation approximates well at any practical density. Worth
knowing before blaming the cube.
"""
import argparse
import os
import sys

# The app vendors scripts/ inside a signed bundle, and a byte-cache written there would change it.
sys.dont_write_bytecode = True
# By this file's own location, not the working directory: the suite loads this module by path from
# elsewhere, where a bare import finds nothing.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from applelog import decode, encode  # noqa: E402
from cubefile import is_current, number, title, write_staged  # noqa: E402

# Rec.709 luma weights. The luminance mix needs a luma, and this cube's output is fed to Apple's
# Rec.709 conversion, so 709 weights are the ones that match what happens next.
LW = (0.2126, 0.7152, 0.0722)

# Luma below this is treated as black: the mix divides by output luma, and a ratio against a
# near-zero denominator is noise, so black is left as the per-channel result computed it.
LUMA_EPSILON = 1e-6

# The contrast pivot: mid grey (18% reflectance) as an Apple Log code value, so a contrast move
# leaves the exposure the meter set where it put it.
MID_GREY = encode(0.18)

# Temperature and tint as per-channel linear gains. The scale is chosen so that 1.0 is a large
# but not absurd correction, and the green axis moves against magenta rather than alone.
WB_SCALE = 0.30
WB_TINT_BLUE = 0.15
# No white-balance gain goes below this, so an extreme temp/tint cannot zero or invert a channel.
# CorrectionCube.swift carries the same floor under an exact-equivalence test: change both or
# neither.
WB_GAIN_FLOOR = 0.05


def triple(s, name):
    parts = s.split(",")
    if len(parts) == 1:
        parts = parts * 3
    if len(parts) != 3:
        raise argparse.ArgumentTypeError("%s wants one value or three: %r" % (name, s))
    try:
        return tuple(float(p) for p in parts)
    except ValueError:
        raise argparse.ArgumentTypeError("%s is not numeric: %r" % (name, s))


def fingerprint(a):
    """The TITLE line, which doubles as the freshness test — see cubefile.py."""
    return title(
        "Input correction (exposure=%s temp=%s tint=%s slope=%s offset=%s power=%s lum_mix=%s contrast=%s saturation=%s size=%d)"
        % (number(a.exposure), number(a.temp), number(a.tint),
           ",".join(number(v) for v in a.slope),
           ",".join(number(v) for v in a.offset),
           ",".join(number(v) for v in a.power),
           number(a.lum_mix), number(a.contrast), number(a.saturation), a.size)
    )


def is_neutral(a):
    """True when this correction does nothing at all.

    The caller uses it to leave the filter out of the graph entirely rather than rendering every
    pixel through a lookup that returns it unchanged. That is not only cheaper: an identity 3D cube
    would pay interpolation error on every pixel.
    """
    return (a.exposure == 0.0 and a.temp == 0.0 and a.tint == 0.0
            and a.slope == (1.0, 1.0, 1.0) and a.offset == (0.0, 0.0, 0.0)
            and a.power == (1.0, 1.0, 1.0)
            and a.contrast == 1.0 and a.saturation == 1.0)


def correct(rgb, a, wb):
    """One triple of Apple Log code values in, one out."""
    # Exposure and white balance are linear operations, so they happen in linear.
    lin = [decode(v) for v in rgb]
    if a.exposure != 0.0:
        k = 2.0 ** a.exposure
        lin = [v * k for v in lin]
    if wb != (1.0, 1.0, 1.0):
        lin = [v * g for v, g in zip(lin, wb)]
    out = [encode(v) for v in lin]

    # The CDL is a log-domain operation: slope, offset, power, in that order, per ASC CDL.
    if a.slope != (1.0, 1.0, 1.0) or a.offset != (0.0, 0.0, 0.0) or a.power != (1.0, 1.0, 1.0):
        cdl = []
        for v, s, o, p in zip(out, a.slope, a.offset, a.power):
            v = v * s + o
            if v < 0.0:
                v = 0.0
            # 1/power so a gamma wheel turned up lifts midtones.
            cdl.append(v ** (1.0 / p) if p != 1.0 else v)
        out = cdl

    # The luminance mix. At 0 the original luma is restored, so what is left of the move is its
    # effect on chroma only.
    if a.lum_mix != 1.0:
        y_in = sum(w * v for w, v in zip(LW, rgb))
        y_out = sum(w * v for w, v in zip(LW, out))
        if y_out > LUMA_EPSILON:
            k = ((1.0 - a.lum_mix) * (y_in / y_out)) + a.lum_mix
            out = [v * k for v in out]

    if a.contrast != 1.0:
        out = [MID_GREY + (v - MID_GREY) * a.contrast for v in out]
    if a.saturation != 1.0:
        y = sum(w * v for w, v in zip(LW, out))
        out = [y + (v - y) * a.saturation for v in out]

    return [min(1.0, max(0.0, v)) for v in out]


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("out", nargs="?", help="file to write; omit it and pass --stdout instead")
    ap.add_argument("--stdout", action="store_true", help="write the cube to stdout")
    ap.add_argument("--exposure", type=float, default=0.0, help="stops, applied in linear")
    ap.add_argument("--temp", type=float, default=0.0, help="warm (+) / cool (-)")
    ap.add_argument("--tint", type=float, default=0.0, help="green (+) / magenta (-)")
    ap.add_argument("--slope", type=lambda s: triple(s, "--slope"), default=(1.0, 1.0, 1.0),
                    help="gain wheel: per-channel multiply in log, R,G,B")
    ap.add_argument("--offset", type=lambda s: triple(s, "--offset"), default=(0.0, 0.0, 0.0),
                    help="lift wheel: per-channel add in log, R,G,B")
    ap.add_argument("--power", type=lambda s: triple(s, "--power"), default=(1.0, 1.0, 1.0),
                    help="gamma wheel: per-channel exponent in log, applied as 1/power, R,G,B")
    ap.add_argument("--lum-mix", dest="lum_mix", type=float, default=1.0,
                    help="1 keeps the per-channel result; 0 restores the original luma")
    ap.add_argument("--contrast", type=float, default=1.0,
                    help="slope in log about mid grey; >1 more contrast")
    ap.add_argument("--saturation", type=float, default=1.0,
                    help="chroma about luma, in log; >1 more saturated")
    ap.add_argument("--size", type=int, default=33, help="cube points per axis, 2..64")
    ap.add_argument("--check-neutral", action="store_true",
                    help="print neutral or active for these parameters and exit, writing nothing")
    a = ap.parse_args()
    # The caller has to know whether this correction does anything, because a neutral one must
    # leave the filter out of the graph entirely rather than render every pixel through a lookup
    # that returns it. Answered HERE so the rule lives with the parameters rather than being
    # reimplemented in shell, where it would be the second copy of a definition.
    if a.check_neutral:
        print("neutral" if is_neutral(a) else "active")
        return
    if a.stdout == bool(a.out):
        ap.error("pass exactly one of OUT or --stdout")
    # An upper bound so a mistyped size cannot spend minutes generating: cost grows with the cube,
    # 1.52s at 65 and so roughly 45s at 200. Why the bound is 64 and not 65 is not recorded — it
    # landed in the same commit as the size-65 measurement above, and ffmpeg's lut3d is not the
    # limit, since it reads Apple's own 65-point conversion.
    if a.size < 2 or a.size > 64:
        ap.error("--size outside 2..64")
    if any(x <= 0.0 for x in a.power):
        ap.error("%s must be positive: %s" % ("--power", a.power))

    wb = (1.0 + WB_SCALE * a.temp,
          1.0 + WB_SCALE * a.tint,
          1.0 - WB_SCALE * a.temp - WB_TINT_BLUE * a.tint)
    wb = tuple(max(WB_GAIN_FLOOR, g) for g in wb)

    if not a.stdout and is_current(a.out, fingerprint(a)):
        print("%s is already current" % a.out)
        return

    n = a.size
    lines = [fingerprint(a), "", "LUT_3D_SIZE %d" % n, ""]
    # .cube order: red fastest, then green, then blue.
    for bi in range(n):
        b = bi / (n - 1)
        for gi in range(n):
            g = gi / (n - 1)
            for ri in range(n):
                r = ri / (n - 1)
                o = correct((r, g, b), a, wb)
                lines.append("%.8f %.8f %.8f" % (o[0], o[1], o[2]))

    if a.stdout:
        sys.stdout.write("\n".join(lines) + "\n")
        print("wrote %d-point 3D LUT to stdout" % n, file=sys.stderr)
        return

    write_staged(a.out, "\n".join(lines) + "\n")
    print("wrote %s (%d-point 3D LUT)" % (a.out, n))


if __name__ == "__main__":
    main()
