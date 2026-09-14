#!/usr/bin/env python3
"""
Generate a 1D .cube LUT: a filmic S-curve applied in DISPLAY space (Rec.709 in, Rec.709 out).

WHY THIS AND NOT THE OTHER ONE
------------------------------
make-filmic-lut.py replaces Apple's CST entirely, doing log -> linear -> tonemap -> Rec.709. That
is the textbook-correct architecture and it produces a better *tone* response, but it lost on
*colour*: a naive BT.2020->709 matrix plus a global saturation multiplier could not match Apple's
CST, which lands the standardised traffic-blue at B/G 1.99 against a 1.98 spec with nothing applied,
while keeping more brick separation. Apple's gamut handling is better than anything hand-rolled here.

So: keep Apple's CST for colour, and do the tone shaping afterwards with this. Display-space
shaping cannot recover highlight detail the CST already compressed, but the CST does not clip
(measured YMAX 884/1023 on this footage), so there is room to work.

Why a generated 1D LUT rather than ffmpeg's `curves` filter: `curves` interpolates control points
with a cubic spline that overshoots past identity when the slope between segments is uneven —
this pipeline hit that twice, once producing an image *brighter* than the uncorrected version.
A 4096-entry 1D LUT is evaluated exactly, with no interpolation surprises.

Apply with ffmpeg's `lut1d` filter.

USAGE
    ./make-tone-lut.py OUT.cube --gamma G --pivot P --contrast C
                                --toe T --shoulder S --black B
    ./make-tone-lut.py --stdout --gamma G ...      same curve, written to stdout

    All six tone flags are required. They used to default to 0.42/1.25/0.30/0.30, which is a
    different look from look.json's: a caller that forgot one got a plausible curve nobody chose.
    Every production caller passes all six from look.json.

    --stdout exists for the preview, which regenerates this curve on every slider move and wants
    it in memory rather than through a temp file. It is also what keeps the curve in ONE
    implementation: a caller that can spawn this does not need its own port of the maths, which
    is the third copy the parity harness could not see.

    --gamma     midtone level, applied FIRST: v = x**gamma. >1 darkens. Needed because contrast
                pivoted about a point BELOW the image's own average brightens rather than
                shapes it — this footage averages 0.65, so a 0.42 pivot alone made it brighter.
                Set gamma so the average lands near the pivot, then let contrast do the shaping.
    --pivot     tonal level held (roughly) fixed while contrast pivots around it.
    --contrast  slope at the pivot. >1 increases contrast.
    --toe       how much the shadows roll off instead of clipping. Higher = softer, more film-like
                shadow; 0 = hard linear into black.
    --shoulder  same for highlights. This is what stops bright areas going to flat paper-white.
    --black     black point lift (>0) or crush (<0), applied last.
"""
import argparse
import os
import sys

# The app vendors scripts/ inside a signed bundle, and a byte-cache written there would change it.
sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from cubefile import is_current, number, title, write_staged  # noqa: E402

SIZE = 4096
TONE_FLAGS = ("gamma", "pivot", "contrast", "toe", "shoulder", "black")


def soft(x, k):
    """Smooth compression toward 0..1 with strength k; k=0 is a no-op."""
    if k <= 0:
        return max(0.0, min(1.0, x))
    if x <= 0:
        return 0.0
    if x >= 1:
        return 1.0
    # a gentle sigmoid-ish squash that preserves the midsection
    return x + k * (x * x * (3 - 2 * x) - x)


def fingerprint(a):
    """The TITLE line, which doubles as the freshness test for a generated cube — see cubefile.py.

    The old TITLE recorded every parameter except gamma, which is the one that was re-tuned, so a
    committed cube could not be traced to the gamma it was built at.
    """
    return title(
        "Filmic tone shaping "
        f"(gamma={number(a.gamma)} pivot={number(a.pivot)} contrast={number(a.contrast)} "
        f"toe={number(a.toe)} shoulder={number(a.shoulder)} black={number(a.black)})"
    )


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("out", nargs="?", help="file to write; omit it and pass --stdout instead")
    ap.add_argument("--stdout", action="store_true", help="write the cube to stdout")
    ap.add_argument("--gamma", type=float, help="midtone level, applied first; >1 darkens (required)")
    ap.add_argument("--pivot", type=float, help="level contrast pivots about (required)")
    ap.add_argument("--contrast", type=float, help="slope at the pivot; >1 more contrast (required)")
    ap.add_argument("--toe", type=float, help="shadow roll-off; 0 is hard into black (required)")
    ap.add_argument("--shoulder", type=float, help="highlight roll-off (required)")
    ap.add_argument("--black", type=float, help="black lift (>0) or crush (<0), last (required)")
    a = ap.parse_args()
    # Exactly one destination. Both together would be ambiguous about which one the caller reads,
    # and neither is the no-argument case that used to die on a bare positional.
    if a.stdout == bool(a.out):
        ap.error("pass exactly one of OUT or --stdout")
    # Required by hand rather than with required=True, so the destination refusal above still
    # fires first and says its own words: the suite asserts it with no tone flags passed.
    missing = ["--" + k for k in TONE_FLAGS if getattr(a, k) is None]
    if missing:
        ap.error("missing %s: there is no default look, pass all six from look.json"
                 % " ".join(missing))

    # Idempotent by design, so callers can invoke it unconditionally and drop their own staleness
    # logic. Generating the 4096-entry table costs ~0.1s, so there is nothing to save by guessing.
    # There is nothing to compare against on the stdout path: the caller asked for the curve, not
    # for a file that might already hold it.
    if not a.stdout and is_current(a.out, fingerprint(a)):
        print(f"{a.out} is already current")
        return

    lines = [
        fingerprint(a),
        "",
        f"LUT_1D_SIZE {SIZE}",
        "",
    ]
    for i in range(SIZE):
        x = i / (SIZE - 1)

        # level first, then contrast pivoted about `pivot`
        v = x ** a.gamma if a.gamma != 1.0 else x
        v = (v - a.pivot) * a.contrast + a.pivot

        # roll off each end rather than clipping
        if v < a.pivot:
            t = v / a.pivot if a.pivot > 0 else 0.0
            v = soft(max(0.0, t), a.toe) * a.pivot
        else:
            span = 1.0 - a.pivot
            t = (v - a.pivot) / span if span > 0 else 0.0
            v = a.pivot + soft(max(0.0, min(1.0, t)), a.shoulder) * span

        v = v * (1.0 - a.black) + a.black
        v = max(0.0, min(1.0, v))
        lines.append(f"{v:.8f} {v:.8f} {v:.8f}")

    # The cube itself goes to stdout and the commentary to stderr. A progress line mixed into the
    # curve would be read as a table entry by whatever is parsing it.
    if a.stdout:
        sys.stdout.write("\n".join(lines) + "\n")
        print(f"wrote {SIZE}-entry 1D LUT to stdout", file=sys.stderr)
        return

    write_staged(a.out, "\n".join(lines) + "\n")
    print(f"wrote {a.out} ({SIZE}-entry 1D LUT)")


if __name__ == "__main__":
    main()
