#!/bin/bash
# grade.sh — one clip, one ffmpeg pass, source to deliverable.
#
# Usage:
#   ./scripts/grade.sh <folder|clip.mov> [...]   process a shoot folder or named clips
#
# Every knob is an environment variable, and this list is the only place they are documented:
#   FEED=1            also emit the 4:5 Feed crop (refused across several clips without CROP_Y)
#   CROP_Y=<px>       vertical offset of the 4:5 crop window on the 2160x3840 master (default 750,
#                     which is IMG_0609's composition — it is a per-clip framing call)
#   STAB=0            skip stabilisation entirely (faster)
#   SMOOTHING=<n>     frames of camera-path lowpass; higher is closer to locked-off
#   MATCH=0           skip exposure matching and use look.json's gamma raw
#   YAVG_IN=<n>       the clip's post-CST mean, if it has already been measured. Skips the probe,
#                     which costs about a second; the render is identical either way.
#   GRAIN_STRENGTH=<n>  override look.json's grain strength
#   PROOF=<seconds>   render this many seconds through the real chain into dist/proofs/
#   DRY=1             plan only, render nothing
#   HEIGHT=<px>       output height (default 1920). Width follows the deliverable's aspect.
#   FPS_OUT=<n>       output frame rate. Default is the source's. Only an integer relation is
#                     accepted — anything needing retiming is refused rather than interpolated.
#   CORRECT_SIZE=<n>  points per axis in the correction cube (default 33; see its header for
#                     the measured cost and error at 17, 33 and 65)
#   LOOK=<name|none>  which film-emulation cube to use, by stem from luts/looks/, or none for a
#                     neutral grade. Overrides look.json's .look.lut for this run.
#   FRAME=<seconds>   render ONE frame at that timecode through the grade chain to a PNG and
#                     stop — the app's exact preview. No delivery stage, no stabilisation.
#   FRAME_HEIGHT=<px> height of that frame (default 1440, the Bench's working height)
#   FRAME_STAGE=source  the same frame with NO grade chain on it: the decoded Apple Log picture,
#                     resampled identically. It is what the app's live preview grades itself while
#                     a control is moving. Default 'graded'.
#   JSON=1            emit one machine-readable event per line on stdout instead of the human
#                     lines, which then go only to the run report. Named codes go to stderr
#                     either way. This is what the app drives the engine through.
#
# WHY ONE PASS. The staged pipeline (01-baseline -> 02-grade -> 03-final) writes two ~2.5GB ProRes
# intermediates per clip and decodes the footage three times. Those intermediates existed so the
# look could be re-tuned without redoing the CST. The look is now FROZEN, so they earn nothing:
# nothing ever re-renders from the master. Collapsing to a single filter graph removes two full
# encodes, two full decodes and ~5GB of disk per clip. The staged scripts are kept for re-tuning
# and for the Bench; this is the path for production runs.
#
# WHAT IS AUTOMATIC vs WHAT THIS REFUSES TO GUESS:
#   automatic  exposure match, stabilisation, the whole grade, tag verification
#   refuses    a clip that does not decode as portrait, and a Feed crop across several clips
#              without an explicit CROP_Y — that offset is a composition call per clip
#
# Orientation is NOT handled here or anywhere: it is an ingest concern and the source is trusted.
# See docs/adr/0005_ORIENTATION_IS_AN_INGEST_CONCERN.md.
#
# EXPOSURE MATCHING is the part that makes "one recipe" actually mean "one look". The grade was
# tuned on a single frame of IMG_0609, ~20 minutes before sunset. Golden hour moves fast; clips
# shot across a shoot window land differently under a fixed curve, and in an unattended batch
# nobody notices until the edit. Each clip's post-CST mean is measured and the tone curve's gamma
# is solved per clip to land on the same place. Disable with MATCH=0 to get the frozen curve raw.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WORK="$(resolve_work_dir "$ROOT")"

CST="$ROOT/luts/apple/AppleLogToRec709-v1.0.cube"
PROOF="${PROOF:-}"        # PROOF=<seconds> renders a short proof; see the note below
# Validated because it is spliced UNQUOTED below (`-t $PROOF`) so that an empty value disappears
# instead of becoming an empty argument — bash 3.2 cannot expand an empty array under `set -u`.
# That split means whitespace in PROOF becomes extra ffmpeg OPTIONS, and `-f mp4 <path>` would
# append a second output file, walking straight past render_delivery's staging.
[ -z "$PROOF" ] || PROOF="$(require_number PROOF "$PROOF")"

# FRAME=<seconds> renders a single frame through the REAL grade chain and stops. It is the app's
# exact preview: a still cannot show grain, the sharpener, the chroma denoise, the stabiliser or
# the dither, all of which are delivery-stage, so this deliberately covers the grade only and the
# interface says so. What it does cover is everything a slider moves — the CST, the look LUT, the
# solved tone curve, saturation and warmth — at full resolution, resampled to display size after
# the grade exactly as the delivery chain resamples after it.
FRAME="${FRAME:-}"
[ -z "$FRAME" ] || FRAME="$(require_number FRAME "$FRAME")"
FRAME_HEIGHT="$(require_number FRAME_HEIGHT "${FRAME_HEIGHT:-1440}")"

# FRAME_STAGE=source gives the same frame with NO grade chain at all: the decoded Apple Log
# picture, resampled the same way, and nothing else. It is what the app's live preview grades in
# its own process while a control is moving, so that the correction stage — which runs before
# Apple's conversion and therefore cannot be modelled from a converted frame — follows the slider
# too. Every filter in the graded path is absent by construction rather than by a second list that
# could drift: the chain simply is not built.
#
# The app never builds a filter graph, which is what tests/conformance.sh and ADR 0008 are for, so
# the command lives here with the rest of them rather than in Swift.
FRAME_STAGE="${FRAME_STAGE:-graded}"
case "$FRAME_STAGE" in
	graded|source) ;;
	*)
		echo "REFUSING: FRAME_STAGE must be 'graded' or 'source', got: $FRAME_STAGE" >&2
		emit_code REFUSE_FRAME_STAGE
		emit refused code REFUSE_FRAME_STAGE
		exit 1;;
esac
FRAME_DIR="$WORK/dist/frames"

# Delivery shape. The sizes were 1080x1920 and 1080x1350 written into the render calls; they are
# the deliverable's ASPECT plus one height now, because the app offers the height as a choice.
HEIGHT="$(require_number HEIGHT "${HEIGHT:-1920}")"
FPS_OUT="${FPS_OUT:-}"
[ -z "$FPS_OUT" ] || FPS_OUT="$(require_number FPS_OUT "$FPS_OUT")"
# Two modes that both mean "do not deliver" would otherwise silently pick one. Refuse instead: a
# preview and a proof answer different questions and neither is a fallback for the other.
if [ -n "$FRAME" ] && [ -n "$PROOF" ]; then
	echo "REFUSING: FRAME and PROOF are both set." >&2
	echo "  FRAME renders one still through the grade chain; PROOF renders seconds through the" >&2
	echo "  whole delivery chain. Pick one." >&2
	emit_code REFUSE_PROOF_AND_FRAME
	emit refused code REFUSE_PROOF_AND_FRAME
	exit 1
fi
# Proofs are not deliverables and must never land where someone uploads from.
if [ -n "$PROOF" ]; then
	OUT_DIR="$WORK/dist/proofs"
else
	OUT_DIR="$WORK/dist/03-final"
fi
# Reports are not deliverables — keep them out of the folder someone uploads from.
REPORT_DIR="$WORK/dist/reports"
# A persistent cache for the per-clip tone LUTs the exposure match generates. It used to be
# assigned over WORK itself, which left one name meaning two things — and the stabilisation
# path below was then built from the wrong one, landing at <work>/dist/.grade-work/dist/stab/
# instead of where 00-stabilise-detect.sh writes. WORK stays the work-dir root.
CACHE="$WORK/dist/.grade-work"

# --- the look. Every value comes from look.json; nothing here holds a copy. ---
# This path used to carry its own tone block while reading colour, grain and stabilisation from
# look.json, so a grade sent from the Bench updated shipped.cube and the staged path while THIS
# script kept rendering the previous tone. That is the two-copies-one-edited failure look() was
# written to end, one layer up. No fallbacks on purpose: a missing value must stop the run, not
# quietly substitute a different look.
# Every one of these is spliced into an ffmpeg filter graph, and look.json is transcribed from the
# Bench's artifact db rather than typed here — see require_number in lib.sh for why that matters.
# The look LUT is a look value like any other, so it comes from look.json. LOOK=<name|none|path>
# overrides it for one run; the app sets it per render.
LOOK_LUT="$(resolve_look_lut "${LOOK:-$(look .look.lut)}" "$ROOT")"

# --- the input correction ---------------------------------------------------------------
# Exposure, white balance and the CDL wheels, generated into one cube that runs BEFORE Apple's
# conversion. Before, because Apple Log carries twelve stops of headroom that the Rec.709 cube
# lands on a display ceiling of 1.0: a correction applied after it works on display-referred
# pixels and clips highlights the source still holds. scripts/make-correct-lut.py carries the
# maths, the published transfer function it decodes with, and the measurements behind its size.
#
# A NEUTRAL correction leaves the filter out of the graph entirely. That is not only cheaper: it
# is what keeps the default render byte-identical to the engine this was forked from, which
# tests/conformance.sh measures. The generator owns that rule, so it is not restated here.
CORRECT_EXPOSURE="$(require_number exposure "$(look .correct.exposure)")"
CORRECT_TEMP="$(require_number temp "$(look .correct.temp)")"
CORRECT_TINT="$(require_number tint "$(look .correct.tint)")"
CORRECT_LUM_MIX="$(require_number lum_mix "$(look .correct.lum_mix)")"
CORRECT_SLOPE="$(look .correct.slope)"
CORRECT_OFFSET="$(look .correct.offset)"
CORRECT_POWER="$(look .correct.power)"
CORRECT_SIZE="$(require_number CORRECT_SIZE "${CORRECT_SIZE:-33}")"
# The triples are not validated here: they never reach a filter graph, only this generator's argv,
# and it refuses a malformed one itself. Validate where a value is READ.
correct_args() {
	printf '%s' "--exposure $CORRECT_EXPOSURE --temp $CORRECT_TEMP --tint $CORRECT_TINT"
	printf '%s' " --slope $CORRECT_SLOPE --offset $CORRECT_OFFSET --power $CORRECT_POWER"
	printf '%s' " --lum-mix $CORRECT_LUM_MIX --size $CORRECT_SIZE"
}
CORRECT_PREFIX=""
SAT="$(require_number SAT "$(look .colour.saturation)")"
WARM="$(require_number WARM "$(look .colour.warmth)")"
G_PIVOT="$(require_number pivot "$(look .tone.pivot)")"
G_CONTRAST="$(require_number contrast "$(look .tone.contrast)")"
G_TOE="$(require_number toe "$(look .tone.toe)")"
G_SHOULDER="$(require_number shoulder "$(look .tone.shoulder)")"
G_BLACK="$(require_number black "$(look .tone.black)")"
G_GAMMA_REF="$(require_number gamma "$(look .tone.gamma)")"   # gamma the look was tuned at...
Y_REF="$(require_number reference_yavg "$(look .match.reference_yavg)")"  # ...against this mean
GRAIN_STRENGTH="$(require_number GRAIN_STRENGTH "${GRAIN_STRENGTH:-$(look .grain.strength)}")"
SMOOTHING="$(require_number SMOOTHING "${SMOOTHING:-$(look .stabilisation.smoothing)}")"
STAB="${STAB:-1}"; FEED="${FEED:-0}"; MATCH="${MATCH:-1}"; DRY="${DRY:-0}"
# PROOF=<seconds> renders that many seconds through the REAL chain, into dist/proofs/ rather than
# dist/03-final/. Two reasons it exists. docs/BATCH_RUNBOOK.md makes a proof a required sign-off
# before committing to the slow render, and until now that recipe lived only in shell history. And
# nothing in the suite executed this filter graph at all: shellcheck cannot see inside the string
# (it reported clean on both previously shipped load-bearing bugs), the parity check touches only
# the tone curve, and every other test stops at DRY=1 — so a dropped label here went green and
# failed three minutes into a 19-clip run.

# Collect inputs: folders expand to their .mov files.
CLIPS=()
for arg in "$@"; do
	if [ -d "$arg" ]; then
		while IFS= read -r f; do CLIPS+=("$f"); done < <(find "$arg" -maxdepth 1 -name '*.mov' | sort)
	elif [ -f "$arg" ]; then CLIPS+=("$arg")
	else
		echo "not found: $arg" >&2
		emit_code REFUSE_NOT_FOUND
		emit refused code REFUSE_NOT_FOUND argument "$arg"
		exit 1
	fi
done
if [ "${#CLIPS[@]}" -eq 0 ]; then
	echo "usage: grade <folder|clip.mov> [...]" >&2
	emit_code REFUSE_NO_ARGS
	emit refused code REFUSE_NO_ARGS
	exit 1
fi

# The Feed crop is a per-clip judgement — 750 is IMG_0609's composition, chosen to drop the
# parking-ceiling strip at the top. Applied to a batch it silently reframes 18 other clips, and
# the files look done. That is CONTEXT.md's "squashed" failure class in another dimension, so it
# is refused rather than warned about. Setting CROP_Y explicitly is taken as "yes, this offset for
# all of them", which is a decision someone made rather than a default nobody saw.
if [ "$FEED" = "1" ] && [ "${#CLIPS[@]}" -gt 1 ] && [ -z "${CROP_Y:-}" ]; then
	echo "REFUSING: FEED=1 across ${#CLIPS[@]} clips with no CROP_Y." >&2
	echo "  The 4:5 crop offset is a per-clip framing call; the default 750 is IMG_0609's." >&2
	echo "  Either run one clip at a time, or pass CROP_Y=<pixels> to accept one offset for all." >&2
	emit_code REFUSE_FEED_NO_CROP_Y
	emit refused code REFUSE_FEED_NO_CROP_Y clips "${#CLIPS[@]}"
	exit 1
fi

# Nothing is CREATED until the arguments are known to be good. This used to run first, so
# `./grade.sh` with no arguments made the output directories and an empty run-*.txt, then printed
# usage and exited 1 — a usage error leaving litter in the folder someone delivers from, and one
# stray report per suite run.
# Resolved once, here, rather than inside the render loop: it is spliced into
# `crop=2160:2700:0:` and a comma in it would open a second filter.
CROP_Y_OK="$(require_number CROP_Y "${CROP_Y:-750}")"

check_disk_space "$WORK/dist" 10
mkdir -p "$OUT_DIR" "$REPORT_DIR" "$CACHE"
[ -z "$FRAME" ] || mkdir -p "$FRAME_DIR"
REPORT="$REPORT_DIR/run-$(date +%Y%m%d-%H%M%S).txt"
: > "$REPORT"
# Under JSON=1 the human line still lands in the report and leaves stdout to the event stream.
# The report is the thing a person reads afterwards, so it is never the half that gets dropped.
say() {
	if [ "$JSON" = "1" ]; then
		printf '%s\n' "$*" >> "$REPORT"
	else
		printf '%s\n' "$*" | tee -a "$REPORT"
	fi
}

# shellcheck disable=SC2046  # deliberate split: correct_args is a flag list, not one argument
if [ "$("$SCRIPT_DIR/make-correct-lut.py" --check-neutral $(correct_args))" = "active" ]; then
	CORRECT_LUT="$CACHE/correct.cube"
	# shellcheck disable=SC2046
	"$SCRIPT_DIR/make-correct-lut.py" "$CORRECT_LUT" $(correct_args) >/dev/null
	CORRECT_PREFIX="lut3d=file='${CORRECT_LUT}':interp=tetrahedral,"
fi

say "grade run $(date '+%Y-%m-%d %H:%M:%S')  —  ${#CLIPS[@]} clip(s)"
say "look: sat=$SAT warm=$WARM grain=$GRAIN_STRENGTH stab=$STAB exposure-match=$MATCH"
[ -z "$CORRECT_PREFIX" ] || say "correction: exposure=$CORRECT_EXPOSURE temp=$CORRECT_TEMP tint=$CORRECT_TINT slope=$CORRECT_SLOPE offset=$CORRECT_OFFSET power=$CORRECT_POWER lum_mix=$CORRECT_LUM_MIX (${CORRECT_SIZE}-point cube)"
say ""
emit run_start clips "${#CLIPS[@]}" saturation "$SAT" warmth "$WARM" \
	grain "$GRAIN_STRENGTH" stabilisation "$STAB" exposure_match "$MATCH" \
	proof "${PROOF:-0}" dry "$DRY" report "$REPORT" out_dir "$OUT_DIR"

OK=0; SKIPPED=0; FAILED=0
for SRC in "${CLIPS[@]}"; do
	# The clip name becomes a path component AND reaches the filter graph, through the per-clip
	# tone LUT and the transform path. It is the one input nobody types.
	CLIP="$(require_clip_name "$(basename "${SRC%.*}")")"

	# Orientation is the source's business. Refuse a clip that would render sideways rather than
	# producing a confidently wrong file; require_portrait decodes a frame and measures it.
	if ! SRC_SIZE="$(require_portrait "$SRC" 2>/dev/null)"; then
		say "SKIP  $CLIP — not portrait. Fix the source orientation, then retry."
		emit_code REFUSE_NOT_PORTRAIT
		emit clip_skipped clip "$CLIP" code REFUSE_NOT_PORTRAIT source "$SRC"
		SKIPPED=$((SKIPPED+1)); continue
	fi
	SRC_W="${SRC_SIZE% *}"; SRC_H="${SRC_SIZE#* }"

	# --- exposure match: one cheap probe, not a full pass --------------------------------
	GAMMA="$G_GAMMA_REF"; YAVG="-"
	if [ "$MATCH" = "1" ] && [ -n "${YAVG_IN:-}" ]; then
		# ALREADY MEASURED. The probe reads the clip's post-CST mean, which does not change when a
		# look does — so an interface adjusting a curve re-measures the same number on every
		# render. It costs about a second of a four-second preview. Passing it back skips that,
		# and the render is identical either way, which a test asserts.
		YAVG="$(require_number YAVG_IN "$YAVG_IN")"
		GAMMA=$("$SCRIPT_DIR/solve-gamma.py" "$YAVG" "$Y_REF" "$G_GAMMA_REF")
	elif [ "$MATCH" = "1" ]; then
		YAVG=$(ffmpeg -v error -ss 1 -i "$SRC" -frames:v 1 \
			-vf "lut3d=file='${CST}':interp=tetrahedral,scale=320:-1,signalstats,metadata=print:file=-" \
			-f null - 2>/dev/null | grep -m1 -oE 'YAVG=[0-9.]+' | cut -d= -f2 || true)
		# `metadata=print:file=-` not plain `metadata=print`: the latter logs at INFO level, which
		# `-v error` suppresses, so the probe returned EMPTY on every clip and every clip silently
		# got the reference gamma. The exposure match appeared to run and did nothing.
		# The solve lives in scripts/solve-gamma.py, not in a python3 -c string here: a degenerate
		# probe used to raise inside it and take the whole batch down at clip n, and a program
		# built by interpolation cannot be tested. Arguments go through argv.
		if [ -n "$YAVG" ]; then
			GAMMA=$("$SCRIPT_DIR/solve-gamma.py" "$YAVG" "$Y_REF" "$G_GAMMA_REF")
		fi
	fi

	TONE="$CACHE/${CLIP}_tone.cube"

	# --- stabilisation: detect on the SOURCE, so no intermediate is needed ---------------
	SFX=""
	if [ "$STAB" = "1" ] && [ -z "$FRAME" ]; then
		TRF="$WORK/dist/stab/${CLIP}.trf"
		if ! transform_is_fresh "$TRF" "$SRC" && [ "$DRY" != "1" ]; then
			mkdir -p "$(dirname "$TRF")"
			trap 'rm -f "${TRF}.partial"' EXIT
			ffmpeg -v error -y -i "$SRC" -vf "lut3d=file='${CST}':interp=tetrahedral,vidstabdetect=shakiness=5:accuracy=15:stepsize=6:result=${TRF}.partial" -f null -
			require_nonempty "${TRF}.partial" "stabilisation analysis"
			mv "${TRF}.partial" "$TRF"
			trap - EXIT
		fi
		if transform_is_fresh "$TRF" "$SRC"; then
			SFX="$(stab_prefix "$TRF" "$SMOOTHING")"
			say "      stabilising from $TRF (smoothing=${SMOOTHING})"
			emit stabilisation clip "$CLIP" state fresh transform "$TRF" smoothing "$SMOOTHING"
		elif [ -f "$TRF" ]; then
			# Only reachable in a dry run: a real run recomputes a stale transform a few lines
			# up, because `! transform_is_fresh` is what triggers the detect pass. The old
			# message said "rendering unstabilised", which is what neither case does — a dry run
			# renders nothing and a real one refreshes it. Saying the cost out loud matters
			# because this is the one decision in a plan that costs ~65s per clip to get wrong.
			say "      stale transform at $TRF — a real run will recompute it (~65s)"
			emit_code STALE_TRANSFORM
			emit stabilisation clip "$CLIP" state stale transform "$TRF"
		else
			# Worth saying out loud: this is the one decision in a dry run that costs ~65s per
			# clip to get wrong, and it used to be made silently.
			say "      no transform at $TRF — will render unstabilised"
			emit_code NO_TRANSFORM
			emit stabilisation clip "$CLIP" state none transform "$TRF"
		fi
	fi

	FPS="$(source_fps "$SRC")"
	# A frame rate change is either an integer relation — dropping or repeating whole frames — or
	# it is retiming, which without motion compensation looks worse than not converting at all.
	# 24 to 30 is the case that tempts people and the one that judders. Refused rather than
	# silently interpolated; ffmpeg's `fps` filter would happily do it.
	FPS_FILTER=""
	if [ -n "$FPS_OUT" ]; then
		if ! FPS_FILTER="$(fps_filter "$FPS" "$FPS_OUT")"; then
			say "SKIP  $CLIP — $FPS_OUT fps from ${FPS} needs retiming."
			emit_code REFUSE_FPS_RETIME
			emit clip_skipped clip "$CLIP" code REFUSE_FPS_RETIME source "$SRC"
			SKIPPED=$((SKIPPED+1)); continue
		fi
	fi
	say "$CLIP  post-CST YAVG=${YAVG}  gamma=${GAMMA}$([ "$GAMMA" != "$G_GAMMA_REF" ] && echo " (matched)")"
	# matched is 1/0 rather than true/false: emit() writes a bare number or a quoted string, and a
	# JSON boolean would need a third case for one field.
	emit clip_planned clip "$CLIP" source "$SRC" yavg "$YAVG" gamma "$GAMMA" \
		matched "$([ "$GAMMA" != "$G_GAMMA_REF" ] && echo 1 || echo 0)" fps "$FPS"
	[ "$DRY" = "1" ] && continue

	# Generated AFTER the dry-run exit, not before: DRY=1 is documented as "plan only, render
	# nothing", and this was writing a 4096-entry cube per clip on a run that renders nothing. The
	# probe and the solve still happen above, because the solved gamma IS the plan.
	"$SCRIPT_DIR/make-tone-lut.py" "$TONE" --gamma "$GAMMA" --pivot "$G_PIVOT" \
		--contrast "$G_CONTRAST" --toe "$G_TOE" --shoulder "$G_SHOULDER" --black "$G_BLACK" >/dev/null

	# The preview stops here: same chain head, same tone cube, no delivery stage. It goes through
	# grade_chain like everything else, so it cannot drift from what the render does — the suite's
	# "grade chain is built in exactly one place" test is what holds that.
	if [ -n "$FRAME" ]; then
		# The stage is in the NAME. Two frames of one clip at one timecode differ only by which
		# chain produced them, and holding a URL while the other stage renders over it is how a
		# test once compared a frame against itself and read 16 code values of error.
		frame_out="$FRAME_DIR/${CLIP}_t${FRAME}s_${FRAME_STAGE}.png"
		# 16-bit PNG, because the point of a preview is to predict a 10-bit render and an 8-bit
		# still is a known source of misreading in the Bench. Lanczos to match the delivery
		# resample; no dither, because nothing here reduces to 8 bits.
		if [ "$FRAME_STAGE" = source ]; then
			# The SAME resample, so the two frames register pixel for pixel and one can be
			# measured against the other. format=gbrp16le before the scale forces the YUV to RGB
			# conversion to happen where the chain's first lut3d forces it, on the same matrix and
			# range — the difference between that and letting the PNG encoder negotiate it is the
			# untagged-probe mistake, which cost hours once already.
			frame_graph="format=gbrp16le,scale=-2:${FRAME_HEIGHT}:flags=lanczos"
		else
			frame_graph="$(grade_chain "$TONE" "$SAT" "$WARM" \
  "${CORRECT_PREFIX}lut3d=file='${CST}':interp=tetrahedral,"),scale=-2:${FRAME_HEIGHT}:flags=lanczos"
		fi
		if ffmpeg -v error -y -ss "$FRAME" -i "$SRC" -frames:v 1 -filter_complex \
"[0:v]${frame_graph}[o]" \
			-map "[o]" -pix_fmt rgb48be "$frame_out"; then
			say "      -> $(basename "$frame_out")  (${FRAME_STAGE}, no delivery stage)"
			emit frame clip "$CLIP" path "$frame_out" at "$FRAME" height "$FRAME_HEIGHT" \
				stage "$FRAME_STAGE"
			OK=$((OK+1))
		else
			say "FAIL  $CLIP — preview frame failed. Continuing."
			emit_code FRAME_FAILED
			emit clip_failed clip "$CLIP" source "$SRC"
			FAILED=$((FAILED+1))
		fi
		continue
	fi

	# What makes this path ONE pass is the head: the CST is spliced into grade_chain rather than
	# spent on its own decode, so conversion, look and tone all happen in the single graph below.
	# Everything else — the grade, then the stabilisation warp onward — is shared with the staged
	# path and lives in lib.sh, which is where the measurements for each part of it live.
	#
	# `0:a:0?` MUST stay quoted: `?` is a glob character. bash only survives it unquoted because an
	# unmatched glob passes through literally, so a file named `0:a:00` in the launch directory
	# breaks it — and this path was the one place it was still bare.
	# A numeric flag pair or nothing at all. Built as a plain string rather than an array because
	# macOS ships bash 3.2, where expanding an EMPTY array under `set -u` raises "unbound
	# variable" — the trap lib.sh's header documents.
	LIMIT=""
	[ -n "$PROOF" ] && LIMIT="-t $PROOF"

	render() {  # render <w> <h> <suffix> [crop]
		local w=$1 h=$2 suffix=$3 crop=${4:-}
		local out="$OUT_DIR/${CLIP}_${suffix}.mp4"
		# A proof is named so it can never be mistaken for a deliverable in a folder listing.
		[ -n "$PROOF" ] && out="$OUT_DIR/${CLIP}_${suffix}_proof-${PROOF}s.mp4"
		# shellcheck disable=SC2086  # $LIMIT is a deliberate split: a numeric flag pair or nothing
		render_delivery "$out" "$suffix encode" \
			-y -i "$SRC" -f lavfi -i "$(grain_plate "$w" "$h" "$FPS")" -filter_complex \
"[0:v]$(grade_chain "$TONE" "$SAT" "$WARM" \
  "${CORRECT_PREFIX}lut3d=file='${CST}':interp=tetrahedral," "${DELIVERY_SETPARAMS},"),\
$(delivery_image_chain "$w" "$h" "$SFX" "$crop")${FPS_FILTER}[b];\
[1:v]$(delivery_grain_branch "$w" "$h" "$GRAIN_STRENGTH")[g];\
[b][g]${DELIVERY_BLEND}[o]" \
			-map "[o]" -map "0:a:0?" -shortest \
			-c:v libx264 -profile:v high -preset slow -crf 18 \
			-color_primaries bt709 -color_trc bt709 -colorspace bt709 \
			-c:a aac -b:a 192k -movflags +faststart \
			$LIMIT || return 1
		# `|| return 1` above is load-bearing now that the caller invokes render() inside an `if`:
		# that suppresses `set -e` for this whole body, so without it a failed render would fall
		# through to `stat` on a file that was never written.
		local bytes; bytes=$(stat -f%z "$out")
		say "      -> $(basename "$out")  $(( bytes / 1048576 ))MB"
		emit output clip "$CLIP" deliverable "$suffix" path "$out" bytes "$bytes"
	}

	# A FAILED CLIP MUST NOT TAKE THE BATCH WITH IT. render_delivery leaves the previous deliverable
	# untouched and returns non-zero, but a bare call propagates through `set -e` and kills the loop
	# — measured: a two-clip run whose first render failed never attempted the second, printed no
	# summary, and left the report ending mid-file. In a 19-clip unattended run a failure at clip 3
	# silently costs the other 16. The non-portrait path a few lines up already skips and continues;
	# this gives the render path the same treatment, and the exit status below makes sure a run with
	# failures in it can never be read as a clean one.
	# Even widths: libx264 rejects an odd dimension, and it rejects it at encode time, after the
	# graph has been built and the first frames decoded.
	REELS_W=$(( HEIGHT * 9 / 16 )); REELS_W=$(( REELS_W - REELS_W % 2 ))
	FEED_H=$(( HEIGHT * 1350 / 1920 )); FEED_H=$(( FEED_H - FEED_H % 2 ))
	FEED_W=$(( FEED_H * 4 / 5 )); FEED_W=$(( FEED_W - FEED_W % 2 ))
	if render "$REELS_W" "$HEIGHT" "reels-stories_9x16" \
		&& { [ "$FEED" != "1" ] || render "$FEED_W" "$FEED_H" "feed_4x5" \
			"$(crop_prefix "$SRC_W" "$SRC_H" 4 5 "$CROP_Y_OK")"; }
	then
		OK=$((OK+1))
	else
		say "FAIL  $CLIP — render failed, previous output left as it was. Continuing."
		emit_code RENDER_FAILED
		emit clip_failed clip "$CLIP" source "$SRC"
		FAILED=$((FAILED+1))
	fi
done

say ""
say "done: $OK rendered, $SKIPPED skipped, $FAILED failed"
say "report: $REPORT"
emit run_done rendered "$OK" skipped "$SKIPPED" failed "$FAILED" report "$REPORT"
[ "$FAILED" -eq 0 ] || exit 1
