#!/bin/bash
# render-golden.sh — did the default render move, and if it did, did anyone mean it to?
#
# WHY IT IS RECORDED FROM THIS REPO'S OWN RENDER. It replaced a comparison against the frozen
# precursor, which could never let the default image get better than the precursor. Here moving
# the image takes one deliberate commit.
#
# THE RECORD IS A STREAM HASH, NOT A FILE HASH. `-c copy -f md5` hashes the packets, so a muxer
# that starts stamping a timestamp cannot fail this. PROVENANCE.md measured two renders of one clip
# minutes apart as byte-identical, so the render is deterministic on a fixed build.
#
# A DIFFERENT ffmpeg OR ARCHITECTURE IS A SKIP, NOT A FAILURE. A golden recorded on one build says
# nothing about another:
# the encoder writes its version into the stream, and SIMD paths are not promised to agree. That is
# a skip until someone measures otherwise, and check.sh counts a skip against the run.
#
# A MISMATCH NAMES WHAT CHANGED. The golden records a hash of every input the render reads, so a
# failure separates "you changed lib.sh" from "nothing you changed, yet the image moved". The list
# is only refreshed by --regenerate, so it can include edits that never moved a pixel.
#
# THE HASH SAYS THE IMAGE MOVED, NOT THAT IT GOT BETTER. Every render lands in dist/golden/ named by
# its hash, so the recorded and the new one can be put side by side. Look at them before
# regenerating. The reason you pass is written into the golden, where the diff shows it.
#
# STABILISATION IS EXCLUDED (STAB=0). Its detect pass costs about a minute per clip, and pinning it
# would rest on vid.stab being deterministic as well, which nobody has measured.
#
# Usage:  ./tests/render-golden.sh                      compare against tests/fixtures/render-golden.json
#         ./tests/render-golden.sh --regenerate "<why>"  record this render as the default image
#   CLIP=<src/x.mov>   the clip to record with (--regenerate only; default: the first in src/)
#   PROOF_SECS=<n>     seconds to record through the real chain (--regenerate only; default 0.1)
#
# Exit: 0 matches or recorded, 1 moved or a render failed, 2 bad usage, 3 skipped (no footage,
#       no cube, or the golden came from a different ffmpeg or architecture).
set -euo pipefail
# The proof is read from the temp work dir's own .loggrade below, so an inherited cache override
# would send it somewhere this script does not look.
unset LOGGRADE_CACHE
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GOLDEN="${GOLDEN:-$ROOT/tests/fixtures/render-golden.json}"
KEEP="$ROOT/dist/golden"
CUBE="$ROOT/luts/rendering/neutral.cube"

skip() { echo "SKIP: $*"; exit 3; }

MODE=compare
WHY=""
case "${1:-}" in
	"") ;;
	--regenerate)
		MODE=regenerate
		WHY="${2:-}"
		# A golden that moved without a reason is the quiet relaxation this file exists to prevent.
		[ -n "$WHY" ] || { echo "REFUSING: --regenerate needs a reason, e.g. --regenerate \"sharpen radius re-measured\"" >&2; exit 2; };;
	*) echo "unknown option: $1" >&2; exit 2;;
esac

ffmpeg_build() { ffmpeg -version | head -1; }

# Every file the default render reads, relative to ROOT. shipped.cube is left out because it is
# generated from look.json by a script already on the list; check.sh because it renders nothing.
inputs() {
	local f
	for f in look.json scripts/* luts/rendering/*.cube; do
		[ -f "$ROOT/$f" ] || continue
		[ "$f" = scripts/check.sh ] && continue
		printf '%s\n' "$f"
	done
}

inputs_json() {
	local f
	while IFS= read -r f; do
		printf '%s\t%s\n' "$f" "$(shasum -a 256 "$ROOT/$f" | cut -d' ' -f1)"
	done < <(inputs) | jq -R -n '[inputs | split("\t") | {(.[0]): .[1]}] | add'
}

[ -f "$CUBE" ] || skip "no ${CUBE#"$ROOT"/}"

if [ "$MODE" = compare ]; then
	[ -f "$GOLDEN" ] || { echo "FAIL: no golden at $GOLDEN — record one with --regenerate \"<why>\"" >&2; exit 1; }
	CLIP_NAME="$(jq -r .clip.name "$GOLDEN")"
	CLIP_BYTES="$(jq -r .clip.bytes "$GOLDEN")"
	PROOF_SECS="$(jq -r .proof_secs "$GOLDEN")"
	RECORDED_BUILD="$(jq -r .ffmpeg "$GOLDEN")"
	RECORDED_ARCH="$(jq -r .arch "$GOLDEN")"
	[ "$RECORDED_BUILD" = "$(ffmpeg_build)" ] ||
		skip "the golden was recorded with '$RECORDED_BUILD', this machine runs '$(ffmpeg_build)'"
	[ "$RECORDED_ARCH" = "$(uname -m)" ] ||
		skip "the golden was recorded on $RECORDED_ARCH, this machine is $(uname -m)"
	CLIP="$ROOT/src/$CLIP_NAME"
	[ -f "$CLIP" ] || skip "no src/$CLIP_NAME, which the golden was recorded from"
	# Same name, different footage, would read as the chain moving.
	[ "$(stat -L -f%z "$CLIP")" = "$CLIP_BYTES" ] ||
		skip "src/$CLIP_NAME is not the file the golden was recorded from ($CLIP_BYTES bytes)"
else
	PROOF_SECS="${PROOF_SECS:-0.1}"
	CLIP="${CLIP:-}"
	if [ -z "$CLIP" ]; then
		for f in "$ROOT"/src/*.mov "$ROOT"/src/*.MOV; do
			if [ -f "$f" ]; then CLIP="$f"; break; fi
		done
	fi
	[ -n "$CLIP" ] || skip "no source footage in src/"
	[ -f "$CLIP" ] || { echo "not a file: $CLIP" >&2; exit 2; }
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/work" "$KEEP"

echo "clip:  $(basename "$CLIP")  (${PROOF_SECS}s through the real chain, unstabilised)"
if ! GRADE_WORK_DIR="$TMP/work" LOOK_FILE="$ROOT/look.json" STAB=0 PROOF="$PROOF_SECS" \
	"$ROOT/scripts/grade.sh" "$CLIP" >"$TMP/render.log" 2>&1; then
	echo "FAIL: the render did not complete. Its output:" >&2
	cat "$TMP/render.log" >&2
	exit 1
fi
PROOF_FILE=""
for f in "$TMP/work/.loggrade/proofs"/*.mp4; do
	if [ -f "$f" ]; then PROOF_FILE="$f"; fi
done
[ -n "$PROOF_FILE" ] || { echo "FAIL: the render wrote no proof" >&2; exit 1; }

HASH="$(ffmpeg -v error -i "$PROOF_FILE" -map 0 -c copy -f md5 - | sed 's/^MD5=//')"
[[ "$HASH" =~ ^[0-9a-f]{32}$ ]] || { echo "FAIL: could not hash the proof: '$HASH'" >&2; exit 1; }
cp "$PROOF_FILE" "$KEEP/$HASH.mp4"

if [ "$MODE" = regenerate ]; then
	PREVIOUS=""
	[ -f "$GOLDEN" ] && PREVIOUS="$(jq -r .stream_md5 "$GOLDEN")"
	jq -n \
		--arg why "$WHY" \
		--arg name "$(basename "$CLIP")" \
		--argjson bytes "$(stat -L -f%z "$CLIP")" \
		--argjson secs "$PROOF_SECS" \
		--arg build "$(ffmpeg_build)" \
		--arg arch "$(uname -m)" \
		--arg md5 "$HASH" \
		--argjson inputs "$(inputs_json)" \
		'{
			_comment: [
				"Generated by tests/render-golden.sh --regenerate. Do not hand-edit: a hash nobody",
				"rendered is a claim nothing produced.",
				"",
				"This is the DEFAULT image this repo renders, recorded from its own chain. Moving it",
				"is allowed and takes a reason, which lands in recorded_because."
			],
			recorded_because: $why,
			clip: {name: $name, bytes: $bytes},
			proof_secs: $secs,
			ffmpeg: $build,
			arch: $arch,
			stream_md5: $md5,
			inputs: $inputs
		}' >"$TMP/golden.json"
	mv "$TMP/golden.json" "$GOLDEN"
	if [ -n "$PREVIOUS" ] && [ "$PREVIOUS" != "$HASH" ]; then
		echo "RECORDED: the default image moved, $PREVIOUS -> $HASH"
		echo "  dist/golden/$PREVIOUS.mp4 is the old one, if this machine rendered it."
	else
		echo "RECORDED: $HASH"
	fi
	echo "  dist/golden/$HASH.mp4 is the render now recorded. Commit the golden with the reason."
	exit 0
fi

EXPECTED="$(jq -r .stream_md5 "$GOLDEN")"
if [ "$HASH" = "$EXPECTED" ]; then
	echo "GOLDEN OK: the default render is the recorded one ($HASH)"
	exit 0
fi

echo "GOLDEN FAILED: the default render moved." >&2
echo "  recorded: $EXPECTED  ($(jq -r .recorded_because "$GOLDEN"))" >&2
echo "  now:      $HASH" >&2
changed=""
while IFS= read -r f; do
	recorded="$(jq -r --arg f "$f" '.inputs[$f] // "absent"' "$GOLDEN")"
	[ "$recorded" = "$(shasum -a 256 "$ROOT/$f" | cut -d' ' -f1)" ] || changed="$changed $f"
done < <(inputs)
while IFS= read -r f; do
	[ -f "$ROOT/$f" ] || changed="$changed $f(removed)"
done < <(jq -r '.inputs | keys[]' "$GOLDEN")
if [ -n "$changed" ]; then
	echo "  inputs that differ from when it was recorded:$changed" >&2
else
	echo "  NO input differs from when it was recorded, so something outside the list moved the image." >&2
fi
echo "  Look at dist/golden/$HASH.mp4 beside dist/golden/$EXPECTED.mp4 (if this machine rendered it)." >&2
echo "  If the change is meant: ./tests/render-golden.sh --regenerate \"<why>\"" >&2
exit 1
