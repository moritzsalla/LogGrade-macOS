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
#   GRAIN_STRENGTH=<n>  override look.json's grain strength
#   PROOF=<seconds>   render this many seconds through the real chain into dist/proofs/
#   DRY=1             plan only, render nothing
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
SAT="$(look .colour.saturation)"; WARM="$(look .colour.warmth)"
G_PIVOT="$(look .tone.pivot)";       G_CONTRAST="$(look .tone.contrast)"
G_TOE="$(look .tone.toe)";           G_SHOULDER="$(look .tone.shoulder)"
G_BLACK="$(look .tone.black)"
G_GAMMA_REF="$(look .tone.gamma)"        # gamma the look was tuned at...
Y_REF="$(look .match.reference_yavg)"    # ...against this post-CST mean (10-bit), on IMG_0609
GRAIN_STRENGTH="${GRAIN_STRENGTH:-$(look .grain.strength)}"; SMOOTHING="${SMOOTHING:-$(look .stabilisation.smoothing)}"
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
	else echo "not found: $arg" >&2; exit 1; fi
done
[ "${#CLIPS[@]}" -gt 0 ] || { echo "usage: grade <folder|clip.mov> [...]" >&2; exit 1; }

# The Feed crop is a per-clip judgement — 750 is IMG_0609's composition, chosen to drop the
# parking-ceiling strip at the top. Applied to a batch it silently reframes 18 other clips, and
# the files look done. That is CONTEXT.md's "squashed" failure class in another dimension, so it
# is refused rather than warned about. Setting CROP_Y explicitly is taken as "yes, this offset for
# all of them", which is a decision someone made rather than a default nobody saw.
if [ "$FEED" = "1" ] && [ "${#CLIPS[@]}" -gt 1 ] && [ -z "${CROP_Y:-}" ]; then
	echo "REFUSING: FEED=1 across ${#CLIPS[@]} clips with no CROP_Y." >&2
	echo "  The 4:5 crop offset is a per-clip framing call; the default 750 is IMG_0609's." >&2
	echo "  Either run one clip at a time, or pass CROP_Y=<pixels> to accept one offset for all." >&2
	exit 1
fi

# Nothing is CREATED until the arguments are known to be good. This used to run first, so
# `./grade.sh` with no arguments made the output directories and an empty run-*.txt, then printed
# usage and exited 1 — a usage error leaving litter in the folder someone delivers from, and one
# stray report per suite run.
check_disk_space "$WORK/dist" 10
mkdir -p "$OUT_DIR" "$REPORT_DIR" "$CACHE"
REPORT="$REPORT_DIR/run-$(date +%Y%m%d-%H%M%S).txt"
: > "$REPORT"
say() { echo "$*" | tee -a "$REPORT"; }

say "grade run $(date '+%Y-%m-%d %H:%M:%S')  —  ${#CLIPS[@]} clip(s)"
say "look: sat=$SAT warm=$WARM grain=$GRAIN_STRENGTH stab=$STAB exposure-match=$MATCH"
say ""

OK=0; SKIPPED=0; FAILED=0
for SRC in "${CLIPS[@]}"; do
	CLIP="$(basename "${SRC%.*}")"

	# Orientation is the source's business. Refuse a clip that would render sideways rather than
	# producing a confidently wrong file; require_portrait decodes a frame and measures it.
	if ! require_portrait "$SRC" 2>/dev/null; then
		say "SKIP  $CLIP — not portrait. Fix the source orientation, then retry."
		SKIPPED=$((SKIPPED+1)); continue
	fi

	# --- exposure match: one cheap probe, not a full pass --------------------------------
	GAMMA="$G_GAMMA_REF"; YAVG="-"
	if [ "$MATCH" = "1" ]; then
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
	if [ "$STAB" = "1" ]; then
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
		elif [ -f "$TRF" ]; then
			say "      stale transform at $TRF — older than the source, rendering unstabilised"
			say "      re-run 00-stabilise-detect.sh for $CLIP to refresh it"
		else
			# Worth saying out loud: this is the one decision in a dry run that costs ~65s per
			# clip to get wrong, and it used to be made silently.
			say "      no transform at $TRF — will render unstabilised"
		fi
	fi

	FPS="$(source_fps "$SRC")"
	say "$CLIP  post-CST YAVG=${YAVG}  gamma=${GAMMA}$([ "$GAMMA" != "$G_GAMMA_REF" ] && echo " (matched)")"
	[ "$DRY" = "1" ] && continue

	# Generated AFTER the dry-run exit, not before: DRY=1 is documented as "plan only, render
	# nothing", and this was writing a 4096-entry cube per clip on a run that renders nothing. The
	# probe and the solve still happen above, because the solved gamma IS the plan.
	"$SCRIPT_DIR/make-tone-lut.py" "$TONE" --gamma "$GAMMA" --pivot "$G_PIVOT" \
		--contrast "$G_CONTRAST" --toe "$G_TOE" --shoulder "$G_SHOULDER" --black "$G_BLACK" >/dev/null

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
  "lut3d=file='${CST}':interp=tetrahedral," "${DELIVERY_SETPARAMS},"),\
$(delivery_image_chain "$w" "$h" "$SFX" "$crop")[b];\
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
		say "      -> $(basename "$out")  $(( $(stat -f%z "$out") / 1048576 ))MB"
	}

	# A FAILED CLIP MUST NOT TAKE THE BATCH WITH IT. render_delivery leaves the previous deliverable
	# untouched and returns non-zero, but a bare call propagates through `set -e` and kills the loop
	# — measured: a two-clip run whose first render failed never attempted the second, printed no
	# summary, and left the report ending mid-file. In a 19-clip unattended run a failure at clip 3
	# silently costs the other 16. The non-portrait path a few lines up already skips and continues;
	# this gives the render path the same treatment, and the exit status below makes sure a run with
	# failures in it can never be read as a clean one.
	if render 1080 1920 "reels-stories_9x16" \
		&& { [ "$FEED" != "1" ] || render 1080 1350 "feed_4x5" "crop=2160:2700:0:${CROP_Y:-750},"; }
	then
		OK=$((OK+1))
	else
		say "FAIL  $CLIP — render failed, previous output left as it was. Continuing."
		FAILED=$((FAILED+1))
	fi
done

say ""
say "done: $OK rendered, $SKIPPED skipped, $FAILED failed"
say "report: $REPORT"
[ "$FAILED" -eq 0 ] || exit 1
