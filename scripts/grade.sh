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
#   CROP_Y=<px>       vertical offset for every deliverable that crops and does not carry its own.
#                     There is NO DEFAULT: a deliverable that crops is refused without one, because
#                     where the window sits is a composition call per clip. CROP_Y=centre says
#                     explicitly that this clip does not need one, resolved against each frame.
#   WIDTH=<px>        the delivery width every deliverable shares. Defaults to HEIGHT's 9:16 width,
#                     so the default run is 1080 wide exactly as before.
#   STAB=0            skip stabilisation entirely (faster)
#   SMOOTHING=<n>     frames of camera-path lowpass; higher is closer to locked-off
#   MATCH=0           skip exposure matching and use look.json's gamma raw
#   MATCH=batch       solve every clip against the MEDIAN of this run's own clips instead of
#                     look.json's reference_yavg, which was measured on one frame of one shoot
#   YAVG_IN=<n>       the clip's post-CST mean, if it has already been measured. Skips the probe,
#                     which costs about a second; the render is identical either way.
#   GRAIN_STRENGTH=<n>  override look.json's grain strength
#   PROOF=<seconds>   render this many seconds through the real chain into dist/proofs/
#   DRY=1             plan only, render nothing
#   HEIGHT=<px>       height of the 9:16 reference frame (default 1920). It sets the shared
#                     delivery width; each deliverable's own height follows its aspect.
#   FPS_OUT=<n>       output frame rate. Default is the source's. Only an integer relation is
#                     accepted — anything needing retiming is refused rather than interpolated.
#   CORRECT_SIZE=<n>  points per axis in the correction cube (default 33; see its header for
#                     the measured cost and error at 17, 33 and 65)
#   LOOK=<name|none>  which film-emulation cube to use, by stem from luts/looks/, or none for a
#                     neutral grade. Overrides look.json's .look.lut for this run.
#   PRINT=<name|none> which print-film cube follows the look, by stem from luts/print/, or none.
#                     Overrides look.json's .print.lut for this run.
#   FRAME=<seconds>   render ONE frame at that timecode through the grade chain to a PNG and
#                     stop — the app's exact preview. No delivery stage, no stabilisation.
#   FRAME_HEIGHT=<px> height of that frame (default 1440, the Bench's working height)
#   FRAME_STAGE=source  the same frame with NO grade chain on it: the decoded Apple Log picture,
#                     resampled identically. It is what the app's live preview grades itself while
#                     a control is moving. Default 'graded'.
#   JSON=1            emit one machine-readable event per line on stdout instead of the human
#                     lines, which then go only to the run report. Named codes go to stderr
#                     either way. This is what the app drives the engine through.
#   GRADE_WORK_DIR=<dir>  where src/ is read from and dist/ is written, instead of the repo. A
#                     `.workdir` file beside the repo does the same thing; resolve_work_dir in
#                     lib.sh picks between them. The whole bats suite runs through this.
#   LOOK_FILE=<path>  which look.json every stage reads (lib.sh). Changing it changes the grade,
#                     so it is a knob like any other rather than an implementation detail.
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
#   refuses    a clip that does not decode as portrait, and a cropped deliverable with no offset —
#              that offset is a composition call per clip, so there is nothing sensible to default
#
# Orientation is NOT handled here or anywhere: it is an ingest concern and the source is trusted.
# See docs/adr/0005_ORIENTATION_IS_AN_INGEST_CONCERN.md.
#
# EXPOSURE MATCHING is the part that makes "one recipe" actually mean "one look". Clips shot across
# a shoot window land differently under a fixed curve, and in an unattended batch nobody notices
# until the edit. Each clip's post-CST mean is measured and the tone curve's gamma is solved per
# clip to land on the same place. Disable with MATCH=0 to get the frozen curve raw.
#
# WHERE "the same place" IS, is the part that does not travel. MATCH=1 lands every clip on
# look.json's match.reference_yavg, which is a measurement of one frame of IMG_0609 ~20 minutes
# before sunset. For that shoot it is the right anchor; for anyone else's footage, or for another
# shoot under different light, it is a number with no meaning that still moves every clip's gamma.
# MATCH=batch anchors on the run's OWN median instead, so a shoot is matched to itself. The default
# stays MATCH=1 because changing it would change every existing render — see docs/adr/0011.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WORK="$(resolve_work_dir "$ROOT")"
# Taken before anything else runs, so the report's wall time includes argument checks and the crop
# probe's decode rather than starting where the report file happens to be created.
RUN_T0="$(now_ms)"

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

# Delivery shape. The sizes were 1080x1920 and 1080x1350 written into the render calls, then an
# aspect plus one height; they are an aspect plus one shared WIDTH now, because the set of shapes
# is no longer fixed at two. HEIGHT is kept as the knob it was — the 9:16 reference frame — and the
# width falls out of it, so a run that says nothing renders 1080 wide exactly as before.
HEIGHT="$(require_number HEIGHT "${HEIGHT:-1920}")"
WIDTH="$(require_number WIDTH "${WIDTH:-$(( HEIGHT * 9 / 16 ))}")"
WIDTH=$(( WIDTH - WIDTH % 2 ))
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
PRINT_LUT="$(resolve_look_lut "${PRINT:-$(look .print.lut)}" "$ROOT" print)"
LOOK_STRENGTH="$(require_unit look.strength "$(look .look.strength)")"
PRINT_STRENGTH="$(require_unit print.strength "$(look .print.strength)")"

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

# --- halation ------------------------------------------------------------------------------
# A warm glow spilling from bright things into what surrounds them, computed in linear light between
# the correction and the conversion. lib.sh's halation_prefix carries the graph and its traps, and
# docs/adr/0012 carries why it sits here. A strength of 0 leaves the whole stage out of the graph,
# which is what keeps a default render identical to the precursor's — the generator owns that rule.
#
# The tint is three numbers spliced into a filter graph, so each is validated where it is read.
HAL_STRENGTH="$(require_number halation.strength "$(look .halation.strength)")"
HAL_THRESHOLD="$(require_number halation.threshold "$(look .halation.threshold)")"
HAL_RADIUS="$(require_number halation.radius "$(look .halation.radius)")"
HAL_TINT="$(look .halation.tint)"
IFS=, read -r _tr _tg _tb _extra <<< "$HAL_TINT"
if [ -n "${_extra:-}" ] || [ -z "${_tb:-}" ]; then
	echo "halation.tint must be three numbers, r,g,b: got '$HAL_TINT'" >&2
	exit 1
fi
HAL_TINT="$(require_number halation.tint "$_tr"),$(require_number halation.tint "$_tg"),$(require_number halation.tint "$_tb")"
HAL_DIR=""
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
GRAIN_SHADOWS="$(require_unit grain.shadows "$(look .grain.shadows)")"
GRAIN_HIGHLIGHTS="$(require_unit grain.highlights "$(look .grain.highlights)")"
SMOOTHING="$(require_number SMOOTHING "${SMOOTHING:-$(look .stabilisation.smoothing)}")"
STAB="${STAB:-1}"; MATCH="${MATCH:-1}"; DRY="${DRY:-0}"
# Empty means NOT GIVEN, which is a different thing from 0 — 0 is the top of the frame and a real
# answer. Validated here because it is spliced into `crop=2160:2700:0:` and a comma in it would
# open a second filter.
CROP_Y_OK=""
if [ -n "${CROP_Y:-}" ]; then
	case "$CROP_Y" in
		centre|center) CROP_Y_OK="centre";;
		*) CROP_Y_OK="$(require_number CROP_Y "$CROP_Y")";;
	esac
fi
case "$MATCH" in
	0|1|batch) ;;
	*)
		echo "REFUSING: MATCH must be 0, 1 or batch, got: $MATCH" >&2
		echo "  0 uses look.json's gamma raw, 1 solves against look.json's reference_yavg," >&2
		echo "  batch solves against the median of this run's own clips." >&2
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

# A crop offset is a per-clip judgement, so there is nothing sensible to default it to. It used to
# default to 750 — IMG_0609's composition, chosen to drop the parking-ceiling strip at the top —
# which is the correct framing for exactly one clip in the world and silently reframes every other,
# producing files that look done. That is CONTEXT.md's "squashed" failure class in another
# dimension, and the same class of baked-in constant that match.reference_yavg was (ADR 0011).
#
# So the default is GONE rather than replaced. Centre was the obvious substitute and is refused as
# one: a batch centred by default gives files that all look finished and are all framed wrong. It
# is available as `CROP_Y=centre`, which is the same picture arrived at by a decision somebody made
# rather than by a default nobody saw. The app never relied on the default — it blocks a render
# whose cropping deliverable has no per-clip offset, which is the rule this now matches.
#
# This fires for ONE clip as readily as for twenty. The old check only caught batches, on the
# reasoning that a single clip was the case the default was chosen for — which was only ever true
# of IMG_0609.
#
# WHICH deliverables crop is a fact about the SOURCE's shape, not about their names: a 4:5 frame is
# a crop of a 9:16 master and the whole frame of a 4:5 one. So it needs one measurement, taken here
# because this refusal has to land before anything is created — a run that refuses halfway through
# has already written files someone has to reason about. It costs one decode (~0.6s), against three
# minutes a clip.
#
# If that measurement fails, every deliverable is ASSUMED to crop. The guard then fires when it did
# not strictly need to, which costs a re-run; guessing the other way costs a batch of silently
# reframed files, which is the failure this exists to prevent.
# EVERY clip, not just the first. Whether a deliverable crops depends on the shape of the clip in
# front of it, so one clip's answer is not the batch's — and the first clip is exactly the one that
# might be about to be skipped, which would decide the run on a frame it never renders. A clip that
# is not portrait is left out for that reason: the loop below skips it, so it has no vote on a
# refusal about files that will exist.
PROBE_SIZE=""
for _src in "${CLIPS[@]}"; do
	_size="$(source_frame_size "$_src" 2>/dev/null || true)"
	case "$_size" in
		*' '*) [ "${_size#* }" -gt "${_size% *}" ] || continue;;
	esac
	# The first shape that will actually be rendered decides, and an unmeasurable one is left empty
	# so deliverable_crops answers conservatively.
	PROBE_SIZE="$_size"
	break
done
_i=0
while [ "$_i" -lt "${#D_NAME[@]}" ]; do
	if [ "${D_OFF[$_i]}" = "-" ] && [ -z "$CROP_Y_OK" ] \
		&& deliverable_crops "$PROBE_SIZE" "${D_AW[$_i]}" "${D_AH[$_i]}"; then
		echo "REFUSING: '${D_NAME[$_i]}' crops, and no offset was given." >&2
		echo "  Where the window sits is a composition call per clip — there is no sensible" >&2
		echo "  default, so this is refused rather than guessed." >&2
		echo "  Pass CROP_Y=<pixels>, or CROP_Y=centre to say that explicitly, or give this" >&2
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
# The cubes depend only on the threshold, so they are made once per run. The prefix itself is built
# per clip below, because its radius is a fraction of each clip's own frame.
if [ "$("$SCRIPT_DIR/make-halation-luts.py" --check-neutral --strength "$HAL_STRENGTH")" = "active" ]; then
	HAL_DIR="$CACHE/halation"
	# Not on a dry run, which renders nothing — the same rule the per-clip tone cube follows.
	[ "$DRY" = "1" ] || "$SCRIPT_DIR/make-halation-luts.py" "$HAL_DIR" --threshold "$HAL_THRESHOLD" >/dev/null
fi

# --- MATCH=batch: the exposure reference comes from this run's own clips -----------------
# One probe per clip, up front, so the median is known before the first render. The results are
# kept and handed to the loop: probing twice would double the cost for a number that cannot have
# changed, and it is the same command either way because both callers use probe_yavg.
#
# A clip whose probe comes back empty is left out of the MEDIAN but still rendered — it falls back
# to the reference gamma below, exactly as it does under MATCH=1.
# Phase totals for the report's summary, in integer milliseconds (see now_ms). Everything from the
# first line of this script to here — argument checks, the crop probe, the correction cube — is
# "preflight".
T_PREFLIGHT=$(( $(now_ms) - RUN_T0 )); T_ORIENT=0; T_PROBE=0; T_STAB=0; T_TONE=0; T_ENCODE=0; T_FRAME=0
BATCH_YAVGS=()
if [ "$MATCH" = "batch" ]; then
	say "measuring ${#CLIPS[@]} clip(s) for a batch exposure reference"
	_t=$(now_ms)
	for SRC in "${CLIPS[@]}"; do
		_y="$(probe_yavg "$SRC" "$CST")"
		[ -n "$_y" ] || _y="-"
		BATCH_YAVGS+=("$_y")
	done
	T_PROBE=$(( $(now_ms) - _t ))
	report_line "      batch exposure probe took $(fmt_ms "$T_PROBE") for ${#CLIPS[@]} clip(s)"
	# `|| true` would hide an all-empty run behind look.json's reference, which is the silent
	# substitution this whole file refuses to make. Stop instead.
	if ! Y_REF="$(printf '%s\n' "${BATCH_YAVGS[@]}" | grep -v '^-$' | median)"; then
		echo "REFUSING: MATCH=batch, but not one clip's exposure could be measured." >&2
		echo "  Without a measurement there is nothing to match to. Use MATCH=1 to grade" >&2
		echo "  against look.json's reference, or MATCH=0 for its gamma raw." >&2
		emit_code REFUSE_BATCH_NO_PROBE
		emit refused code REFUSE_BATCH_NO_PROBE clips "${#CLIPS[@]}"
		exit 1
	fi
	say "batch exposure reference: YAVG=$Y_REF (look.json's is not used under MATCH=batch)"
fi

say "grade run $(date '+%Y-%m-%d %H:%M:%S')  —  ${#CLIPS[@]} clip(s)"
say "look: sat=$SAT warm=$WARM grain=$GRAIN_STRENGTH stab=$STAB exposure-match=$MATCH"
say "film: look=${LOOK_LUT:-none}@$LOOK_STRENGTH print=${PRINT_LUT:-none}@$PRINT_STRENGTH"
[ -z "$CORRECT_PREFIX" ] || say "correction: exposure=$CORRECT_EXPOSURE temp=$CORRECT_TEMP tint=$CORRECT_TINT slope=$CORRECT_SLOPE offset=$CORRECT_OFFSET power=$CORRECT_POWER lum_mix=$CORRECT_LUM_MIX (${CORRECT_SIZE}-point cube)"
[ -z "$HAL_DIR" ] || say "halation: strength=$HAL_STRENGTH threshold=$HAL_THRESHOLD radius=$HAL_RADIUS tint=$HAL_TINT"
# Not for FRAME: the app runs one per preview, and on a 2017 Intel MacBook these six process spawns
# measured ~150ms of a ~3s frame — for a line that is identical in every preview report.
[ -n "$FRAME" ] || report_environment "$ROOT"
# The EFFECTIVE values, after defaults and look.json, which is what a report read weeks later needs:
# the environment that launched the run is gone by then.
report_line "knobs:   deliverables=$(IFS=,; printf '%s' "${D_NAME[*]}") width=$WIDTH height=$HEIGHT crop_y=${CROP_Y_OK:--} match=$MATCH reference_yavg=$Y_REF stab=$STAB smoothing=$SMOOTHING grain=$GRAIN_STRENGTH fps_out=${FPS_OUT:--} proof=${PROOF:--} frame=${FRAME:--} frame_height=$FRAME_HEIGHT frame_stage=$FRAME_STAGE look_lut=${LOOK_LUT:-none}@$LOOK_STRENGTH print_lut=${PRINT_LUT:-none}@$PRINT_STRENGTH halation=${HAL_STRENGTH}/${HAL_THRESHOLD}/${HAL_RADIUS}/${HAL_TINT} grain_weights=${GRAIN_SHADOWS}/${GRAIN_HIGHLIGHTS} correct_size=$CORRECT_SIZE dry=$DRY json=$JSON"
report_line "work:    $WORK"
report_line "preflight took $(fmt_ms "$T_PREFLIGHT")"
say ""
emit run_start clips "${#CLIPS[@]}" saturation "$SAT" warmth "$WARM" \
	grain "$GRAIN_STRENGTH" stabilisation "$STAB" exposure_match "$MATCH" \
	exposure_reference "$Y_REF" deliverables "$(IFS=,; printf '%s' "${D_NAME[*]}")" \
	proof "${PROOF:-0}" dry "$DRY" report "$REPORT" out_dir "$OUT_DIR"

OK=0; SKIPPED=0; FAILED=0
# Indexed rather than `for SRC in "${CLIPS[@]}"`: under MATCH=batch the probe already ran, and the
# result is found by position.
CLIP_I=0
for SRC in "${CLIPS[@]}"; do
	# Taken and advanced BEFORE any `continue`, because BATCH_YAVGS is aligned with CLIPS — every
	# clip, including the ones about to be skipped. Advancing it further down would silently hand
	# clip n+1 the measurement of clip n as soon as anything ahead of it skipped.
	BI="$CLIP_I"; CLIP_I=$(( CLIP_I + 1 ))
	CLIP_T0=$(now_ms)

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
	HALATION_PREFIX=""
	[ -z "$HAL_DIR" ] || HALATION_PREFIX="$(halation_prefix "$HAL_DIR" \
		"$(halation_sigma "$SRC_H" "$HAL_RADIUS")" "$HAL_STRENGTH" "$HAL_TINT")"
	_t=$(( $(now_ms) - CLIP_T0 )); T_ORIENT=$(( T_ORIENT + _t ))
	report_line "      orientation check took $(fmt_ms "$_t")"

	# --- exposure match: one cheap probe, not a full pass --------------------------------
	# The solve lives in scripts/solve-gamma.py, not in a python3 -c string here: a degenerate
	# probe used to raise inside it and take the whole batch down at clip n, and a program built by
	# interpolation cannot be tested. Arguments go through argv.
	GAMMA="$G_GAMMA_REF"; YAVG="-"
	if [ "$MATCH" != "0" ]; then
		if [ -n "${YAVG_IN:-}" ]; then
			# ALREADY MEASURED. The probe reads the clip's post-CST mean, which does not change
			# when a look does — so an interface adjusting a curve re-measures the same number on
			# every render. It costs about a second of a four-second preview. Passing it back skips
			# that, and the render is identical either way, which a test asserts.
			YAVG="$(require_number YAVG_IN "$YAVG_IN")"
		elif [ "$MATCH" = "batch" ]; then
			# Measured in the pre-pass that produced Y_REF; "-" means that probe came back empty.
			YAVG="${BATCH_YAVGS[$BI]}"
		else
			_t=$(now_ms)
			YAVG="$(probe_yavg "$SRC" "$CST")"
			[ -n "$YAVG" ] || YAVG="-"
			_t=$(( $(now_ms) - _t )); T_PROBE=$(( T_PROBE + _t ))
			report_line "      exposure probe took $(fmt_ms "$_t")"
		fi
		if [ "$YAVG" != "-" ]; then
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
			_t=$(now_ms)
			ffmpeg -v error -y -i "$SRC" -vf "lut3d=file='${CST}':interp=tetrahedral,vidstabdetect=shakiness=5:accuracy=15:stepsize=6:result=${TRF}.partial" -f null -
			_t=$(( $(now_ms) - _t )); T_STAB=$(( T_STAB + _t ))
			report_line "      stabilisation detect took $(fmt_ms "$_t")"
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
	# NUMERICALLY, not as strings. solve-gamma.py prints 2.020 where look.json says 2.02, so a
	# clip the solve left exactly where it started was reported as "(matched)" — a claim that the
	# grade moved when it did not. Harmless under MATCH=1, where landing precisely on the reference
	# is a coincidence; under MATCH=batch the median clip lands there BY CONSTRUCTION, so the field
	# would have been wrong for one clip in every run.
	MATCHED="$(awk -v a="$GAMMA" -v b="$G_GAMMA_REF" 'BEGIN { print (a == b) ? 0 : 1 }')"
	say "$CLIP  post-CST YAVG=${YAVG}  gamma=${GAMMA}$([ "$MATCHED" = "1" ] && echo " (matched)")"
	# matched is 1/0 rather than true/false: emit() writes a bare number or a quoted string, and a
	# JSON boolean would need a third case for one field.
	emit clip_planned clip "$CLIP" source "$SRC" yavg "$YAVG" gamma "$GAMMA" \
		matched "$MATCHED" fps "$FPS"
	# Frame count and duration are what tell a slow run on a long clip from a slow machine. Not for
	# FRAME: the app runs that once per preview, where two ffprobes (~120ms) buy nothing it uses.
	if [ -z "$FRAME" ]; then
		report_line "      source: ${SRC_W}x${SRC_H} at ${FPS} fps, $(probe_number "$SRC" format=duration)s, $(probe_number "$SRC" stream=nb_frames) frames, $(( $(stat -f%z "$SRC" 2>/dev/null || echo 0) / 1048576 ))MB  ($SRC)"
	fi
	[ "$DRY" = "1" ] && continue

	# Generated AFTER the dry-run exit, not before: DRY=1 is documented as "plan only, render
	# nothing", and this was writing a 4096-entry cube per clip on a run that renders nothing. The
	# probe and the solve still happen above, because the solved gamma IS the plan.
	_t=$(now_ms)
	"$SCRIPT_DIR/make-tone-lut.py" "$TONE" --gamma "$GAMMA" --pivot "$G_PIVOT" \
		--contrast "$G_CONTRAST" --toe "$G_TOE" --shoulder "$G_SHOULDER" --black "$G_BLACK" >/dev/null
	_t=$(( $(now_ms) - _t )); T_TONE=$(( T_TONE + _t ))
	report_line "      tone cube took $(fmt_ms "$_t")"

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
  "${CORRECT_PREFIX}${HALATION_PREFIX}lut3d=file='${CST}':interp=tetrahedral,"),scale=-2:${FRAME_HEIGHT}:flags=lanczos"
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
		local t0; t0=$(now_ms)
		# shellcheck disable=SC2086  # $LIMIT is a deliberate split: a numeric flag pair or nothing
		render_delivery "$out" "$suffix encode" \
			-y -i "$SRC" -f lavfi -i "$(grain_plate "$w" "$h" "$FPS")" -filter_complex \
"[0:v]$(grade_chain "$TONE" "$SAT" "$WARM" \
  "${CORRECT_PREFIX}${HALATION_PREFIX}lut3d=file='${CST}':interp=tetrahedral," "${DELIVERY_SETPARAMS},"),\
$(delivery_image_chain "$w" "$h" "$SFX" "$crop")${FPS_FILTER}[b];\
[1:v]$(delivery_grain_branch "$w" "$h" "$GRAIN_STRENGTH")[g];\
$(delivery_grain_merge b g o "$GRAIN_SHADOWS" "$GRAIN_HIGHLIGHTS")" \
			-map "[o]" -map "0:a:0?" -shortest \
			-c:v libx264 -profile:v high -preset slow -crf 18 \
			-color_primaries bt709 -color_trc bt709 -colorspace bt709 \
			-c:a aac -b:a 192k -movflags +faststart \
			$LIMIT || return 1
		# `|| return 1` above is load-bearing now that the caller invokes render() inside an `if`:
		# that suppresses `set -e` for this whole body, so without it a failed render would fall
		# through to `stat` on a file that was never written.
		local ms=$(( $(now_ms) - t0 )); T_ENCODE=$(( T_ENCODE + ms ))
		report_encode "$suffix encode" "$out" "$ms"
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
	# Every deliverable in the set, in the order it was given. The set used to be one `if` with
	# `reels` in the condition and `feed` in its tail, which is why adding a third shape meant
	# editing this line rather than a list.
	#
	# THE SIZE IS SAID OUT LOUD, per deliverable, because it is DERIVED now. Height follows the
	# aspect off the shared width, so a HEIGHT that is not a multiple of 16 lands a 9:16 frame a
	# pixel or two off the number that was asked for. Stating it is the difference between a
	# rounding and a silent wrongness; this file has no budget for the second kind.
	CLIP_OK=1
	_i=0
	while [ "$_i" -lt "${#D_NAME[@]}" ]; do
		_h="$(deliverable_height "$WIDTH" "${D_AW[$_i]}" "${D_AH[$_i]}")"
		# The deliverable's own offset if it carries one, otherwise the run's. A deliverable that
		# does not crop ignores both, and crop_prefix is what decides that.
		_off="${D_OFF[$_i]}"
		[ "$_off" != "-" ] || _off="$CROP_Y_OK"
		if ! _crop="$(crop_prefix "$SRC_W" "$SRC_H" "${D_AW[$_i]}" "${D_AH[$_i]}" "$_off")"; then
			say "FAIL  $CLIP — ${D_NAME[$_i]}: that crop does not fit ${SRC_W}x${SRC_H}."
			emit_code REFUSE_CROP_WINDOW
			emit clip_failed clip "$CLIP" source "$SRC" deliverable "${D_NAME[$_i]}"
			CLIP_OK=0; break
		fi
		# The RESOLVED row, read back out of the filter, not the word that was asked for. `centre`
		# is computed per clip against the measured frame, so printing "centre" would hide which
		# row it actually landed on — the same silence the derived height is printed to avoid.
		_at="${_crop%,}"; _at="${_at##*:}"
		say "      ${D_NAME[$_i]}: ${WIDTH}x${_h}${_crop:+ cropped at $_at}"
		render "$WIDTH" "$_h" "${D_SUFFIX[$_i]}" "$_crop" || { CLIP_OK=0; break; }
		_i=$(( _i + 1 ))
	done
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
report_line "  orientation     $(fmt_ms "$T_ORIENT")"
report_line "  exposure probe  $(fmt_ms "$T_PROBE")"
report_line "  stabilisation   $(fmt_ms "$T_STAB")"
report_line "  tone cube       $(fmt_ms "$T_TONE")"
report_line "  encode          $(fmt_ms "$T_ENCODE")"
report_line "  frame render    $(fmt_ms "$T_FRAME")"
report_line "  other           $(fmt_ms $(( RUN_MS - T_PREFLIGHT - T_ORIENT - T_PROBE - T_STAB - T_TONE - T_ENCODE - T_FRAME )))"
say "report: $REPORT"
emit run_done rendered "$OK" skipped "$SKIPPED" failed "$FAILED" report "$REPORT"
[ "$FAILED" -eq 0 ] || exit 1
