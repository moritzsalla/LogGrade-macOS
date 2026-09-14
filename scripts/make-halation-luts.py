#!/usr/bin/env python3
"""
Generate the four 1D .cube LUTs the halation stage runs on.

WHAT HALATION IS, AND WHY IT RUNS BEFORE APPLE'S CONVERSION
-----------------------------------------------------------
On film, light that passes through the emulsion reflects off the film base and exposes the red-
sensitive layer a second time, a little way from where it landed. Bright things grow a warm glow
into whatever dark surrounds them. It is the single most recognisable film artefact, and a cube
cannot do it: it is spatial.

Light adds in LINEAR light, so the glow is computed and added there — decoded from Apple Log with
the published transfer function, before Apple's conversion compresses twelve stops onto a display
ceiling. Added after the conversion, a sky and a white car would contribute the same glow, because
both were already landed on 1.0. See docs/adr/0012_HALATION_IN_LINEAR_BEFORE_THE_CONVERSION.md.

THE GLOW IS AT EDGES ONLY: blur(highlight) - highlight, clamped at zero
------------------------------------------------------------------------
Blurring the highlights and adding the whole blur was tried first and rejected by eye: a large
bright area adds glow to itself, so an overcast sky turned uniformly pink. A uniform field's own
halation is baked into a film stock's measured response, so what the eye reads as halation is only
the part that spills past an edge. Subtracting the unblurred highlight keeps exactly that part.

THE FOUR FILES, AND THE ffmpeg TRAPS EACH ONE IS SHAPED AROUND
--------------------------------------------------------------
applelog-to-linear.cube   Apple Log -> linear, OFFSET BY -R0 so it is never negative.
linear-to-applelog.cube   the inverse, over a domain of 0..16.
    `lut1d` ignores a negative DOMAIN_MIN: it indexes the table as if the domain started at zero, so
    a cube declaring -0.056..16 was read shifted by 0.056 and the round trip came back 20 code values
    out. Apple Log's toe does go negative (decode(0) = R0), so the linear values carry +(-R0) instead
    and every operation on them is one that an offset passes through: a blur, a weighted sum whose
    weights add to one, and adding a glow that has no offset of its own. Measured round trip through
    both, into Apple's conversion, against the same float path without them: 0.02 code values worst.
halation-threshold.cube   Apple Log -> max(0, linear - threshold), per channel.
nonnegative.cube          identity over 0..16, which clamps the edge-only subtraction at zero.
    Every value past 1.0 has to survive the stage, and several filters that look suitable clamp
    there in float: `blend` addition, `avgblur`, `boxblur`. The builder in lib.sh uses `mix` and
    `gblur` because both were measured not to.

65536 entries for the two transfer cubes. It is not caution: at 4096, linear interpolation across
the log curve's steepest region costs about half a 10-bit code value, and the files are generated
once per threshold and cached.

USAGE
    ./make-halation-luts.py OUT_DIR --threshold 1.0
    ./make-halation-luts.py --check-neutral --strength 0

    --threshold  linear scene reflectance above which light contributes glow, per channel. 1.0 is
                 diffuse white; 18% grey is 0.18.
    --strength   only read by --check-neutral. 0 is neutral, and the caller leaves the whole stage
                 out of the graph — which is what keeps a default render byte-identical to the
                 precursor's, since even an idle float round trip moves the picture by 0.23 code
                 values on average against the 10-bit path.
"""
import argparse
import os
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from applelog import R0, decode, encode  # noqa: E402
from cubefile import is_current, number, title, write_staged  # noqa: E402

TRANSFER_SIZE = 65536
SMALL_SIZE = 4096
# Headroom over decode(1.0) - R0 = 12.06, so a glow added on top of the brightest source value is
# still inside the table rather than clamped before it is encoded. Anything past 12 encodes above
# 1.0, which Apple's conversion clamps anyway.
LINEAR_MAX = 16.0

VERSION = "halation-luts v1"


def row(v):
    return "%.8f %.8f %.8f" % (v, v, v)


def cube(heading, size, domain_max, fn):
    """The whole file as a string, TITLE first — see cubefile.py."""
    lines = [title(heading), "", "LUT_1D_SIZE %d" % size]
    if domain_max != 1.0:
        lines += ["DOMAIN_MIN 0 0 0", "DOMAIN_MAX %g %g %g" % (domain_max, domain_max, domain_max)]
    lines.append("")
    for i in range(size):
        lines.append(row(fn(domain_max * i / (size - 1))))
    return "\n".join(lines) + "\n"


def files(threshold):
    """Every file this generator owns, as (name, title, size, domain max, function). Titles carry
    what each was built from, so a changed threshold regenerates only the cube that depends on it."""
    return [
        ("applelog-to-linear.cube", "%s: Apple Log to linear, offset by -R0" % VERSION,
         TRANSFER_SIZE, 1.0, lambda p: decode(p) - R0),
        ("linear-to-applelog.cube", "%s: linear offset by -R0 to Apple Log" % VERSION,
         TRANSFER_SIZE, LINEAR_MAX, lambda x: min(1.0, encode(x + R0))),
        ("halation-threshold.cube", "%s: threshold=%s" % (VERSION, number(threshold)),
         SMALL_SIZE, 1.0, lambda p: max(0.0, decode(p) - threshold)),
        ("nonnegative.cube", "%s: clamp below zero" % VERSION,
         SMALL_SIZE, LINEAR_MAX, lambda x: x),
    ]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("out", nargs="?", help="directory to write the four cubes into")
    ap.add_argument("--threshold", type=float, default=1.0)
    ap.add_argument("--strength", type=float, default=0.0)
    ap.add_argument("--check-neutral", action="store_true",
                    help="print neutral or active for --strength and exit, writing nothing")
    a = ap.parse_args()
    # The rule lives with the parameters, as make-correct-lut.py's does, rather than being
    # reimplemented in shell where it would be a second definition.
    if a.check_neutral:
        print("neutral" if a.strength == 0.0 else "active")
        return
    if not a.out:
        ap.error("pass OUT_DIR, or --check-neutral")
    if a.threshold < 0.0 or a.threshold >= LINEAR_MAX:
        ap.error("--threshold outside 0..%g" % LINEAR_MAX)

    os.makedirs(a.out, exist_ok=True)
    wrote = []
    for name, text, size, domain_max, fn in files(a.threshold):
        path = os.path.join(a.out, name)
        if is_current(path, title(text)):
            continue
        write_staged(path, cube(text, size, domain_max, fn))
        wrote.append(name)
    print("wrote %s" % ", ".join(wrote) if wrote else "%s is already current" % a.out)


if __name__ == "__main__":
    main()
