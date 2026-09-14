"""
Apple Log's published transfer function, in one place.

Two generators need it: the input correction (scripts/make-correct-lut.py) and the halation stage
(scripts/make-halation-luts.py). A formula copied into both is a formula that gets edited in one, so
both import it from here. The Swift transcriptions are held to these functions by exact-equivalence
tests, not by a tolerance.

The constants are from Apple's Log Profile white paper: a parabolic toe below a small threshold,
which is what lets the format hold negative scene values, and a log curve above it.
luts/apple/SOURCE.txt carries the provenance, and the correction to this repo's earlier claim that
the function was proprietary.

Measured: encode(decode(p)) round-trips to 8e-17 across 0..1, and decode(1.0) is 12.0000 — twelve
times diffuse white, about 3.6 stops above it, which the Rec.709 conversion has to land on a display
ceiling of 1.0.
"""
import math

R0 = -0.05641088
RT = 0.01
C = 47.28711236
BETA = 0.00964052
GAMMA = 0.08550479
DELTA = 0.69336945
PT = C * (RT - R0) ** 2


def decode(p):
    """Apple Log code value -> linear scene reflectance."""
    if p < 0.0:
        return R0
    if p < PT:
        return math.sqrt(p / C) + R0
    return 2.0 ** ((p - DELTA) / GAMMA) - BETA


def encode(r):
    """Linear scene reflectance -> Apple Log code value."""
    if r < R0:
        return 0.0
    if r < RT:
        return C * (r - R0) ** 2
    return GAMMA * math.log2(r + BETA) + DELTA
