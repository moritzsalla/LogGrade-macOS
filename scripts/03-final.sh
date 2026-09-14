#!/bin/bash
# Stage 3: graded master -> delivery.
# Usage: ./03-final.sh IMG_XXXX [deliverable] [CROP_Y]
#
#   deliverable  a preset — `reels` (9:16, the default) or `feed` (4:5) — or an arbitrary shape
#          written `name:aspect-w:aspect-h[:offset]`, e.g. `square:1:1` or `wide:16:9:400`. The
#          shapes are resolved by deliverable_spec in lib.sh, the same one grade.sh reads, so the
#          two paths cannot disagree about what a name means. WIDTH=<px> sets the shared delivery
#          width (default 1080) and the height follows the aspect.
#
#   CROP_Y applies to whichever deliverables actually crop this master: the vertical offset, in
#          pixels on the master, where the crop window starts. THERE IS NO DEFAULT — it used to be
#          750, which is IMG_0609's biased-up crop and nobody else's, so a deliverable that crops is
#          refused without one. Eyeball a crop preview per clip and pass the right offset, or pass
#          `centre` to say explicitly that this clip does not need one. A deliverable that is
#          already the master's own shape takes no crop and ignores it.
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
[ -n "$CLIP" ] || { echo "usage: ./03-final.sh IMG_XXXX [deliverable] [CROP_Y]" >&2; exit 1; }
# ...and then the name itself: it becomes a path component AND reaches the filter graph.
CLIP="$(require_clip_name "$CLIP")"
TARGET="${2:-reels}"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WORK="$(resolve_work_dir "$ROOT")"
# Both are spliced into the filter graph, and look.json is transcribed from the Bench's artifact
# db rather than typed here — see require_number in lib.sh.
SMOOTHING="$(require_number SMOOTHING "${SMOOTHING:-$(look .stabilisation.smoothing)}")"  # lowpass
GRAIN_STRENGTH="$(require_number GRAIN_STRENGTH "${GRAIN_STRENGTH:-$(look .grain.strength)}")"
GRAIN_SHADOWS="$(require_unit grain.shadows "$(look .grain.shadows)")"
GRAIN_HIGHLIGHTS="$(require_unit grain.highlights "$(look .grain.highlights)")"

# The shape is DATA, resolved by lib.sh. This was a two-branch `case` carrying its own sizes and
# its own `crop=2160:2700:0:` — the width, the aspect and the master's dimensions all written in,
# and all three wrong the moment any of them changed. The crop window is computed from the master
# that is actually on disk, a few lines down, once it has been measured.
read -r NAME AW AH OFF SUFFIX <<< "$(deliverable_spec "$TARGET")"
W="$(require_number WIDTH "${WIDTH:-1080}")"; W=$(( W - W % 2 ))
H="$(deliverable_height "$W" "$AW" "$AH")"
# The positional offset wins over the spec's own, because it is the more specific thing the caller
# just typed; CROP_Y from the environment is the fallback. `centre` passes through as a word and is
# resolved per clip by crop_prefix, against the frame it actually measured. An offset that is never
# supplied stays empty, and crop_prefix refuses it rather than inventing one.
_arg_off="${3:-${CROP_Y:-}}"
if [ -n "$_arg_off" ]; then
	case "$_arg_off" in
		centre|center) OFF="centre";;
		*) OFF="$(require_number CROP_Y "$_arg_off")";;
	esac
elif [ "$OFF" = "-" ]; then
	OFF=""
fi

IN="$WORK/dist/02-graded/${CLIP}_graded.mov"
SRC="$WORK/src/${CLIP}.mov"
OUT="$WORK/dist/03-final/${CLIP}_${SUFFIX}.mp4"

[ -f "$IN" ] || { echo "graded master not found: $IN — run 02-grade.sh first" >&2; exit 1; }
check_disk_space "$WORK/dist" 2
# Create the output directory. This used to rely on a checked-in dist/*/.gitkeep marker, which
# is wrong the moment a work dir is set: the marker was in the repo and the output was not.
mkdir -p "$(dirname "$OUT")"
# Refuses a landscape master rather than squashing it into a vertical delivery, or cropping past
# the frame edge. See require_portrait in lib.sh. The size it hands back is what the crop window is
# computed from — measured, never assumed to be 2160x3840.
IN_SIZE="$(require_portrait "$IN")"
CROP="$(crop_prefix "${IN_SIZE% *}" "${IN_SIZE#* }" "$AW" "$AH" "$OFF")"
echo "deliverable: $NAME  ${W}x${H}${CROP:+  cropped at $OFF}"

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
$(delivery_grain_merge b g o "$GRAIN_SHADOWS" "$GRAIN_HIGHLIGHTS")" \
	-map "[o]" -map "0:a:0?" -shortest \
	-c:v libx264 -profile:v high -preset slow -crf 18 \
	-color_primaries bt709 -color_trc bt709 -colorspace bt709 \
	-c:a aac -b:a 192k \
	-movflags +faststart
echo "done: $OUT"
