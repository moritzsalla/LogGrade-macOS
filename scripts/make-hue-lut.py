#!/usr/bin/env python3
"""
Generate a 3D .cube LUT for the hue curves: hue against hue, hue against saturation and hue against
lightness, the per-colour controls a grading app gives as three curves.

WHAT IT ACTS ON. Display-referred Rec.709 code values (BT.1886, gamma 2.4), after the conversion,
the film look and the print, and before the tone curve: the colours as the stock rendered them, so
"the greens" means the greens on screen. The tone stage that follows is luma-only and merges this
stage's chroma back unchanged.

WHY OKLAB. Hue is read and turned in Oklab, whose hue angle holds perceived hue as lightness and
chroma change: an HSV hue curve moves a dark green and a bright one by visibly different amounts.

THE CURVES. Each is 12 values, one every 30 degrees of Oklab hue starting at 0 (roughly pink-red; 60
orange-yellow, 120-150 green, 240-270 blue), joined by a periodic uniform Catmull-Rom spline. Local
on purpose: moving one knot bends only the two spans either side of it, so pulling the greens down
cannot shift the blues, which a global cubic spline did by overshooting between knots.

    rot  degrees added to the hue, -60..60
    sat  chroma gain minus one, -1..1 (-1 removes the colour, 1 doubles it)
    lum  lightness gain minus one, -0.5..0.5

A COLOUR WITH LITTLE CHROMA HAS NO HUE TO SPEAK OF, so every move fades in with chroma (a smoothstep
from 0 to 0.08): a grey cannot turn green because the green knot moved, and a near-grey does not
flicker between the hues its noise lands on.

OUT OF GAMUT, chroma gives way at constant lightness and hue until the colour fits, rather than each
channel clipping, which shifts hue and flattens saturated gradation.

USAGE
    ./make-hue-lut.py OUT.cube --rot R0,..,R11 --sat S0,..,S11 --lum L0,..,L11 [--size 33]
    ./make-hue-lut.py --stdout ...
    ./make-hue-lut.py --check-neutral ...   prints neutral or active, writes nothing

HueCube.swift is a transcription of this file, held to it number for number by HueCubeTests: change
both or neither.
"""
import argparse
import math
import os
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from cubefile import is_current, number, title, write_staged  # noqa: E402

KNOTS = 12
SPAN = 360.0 / KNOTS
# Linear Rec.709 to LMS, and LMS' to Lab: Oklab's published matrices.
M1 = ((0.4122214708, 0.5363325363, 0.0514459929),
      (0.2119034982, 0.6806995451, 0.1073969566),
      (0.0883024619, 0.2817188376, 0.6299787005))
M2 = ((0.2104542553, 0.7936177850, -0.0040720468),
      (1.9779984951, -2.4285922050, 0.4505937099),
      (0.0259040371, 0.7827717662, -0.8086757660))


def inverse(m):
    """Computed, not the inverses Oklab publishes, which are rounded to ten places: a round trip
    must return an untouched colour, and near black the 1/2.4 power turns a 1e-6 linear error
    into most of a code value."""
    (a, b, c), (d, e, f), (g, h, i) = m
    det = a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g)
    return ((e * i - f * h) / det, (c * h - b * i) / det, (b * f - c * e) / det),\
           ((f * g - d * i) / det, (a * i - c * g) / det, (c * d - a * f) / det),\
           ((d * h - e * g) / det, (b * g - a * h) / det, (a * e - b * d) / det)


M1I = inverse(M1)
M2I = inverse(M2)
CHROMA_FADE = 0.08
LIMITS = {"rot": 60.0, "sat": 1.0, "lum": 0.5}
FIT_STEPS = 18
DISPLAY_GAMMA = 2.4
GAMUT_EPSILON = 1e-9


def curve_values(s, name):
    parts = s.split(",")
    if len(parts) != KNOTS:
        raise argparse.ArgumentTypeError("--%s wants %d values: %r" % (name, KNOTS, s))
    try:
        values = tuple(float(p) for p in parts)
    except ValueError:
        raise argparse.ArgumentTypeError("--%s is not numeric: %r" % (name, s))
    if any(not math.isfinite(v) or abs(v) > LIMITS[name] for v in values):
        raise argparse.ArgumentTypeError("--%s outside -%g..%g: %r" % (name, LIMITS[name], LIMITS[name], s))
    return values


def mul(m, v):
    return (m[0][0] * v[0] + m[0][1] * v[1] + m[0][2] * v[2],
            m[1][0] * v[0] + m[1][1] * v[1] + m[1][2] * v[2],
            m[2][0] * v[0] + m[2][1] * v[1] + m[2][2] * v[2])


def spline(knots, hue):
    """Periodic uniform Catmull-Rom through the knots, at a hue in degrees."""
    x = (hue % 360.0) / SPAN
    i = int(math.floor(x))
    t = x - i
    p0, p1, p2, p3 = (knots[(i - 1) % KNOTS], knots[i % KNOTS],
                      knots[(i + 1) % KNOTS], knots[(i + 2) % KNOTS])
    return 0.5 * (2.0 * p1 + (p2 - p0) * t + (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * t * t
                  + (3.0 * p1 - p0 - 3.0 * p2 + p3) * t * t * t)


def cube_root(v):
    return math.copysign(abs(v) ** (1.0 / 3.0), v)


def to_linear(lab):
    lms = mul(M2I, lab)
    return mul(M1I, (lms[0] ** 3, lms[1] ** 3, lms[2] ** 3))


def in_gamut(rgb):
    # A tolerance, or the round trip's own 1e-17 of error puts an untouched primary "out of gamut"
    # and the fit desaturates it: the gamut is not convex along a hue line near its corners.
    return all(-GAMUT_EPSILON <= c <= 1.0 + GAMUT_EPSILON for c in rgb)


def shape(rgb, a):
    """One triple of display code values in, one out."""
    lin = tuple(max(0.0, c) ** DISPLAY_GAMMA for c in rgb)
    lms = mul(M1, lin)
    L, A, B = mul(M2, (cube_root(lms[0]), cube_root(lms[1]), cube_root(lms[2])))
    C = math.sqrt(A * A + B * B)
    f = min(1.0, C / CHROMA_FADE)
    fade = f * f * (3.0 - 2.0 * f)
    if fade == 0.0:
        return rgb
    hue = math.atan2(B, A) * 180.0 / math.pi
    turned = (hue + fade * spline(a.rot, hue)) * math.pi / 180.0
    chroma = C * max(0.0, 1.0 + fade * spline(a.sat, hue))
    L = L * max(0.0, 1.0 + fade * spline(a.lum, hue))
    lin = to_linear((L, chroma * math.cos(turned), chroma * math.sin(turned)))
    if not in_gamut(lin):
        lo, hi = 0.0, 1.0
        for _ in range(FIT_STEPS):
            mid = (lo + hi) / 2.0
            k = chroma * mid
            if in_gamut(to_linear((L, k * math.cos(turned), k * math.sin(turned)))):
                lo = mid
            else:
                hi = mid
        k = chroma * lo
        lin = to_linear((L, k * math.cos(turned), k * math.sin(turned)))
    return tuple(min(1.0, max(0.0, c)) ** (1.0 / DISPLAY_GAMMA) for c in lin)


def is_neutral(a):
    return all(v == 0.0 for v in a.rot + a.sat + a.lum)


def fingerprint(a):
    return title("Hue curves (rot=%s sat=%s lum=%s size=%d)" % (
        ",".join(number(v) for v in a.rot), ",".join(number(v) for v in a.sat),
        ",".join(number(v) for v in a.lum), a.size))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("out", nargs="?", help="file to write; omit it and pass --stdout instead")
    ap.add_argument("--stdout", action="store_true")
    zero = ",".join(["0"] * KNOTS)
    for name in ("rot", "sat", "lum"):
        ap.add_argument("--" + name, type=lambda s, n=name: curve_values(s, n), default=curve_values(zero, name))
    ap.add_argument("--size", type=int, default=33, help="cube points per axis, 2..64")
    ap.add_argument("--check-neutral", action="store_true")
    a = ap.parse_args()
    if a.check_neutral:
        print("neutral" if is_neutral(a) else "active")
        return
    if a.stdout == bool(a.out):
        ap.error("pass exactly one of OUT or --stdout")
    if a.size < 2 or a.size > 64:
        ap.error("--size outside 2..64")
    if not a.stdout and is_current(a.out, fingerprint(a)):
        print("%s is already current" % a.out)
        return
    n = a.size
    lines = [fingerprint(a), "", "LUT_3D_SIZE %d" % n, ""]
    for bi in range(n):
        b = bi / (n - 1)
        for gi in range(n):
            g = gi / (n - 1)
            for ri in range(n):
                o = shape((ri / (n - 1), g, b), a)
                lines.append("%.8f %.8f %.8f" % (o[0], o[1], o[2]))
    if a.stdout:
        sys.stdout.write("\n".join(lines) + "\n")
        return
    write_staged(a.out, "\n".join(lines) + "\n")
    print("wrote %s (%d-point 3D LUT)" % (a.out, n))


if __name__ == "__main__":
    main()
