#!/bin/bash
# Records the engine's event stream into tests/fixtures/events.jsonl.
#
# WHY A RECORDED STREAM. The app parses these events, and a parser is only as good as the shape it
# was written against. A fixture lets the app's own tests run with no ffmpeg, no footage and no
# render — and it makes the contract diffable, so a field that quietly changes name or type shows
# up as a diff in a review rather than as a wrapper that silently stops showing progress.
#
# It is checked by content, like every other generated artefact here: tests/lib.bats regenerates
# the stream and compares. mtime cannot work, because git does not preserve it.
#
# NORMALISED, because two things in a real run are not reproducible: the work directory's path and
# the free space on the volume. Both are replaced with tokens. Everything else — the event names,
# the field names, the order, the look values — is the contract.
#
# Usage:  ./tests/make-event-fixture.sh [--check]
#           (no flag) rewrite the fixture
#           --check   print the stream and exit non-zero if it differs from the fixture
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE="$ROOT/tests/fixtures/events.jsonl"
MODE="${1:-}"

command -v ffmpeg >/dev/null || { echo "SKIP: ffmpeg not installed"; exit 3; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/src"

# A portrait clip and a landscape one, so the stream carries a planned clip AND a refused one. Same
# construction the bats suite uses: encode first, then tag in a -c copy remux, because prores_ks
# does not reliably stamp the flags it is given.
_mk() {  # _mk <w> <h> <out>
	ffmpeg -y -v error -f lavfi -i "color=c=gray:s=${1}x${2}:d=0.1:r=24" \
		-frames:v 1 -c:v prores_ks -profile:v 3 -pix_fmt yuv422p10le "$3.raw.mov"
	ffmpeg -y -v error -i "$3.raw.mov" -map 0:v:0 -c copy \
		-color_primaries bt709 -color_trc bt709 -colorspace bt709 "$3"
	rm -f "$3.raw.mov"
}
_mk 64 128 "$WORK/src/TALL.mov"
_mk 128 64 "$WORK/src/WIDE.mov"

STREAM="$(JSON=1 DRY=1 MATCH=0 GRADE_WORK_DIR="$WORK" "$ROOT/scripts/grade.sh" "$WORK/src" 2>/dev/null \
	| sed -e "s|$WORK|<WORK>|g" \
	      -e 's|"report":"[^"]*"|"report":"<REPORT>"|' \
	      -e 's|"available_gb":[0-9]*|"available_gb":"<GB>"|')"

if [ "$MODE" = "--check" ]; then
	printf '%s\n' "$STREAM"
	exit 0
fi
mkdir -p "$(dirname "$FIXTURE")"
printf '%s\n' "$STREAM" > "$FIXTURE"
echo "wrote $FIXTURE ($(printf '%s\n' "$STREAM" | wc -l | tr -d ' ') events)"
