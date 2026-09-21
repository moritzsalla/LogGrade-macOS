#!/usr/bin/env python3
"""
Generate a 3D .cube LUT that renders Apple Log to a Rec.709 display, in place of Apple's cube.

WHY THIS EXISTS. Apple's AppleLogToRec709 cube lands log 0.75-1.0 on output 0.89-1.0: it spends
most of the highlight latitude before any grade sees it, and every stage after it works on
highlights that are already squeezed. Measured against this rendering at matched colour on
IMG_0607, the sky held 38% less contrast through Apple's cube (luma sd 0.050 against 0.069). This
one is built from the published transfer function instead, so the whole range reaches the grade.
It is also redistributable, which Apple's cube was not, so a fresh clone renders with nothing
downloaded — which is why Apple's cube is gone rather than kept as an option.

NEUTRAL, NOT A LOOK. It is the app's starting point: a clip opens looking like a finished picture,
and the film presets replace it (luts/film/) when someone wants a stock. So it carries contrast and
a highlight roll-off, and no hue shaping of its own beyond what any display rendering must do.

HOW IT WORKS, in order:

  1. Apple Log -> linear BT.2020 (scripts/applelog.py, Apple's published formula). Code 1.0 decodes
     to 12.0, twelve times diffuse white.
  2. BT.2020 -> Rec.709 primaries, then an ACES-style gamut compression in scene linear, so a
     colour outside 709 is pulled in before any curve meets a negative channel.
  3. A Michaelis-Menten tone scale, solved so scene 0.18 lands on `grey` and `peak` lands on
     display white. Applied TWICE: once per channel, which is where a rendering gets its density,
     and once on a norm of the three channels, which is where it gets a hue that does not skew.
  4. The two are combined in Oklab: lightness and hue from the norm rendering, chroma the larger of
     the two, easing to the per-channel hue and to white in the last stretch before the ceiling.
     A per-channel rendering alone turns a +4-stop sky from blue to white by merging channels; a
     norm rendering alone leaves saturated colour flat and posterised.
  5. Chroma is compressed SMOOTHLY toward the gamut boundary at constant lightness and hue, rather
     than scaled back only once it has crossed it. Both keep the hue; only this one keeps the
     derivative. Measured along a ramp into saturated green, a hard fit stepped 10.5x its own
     average at the moment it engaged, and that kink is also what a 65-point cube cannot carry:
     tetrahedral interpolation of it read up to 23 code values from the exact rendering.

THE NUMBERS:
    --contrast  the tone scale's exponent. 1.0 is flat, 1.35 is the shipped default.
    --saturation  chroma gain on the result, 1.0 leaves it as rendered.
    --grey      where scene 0.18 lands, in display code values for Apple playback (cubefile.py).
    --peak      the scene value that reaches display white, in stops above 0.18. Apple Log's code
                1.0 decodes to 12.0, which is 6.06 stops above 0.18 and 3.6 above diffuse white, so
                anything below that clips the top of what the camera recorded.
    --black     a display black lift, in code values: a rendering's black is a flare, not a clip.

HueCube's and the correction's Swift transcriptions have exact-equivalence tests. This one does
NOT: the app reads the generated .cube, exactly as it reads Apple's and the film cubes, so there is
only ever one implementation of it.

USAGE
    ./make-rendering-lut.py OUT.cube [--contrast 1.35] [--saturation 1.05] [--grey 0.332]
                                     [--peak 6.06] [--black 0.0] [--size 65]
    ./make-rendering-lut.py --stdout ...
"""
import argparse
import math
import os
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from applelog import decode  # noqa: E402
from cubefile import display_decode, display_encode, is_current, number, title, write_staged  # noqa: E402

BT2020_TO_709 = ((1.6605, -0.5876, -0.0728),
                 (-0.1246, 1.1329, -0.0083),
                 (-0.0182, -0.1006, 1.1187))
OK_M1 = ((0.4122214708, 0.5363325363, 0.0514459929),
         (0.2119034982, 0.6806995451, 0.1073969566),
         (0.0883024619, 0.2817188376, 0.6299787005))
OK_M2 = ((0.2104542553, 0.7936177850, -0.0040720468),
         (1.9779984951, -2.4285922050, 0.4505937099),
         (0.0259040371, 0.7827717662, -0.8086757660))
# The scene value reaching display white, as a multiple of 0.18. Apple Log's own ceiling is 12.0.
GREY = 0.18
FLARE = 0.01
# Where chroma starts easing toward white, in Oklab lightness, and the gamut fit's steps.
FADE_FROM = 0.84
FIT_STEPS = 28
# Where the compression toward the gamut boundary begins, as a fraction of the boundary's own
# chroma. Below it a colour is untouched; above it it approaches the boundary and never crosses.
GAMUT_KNEE = 0.75
# THE MATHS' OWN VERSION, stamped into the TITLE beside the parameters. Freshness is by content
# here as everywhere (scripts/cubefile.py), and the parameters alone do not describe the cube: a
# change to the rendering itself left every committed cube "already current" and silently stale.
# Raise it whenever this file's output changes for unchanged parameters.
REVISION = 4
GAMUT_THRESHOLD, GAMUT_LIMIT, GAMUT_POWER = 0.9, 1.15, 1.2


def mul(m, v):
    return (m[0][0] * v[0] + m[0][1] * v[1] + m[0][2] * v[2],
            m[1][0] * v[0] + m[1][1] * v[1] + m[1][2] * v[2],
            m[2][0] * v[0] + m[2][1] * v[1] + m[2][2] * v[2])


def inverse(m):
    """Computed rather than quoted, for the reason make-hue-lut.py's copy gives."""
    (a, b, c), (d, e, f), (g, h, i) = m
    det = a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g)
    return ((e * i - f * h) / det, (c * h - b * i) / det, (b * f - c * e) / det),\
           ((f * g - d * i) / det, (a * i - c * g) / det, (c * d - a * f) / det),\
           ((d * h - e * g) / det, (b * g - a * h) / det, (a * e - b * d) / det)


OK_M1I = inverse(OK_M1)
OK_M2I = inverse(OK_M2)


def to_oklab(v):
    lms = mul(OK_M1, v)
    return mul(OK_M2, tuple(math.copysign(abs(c) ** (1.0 / 3.0), c) for c in lms))


def from_oklab(lab):
    lms = mul(OK_M2I, lab)
    return mul(OK_M1I, (lms[0] ** 3, lms[1] ** 3, lms[2] ** 3))


def tonescale(x, contrast, s0, s1):
    """Michaelis-Menten with a power, plus a flare term that gives the toe its lift."""
    x = max(0.0, x)
    y = s1 * (x / (x + s0)) ** contrast
    return y * y / (y + FLARE)


def solve_tonescale(contrast, grey_out, peak):
    """s0 and s1 so that 0.18 renders to grey_out (linear) and `peak` reaches 1.0."""
    lo, hi = 1e-4, 100.0
    for _ in range(200):
        s0 = math.sqrt(lo * hi)
        s1 = solve_peak(peak, contrast, s0)
        if tonescale(GREY, contrast, s0, s1) > grey_out:
            lo = s0
        else:
            hi = s0
    return s0, s1


def solve_peak(peak, contrast, s0):
    lo, hi = 0.5, 20.0
    for _ in range(100):
        s1 = (lo + hi) / 2.0
        if tonescale(peak, contrast, s0, s1) > 1.0:
            hi = s1
        else:
            lo = s1
    return s1


def soft_compress(d):
    """ACES reference gamut compression of one distance from the achromatic axis."""
    if d < GAMUT_THRESHOLD:
        return d
    s = ((GAMUT_LIMIT - GAMUT_THRESHOLD)
         / (((1 - GAMUT_THRESHOLD) / (GAMUT_LIMIT - GAMUT_THRESHOLD)) ** -GAMUT_POWER - 1) ** (1 / GAMUT_POWER))
    x = (d - GAMUT_THRESHOLD) / s
    return GAMUT_THRESHOLD + s * x / (1 + x ** GAMUT_POWER) ** (1 / GAMUT_POWER)


def scene_gamut_compress(v):
    ach = max(v)
    if ach <= 0.0:
        return (0.0, 0.0, 0.0)
    return tuple(ach - soft_compress((ach - c) / ach) * ach for c in v)


def render(lin, params):
    """One triple of linear BT.2020 scene values in, one triple of display code values out."""
    contrast, s0, s1, saturation, black = params
    v = scene_gamut_compress(mul(BT2020_TO_709, lin))
    per = tuple(tonescale(c, contrast, s0, s1) for c in v)
    # A SMOOTH MAX. Plain max(rgb) kinks where two channels cross, and a lightness taken from it
    # kinked with it — visible as a hue step across a bright yellow.
    norm = max((sum(max(c, 0.0) ** 4 for c in v) / 3.0) ** 0.25, 1e-8)
    scaled = tonescale(norm, contrast, s0, s1)
    hue_ref = tuple(scaled * max(c, 0.0) / norm for c in v)
    Lp, ap, bp = to_oklab(per)
    L, ha, hb = to_oklab(hue_ref)
    hh = math.hypot(ha, hb)
    hp = math.hypot(ap, bp)
    t = min(1.0, max(0.0, (L - FADE_FROM) / (1.0 - FADE_FROM)))
    fade = t * t * (3.0 - 2.0 * t)
    C = max(hh, hp) * saturation * (1.0 - fade)
    # Near white the hue follows the per-channel rendering, which drifts toward the display
    # primaries' mix the way film does; the norm hue drove a bright yellow's blue channel to zero
    # across a few code values.
    ur = (ha / hh, hb / hh) if hh > 1e-7 else (0.0, 0.0)
    up = (ap / hp, bp / hp) if hp > 1e-7 else ur
    ca, cb = ur[0] + (up[0] - ur[0]) * fade, ur[1] + (up[1] - ur[1]) * fade
    cn = math.hypot(ca, cb)
    ca, cb = (ca / cn, cb / cn) if cn > 1e-7 else (0.0, 0.0)
    L = min(L, 1.0)
    L = black + L * (1.0 - black)
    C = fit_chroma(L, C, ca, cb)
    out = from_oklab((L, C * ca, C * cb))
    return tuple(display_encode(c) for c in out)


def gamut_chroma(L, ca, cb):
    """The largest chroma that still fits in Rec.709 at this lightness and hue."""
    lo, hi = 0.0, 4.0
    for _ in range(FIT_STEPS):
        mid = (lo + hi) / 2.0
        c = from_oklab((L, mid * ca, mid * cb))
        if min(c) < -1e-9 or max(c) > 1.0 + 1e-9:
            hi = mid
        else:
            lo = mid
    return lo


def fit_chroma(L, C, ca, cb):
    """Chroma eased toward the boundary rather than cut off at it. A hard fit leaves the rendering
    with a kink exactly where it engages, which reads as a hard edge in a saturated gradient and is
    the one shape a cube cannot interpolate."""
    boundary = gamut_chroma(L, ca, cb)
    if boundary <= 0.0:
        return 0.0
    t = C / boundary
    if t <= GAMUT_KNEE:
        return C
    span = 1.0 - GAMUT_KNEE
    x = (t - GAMUT_KNEE) / span
    return boundary * (GAMUT_KNEE + span * x / (1.0 + x))


def parameters(a):
    s0, s1 = solve_tonescale(a.contrast, display_decode(a.grey), GREY * 2 ** a.peak)
    return (a.contrast, s0, s1, a.saturation, a.black)


def fingerprint(a):
    return title("Apple Log -> Rec.709 rendering rev%d (contrast=%s saturation=%s grey=%s peak=%s "
                 "black=%s size=%d)"
                 % (REVISION, number(a.contrast), number(a.saturation), number(a.grey),
                    number(a.peak), number(a.black), a.size))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("out", nargs="?", help="file to write; omit it and pass --stdout instead")
    ap.add_argument("--stdout", action="store_true")
    ap.add_argument("--contrast", type=float, default=1.35)
    ap.add_argument("--saturation", type=float, default=1.05)
    ap.add_argument("--grey", type=float, default=0.332, help="where scene 0.18 lands, in code values")
    ap.add_argument("--peak", type=float, default=6.06,
                    help="stops above 0.18 that reach display white; 6.06 is Apple Log's own ceiling")
    ap.add_argument("--black", type=float, default=0.0, help="display black lift, in code values")
    ap.add_argument("--size", type=int, default=65, help="cube points per axis, 2..65")
    a = ap.parse_args()
    if a.stdout == bool(a.out):
        ap.error("pass exactly one of OUT or --stdout")
    if a.size < 2 or a.size > 65:
        ap.error("--size outside 2..65")
    if not 0.0 < a.grey < 1.0:
        ap.error("--grey outside 0..1")
    if a.contrast <= 0 or a.saturation < 0 or a.peak <= 0 or not 0.0 <= a.black < 1.0:
        ap.error("a parameter is outside its range")
    if not a.stdout and is_current(a.out, fingerprint(a)):
        print("%s is already current" % a.out)
        return
    params = parameters(a)
    n = a.size
    # Decoded once per axis value rather than per sample: the same 65 numbers, 274,625 times.
    axis = [decode(i / (n - 1)) for i in range(n)]
    lines = [fingerprint(a), "", "LUT_3D_SIZE %d" % n, ""]
    for b in axis:
        for g in axis:
            for r in axis:
                lines.append("%.6f %.6f %.6f" % render((r, g, b), params))
    text = "\n".join(lines) + "\n"
    if a.stdout:
        sys.stdout.write(text)
        return
    write_staged(a.out, text)
    print("wrote %s (%d-point 3D LUT)" % (a.out, n))


if __name__ == "__main__":
    main()
