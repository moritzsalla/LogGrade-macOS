#!/bin/bash
# Stage 3: graded master -> delivery.
# Usage: ./03-final.sh IMG_XXXX [reels|feed] [CROP_Y]
#
#   reels  9:16, 1080x1920 — Reels and Stories. The default.
#   feed   4:5, 1080x1350 — a Feed post, cropped from the portrait master.
#
#   CROP_Y applies to `feed` only: the vertical offset (in pixels on the 2160x3840 master) where
#          the 2160x2700 crop window starts. Default 750 is IMG_0609's biased-up crop, which
#          removes the parking-ceiling strip at the top and keeps the ivy plus a little more road
#          at the bottom. It is NOT assumed correct for every clip's composition — eyeball a crop
#          preview per clip and pass the right offset.
#
#   ACCEPT_STALE=1 delivers even though the transform is older than its source, i.e. unstabilised
#          on purpose. Without it a stale transform is refused: this stage has no detect pass, so
#          the alternative is a file that looks finished and quietly lacks the stabilisation.
#
# WHY ONE SCRIPT. This was two, 86% identical line for line, and they had already drifted: the
# grain rationale existed in the reels copy only. The two deliverables differ in four values —
# output size, grain plate size, whether a crop precedes the downscale, and the output name — so
# they are arguments, not files. The chain itself now lives once in lib.sh, next to the
# measurements that justify each part of it.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

# `${1:-}` so a no-argument run says what it wanted — see 00-stabilise-detect.sh.
CLIP="${1:-}"
[ -n "$CLIP" ] || { echo "usage: ./03-final.sh IMG_XXXX [reels|feed] [CROP_Y]" >&2; exit 1; }
# ...and then the name itself: it becomes a path component AND reaches the filter graph.
CLIP="$(require_clip_name "$CLIP")"
TARGET="${2:-reels}"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WORK="$(resolve_work_dir "$ROOT")"
# Both are spliced into the filter graph, and look.json is transcribed from the Bench's artifact
# db rather than typed here — see require_number in lib.sh.
SMOOTHING="$(require_number SMOOTHING "${SMOOTHING:-$(look .stabilisation.smoothing)}")"  # lowpass
GRAIN_STRENGTH="$(require_number GRAIN_STRENGTH "${GRAIN_STRENGTH:-$(look .grain.strength)}")"

case "$TARGET" in
	reels)
		W=1080; H=1920; CROP=""
		SUFFIX="reels-stories_9x16"
		;;
	feed)
		W=1080; H=1350
		CROP="crop=2160:2700:0:$(require_number CROP_Y "${3:-750}"),"
		SUFFIX="feed_4x5"
		;;
	*)
		echo "unknown delivery target: $TARGET (expected 'reels' or 'feed')" >&2
		exit 1
		;;
esac

IN="$WORK/dist/02-graded/${CLIP}_graded.mov"
SRC="$WORK/src/${CLIP}.mov"
OUT="$WORK/dist/03-final/${CLIP}_${SUFFIX}.mp4"

[ -f "$IN" ] || { echo "graded master not found: $IN — run 02-grade.sh first" >&2; exit 1; }
check_disk_space "$WORK/dist" 2
# Create the output directory rather than relying on the checked-in dist/*/.gitkeep markers:
# with a work dir set, those live in the repo and the output does not.
mkdir -p "$(dirname "$OUT")"
# Refuses a landscape master rather than squashing it into a vertical delivery, or cropping past
# the frame edge. See require_portrait in lib.sh.
require_portrait "$IN"

# --- optional stabilisation -------------------------------------------------
# If a transform exists (from 00-stabilise-detect.sh), the sway is smoothed out before the
# downscale, so the warp resamples at full resolution rather than at delivery size. It also fixes
# a colour artefact: handheld sway slides high-contrast edges across the chroma sampling grid, so
# chroma fringing PHASE-SHIFTS frame to frame and reads as a shimmer along the street-sign
# lettering. Holding the frame still stops the shimmer moving; the chroma denoise in the chain
# removes what remains. Neither alone gets it.
#
# Freshness is judged against the SOURCE clip, not this stage's input: transforms are motion-only
# and survive a re-grade, so a re-rendered master must not invalidate one. See transform_is_fresh.
STAB_PREFIX=""
TRF="$WORK/dist/stab/${CLIP}.trf"
if transform_is_fresh "$TRF" "$SRC"; then
	STAB_PREFIX="$(stab_prefix "$TRF" "$SMOOTHING")"
	echo "stabilising with $TRF (smoothing=${SMOOTHING})"
elif [ -f "$TRF" ]; then
	# REFUSED, not warned about. This stage has no detect pass, so a stale transform here means
	# delivering a file that quietly lacks the stabilisation someone asked for — and it looks
	# finished, which is CONTEXT.md's "squashed" failure class in another dimension. The warning
	# was printed among a dozen other lines and then the render went ahead anyway.
	#
	# ACCEPT_STALE=1 is how you say "yes, unstabilised, I know": a decision someone made rather
	# than a default nobody saw.
	emit_code STALE_TRANSFORM
	if [ "${ACCEPT_STALE:-0}" != "1" ]; then
		echo "REFUSING: stale transform at $TRF — older than $SRC." >&2
		echo "  It was measured on footage that no longer exists, so the warp would fight the" >&2
		echo "  frames it is applied to. Re-run 00-stabilise-detect.sh $CLIP to refresh it," >&2
		echo "  or pass ACCEPT_STALE=1 to deliver this unstabilised on purpose." >&2
		exit 1
	fi
	echo "stale transform at $TRF — rendering unstabilised, accepted via ACCEPT_STALE=1"
else
	echo "no transforms at $TRF — rendering unstabilised (run 00-stabilise-detect.sh first)"
fi

FPS="$(source_fps "$IN")"

# render_delivery, never a bare `ffmpeg -y "$OUT"`: pointing ffmpeg at the delivery path truncates
# the existing file before it knows whether the graph initialises, so a failed re-render destroys
# the approved deliverable it was overwriting. It also handles the non-empty check and the tag
# verification, because a file that lands must be one that was checked. See lib.sh.
render_delivery "$OUT" "$SUFFIX encode" \
	-y -i "$IN" -f lavfi -i "$(grain_plate "$W" "$H" "$FPS")" \
	-filter_complex "[0:v]$(delivery_image_chain "$W" "$H" "$STAB_PREFIX" "$CROP")[b];\
[1:v]$(delivery_grain_branch "$W" "$H" "$GRAIN_STRENGTH")[g];\
[b][g]${DELIVERY_BLEND}[o]" \
	-map "[o]" -map "0:a:0?" -shortest \
	-c:v libx264 -profile:v high -preset slow -crf 18 \
	-color_primaries bt709 -color_trc bt709 -colorspace bt709 \
	-c:a aac -b:a 192k \
	-movflags +faststart
echo "done: $OUT"
