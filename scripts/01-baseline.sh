#!/bin/bash
# Stage 1: source -> baseline (the conversion out of Apple Log, correct colour tags).
# Usage: ./01-baseline.sh IMG_XXXX
#
# Rotation is NOT handled anywhere in this pipeline. Orientation is an ingest concern and the
# source is trusted — see docs/adr/0005 and CLAUDE.md. The frame is measured only where a crop is
# computed from it, in the two render paths that deliver.
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
SRC="$(source_path "$WORK" "$CLIP")"
OUT="$(baseline_path "$WORK" "$CLIP")"

[ -f "$SRC" ] || { echo "source not found: $SRC" >&2; exit 1; }
# look.json's conversion, and its log denoise, which must run here before the cube: stage 3 drops
# hqdn3d whenever finish.denoise is on. A film conversion's per-clip metering is grade.sh's only.
CST="$(resolve_conversion "${CONVERT:-$(look .convert.cube)}")" || exit 1
load_delivery_look || exit 1
DENOISE_PREFIX=""
[ "$FINISH" = 0 ] || DENOISE_PREFIX="$(denoise_prefix "$DENOISE_STRENGTH")"
# A clip's baseline and graded masters measured 4.6GB together (docs/PIPELINE.md, "Disk space
# policy"); 10GB is a margin over that, not a measurement.
check_disk_space "$WORK/dist" 10
# Create the output directory. This used to rely on a checked-in dist/*/.gitkeep marker, which
# is wrong the moment a work dir is set: the marker was in the repo and the output was not.
mkdir -p "$(dirname "$OUT")"

FILTER="${DENOISE_PREFIX}lut3d=file='${CST}':interp=tetrahedral"

ffmpeg -y -i "$SRC" -vf "$FILTER" \
	"${PRORES_MASTER[@]}" \
	"$OUT" -v error

require_nonempty "$OUT" "baseline encode"
safe_retag "$OUT"
echo "done: $OUT"
