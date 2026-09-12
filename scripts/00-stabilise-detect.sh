#!/bin/bash
# Stage 0 (optional): analyse camera motion, producing transforms the final stages apply.
# Usage: ./00-stabilise-detect.sh IMG_XXXX
# Reads dist/02-graded/<clip>_graded.mov, writes dist/stab/<clip>.trf
#
# Numbered 00 but run LAST in practice — it needs the master, and it is only worth running on a
# clip that was shot handheld. A clip on a tripod needs nothing. The finals skip stabilisation
# silently when no .trf exists for the clip, so this is opt-in per clip.
#
# WHY IT ALSO FIXES A COLOUR ARTEFACT: handheld sway slides high-contrast edges across the chroma
# sampling grid frame by frame, so chroma fringing does not sit still — it phase-shifts, and reads
# as a shimmer crawling along fine lettering (spotted on the street sign, described as "moving like
# a sine wave"). Holding the frame still stops the shimmer moving; the finals' hqdn3d chroma pass
# removes what is left. Neither alone gets it.
#
# Cost: roughly 65s for a 26s 4K clip on this machine (measured 12.4s for a 5s segment). Analysis
# is decode-bound, so it is far cheaper than the encode that follows.
#
# Detection runs on the MASTER, at full 4K, so the transforms are in master pixel units and the
# finals can warp before downscaling — the warp then resamples at 4K instead of at delivery size.
# Transforms describe MOTION only, so they survive a re-grade: change the look or tone and the
# same .trf still applies. Only a change to rotation or framing invalidates it.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

# `${1:-}`, not `$1`: under `set -u` a bare $1 makes a no-argument run die with
# "$1: unbound variable" and a line number instead of saying what it wanted. The bats test named
# for this asserts that exact string is absent, but only ever calls the scripts WITH an argument,
# so it could not see it. grade.sh was the only entry point that got this right.
CLIP="${1:-}"
[ -n "$CLIP" ] || { echo "usage: ./00-stabilise-detect.sh IMG_XXXX" >&2; exit 1; }
# ...and then the name itself: it becomes a path component AND reaches the filter graph.
CLIP="$(require_clip_name "$CLIP")"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WORK="$(resolve_work_dir "$ROOT")"
IN="$WORK/dist/02-graded/${CLIP}_graded.mov"
OUT_DIR="$WORK/dist/stab"
OUT="$OUT_DIR/${CLIP}.trf"

[ -f "$IN" ] || { echo "graded master not found: $IN — run 02-grade.sh first" >&2; exit 1; }
mkdir -p "$OUT_DIR"

# shakiness=5 suits "static handheld" — the iPhone's own stabilisation has already removed the
# large motion, so what is left is low-amplitude sway. stepsize=6 trades a little accuracy for
# speed and is plenty at this amplitude.
# Write to a temp file, install on success only. An interrupted detect (Ctrl-C, a killed background
# job) otherwise leaves a TRUNCATED .trf in place of a good one, and the failure surfaces much
# later and somewhere else: the finals die deep in the filter graph with "Cannot parse localmotion:
# unexpected end of file", which does not point back here at all. Learned by doing exactly that —
# a two-second smoke test destroyed a three-minute analysis.
TMP="${OUT}.partial"
trap 'rm -f "$TMP"' EXIT

ffmpeg -y -i "$IN" \
	-vf "vidstabdetect=shakiness=5:accuracy=15:stepsize=6:result=${TMP}" \
	-f null - -v error

require_nonempty "$TMP" "stabilisation analysis"
mv "$TMP" "$OUT"
trap - EXIT
echo "done: $OUT"
echo "the final stages will now pick this up automatically; override smoothing with e.g.:"
echo "  SMOOTHING=45 ./03-final.sh ${CLIP} reels"
