#!/usr/bin/env python3
"""Solve the per-clip gamma that lands a clip where the look was tuned.

Usage: solve-gamma.py <clip-yavg> <reference-yavg> <reference-gamma>

All three come from look.json and from one cheap probe per clip; the two means are 10-bit
post-CST luma averages. Prints the gamma to apply.

WHY THIS IS ITS OWN FILE. It used to be a python3 -c program built by string interpolation inside
grade.sh, which made it both unreachable by any test and a place where an unexpected probe value
would be spliced into the program text. The domain guards below are the whole reason it is worth
testing: math.log(0) raises on a near-black frame and y == 1.0 divides by zero, and under
`set -euo pipefail` either one killed the entire batch at clip n instead of rendering that clip
with the frozen curve. An unusable probe now falls back to the reference gamma, which is already
what grade.sh does when the probe comes back empty.

The clamp is a separate judgement: the solve is only meaningful near the exposure the look was
tuned at, so a clip four stops away gets the nearest sane curve rather than an extrapolation
nobody has looked at.
"""

import math
import sys

CLAMP_LO, CLAMP_HI = 1.2, 3.2


def solve(clip_yavg, reference_yavg, reference_gamma, peak=1023.0):
	y = clip_yavg / peak
	r = reference_yavg / peak
	# Outside the open unit interval there is no solve: log(0) raises, and y == 1 makes the
	# denominator zero. Both mean "this probe tells us nothing", not "this clip is broken".
	if not 0.0 < y < 1.0 or not 0.0 < r < 1.0:
		return reference_gamma
	# Solve x_new ** g_new == x_ref ** g_ref, so every clip lands where the look was tuned.
	return max(CLAMP_LO, min(CLAMP_HI, reference_gamma * math.log(r) / math.log(y)))


def main(argv):
	if len(argv) != 4:
		print(__doc__.strip().splitlines()[2], file=sys.stderr)
		return 2
	try:
		clip, reference, gamma = (float(a) for a in argv[1:])
	except ValueError:
		print(f"solve-gamma: non-numeric argument in {argv[1:]}", file=sys.stderr)
		return 2
	print("%.3f" % solve(clip, reference, gamma))
	return 0


if __name__ == "__main__":
	sys.exit(main(sys.argv))
