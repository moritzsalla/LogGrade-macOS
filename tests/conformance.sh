#!/bin/bash
# conformance.sh — does this fork still render what the precursor rendered?
#
# WHY THIS EXISTS. The engine here is a copy (see PROVENANCE.md), and a copy that is about to be
# instrumented and then parameterised needs the one thing a copy cannot provide for itself: proof
# that the image did not move. The precursor is frozen, so it can be the oracle. This renders the
# same clip through both engines and compares the bytes.
#
# BYTE-IDENTICAL, not similar. Both sides run the same ffmpeg binary with the same arguments, so
# anything short of identical means the graph diverged — and a tolerance would let exactly that
# through, which is the failure this test exists to catch. Verified before relying on it: two runs
# of the precursor, minutes apart, produced identical files. Nothing passes `-bitexact`; this build
# simply stamps no timestamp into the container.
#
# IT PINS THE DEFAULT CONFIGURATION ONLY. Parameterising the chain will legitimately break this
# once. The commit that does it says so in its message and re-bases the expectation deliberately;
# quietly relaxing this test would leave the repo with a guard that cannot fail.
#
# STABILISATION IS EXCLUDED (STAB=0). Its detect pass costs ~65s per clip per side, and pinning it
# would rest on vid.stab being deterministic as well. So the warp is not covered here — everything
# from the CST through the grade, the downscale, the sharpen, the grain and the encode is.
#
# BOTH SIDES READ THIS REPO'S look.json, via LOOK_FILE. The test isolates the CHAIN: a look edit
# then moves both sides identically and conformance still holds, which is what you want, because a
# look is data and the chain is code.
#
# Usage:  ./tests/conformance.sh [clip.mov]
#   PRECURSOR=<path>    where the frozen original lives (default: ../ffgrade)
#   PROOF_SECS=<n>      seconds to render through the real chain (default: 0.1)
#
# Exit: 0 identical, 1 diverged or a render failed, 3 skipped (no precursor, no cube, no footage).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PRECURSOR="${PRECURSOR:-$(cd "$ROOT/.." && pwd)/ffgrade}"
PROOF_SECS="${PROOF_SECS:-0.1}"

skip() { echo "SKIP: $*"; exit 3; }

[ -x "$PRECURSOR/scripts/grade.sh" ] || skip "no precursor engine at $PRECURSOR/scripts/grade.sh"
CUBE="luts/apple/AppleLogToRec709-v1.0.cube"
[ -f "$ROOT/$CUBE" ]       || skip "this repo has no $CUBE (see luts/apple/SOURCE.txt)"
[ -f "$PRECURSOR/$CUBE" ]  || skip "the precursor has no $CUBE to render with"

# Footage is never committed, so it comes from whichever src/ actually has some. Reading the
# precursor's src/ is fine: this test only ever READS from there, and writes nothing into it.
CLIP="${1:-}"
if [ -z "$CLIP" ]; then
	for d in "$ROOT/src" "$PRECURSOR/src"; do
		for f in "$d"/*.mov "$d"/*.MOV; do
			if [ -f "$f" ]; then CLIP="$f"; break 2; fi
		done
	done
fi
[ -n "$CLIP" ] || skip "no source footage in src/ — this repo's or the precursor's"
[ -f "$CLIP" ] || { echo "not a file: $CLIP" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
# resolve_work_dir refuses a configured directory that does not exist, so create both up front.
mkdir -p "$TMP/precursor" "$TMP/fork"

render() {  # render <label> <engine-root> <work-dir>
	local label="$1" engine="$2" work="$3"
	if ! GRADE_WORK_DIR="$work" LOOK_FILE="$ROOT/look.json" STAB=0 PROOF="$PROOF_SECS" \
		"$engine/scripts/grade.sh" "$CLIP" >"$TMP/$label.log" 2>&1; then
		echo "FAIL: the $label engine did not render. Its output:" >&2
		cat "$TMP/$label.log" >&2
		return 1
	fi
}

echo "clip:       $(basename "$CLIP")  (${PROOF_SECS}s through the real chain, unstabilised)"
echo "precursor:  $PRECURSOR"
render precursor "$PRECURSOR" "$TMP/precursor"
render fork      "$ROOT"      "$TMP/fork"

pick() {  # pick <work-dir> -> the proof it wrote
	local found=""
	for f in "$1/dist/proofs"/*.mp4; do
		if [ -f "$f" ]; then found="$f"; fi
	done
	printf '%s\n' "$found"
}
A="$(pick "$TMP/precursor")"
B="$(pick "$TMP/fork")"
if [ -z "$A" ] || [ -z "$B" ]; then
	echo "FAIL: a side produced no proof (precursor='$A' fork='$B')" >&2
	exit 1
fi

if cmp -s "$A" "$B"; then
	echo "CONFORMANCE OK: byte-identical to the precursor ($(stat -f%z "$A") bytes)"
	exit 0
fi

# Diverged. Print enough to tell a chain change from a muxer change without a second run: if the
# packet streams match and only the files differ, the graph is fine and the container is not.
echo "CONFORMANCE FAILED: this fork no longer renders what the precursor renders." >&2
echo "  precursor: $(stat -f%z "$A") bytes" >&2
echo "  fork:      $(stat -f%z "$B") bytes" >&2
for f in "$A" "$B"; do
	printf '  stream %s ' "$(basename "$(dirname "$(dirname "$f")")")" >&2
	ffmpeg -v error -i "$f" -map 0 -c copy -f md5 - >&2
done
echo "  If the stream hashes MATCH, the chain is intact and the container changed." >&2
echo "  If they differ, the filter graph changed — say so in the commit, or fix it." >&2
exit 1
