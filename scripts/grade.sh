#!/bin/bash
# grade.sh — one clip, one ffmpeg pass, source to deliverable.
#
# Usage:
#   ./scripts/grade.sh <folder|clip.mov> [...]   process a shoot folder or named clips
#
# Every knob is an environment variable. This list is the complete one; USAGE.md groups the same
# set by what it is for, and went looking for exactly the two that used to be missing here.
#   DELIVERABLES=<list>  what to render, comma separated. Default 'reels'. Each entry is either a
#                     preset — 'reels' (9:16) or 'feed' (4:5) — or 'name:aspect-w:aspect-h[:offset]',
#                     e.g. 'reels,feed' or 'square:1:1,wide:16:9:400'. Height follows the aspect off
#                     the shared delivery width; see WIDTH.
#   CROP_OFFSET=<px>  crop offset for every deliverable that crops and does not carry its own: from
#                     the top on a frame taller than the window, from the left on one wider.
#                     There is NO DEFAULT: a deliverable that crops is refused without one, because
#                     where the window sits is a composition call per clip. CROP_OFFSET=centre says
#                     explicitly that this clip does not need one, resolved against each frame.
#   WIDTH=<px>        the delivery width every deliverable shares. Defaults to HEIGHT's 9:16 width,
#                     so the default run is 1080 wide exactly as before.
#   STAB=0            skip stabilisation entirely (faster)
#   SMOOTHING=<n>     frames of camera-path lowpass; higher is closer to locked-off
#   MATCH=0           skip exposure metering and render every clip as shot
#   GRAIN_STRENGTH=<n>  override look.json's grain strength
#   PROOF=<seconds>   render this many seconds through the real chain into .loggrade/proofs/
#   DRY=1             plan only, render nothing
#   HEIGHT=<px>       height of the 9:16 reference frame (default 1920). It sets the shared
#                     delivery width; each deliverable's own height follows its aspect.
#   DELIVERY_CODEC=<c>  h264 (default) | hevc | hevc10 | prores422 | prores422hq. lib.sh's
#                     delivery_encode_args says what each one is for.
#   DELIVERY_QUALITY=<q>  auto (default) | high | max. ProRes takes auto only: its profile is its quality.
#   DELIVERY_CONTAINER=<c>  mp4 (default) | mov. ProRes needs mov, and mp4 with it is refused.
#   DELIVERY_AUDIO=0  deliver with no audio stream (default 1).
#   FPS_OUT=<n>       output frame rate. Default is the source's. Only an integer relation is
#                     accepted — anything needing retiming is refused rather than interpolated.
#   CORRECT_SIZE=<n>  points per axis in the correction cube (default 33; see its header for
#                     the measured cost and error at 17, 33 and 65)
#   FRAME=<seconds>   render ONE frame at that timecode through the grade chain to a PNG and
#                     stop — the app's exact preview. No delivery stage, no stabilisation.
#   FRAME_HEIGHT=<px> height of that frame (default 1440, the app's preview height in PreviewRenderer)
#   FRAME_STAGE=source  the same frame with NO grade chain on it: the decoded Apple Log picture,
#                     resampled identically. It is what the app's live preview grades itself while
#                     a control is moving. Default 'graded'.
#   JSON=1            emit one machine-readable event per line on stdout instead of the human
#                     lines, which then go only to the run report. Named codes go to stderr
#                     either way. This is what the app drives the engine through.
#   EXPORT_DIR=<dir>  where deliverables land. Default: '<work>/LogGrade export <date time>'.
#   GRADE_WORK_DIR=<dir>  where src/ is read from and exports and .loggrade/ are written, instead of the repo. A
#                     `.workdir` file beside the repo does the same thing; resolve_work_dir in
#                     lib.sh picks between them. The whole bats suite runs through this.
#   CONVERT=<name>    the conversion out of Apple Log for this run, overriding look.json's
#                     convert.cube: a cube from luts/rendering/ or luts/film/.
#   LOOK_FILE=<path>  which look.json every stage reads (lib.sh). Changing it changes the grade,
#                     so it is a knob like any other rather than an implementation detail.
#
# WHY ONE PASS. The staged pipeline (01-baseline -> 02-grade -> 03-final) writes two ~2.5GB ProRes
# intermediates per clip and decodes the footage three times. Those intermediates existed so the
# look could be re-tuned without redoing the CST. The look is now FROZEN, so they earn nothing:
# nothing ever re-renders from the master. Collapsing to a single filter graph removes two full
# encodes, two full decodes and ~5GB of disk per clip. The staged scripts are kept for re-tuning;
# this is the path for production runs.
#
# WHAT IS AUTOMATIC vs WHAT THIS REFUSES TO GUESS:
#   automatic  exposure match, stabilisation, the whole grade, tag verification
#   refuses    a clip whose frame cannot be measured, and a cropped deliverable with no offset —
#              that offset is a composition call per clip, so there is nothing sensible to default
#
# Orientation is NOT handled here or anywhere: it is an ingest concern and the source is trusted.
# See docs/adr/0005_ORIENTATION_IS_AN_INGEST_CONCERN.md.
#
# EXPOSURE METERING is the part that makes "one recipe" actually mean "one look". Clips shot across
# a shoot window land differently, and in an unattended batch nobody notices until the edit. Each
# clip's own log-average and grey balance are measured from one decoded frame and applied IN LINEAR
# LIGHT, before the conversion, where a stop is a stop (scripts/solve-exposure.py). The move is
# damped, so a dusk clip stays darker than a noon one. MATCH=0 renders every clip as shot.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WORK="$(resolve_work_dir "$ROOT")"
# Taken before anything else runs, so the report's wall time includes argument checks and the crop
# probe's decode rather than starting where the report file happens to be created.
RUN_T0="$(now_ms)"

# PROOF=<seconds> renders that many seconds through the REAL chain, into .loggrade/proofs/ rather
# than the export folder. Two reasons it exists. A proof is the sign-off before committing to the slow
# render. And
# nothing in the suite executed this filter graph at all: shellcheck cannot see inside the string
# (it reported clean on both previously shipped load-bearing bugs), the parity check touches only
# the tone curve, and every other test stopped at DRY=1 — so a dropped label went green and failed
# three minutes into a 19-clip run.
PROOF="${PROOF:-}"
# Validated because it is spliced UNQUOTED below (`-t $PROOF`) so that an empty value disappears
# instead of becoming an empty argument — bash 3.2 cannot expand an empty array under `set -u`.
# That split means whitespace in PROOF becomes extra ffmpeg OPTIONS, and `-f mp4 <path>` would
# append a second output file, walking straight past render_delivery's staging.
[ -z "$PROOF" ] || PROOF="$(require_number PROOF "$PROOF")"

# FRAME=<seconds> renders a single frame through the REAL grade chain and stops. It is the app's
# exact preview: a still cannot show grain, the sharpener, the chroma denoise, the stabiliser or
# the dither, all of which are delivery-stage, so this deliberately covers the grade only and the
# interface says so. What it does cover is everything a slider moves — the conversion, the hue curves, the
# tone curve, saturation and warmth — at full resolution, resampled to display size after
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
# The app never builds a filter graph, which is what EndToEndTests and ADR 0008 are for, so
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
FRAME_DIR="$(work_cache "$WORK")/frames"
# Everything except an ungraded preview frame runs Apple's conversion, including the exposure probe
# that would otherwise fail into an empty measurement and plan every clip at the reference gamma.
# A film cube is a conversion too: resolve_conversion refuses a missing one either way.
CONVERT_NAME="${CONVERT:-$(look .convert.cube)}" || exit 1
CST="$(resolve_conversion "$CONVERT_NAME")" || exit 1

# Delivery shape. The sizes were 1080x1920 and 1080x1350 written into the render calls, then an
# aspect plus one height; they are an aspect plus one shared WIDTH now, because the set of shapes
# is no longer fixed at two. HEIGHT is kept as the knob it was — the 9:16 reference frame — and the
# width falls out of it, so a run that says nothing renders 1080 wide exactly as before.
HEIGHT="$(require_number HEIGHT "${HEIGHT:-1920}")"
WIDTH="$(delivery_width)" || exit 1
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
	OUT_DIR="$(work_cache "$WORK")/proofs"
else
	OUT_DIR="$(export_dir "$WORK")"
fi
# Reports are not deliverables — keep them out of the folder someone uploads from.
REPORT_DIR="$(work_cache "$WORK")/reports"
# A persistent cache for the per-clip tone LUTs the exposure match generates. It used to be
# assigned over WORK itself, which left one name meaning two things — and the stabilisation
# path below was then built from the wrong one, landing inside the cache instead of
# where 00-stabilise-detect.sh writes. WORK stays the work-dir root.
CACHE="$(work_cache "$WORK")/work"

# --- the look. Every value comes from look.json; nothing here holds a copy. ---
# This path used to carry its own tone block while reading colour, grain and stabilisation from
# look.json, so a grade sent from the since-removed Bench updated shipped.cube and the staged path
# while THIS script kept rendering the previous tone. That is the two-copies-one-edited failure
# look() was written to end, one layer up. No fallbacks on purpose: a missing value must stop the
# run, not quietly substitute a different look.
# Every one of these is spliced into an ffmpeg filter graph, and the look file is usually the
# app's LOOK_FILE rather than typed — see require_number in lib.sh for why that matters.
# The loaders keep a value that is already set, which is for callers that source lib.sh — so the
# names are cleared first, or a stray SAT in someone's environment would become the grade.
unset SAT WARM HUE_LUT
load_grade_look || exit 1
load_delivery_look || exit 1

# --- the input correction ---------------------------------------------------------------
# Exposure, white balance and the CDL wheels, generated into one cube that runs BEFORE Apple's
# conversion. Before, because Apple Log decodes to 12x diffuse white at code 1.0 — about 3.6 stops
# of highlight headroom — and the Rec.709 cube lands all of it on a display ceiling of 1.0: a
# correction applied after it works on display-referred pixels and clips highlights the source
# still holds. scripts/make-correct-lut.py carries the maths, the published transfer function it
# decodes with, and the measurements behind its size.
#
# A NEUTRAL correction leaves the filter out of the graph entirely. That is not only cheaper: an
# identity cube pays interpolation error on every pixel. The generator owns that rule, so it is not
# restated here.
CORRECT_ARGS="$(correction_args)" || exit 1
CORRECT_STATE="$(correction_state)" || exit 1
CORRECT_SIZE="$(require_number CORRECT_SIZE "${CORRECT_SIZE:-33}")"
CORRECT_PREFIX=""
# Delivery-stage like the sharpener: not in a FRAME, which the live preview is held to, and not
# under FINISH=0. load_delivery_look reads the strength.
DENOISE_PREFIX=""
[ "$FINISH" = 0 ] || DENOISE_PREFIX="$(denoise_prefix "$DENOISE_STRENGTH")"

# --- halation ------------------------------------------------------------------------------
# A warm glow spilling from bright things into what surrounds them, computed in linear light between
# the correction and the conversion. lib.sh's halation_prefix carries the graph and its traps, and
# docs/adr/0012 carries why it sits here. A strength of 0 leaves the whole stage out of the graph,
# because even idle it moves the picture — the generator owns that rule.
#
# The tint is three numbers spliced into a filter graph, so each is validated where it is read.
HAL_STRENGTH="$(require_number halation.strength "$(look .halation.strength)")"
HAL_STATE="$(halation_state)" || exit 1
HAL_THRESHOLD="$(require_number halation.threshold "$(look .halation.threshold)")"
HAL_RADIUS="$(require_number halation.radius "$(look .halation.radius)")"
HAL_TINT="$(require_numbers halation.tint "$(look .halation.tint)")" || exit 1
IFS=, read -r _tr _tg _tb _extra <<< "$HAL_TINT"
if [ -n "${_extra:-}" ] || [ -z "${_tb:-}" ]; then
	echo "halation.tint must be three numbers, r,g,b: got '$HAL_TINT'" >&2
	exit 1
fi
HAL_DIR=""
TONE_SHAPE_ARGS="$(tone_shape_args)" || exit 1
TONE_GAMMA="$(require_number gamma "$(look .tone.gamma)")"
# Where a clip's metered log-average lands, in stops from mid grey.
REF_STOPS="$(require_number reference_stops "$(look .match.reference_stops)")"
STAB="${STAB:-1}"; MATCH="${MATCH:-1}"; DRY="${DRY:-0}"
# Empty means NOT GIVEN, which is a different thing from 0; see crop_offset.
CROP_OFFSET_OK="$(crop_offset CROP_OFFSET "${CROP_OFFSET:-}")" || exit 1
[ "$CROP_OFFSET_OK" != "-" ] || CROP_OFFSET_OK=""
case "$MATCH" in
	0|1) ;;
	*)
		echo "REFUSING: MATCH must be 0 or 1, got: $MATCH" >&2
		echo "  1 meters each clip's exposure and white balance before the conversion," >&2
		echo "  0 renders every clip as shot." >&2
		emit_code REFUSE_MATCH_MODE
		emit refused code REFUSE_MATCH_MODE
		exit 1;;
esac

# --- what to render ---------------------------------------------------------------------
# Parallel arrays rather than one array of records: macOS ships bash 3.2, which has no associative
# arrays and no nested ones. They are built together and read together, so they cannot drift.
#
# Globbing is off across the split because a deliverable name reaches a filename, and an unquoted
# `*` in DELIVERABLES would otherwise expand against the launch directory before it is ever seen.
D_NAME=(); D_AW=(); D_AH=(); D_OFF=(); D_SUFFIX=()
set -f
OLD_IFS="$IFS"; IFS=','
for _spec in ${DELIVERABLES:-reels}; do
	IFS="$OLD_IFS"
	_fields="$(deliverable_spec "$_spec")" || {
		emit_code REFUSE_DELIVERABLE
		emit refused code REFUSE_DELIVERABLE spec "$_spec"
		exit 1
	}
	read -r _n _aw _ah _off _sfx <<< "$_fields"
	D_NAME+=("$_n"); D_AW+=("$_aw"); D_AH+=("$_ah"); D_OFF+=("$_off"); D_SUFFIX+=("$_sfx")
	IFS=','
done
IFS="$OLD_IFS"
set +f
if [ "${#D_NAME[@]}" -eq 0 ]; then
	echo "REFUSING: DELIVERABLES is empty — there is nothing to render." >&2
	emit_code REFUSE_NO_DELIVERABLES
	emit refused code REFUSE_NO_DELIVERABLES
	exit 1
fi

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

# A crop offset is a per-clip judgement, so there is nothing sensible to default it to. It used to
# default to 750 — IMG_0609's composition, chosen to drop the parking-ceiling strip at the top —
# which is the correct framing for exactly one clip in the world and silently reframes every other,
# producing files that look done. That is CONTEXT.md's "squashed" failure class in another
# dimension, and the same class of baked-in constant that match.reference_yavg was (ADR 0011).
#
# So the default is GONE rather than replaced. Centre was the obvious substitute and is refused as
# one: a batch centred by default gives files that all look finished and are all framed wrong. It
# is available as `CROP_OFFSET=centre`, which is the same picture arrived at by a decision somebody made
# rather than by a default nobody saw. The app never relied on the default — it blocks a render
# whose cropping deliverable has no per-clip offset, which is the rule this now matches.
#
# This fires for ONE clip as readily as for twenty. The old check only caught batches, on the
# reasoning that a single clip was the case the default was chosen for — which was only ever true
# of IMG_0609.
#
# WHICH deliverables crop is a fact about the SOURCE's shape, not about their names: a 4:5 frame is
# a crop of a 9:16 master and the whole frame of a 4:5 one, and 9:16 is a crop of a landscape one.
# So it needs measurements, taken here because this refusal has to land before anything is created —
# a run that refuses halfway through has already written files someone has to reason about. It
# costs one decode a clip (~0.6s), against three minutes a clip.
#
# EVERY clip, not just the first. Whether a deliverable crops depends on the shape of the clip in
# front of it, and a batch can mix portrait and landscape. The sizes are kept, aligned with CLIPS,
# so the loop below reuses them rather than decoding each clip a second time. A clip that cannot be
# measured is stored as "-" and left out of the vote: the loop skips it, so it has no say in a
# refusal about files that will exist.
T_MEASURE_T0=$(now_ms)
CLIP_SIZES=()
for _src in "${CLIPS[@]}"; do
	_size="$(source_frame_size "$_src" 2>/dev/null || true)"
	case "$_size" in
		*' '*) ;;
		*) _size="-";;
	esac
	CLIP_SIZES+=("$_size")
done
T_MEASURE=$(( $(now_ms) - T_MEASURE_T0 ))
_i=0
while [ "$_i" -lt "${#D_NAME[@]}" ]; do
	_crops=0
	# Not for FRAME: a still is the uncropped picture and writes no deliverable, and the live
	# preview asks for one before anyone has placed a crop. A DRY plan still refuses, because it
	# reports what an export would do.
	if [ -z "$FRAME" ] && [ "${D_OFF[$_i]}" = "-" ] && [ -z "$CROP_OFFSET_OK" ]; then
		for _size in "${CLIP_SIZES[@]}"; do
			[ "$_size" != "-" ] || continue
			if deliverable_crops "$_size" "${D_AW[$_i]}" "${D_AH[$_i]}"; then
				_crops=1; break
			fi
		done
	fi
	if [ "$_crops" = "1" ]; then
		echo "REFUSING: '${D_NAME[$_i]}' crops, and no offset was given." >&2
		echo "  Where the window sits is a composition call per clip — there is no sensible" >&2
		echo "  default, so this is refused rather than guessed." >&2
		echo "  Pass CROP_OFFSET=<pixels>, or CROP_OFFSET=centre to say that explicitly, or give this" >&2
		echo "  deliverable its own: ${D_NAME[$_i]}:${D_AW[$_i]}:${D_AH[$_i]}:<px|centre>." >&2
		emit_code REFUSE_CROP_NO_OFFSET
		emit refused code REFUSE_CROP_NO_OFFSET clips "${#CLIPS[@]}" deliverable "${D_NAME[$_i]}"
		exit 1
	fi
	_i=$(( _i + 1 ))
done

# Nothing is CREATED until the arguments are known to be good. This used to run first, so
# `./grade.sh` with no arguments made the output directories and an empty run-*.txt, then printed
# usage and exited 1 — a usage error leaving litter in the folder someone delivers from, and one
# stray report per suite run.
#
# 10GB is the staged stages' margin, kept although this path writes no ProRes masters; nothing
# records a measurement for a one-pass run, so it has not been lowered on a guess.
check_disk_space "$WORK" 10
# The export folder is made only when a deliverable is about to land in it: a preview, a dry run or
# a refused clip must not leave an empty dated folder behind.
mkdir -p "$REPORT_DIR" "$CACHE"
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

if [ "$CORRECT_STATE" = "active" ]; then
	CORRECT_LUT="$CACHE/correct.cube"
	# shellcheck disable=SC2086  # deliberate split: a flag list of validated values
	"$SCRIPT_DIR/make-correct-lut.py" "$CORRECT_LUT" $CORRECT_ARGS --size "$CORRECT_SIZE" >/dev/null
	CORRECT_PREFIX="lut3d=file='${CORRECT_LUT}':interp=tetrahedral,"
fi
# The hue curves' cube, once per run; grade_chain splices it in after the print.
ensure_hue_lut "$CACHE" || exit 1
# The cubes depend only on the threshold, so they are made once per run. The prefix itself is built
# per clip below, because its radius is a fraction of each clip's own frame.
if [ "$HAL_STATE" = "active" ]; then
	HAL_DIR="$CACHE/halation"
	# Not on a dry run, which renders nothing — the same rule the per-clip tone cube follows.
	[ "$DRY" = "1" ] || "$SCRIPT_DIR/make-halation-luts.py" "$HAL_DIR" --threshold "$HAL_THRESHOLD" >/dev/null
fi

# Phase totals for the report's summary, in integer milliseconds (see now_ms). Everything from the
# first line of this script to here — argument checks, the crop probe, the correction cube — is
# "preflight".
T_PREFLIGHT=$(( $(now_ms) - RUN_T0 - T_MEASURE )); T_PROBE=0; T_STAB=0; T_TONE=0; T_ENCODE=0; T_FRAME=0
say "grade run $(date '+%Y-%m-%d %H:%M:%S')  —  ${#CLIPS[@]} clip(s)"
say "look: gamma=$TONE_GAMMA sat=$SAT warm=$WARM grain=$GRAIN_STRENGTH stab=$STAB exposure-match=$MATCH"
say "convert: $CONVERT_NAME"
# The flags themselves, which are exactly what the generator ran on, rather than a second spelling.
[ -z "$CORRECT_PREFIX" ] || say "correction: $CORRECT_ARGS (${CORRECT_SIZE}-point cube)"
[ -z "$HAL_DIR" ] || say "halation: strength=$HAL_STRENGTH threshold=$HAL_THRESHOLD radius=$HAL_RADIUS tint=$HAL_TINT"
# Not for FRAME: the app runs one per preview, and on a 2017 Intel MacBook these six process spawns
# measured ~150ms of a ~3s frame — for a line that is identical in every preview report.
[ -n "$FRAME" ] || report_environment "$ROOT"
# The EFFECTIVE values, after defaults and look.json, which is what a report read weeks later needs:
# the environment that launched the run is gone by then.
report_line "knobs:   deliverables=$(IFS=,; printf '%s' "${D_NAME[*]}") width=$WIDTH height=$HEIGHT crop_offset=${CROP_OFFSET_OK:--} match=$MATCH stab=$STAB smoothing=$SMOOTHING grain=$GRAIN_STRENGTH fps_out=${FPS_OUT:--} proof=${PROOF:--} frame=${FRAME:--} frame_height=$FRAME_HEIGHT frame_stage=$FRAME_STAGE halation=${HAL_STRENGTH}/${HAL_THRESHOLD}/${HAL_RADIUS}/${HAL_TINT} grain_weights=${GRAIN_SHADOWS}/${GRAIN_HIGHLIGHTS} audio_highpass=${AUDIO_HIGHPASS_HZ} codec=$DELIVERY_CODEC quality=$DELIVERY_QUALITY container=$DELIVERY_CONTAINER audio=$DELIVERY_AUDIO correct_size=$CORRECT_SIZE convert=$CONVERT_NAME reference_stops=$REF_STOPS denoise=$DENOISE_STRENGTH sharpen=$SHARPEN gauge=$GAUGE dry=$DRY json=$JSON"
report_line "work:    $WORK"
report_line "preflight took $(fmt_ms "$T_PREFLIGHT")"
say ""
emit run_start clips "${#CLIPS[@]}" saturation "$SAT" warmth "$WARM" \
	grain "$GRAIN_STRENGTH" stabilisation "$STAB" exposure_match "$MATCH" \
	exposure_reference "$REF_STOPS" deliverables "$(IFS=,; printf '%s' "${D_NAME[*]}")" \
	proof "${PROOF:-0}" dry "$DRY" report "$REPORT" out_dir "$OUT_DIR"

OK=0; SKIPPED=0; FAILED=0
# A position counter beside the loop: CLIP_SIZES was measured up front, aligned with CLIPS, and is
# read by index. It advances BEFORE any `continue`, or a skipped clip would hand the next one the
# size of the clip before it — a wrong crop on a file that looks finished.
CLIP_I=0
for SRC in "${CLIPS[@]}"; do
	CLIP_T0=$(now_ms)

	# The clip name becomes a path component AND reaches the filter graph, through the per-clip
	# tone LUT and the transform path. It is the one input nobody types.
	CLIP="$(require_clip_name "$(basename "${SRC%.*}")")"

	# Measured up front, with the crop refusal. Every crop and the halation radius come from these
	# two numbers, so a clip without them is skipped rather than guessed at.
	SRC_SIZE="${CLIP_SIZES[$CLIP_I]}"
	CLIP_I=$(( CLIP_I + 1 ))
	if [ "$SRC_SIZE" = "-" ]; then
		say "SKIP  $CLIP — could not measure a decoded frame. Check the file plays, then retry."
		emit_code REFUSE_UNMEASURED
		emit clip_skipped clip "$CLIP" code REFUSE_UNMEASURED source "$SRC"
		SKIPPED=$((SKIPPED+1)); continue
	fi
	SRC_W="${SRC_SIZE% *}"; SRC_H="${SRC_SIZE#* }"
	HALATION_PREFIX=""
	[ -z "$HAL_DIR" ] || HALATION_PREFIX="$(halation_prefix "$HAL_DIR" \
		"$(halation_sigma "$SRC_W" "$SRC_H" "$HAL_RADIUS")" "$HAL_STRENGTH" "$HAL_TINT")"

	# --- exposure metering: one decoded frame, measured in linear ------------------------
	# The maths lives in scripts/solve-exposure.py rather than in a python3 -c string here: a
	# program built by interpolation cannot be tested, and a degenerate frame must answer "no
	# correction" instead of taking the batch down at clip n. Arguments go through argv.
	#
	# The per-clip correction cube it feeds is built below, after the dry-run exit, like the tone
	# cube: a plan renders nothing.
	METERED="0 0 0"
	if [ "$MATCH" != "0" ]; then
		_t=$(now_ms)
		METERED="$(probe_scene_exposure "$SRC" "$REF_STOPS")"
		_t=$(( $(now_ms) - _t )); T_PROBE=$(( T_PROBE + _t ))
		report_line "      exposure meter took $(fmt_ms "$_t")"
	fi

	TONE="$CACHE/${CLIP}_tone.cube"

	# --- stabilisation: detect on the SOURCE, so no intermediate is needed ---------------
	SFX=""
	if [ "$STAB" = "1" ] && [ -z "$FRAME" ]; then
		TRF="$(transform_path "$WORK" "$CLIP")"
		if ! transform_is_fresh "$TRF" "$SRC" && [ "$DRY" != "1" ]; then
			_t=$(now_ms)
			detect_transform "$SRC" "$TRF" "lut3d=file='${CST}':interp=tetrahedral,"
			_t=$(( $(now_ms) - _t )); T_STAB=$(( T_STAB + _t ))
			report_line "      stabilisation detect took $(fmt_ms "$_t")"
		fi
		if transform_is_fresh "$TRF" "$SRC"; then
			SFX="$(stab_prefix "$TRF" "$SMOOTHING")"
			say "      stabilising from $TRF (smoothing=${SMOOTHING})"
			emit stabilisation clip "$CLIP" state fresh transform "$TRF" smoothing "$SMOOTHING"
		elif [ -f "$TRF" ]; then
			# Only reachable in a dry run: a real run recomputes a stale transform a few lines
			# up, because `! transform_is_fresh` is what triggers the detect pass. The old
			# message said "rendering unstabilised", which is what neither case does — a dry run
			# renders nothing and a real one refreshes it.
			#
			# Both this branch and the next say the cost out loud: whether a transform exists is the
			# one decision in a plan that costs ~65s per clip to get wrong, and it used to be made
			# silently.
			say "      stale transform at $TRF — a real run will recompute it (~65s)"
			emit_code STALE_TRANSFORM
			emit stabilisation clip "$CLIP" state stale transform "$TRF"
		else
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
	read -r METER_STOPS METER_TEMP METER_TINT <<< "$METERED"
	say "$CLIP  metered exposure=${METER_STOPS} temp=${METER_TEMP} tint=${METER_TINT}"
	# width and height are the DECODED frame, which is how the app learns a clip's orientation
	# without a second guard of its own (ClipProbe reads the container, which lies about rotation).
	emit clip_planned clip "$CLIP" source "$SRC" fps "$FPS" width "$SRC_W" height "$SRC_H" \
		metered_exposure "$METER_STOPS" metered_temp "$METER_TEMP" metered_tint "$METER_TINT"
	# Frame count and duration are what tell a slow run on a long clip from a slow machine. Not for
	# FRAME: the app runs that once per preview, where two ffprobes (~120ms) buy nothing it uses.
	if [ -z "$FRAME" ]; then
		report_line "      source: ${SRC_W}x${SRC_H} at ${FPS} fps, $(probe_number "$SRC" format=duration)s, $(probe_number "$SRC" stream=nb_frames) frames, $(( $(stat -f%z "$SRC" 2>/dev/null || echo 0) / 1048576 ))MB  ($SRC)"
	fi
	[ "$DRY" = "1" ] && continue

	# Generated AFTER the dry-run exit, not before: DRY=1 is documented as "plan only, render
	# nothing", and this was writing a 4096-entry cube per clip on a run that renders nothing. The
	# probe and the solve still happen above, because the solved gamma IS the plan.
	# A neutral curve is no cube and no luma branch; see grade_chain.
	TONE_STATE="$(tone_state "$TONE_GAMMA")" || exit 1
	if [ "$TONE_STATE" = neutral ]; then
		TONE=""
	else
		_t=$(now_ms)
		# shellcheck disable=SC2086  # deliberate split: a flag list of validated values
		"$SCRIPT_DIR/make-tone-lut.py" "$TONE" --gamma "$TONE_GAMMA" $TONE_SHAPE_ARGS >/dev/null
		_t=$(( $(now_ms) - _t )); T_TONE=$(( T_TONE + _t ))
		report_line "      tone cube took $(fmt_ms "$_t")"
	fi

	CLIP_CORRECT_PREFIX="$CORRECT_PREFIX"
	if [ "$METERED" != "0 0 0" ]; then
		# shellcheck disable=SC2086  # deliberate split: three validated numbers
		CLIP_CORRECT_ARGS="$(correction_args $METERED)" || exit 1
		# shellcheck disable=SC2086
		CLIP_CORRECT_STATE="$(correction_state $METERED)" || exit 1
		if [ "$CLIP_CORRECT_STATE" = active ]; then
			CLIP_CORRECT_LUT="$CACHE/${CLIP}_correct.cube"
			# shellcheck disable=SC2086  # a flag list of validated values
			"$SCRIPT_DIR/make-correct-lut.py" "$CLIP_CORRECT_LUT" $CLIP_CORRECT_ARGS \
				--size "$CORRECT_SIZE" >/dev/null
			CLIP_CORRECT_PREFIX="lut3d=file='${CLIP_CORRECT_LUT}':interp=tetrahedral,"
		else
			CLIP_CORRECT_PREFIX=""
		fi
	fi

	# The preview stops here: same chain head, same tone cube, no delivery stage. It goes through
	# grade_chain like everything else, so it cannot drift from what the render does — the suite's
	# "grade chain is built in exactly one place" test is what holds that.
	if [ -n "$FRAME" ]; then
		# The stage is in the NAME. Two frames of one clip at one timecode differ only by which
		# chain produced them, and holding a URL while the other stage renders over it is how a
		# test once compared a frame against itself and read 16 code values of error.
		frame_out="$FRAME_DIR/${CLIP}_t${FRAME}s_${FRAME_STAGE}.png"
		# 16-bit PNG, because the point of a preview is to predict a 10-bit render and an 8-bit
		# still was a known source of misreading in the since-removed Bench. Lanczos to match the
		# delivery resample; no dither, because nothing here reduces to 8 bits.
		if [ "$FRAME_STAGE" = source ]; then
			# The SAME resample, so the two frames register pixel for pixel and one can be
			# measured against the other. format=gbrp16le before the scale forces the YUV to RGB
			# conversion to happen where the chain's first lut3d forces it, on the same matrix and
			# range — the difference between that and letting the PNG encoder negotiate it is the
			# untagged-probe mistake, which cost hours once already.
			frame_graph="format=gbrp16le,scale=-2:${FRAME_HEIGHT}:flags=lanczos"
		else
			frame_graph="$(grade_chain "$TONE" "$SAT" "$WARM" \
				"${CLIP_CORRECT_PREFIX}${HALATION_PREFIX}lut3d=file='${CST}':interp=tetrahedral,"),scale=-2:${FRAME_HEIGHT}:flags=lanczos"
		fi
		# One argument list for both the report and ffmpeg, so what is recorded cannot drift from what
		# ran. Never empty, so bash 3.2's empty-array trap under `set -u` does not apply.
		frame_args=(-ss "$FRAME" -i "$SRC" -frames:v 1 -filter_complex "[0:v]${frame_graph}[o]" \
			-map "[o]" -pix_fmt rgb48be "$frame_out")
		report_command "frame" "${frame_args[@]}"
		_t=$(now_ms)
		if ffmpeg -v error -y "${frame_args[@]}"; then
			_t=$(( $(now_ms) - _t )); T_FRAME=$(( T_FRAME + _t ))
			report_line "      frame render took $(fmt_ms "$_t"), clip $(fmt_ms $(( $(now_ms) - CLIP_T0 )))"
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
	# The warp, crop and reduction come FIRST (delivery_geometry), so the grade runs at delivery
	# size; the pieces live in lib.sh, which is where the measurements for each part of them live.
	#
	# A numeric flag pair or nothing at all. Built as a plain string rather than an array because
	# macOS ships bash 3.2, where expanding an EMPTY array under `set -u` raises "unbound
	# variable" — the trap lib.sh's header documents.
	LIMIT=""
	[ -n "$PROOF" ] && LIMIT="-t $PROOF"

	# Every deliverable of the clip in ONE ffmpeg: decoded, stabilised, shrunk and graded once, then
	# split into each deliverable's crop, finish and encode (render_deliverables). Reels and feed
	# used to be two whole passes over the source, grade included.
	render() {  # render — reads R_* for the clip's deliverables
		local n="${#R_SUFFIX[@]}" i specs=() scale fw fh
		for (( i = 0; i < n; i++ )); do
			specs+=("${R_H[$i]}:${R_CROP[$i]:--}")
		done
		scale="$(delivery_scale "$SRC_H" "${specs[@]}")"
		fw="$(scaled_even "$SRC_W" "$scale")"; fh="$(scaled_even "$SRC_H" "$scale")"
		# The glow is in the shared frame's pixels, which is what it is blurred in.
		local HALATION_PREFIX=""
		[ -z "$HAL_DIR" ] || HALATION_PREFIX="$(halation_prefix "$HAL_DIR" \
			"$(delivery_halation_sigma "$SRC_W" "$SRC_H" "$HAL_RADIUS" "$scale")" "$HAL_STRENGTH" "$HAL_TINT")"
		local shared
		shared="$(delivery_geometry "$fw" "$fh" "$SFX")$(grade_chain "$TONE" "$SAT" "$WARM" \
  "${DENOISE_PREFIX}${CLIP_CORRECT_PREFIX}${HALATION_PREFIX}lut3d=file='${CST}':interp=tetrahedral," "${DELIVERY_SETPARAMS},")"
		local args=() label=""
		for (( i = 0; i < n; i++ )); do
			args+=("${R_OUT[$i]}" "$WIDTH" "${R_H[$i]}" \
				"$(scaled_crop "${R_CROP[$i]}" "$scale" "$fw" "$fh")$(delivery_image_chain "$WIDTH" "${R_H[$i]}" "" "" "$FINISH" "$FPS")${FPS_FILTER}")
			label="${label:+$label+}${R_SUFFIX[$i]}"
		done
		local t0; t0=$(now_ms)
		# shellcheck disable=SC2086  # $LIMIT is a deliberate split: a numeric flag pair or nothing
		render_deliverables "$label encode" "$SRC" "$FPS" "$shared" "$n" "${args[@]}" $LIMIT || return 1
		# `|| return 1` above is load-bearing now that the caller invokes render() inside an `if`:
		# that suppresses `set -e` for this whole body, so without it a failed render would fall
		# through to `stat` on a file that was never written.
		local ms=$(( $(now_ms) - t0 )); T_ENCODE=$(( T_ENCODE + ms ))
		[ "$n" -eq 1 ] || report_line "      one pass for $n deliverables; each line below is that pass's time"
		local bytes
		for (( i = 0; i < n; i++ )); do
			report_encode "${R_SUFFIX[$i]} encode" "${R_OUT[$i]}" "$ms"
			bytes=$(stat -f%z "${R_OUT[$i]}")
			say "      -> $(basename "${R_OUT[$i]}")  $(( bytes / 1048576 ))MB"
			emit output clip "$CLIP" deliverable "${R_SUFFIX[$i]}" path "${R_OUT[$i]}" bytes "$bytes"
		done
	}

	# A FAILED CLIP MUST NOT TAKE THE BATCH WITH IT. render_delivery leaves the previous deliverable
	# untouched and returns non-zero, but a bare call propagates through `set -e` and kills the loop
	# — measured: a two-clip run whose first render failed never attempted the second, printed no
	# summary, and left the report ending mid-file. In a 19-clip unattended run a failure at clip 3
	# silently costs the other 16. The unmeasured path a few lines up already skips and continues;
	# this gives the render path the same treatment, and the exit status below makes sure a run with
	# failures in it can never be read as a clean one.
	# Every deliverable in the set, in the order it was given. The set used to be one `if` with
	# `reels` in the condition and `feed` in its tail, which is why adding a third shape meant
	# editing this line rather than a list.
	#
	# THE SIZE IS SAID OUT LOUD, per deliverable, because it is DERIVED now. Height follows the
	# aspect off the shared width, so a HEIGHT that is not a multiple of 16 lands a 9:16 frame a
	# pixel or two off the number that was asked for. Stating it is the difference between a
	# rounding and a silent wrongness; this file has no budget for the second kind.
	CLIP_OK=1
	R_OUT=(); R_H=(); R_CROP=(); R_SUFFIX=()
	_i=0
	while [ "$_i" -lt "${#D_NAME[@]}" ]; do
		_h="$(deliverable_height "$WIDTH" "${D_AW[$_i]}" "${D_AH[$_i]}")"
		# The deliverable's own offset if it carries one, otherwise the run's. A deliverable that
		# does not crop ignores both, and crop_prefix is what decides that.
		_off="${D_OFF[$_i]}"
		[ "$_off" != "-" ] || _off="$CROP_OFFSET_OK"
		if ! _crop="$(crop_prefix "$SRC_W" "$SRC_H" "${D_AW[$_i]}" "${D_AH[$_i]}" "$_off")"; then
			say "FAIL  $CLIP — ${D_NAME[$_i]}: that crop does not fit ${SRC_W}x${SRC_H}."
			emit_code REFUSE_CROP_WINDOW
			emit clip_failed clip "$CLIP" source "$SRC" deliverable "${D_NAME[$_i]}"
			CLIP_OK=0; break
		fi
		# The RESOLVED window, read back out of the filter, not the word that was asked for. `centre`
		# is computed per clip against the measured frame, so printing "centre" would hide where it
		# actually landed — the same silence the derived height is printed to avoid. The window's
		# size is printed too, because a small source is upscaled to the delivery width without it.
		say "      ${D_NAME[$_i]}: ${WIDTH}x${_h}${_crop:+ $(crop_description "$_crop")}"
		R_OUT+=("$(deliverable_path "$OUT_DIR" "$CLIP" "${D_SUFFIX[$_i]}" "$PROOF")")
		R_H+=("$_h"); R_CROP+=("$_crop"); R_SUFFIX+=("${D_SUFFIX[$_i]}")
		_i=$(( _i + 1 ))
	done
	[ "$CLIP_OK" = 0 ] || { mkdir -p "$OUT_DIR" && render; } || CLIP_OK=0
	report_line "      clip took $(fmt_ms $(( $(now_ms) - CLIP_T0 )))"
	if [ "$CLIP_OK" = "1" ]; then
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
# "other" is whatever no phase claims — mostly ffprobe calls and the report's own bookkeeping. It
# is printed so the phases visibly add up, and a large one says a phase is missing its timer.
RUN_MS=$(( $(now_ms) - RUN_T0 ))
report_line "finished $(date '+%Y-%m-%d %H:%M:%S'), wall time $(fmt_ms "$RUN_MS")"
report_line "  preflight       $(fmt_ms "$T_PREFLIGHT")"
report_line "  frame measure   $(fmt_ms "$T_MEASURE")"
report_line "  exposure probe  $(fmt_ms "$T_PROBE")"
report_line "  stabilisation   $(fmt_ms "$T_STAB")"
report_line "  tone cube       $(fmt_ms "$T_TONE")"
report_line "  encode          $(fmt_ms "$T_ENCODE")"
report_line "  frame render    $(fmt_ms "$T_FRAME")"
report_line "  other           $(fmt_ms $(( RUN_MS - T_PREFLIGHT - T_MEASURE - T_PROBE - T_STAB - T_TONE - T_ENCODE - T_FRAME )))"
say "report: $REPORT"
emit run_done rendered "$OK" skipped "$SKIPPED" failed "$FAILED" report "$REPORT"
[ "$FAILED" -eq 0 ] || exit 1
