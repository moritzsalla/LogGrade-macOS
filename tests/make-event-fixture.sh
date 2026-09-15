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
#           --check   print the stream and write nothing; the caller compares it with the fixture
#                     (tests/lib.bats does). Exits 0 whether or not it differs; non-zero only if
#                     the engine run fails, and 3 without ffmpeg.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE="$ROOT/tests/fixtures/events.jsonl"
MODE="${1:-}"

command -v ffmpeg >/dev/null || { echo "SKIP: ffmpeg not installed"; exit 3; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/src"

# A clip and a file that is not a video, so the stream carries a planned clip AND a skipped one,
# from the builder the bats suite uses.
# shellcheck source=tests/fixture-clip.sh
source "$ROOT/tests/fixture-clip.sh"
# 72x128 IS 9:16 EXACTLY, so reels takes it whole: a source that crops is refused without an offset,
# and the generator would exit non-zero and produce nothing.
make_tagged_clip 72 128 bt709 bt709 bt709 "$WORK/src/TALL.mov"
printf 'not a video\n' > "$WORK/src/BROKEN.mov"

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
