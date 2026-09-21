"""Re-encode a BT.1886 (gamma 2.4) bake from ~/Documents/ffgrade-film-bake for Apple playback, as every
committed film cube is (`display=apple1.961` in its TITLE, luts/film/CHANGELOG.txt; plain
`display=apple` was the inverse BT.709 OETF, whose shadows playback shows too dark). scan_bake3.py and
trim.py still write gamma 2.4; a cube copied in without this step renders milky on every Mac and iPhone.

usage: python3 reencode-for-apple-display.py IN.cube OUT.cube REPO/scripts [COMPARE.cube]
COMPARE prints the max difference against another cube, e.g. the committed one, to prove a re-bake
reproduces it.
"""
import sys

sys.path.insert(0, sys.argv[3])
from cubefile import display_encode  # noqa: E402

src, dst = sys.argv[1], sys.argv[2]
with open(src) as fh, open(dst, "w") as out:
    for line in fh:
        s = line.split()
        if line.startswith("TITLE"):
            out.write(line.rstrip("\n").rstrip('"') + ' display=apple1.961"\n')
        elif len(s) == 3 and s[0][0] in "-0123456789.":
            out.write(" ".join("%.6f" % display_encode(max(0.0, float(v)) ** 2.4) for v in s) + "\n")
        else:
            out.write(line)

if len(sys.argv) > 4:
    def rows(p):
        return [list(map(float, ln.split())) for ln in open(p) if len(ln.split()) == 3 and ln[0] in "-0123456789."]
    a, b = rows(dst), rows(sys.argv[4])
    print("rows", len(a), len(b), "max diff", max(abs(x - y) for r, q in zip(a, b) for x, y in zip(r, q)))
    print("title same", open(dst).readline() == open(sys.argv[4]).readline())
