#!/bin/bash
# Stage 1: source -> baseline (Log->Rec709 CST, correct colour tags).
# Usage: ./01-baseline.sh IMG_XXXX
#
# Rotation is NOT handled anywhere in this pipeline. Orientation is an ingest concern and the
# source is trusted — see docs/adr/0005 and CLAUDE.md. This stage does not check it either: a
# baseline is not a deliverable, so a sideways clip here is merely sideways. The refusal lives in
# the two final stages, where a landscape frame would be silently squashed into a vertical
# delivery. That is the failure worth catching, and catching it costs a decode, so it is paid once
# at the point where it matters.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

# `${1:-}` so a no-argument run says what it wanted — see 00-stabilise-detect.sh.
CLIP="${1:-}"
[ -n "$CLIP" ] || { echo "usage: ./01-baseline.sh IMG_XXXX" >&2; exit 1; }
# ...and then the name itself: it becomes a path component AND reaches the filter graph.
CLIP="$(require_clip_name "$CLIP")"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WORK="$(resolve_work_dir "$ROOT")"
SRC="$WORK/src/${CLIP}.mov"
LUT="$ROOT/luts/apple/AppleLogToRec709-v1.0.cube"
OUT="$WORK/dist/01-baseline/${CLIP}_baseline.mov"

[ -f "$SRC" ] || { echo "source not found: $SRC" >&2; exit 1; }
# Apple's CST is NOT in this repo — it is not redistributable (see luts/apple/SOURCE.txt). On a
# fresh clone it will be missing, so say so precisely rather than letting ffmpeg fail on a path.
[ -f "$LUT" ] || {
	echo "Apple's Log->Rec709 LUT is missing:" >&2
	echo "  $LUT" >&2
	echo "It is deliberately not committed — Apple's licence does not permit redistributing it." >&2
	echo "Download it (free Apple ID, ~2 min) per luts/apple/SOURCE.txt, then re-run." >&2
	exit 1
}
check_disk_space "$WORK/dist" 10
# Create the output directory rather than relying on the checked-in dist/*/.gitkeep
# markers: with a work dir set, those live in the repo and the output does not.
mkdir -p "$(dirname "$OUT")"

FILTER="lut3d=file='${LUT}':interp=tetrahedral"

ffmpeg -y -i "$SRC" -vf "$FILTER" \
	-c:v prores_ks -profile:v 3 -pix_fmt yuv422p10le \
	-c:a copy \
	"$OUT" -v error

require_nonempty "$OUT" "baseline encode"
safe_retag "$OUT"
echo "done: $OUT"
