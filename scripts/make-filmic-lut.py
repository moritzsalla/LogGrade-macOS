#!/usr/bin/env python3
"""
Generate a 3D .cube LUT: Apple Log -> scene-linear -> filmic tonemap -> Rec.709.

NOT WHAT SHIPS. This route lost on colour to Apple's CST (docs/PIPELINE.md, "Tried and rejected").
Kept because the architecture is right and may win with proper gamut mapping.

WHY THIS EXISTS
---------------
Apple's AppleLogToRec709 LUT is a *technical* conversion: accurate, neutral, and deliberately
flat. Grading on top of its output means shaping an image whose highlights have already been
compressed into display range by someone else's tone map. Apple Log actually carries linear
values up to 12.0 (12x diffuse white, ~3.6 stops of headroom above white) and this footage uses
about 5.4x of it — all of which the technical CST squashes.

This does it the way a cinema pipeline does: decode log to scene-linear, apply a filmic tone
curve in linear (which is the only place highlight rolloff and shadow density behave correctly),
then encode to Rec.709.

The free stills-emulation LUTs are the wrong tool for this regardless of their grid size: they
emulate a photographic print of an already-developed image, not a cinema tone response applied to
scene-linear light.

It is a 3D LUT because a gamut conversion is unavoidable: Apple Log is in BT.2020 primaries and
the delivery is Rec.709, and a 3x3 matrix cannot be expressed as a per-channel curve. Skipping it
(the first attempt here was a 1D LUT) leaves everything badly under-saturated — BT.2020 numbers
read as Rec.709 desaturate, measured as brick R78 G75 B74 versus R150 G139 B133 with the matrix.
The matrix must be applied in LINEAR, between the log decode and the tone map.

Apply with ffmpeg's `lut3d` filter (interp=tetrahedral).

USAGE
    ./make-filmic-lut.py OUT.cube [--exposure 1.0] [--white 11.2]
                                  [--contrast 1.0] [--toe 0.20] [--sat 1.0]
                                  [--loglin <AppleLogToLin-v1.0.cube>]

    --exposure  linear gain before the tone curve. >1 brighter. This is the main exposure control
                and it operates in LINEAR, which is why highlights roll off instead of clipping.
    --white     linear value mapped to display white. Higher = more of the highlight headroom is
                used, gentler shoulder. 11.2 is the Hable default; lower values (~6) put more
                contrast into the midtones.
    --contrast  extra S-curve applied in display space after the tone map. 1.0 = none.
    --toe       Hable toe strength; higher = denser, more "closed" shadows.
    --sat       saturation restored AFTER the tone map. A per-channel filmic curve compresses
                each channel independently, which desaturates — badly in the highlights. This is
                the standard compensation; without it the output measures markedly flatter than
                Apple's own CST (brick R-B 8.6 vs 17.0 when first tested).
    --loglin    Apple's AppleLogToLin cube. It is not in this repo (Apple's licence), and this
                route is abandoned anyway — see docs/PIPELINE.md.
"""
import argparse
import os
import sys

SIZE = 65  # per-axis grid of the generated 3D LUT (65^3, matching Apple's own CST)

# BT.2020 -> BT.709 primaries, applied to LINEAR light.
BT2020_TO_709 = (
    ( 1.6605, -0.5876, -0.0728),
    (-0.1246,  1.1329, -0.0083),
    (-0.0182, -0.1006,  1.1187),
)

# Rec.709 luma weights: the saturation compensation runs on the Rec.709 output.
REC709_LUMA = (0.2126, 0.7152, 0.0722)


def read_apple_log_to_lin(path):
    """Apple's LogToLin is itself a 4096-entry 1D LUT; return its linear values."""
    vals = []
    with open(path) as fh:
        for line in fh:
            s = line.strip()
            if not s or s.startswith("#") or s.startswith("TITLE") or s.startswith("LUT_"):
                continue
            p = s.split()
            if len(p) == 3:
                try:
                    vals.append(float(p[0]))  # R=G=B for a transfer function
                except ValueError:
                    pass
    if not vals:
        sys.exit(f"no LUT data parsed from {path}")
    return vals


def sample(table, x):
    """Linear interpolation into a 1D table for x in [0,1]."""
    if x <= 0:
        return table[0]
    if x >= 1:
        return table[-1]
    pos = x * (len(table) - 1)
    i = int(pos)
    f = pos - i
    j = min(i + 1, len(table) - 1)
    return table[i] * (1 - f) + table[j] * f


def hable(x, A=0.15, B=0.50, C=0.10, D=0.20, E=0.02, F=0.30):
    """Hable/Uncharted2 filmic curve — a toe, a near-linear midsection and a shoulder."""
    return ((x * (A * x + C * B) + D * E) / (x * (A * x + B) + D * F)) - E / F


def rec709_oetf(v):
    """Scene-linear (display-referred, 0-1) -> Rec.709 signal."""
    v = max(0.0, min(1.0, v))
    return 4.5 * v if v < 0.018 else 1.099 * (v ** 0.45) - 0.099


def scurve(v, amount):
    """Gentle contrast S applied in display space; amount=1.0 is a no-op."""
    if amount == 1.0:
        return v
    v = max(0.0, min(1.0, v))
    # smoothstep blended with identity, scaled by amount
    s = v * v * (3 - 2 * v)
    return max(0.0, min(1.0, v + (s - v) * (amount - 1.0)))


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("out", help="file to write")
    ap.add_argument("--loglin", default=None,
                    help="path to Apple's AppleLogToLin-v1.0.cube, which this repo does not ship")
    ap.add_argument("--exposure", type=float, default=1.0,
                    help="linear gain before the tone curve; >1 brighter")
    ap.add_argument("--white", type=float, default=11.2,
                    help="linear value mapped to display white; 11.2 is the Hable default")
    ap.add_argument("--contrast", type=float, default=1.0,
                    help="display-space S-curve after the tone map; 1.0 is none")
    ap.add_argument("--toe", type=float, default=0.20, help="Hable toe strength; higher is denser")
    ap.add_argument("--sat", type=float, default=1.0,
                    help="saturation restored after the tone map; 1.0 is none")
    a = ap.parse_args()

    loglin_path = a.loglin
    if loglin_path is None:
        here = os.path.dirname(os.path.abspath(__file__))
        loglin_path = os.path.join(here, "..", "AppleLogToLin-v1.0.cube")

    table = read_apple_log_to_lin(loglin_path)
    norm = hable(a.white, D=a.toe)

    lines = [
        f'TITLE "AppleLog to Filmic Rec709 (exp={a.exposure} white={a.white} '
        f'contrast={a.contrast} toe={a.toe})"',
        "",
        f"LUT_3D_SIZE {SIZE}",
        "",
    ]
    m = BT2020_TO_709
    # .cube 3D ordering: red varies fastest, then green, then blue
    for bi in range(SIZE):
        for gi in range(SIZE):
            for ri in range(SIZE):
                lin = [max(0.0, sample(table, c / (SIZE - 1))) for c in (ri, gi, bi)]
                rgb = [
                    m[0][0] * lin[0] + m[0][1] * lin[1] + m[0][2] * lin[2],
                    m[1][0] * lin[0] + m[1][1] * lin[1] + m[1][2] * lin[2],
                    m[2][0] * lin[0] + m[2][1] * lin[1] + m[2][2] * lin[2],
                ]
                out = []
                for c in rgb:
                    c = max(0.0, c) * a.exposure
                    d = max(0.0, min(1.0, hable(c, D=a.toe) / norm))
                    out.append(scurve(rec709_oetf(d), a.contrast))
                if a.sat != 1.0:
                    y = sum(w * c for w, c in zip(REC709_LUMA, out))
                    out = [max(0.0, min(1.0, y + (c - y) * a.sat)) for c in out]
                lines.append("%.6f %.6f %.6f" % tuple(out))

    with open(a.out, "w") as fh:
        fh.write("\n".join(lines) + "\n")

    # report where the landmarks land, as a sanity check
    def out_for_linear(target):
        for i in range(1, len(table)):
            if table[i] >= target:
                x = (i - 1 + (target - table[i - 1]) / (table[i] - table[i - 1])) / (len(table) - 1)
                lin = max(0.0, sample(table, x)) * a.exposure
                d = max(0.0, min(1.0, hable(lin, D=a.toe) / norm))
                return scurve(rec709_oetf(d), a.contrast)
        return None

    print(f"wrote {a.out}  ({SIZE}^3 3D LUT)")
    for t, label in ((0.18, "middle grey"), (1.0, "diffuse white"), (5.4, "scene max ~5.4x")):
        o = out_for_linear(t)
        if o is not None:
            print(f"  linear {t:5.2f} ({label:16s}) -> output {o:.3f}")


if __name__ == "__main__":
    main()
