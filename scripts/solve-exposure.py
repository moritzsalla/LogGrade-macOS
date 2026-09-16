#!/usr/bin/env python3
"""Solve a clip's exposure and white balance in scene-linear light, for a film conversion.

Usage: ffmpeg ... -vf scale=160:160,format=gbrpf32le -f rawvideo - | solve-exposure.py <width> <height> <reference-stops>

Reads one decoded Apple Log frame (planar float G, B, R, as ffmpeg's gbrpf32le lays it out) and
prints `<exposure-stops> <temp> <tint>`, in make-correct-lut.py's units, to add to look.json's own
correction.

WHY NOT THE GAMMA MATCH. MATCH=1 solves a tone-curve gamma after Apple's conversion, on display
pixels. A film cube is the conversion AND the tone, so a curve after it bends the stock's own
characteristic curve; exposure belongs before it, in linear, where a stop is a stop.

EXPOSURE is the log-average luminance: the mean of log2(Y) over the frame, which is what a meter
averages and what the negative responds to. `reference-stops` is that mean, in stops from 0.18,
that the film looks were baked for. The move is DAMPED, not a full normalisation: a dusk scene is
darker than noon on film too, and landing both on one grey erases the difference someone shot.

WHITE BALANCE weights every pixel by how close to neutral it already is (grey-world restricted to
near-greys, so a green park does not read as a magenta cast), in the camera's own primaries, and
turns the ratio into temp/tint through the generator's gain model. Damped for the same reason:
golden hour is meant to be warm.
"""

import math
import os
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from applelog import decode  # noqa: E402

# Share of the measured difference that is corrected, a judgement rather than a measurement. On
# the 19 clips of the reference shoot the centre-weighted log-average spans -1.1 to +0.8 stops; at
# 0.6 the correction stays within -0.75..+0.45.
EXPOSURE_DAMPING = 0.6
BALANCE_DAMPING = 0.5
EXPOSURE_LIMIT = 2.0
BALANCE_LIMIT = 0.5
# BT.2020 luma, the camera's primaries.
LW = (0.2627, 0.6780, 0.0593)
# make-correct-lut.py's white balance gains: R = 1 + S*temp, G = 1 + S*tint, B = 1 - S*temp - T*tint.
WB_SCALE = 0.30
WB_TINT_BLUE = 0.15
USAGE = "Usage: solve-exposure.py <width> <height> <reference-stops>"


def solve(pixels, reference_stops):
	"""pixels: iterable of (r, g, b, weight), Apple Log code values and a metering weight.
	Returns (stops, temp, tint)."""
	logs, wr, wb, wsum = 0.0, 0.0, 0.0, 0.0
	n = 0.0
	for r, g, b, meter in pixels:
		lr, lg, lb = decode(r), decode(g), decode(b)
		y = LW[0] * lr + LW[1] * lg + LW[2] * lb
		# Below the noise floor and above sensor clip, a pixel says nothing about exposure or colour.
		if not 0.002 < y < 4.0 or min(lr, lg, lb) <= 0.0:
			continue
		logs += meter * math.log2(y / 0.18)
		n += meter
		# Chromaticity distance from neutral in log ratios; a grey card is 0.
		cr, cb = math.log(lr / lg), math.log(lb / lg)
		w = math.exp(-(cr * cr + cb * cb) / (2 * 0.15 * 0.15))
		wr += w * cr
		wb += w * cb
		wsum += w
	if n <= 0.0:
		return 0.0, 0.0, 0.0
	stops = max(-EXPOSURE_LIMIT, min(EXPOSURE_LIMIT, EXPOSURE_DAMPING * (reference_stops - logs / n)))
	if wsum < 1e-6:
		return stops, 0.0, 0.0
	# Gains that would bring the weighted mean to neutral, relative to green, damped in log.
	r = math.exp(-BALANCE_DAMPING * wr / wsum)
	b = math.exp(-BALANCE_DAMPING * wb / wsum)
	# Solve the generator's gain model for these ratios: (1+S*t)/(1+S*n) = r, (1-S*t-T*n)/(1+S*n) = b.
	tint = (2 - r - b) / (WB_SCALE * r + WB_SCALE * b + WB_TINT_BLUE)
	temp = (r * (1 + WB_SCALE * tint) - 1) / WB_SCALE
	clamp = lambda v: max(-BALANCE_LIMIT, min(BALANCE_LIMIT, v))  # noqa: E731
	return stops, clamp(temp), clamp(tint)


def centre_weights(w, h):
	"""Centre-weighted metering, as a camera's: a sky across the top of a frame should not set the
	exposure of the person in the middle of it. Row-major, like the planes."""
	for y in range(h):
		for x in range(w):
			dx, dy = (x + 0.5) / w - 0.5, (y + 0.5) / h - 0.5
			yield math.exp(-(dx * dx + dy * dy) / (2 * 0.25 * 0.25))


def main(argv):
	if len(argv) != 4:
		print(USAGE, file=sys.stderr)
		return 2
	import array
	w, h, ref = int(argv[1]), int(argv[2]), float(argv[3])
	data = array.array("f")
	data.frombytes(sys.stdin.buffer.read())
	plane = w * h
	if len(data) < 3 * plane:
		# An unreadable frame is no correction rather than a failed batch.
		print("0 0 0")
		return 0
	g, b, r = data[0:plane], data[plane:2 * plane], data[2 * plane:3 * plane]
	stops, temp, tint = solve(zip(r, g, b, centre_weights(w, h)), ref)
	print("%.3f %.3f %.3f" % (stops, temp, tint))
	return 0


if __name__ == "__main__":
	sys.exit(main(sys.argv))
