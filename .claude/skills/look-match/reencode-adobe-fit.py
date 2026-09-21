"""Re-encode a cube `calib.py bake` wrote for Apple playback, as the committed Portra 160 and 800 are
("from=adobergb-power" in the TITLE, luts/film/CHANGELOG.txt). calib.py fits code values to the
partner's Adobe RGB edits, so its output codes mean Adobe RGB (gamma 563/256) light; playback shows
gamma 502/256 (scripts/cubefile.py). Primaries are left alone: converting them clipped 8% of the lattice
and scored no better on Portra 800.

usage: python3 reencode-adobe-fit.py IN.cube OUT.cube
"""
import sys

src, dst = sys.argv[1], sys.argv[2]
with open(src) as fh, open(dst, "w") as out:
    for line in fh:
        s = line.split()
        if line.startswith("TITLE"):
            out.write(line.replace("display=apple", "display=apple1.961 from=adobergb-power"))
        elif len(s) == 3 and s[0][0] in "-0123456789.":
            out.write(" ".join("%.6f" % (min(1.0, max(0.0, float(v))) ** (563 / 502)) for v in s) + "\n")
        else:
            out.write(line)
