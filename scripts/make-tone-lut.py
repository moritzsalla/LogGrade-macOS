#!/usr/bin/env python3
"""
Generate a 1D .cube LUT: a filmic S-curve applied in DISPLAY space (Rec.709 in, Rec.709 out).

WHY THIS AND NOT THE OTHER ONE
------------------------------
make-filmic-lut.py replaces Apple's CST entirely, doing log -> linear -> tonemap -> Rec.709. That
is the textbook-correct architecture and it produces a better *tone* response, but it lost on
*colour*: a naive BT.2020->709 matrix plus a global saturation multiplier could not match Apple's
CST, which lands the standardised traffic-blue at B/G 1.97 against a 1.98 spec while keeping more
brick separation. Apple's gamut handling is better than anything hand-rolled here.

So: keep Apple's CST for colour, and do the tone shaping afterwards with this. Display-space
shaping cannot recover highlight detail the CST already compressed, but the CST does not clip
(measured YMAX 884/1023 on this footage), so there is room to work.

Why a generated 1D LUT rather than ffmpeg's `curves` filter: `curves` interpolates control points
with a cubic spline that overshoots past identity when the slope between segments is uneven —
this pipeline hit that twice, once producing an image *brighter* than the uncorrected version.
A 4096-entry 1D LUT is evaluated exactly, with no interpolation surprises.

Apply with ffmpeg's `lut1d` filter.

USAGE
    ./make-tone-lut.py OUT.cube [--pivot 0.42] [--contrast 1.25]
                                [--toe 0.30] [--shoulder 0.30] [--black 0.0]
    ./make-tone-lut.py --stdout [--pivot ...]      same curve, written to stdout

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

SIZE = 4096


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
    """The TITLE line, which doubles as the freshness test for a generated cube.

    ensure_tone_lut used to compare the cube's mtime against look.json's. git does not preserve
    mtimes, so on every fresh clone the committed cube lands NEWER than look.json and is trusted
    forever — verified: with look.json backdated and contrast changed to 0.5, the stale 1.09 curve
    stayed in place in silence. Comparing content instead removes the whole failure class.

    The old TITLE recorded every parameter except gamma, which is the one that was re-tuned, so a
    committed cube could not be traced to the gamma it was built at.
    """
    return (
        'TITLE "Filmic tone shaping '
        f"(gamma={a.gamma} pivot={a.pivot} contrast={a.contrast} "
        f'toe={a.toe} shoulder={a.shoulder} black={a.black})"'
    )


def is_current(path, a):
    """True when `path` already encodes exactly these parameters.

    The format lives here, in one place, rather than being reimplemented in shell — a second copy
    of a fingerprint format is just the drift it exists to detect, one level down.
    """
    try:
        with open(path) as fh:
            return fh.readline().rstrip("\n") == fingerprint(a)
    except OSError:
        return False


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("out", nargs="?", help="file to write; omit it and pass --stdout instead")
    ap.add_argument("--stdout", action="store_true", help="write the cube to stdout")
    ap.add_argument("--gamma", type=float, default=1.0)
    ap.add_argument("--pivot", type=float, default=0.42)
    ap.add_argument("--contrast", type=float, default=1.25)
    ap.add_argument("--toe", type=float, default=0.30)
    ap.add_argument("--shoulder", type=float, default=0.30)
    ap.add_argument("--black", type=float, default=0.0)
    a = ap.parse_args()
    # Exactly one destination. Both together would be ambiguous about which one the caller reads,
    # and neither is the no-argument case that used to die on a bare positional.
    if a.stdout == bool(a.out):
        ap.error("pass exactly one of OUT or --stdout")

    # Idempotent by design, so callers can invoke it unconditionally and drop their own staleness
    # logic. Generating the 4096-entry table costs ~0.1s, so there is nothing to save by guessing.
    # There is nothing to compare against on the stdout path: the caller asked for the curve, not
    # for a file that might already hold it.
    if not a.stdout and is_current(a.out, a):
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

    # Write then rename, never write in place. is_current() above reads only the TITLE line, so a
    # file truncated by an interrupted or short write keeps a valid-looking fingerprint and is
    # treated as current forever — silently grading every clip through a partial curve. Staging
    # makes a half-written cube impossible to observe. Same failure class 00-stabilise-detect.sh
    # guards with its .partial file, one layer down.
    # The cube itself goes to stdout and the commentary to stderr. A progress line mixed into the
    # curve would be read as a table entry by whatever is parsing it.
    if a.stdout:
        sys.stdout.write("\n".join(lines) + "\n")
        print(f"wrote {SIZE}-entry 1D LUT to stdout", file=sys.stderr)
        return

    partial = a.out + ".partial"
    try:
        with open(partial, "w") as fh:
            fh.write("\n".join(lines) + "\n")
        os.replace(partial, a.out)
    except BaseException:
        if os.path.exists(partial):
            os.unlink(partial)
        raise
    print(f"wrote {a.out} ({SIZE}-entry 1D LUT)")


if __name__ == "__main__":
    main()
