#!/bin/bash
# Stage 2: baseline -> graded master (look LUT + tone curve + colour, i.e. the whole grade).
# Usage: ./02-grade.sh IMG_XXXX
# Reads dist/01-baseline/<clip>_baseline.mov, writes dist/02-graded/<clip>_graded.mov.
#
# THE TONE LUT IS THE POINT. The Portra LUT alone leaves the image far too bright and flat
# ("milky"): nothing reaches black and the whole frame sits ~25% too high. shipped.cube fixes that.
# Don't drop it thinking it's redundant — see docs/PIPELINE.md, "Tone shaping".
#
# The graph itself is grade_chain in lib.sh, shared with grade.sh so a look cannot move on one
# path and not the other. Its header carries the reasoning — luma-only tone, and why both branches
# must be yuv444p10le. This stage adds only the ProRes encode: no CST (stage 01 did it) and no
# setparams (nothing downstream here negotiates a colourspace).
#
# The saturation and warmth below are a CREATIVE choice made by eye in the Grade Bench, not a
# correction. Measured against the standardised colours in frame, the Apple CST's own colour is
# already accurate (traffic blue lands at B/G 1.99 against a 1.98 spec with nothing applied). The
# values here deliberately depart from that. Change them because the look should change, never
# because a reading looks "wrong" — being off-spec here is the intent.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

# `${1:-}` so a no-argument run says what it wanted — see 00-stabilise-detect.sh.
CLIP="${1:-}"
[ -n "$CLIP" ] || { echo "usage: ./02-grade.sh IMG_XXXX" >&2; exit 1; }
# ...and then the name itself: it becomes a path component AND reaches the filter graph.
CLIP="$(require_clip_name "$CLIP")"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WORK="$(resolve_work_dir "$ROOT")"
BASELINE="$WORK/dist/01-baseline/${CLIP}_baseline.mov"
TONE="$ROOT/luts/tone/shipped.cube"
# Graded by eye in the Grade Bench (bench/), calibrated live against the RAL references in frame,
# then sent back through the artifact db. Deliberately off-spec: saturation 1.27 puts the traffic
# blue at B/G 2.39 against a 1.98 spec. That is a grade, not an error — accuracy is the reference
# you depart from on purpose.
#
# THE NUMBERS ARE NOT HERE. They live in look.json, and ensure_tone_lut below regenerates
# shipped.cube from it whenever the two disagree. This header used to carry its own copy of all six
# tone values plus a regenerate command whose path pointed outside the repo — two copies of a look,
# which is the drift look.json exists to end.
#
# Worth keeping from that copy: `toe` was measured to do NOTHING at pivot 0.39 — identical
# percentiles at 0.07 and 0.00 — so it is zeroed rather than left as a decorative knob. The black
# point is the live shadow control here.
# Both are spliced into the filter graph; see require_number in lib.sh.
# The look LUT is a look value like any other, so it comes from look.json. LOOK=<name|none|path>
# overrides it for one run; the app sets it per render.
LOOK_LUT="$(resolve_look_lut "${LOOK:-$(look .look.lut)}" "$ROOT")"
SAT="$(require_number SAT "$(look .colour.saturation)")"
WARM="$(require_number WARM "$(look .colour.warmth)")"
OUT="$WORK/dist/02-graded/${CLIP}_graded.mov"

[ -f "$BASELINE" ] || { echo "baseline not found: $BASELINE — run 01-baseline.sh first" >&2; exit 1; }
check_disk_space "$WORK/dist" 10
# Create the output directory. This used to rely on a checked-in dist/*/.gitkeep marker, which
# is wrong the moment a work dir is set: the marker was in the repo and the output was not.
mkdir -p "$(dirname "$OUT")"
ensure_tone_lut "$ROOT"

ffmpeg -y -i "$BASELINE" \
	-filter_complex "[0:v]$(grade_chain "$TONE" "$SAT" "$WARM")[o]" \
	-map "[o]" -map "0:a:0?" \
	-c:v prores_ks -profile:v 3 -pix_fmt yuv422p10le \
	-c:a copy \
	"$OUT" -v error

require_nonempty "$OUT" "grade encode"
safe_retag "$OUT"
echo "done: $OUT"
