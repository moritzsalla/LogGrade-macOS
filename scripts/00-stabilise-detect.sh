#!/bin/bash
# Stage 0 (optional): analyse camera motion, producing transforms the final stages apply.
# Usage: ./00-stabilise-detect.sh IMG_XXXX
# Reads .loggrade/masters/<clip>_graded.mov, writes .loggrade/stabilisation/<clip>.trf
#
# Numbered 00 but run LAST in practice — it needs the master, and it is only worth running on a
# clip that was shot handheld. A clip on a tripod needs nothing. With no .trf for the clip,
# 03-final.sh says so and renders unstabilised, so this is opt-in per clip; a .trf older than its
# source is refused there instead.
#
# WHY IT ALSO FIXES A COLOUR ARTEFACT: handheld sway slides high-contrast edges across the chroma
# sampling grid frame by frame, so chroma fringing does not sit still — it phase-shifts, and reads
# as a shimmer crawling along fine lettering (spotted on the street sign, described as "moving like
# a sine wave"). Holding the frame still stops the shimmer moving.
#
# Detection runs on the MASTER, at half size, and the transforms are written in master pixel units
# (detect_transform), so the finals can warp before downscaling.
# Transforms describe MOTION only, so they survive a re-grade: change the look or tone and the
# same .trf still applies. Only a change to rotation or framing invalidates it.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

# `${1:-}`, not `$1`: under `set -u` a bare $1 makes a no-argument run die with
# "$1: unbound variable" and a line number instead of saying what it wanted. The suite's first test
# for this only ever passed an argument, so it could not see it; a no-argument test now covers
# every stage script.
CLIP="${1:-}"
[ -n "$CLIP" ] || { echo "usage: ./00-stabilise-detect.sh IMG_XXXX" >&2; exit 1; }
# ...and then the name itself: it becomes a path component AND reaches the filter graph.
CLIP="$(require_clip_name "$CLIP")"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WORK="$(resolve_work_dir "$ROOT")"
IN="$(graded_master_path "$WORK" "$CLIP")"
OUT="$(transform_path "$WORK" "$CLIP")"

[ -f "$IN" ] || { echo "graded master not found: $IN — run 02-grade.sh first" >&2; exit 1; }
# No CST head: the master has already been converted. The settings and the staging are
# detect_transform's, shared with grade.sh, which writes the same cache.
detect_transform "$IN" "$OUT"
echo "done: $OUT"
echo "the final stages will now pick this up automatically; override smoothing with e.g.:"
echo "  SMOOTHING=45 ./03-final.sh ${CLIP} reels"
