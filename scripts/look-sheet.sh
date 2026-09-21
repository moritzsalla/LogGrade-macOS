#!/bin/bash
# look-sheet.sh — one contact sheet for judging looks by eye: a row per clip, a column per look,
# optionally a row of reference images on top. Every tile comes from grade.sh itself, so the sheet
# shows the engine, never a second implementation of it.
#
# usage: look-sheet.sh [-c COLUMN]... [-t SECONDS] [-d] [-r] [-n] [-o OUT.png] [CLIP|DIR]...
#
#   -c COLUMN  [label=][checkout:]look, repeatable. look: neutral (look.json), a preset name in
#              presets/, or a look file path. checkout: `main` (the main checkout, when this is a
#              worktree) or a repo path; its own scripts render it. Default: neutral and every preset.
#   -t SECONDS timecode of the still, default 1
#   -d         delivered: tiles from a proof of the delivered file (grain, sharpening, the 9:16
#              crop), not the grade-only still. Much slower.
#   -r         a top row of reference images from references/
#   -n         don't open the sheet in Preview
#   -o OUT     default .loggrade/sheets/look-sheet-<time>.png
#
# CLIP|DIR default to src/, or the main checkout's src/ when this one has none (a worktree), with
# at most four clips spread across a folder. Prints the sheet's path on stdout.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib.sh
. "$ROOT/scripts/lib.sh"

usage() { sed -n '/^# usage:/,/^# at most/s/^# \{0,1\}//p' "$0" >&2; exit "${1:-2}"; }

COLUMNS_SPEC=(); T=1; DELIVERED=0; REFS=0; OPEN=1; OUT=""
while getopts 'c:t:drno:h' opt; do
	case "$opt" in
		c) COLUMNS_SPEC+=("$OPTARG");;
		t) T="$(require_number "-t" "$OPTARG")";;
		d) DELIVERED=1;;
		r) REFS=1;;
		n) OPEN=0;;
		o) OUT="$OPTARG";;
		h) usage 0;;
		*) usage;;
	esac
done
shift $((OPTIND - 1))

# The main checkout holds the footage and the references; a worktree has an empty src/.
MAIN="$(dirname "$(cd "$ROOT" && cd "$(git rev-parse --git-common-dir)" && pwd)")"

# Tile height; a cell is as wide as the widest tile.
H=720

# THE COLOUR TRAP THIS SCRIPT EXISTS FOR. A render's pixels are Rec.709 codes meant for Apple
# playback, and a delivered file is tagged 1-1-1. AVFoundation shows such a file through the
# "HDTV" ICC profile CoreVideo attaches to the decoded frame: Rec.709 primaries and a pure 1.961
# gamma (its curv tag is 0x01F6). A PNG with no profile is opened as sRGB instead (ImageIO reports
# kCGColorSpaceSRGB), so a sheet of raw codes shows every tile darker than QuickTime shows the
# file. Against AVFoundation's own rendering of an IMG_0607 proof frame, as sRGB: raw codes 8.9/255
# darker on average, the inverse BT.709 OETF (ITU-709.icc, cubefile.py) 4.2 off and 12 too light at
# code 23 of a grey ramp, gamma 1.961 0.9. Only after a zscale decode: swscale reads the same YUV
# 1.8 codes darker.
DISPLAY_TO_SRGB="lutrgb=r='$(
	e="st(0,pow(val/maxval,1.961));maxval*if(lte(ld(0),0.0031308),12.92*ld(0),1.055*pow(ld(0),1/2.4)-0.055)"
	printf "%s':g='%s':b='%s" "$e" "$e" "$e")'"

FONT=/System/Library/Fonts/Menlo.ttc
TMP="$(mktemp -d -t look-sheet)"
trap 'rm -rf "$TMP"' EXIT

# ---- columns ---------------------------------------------------------------------------------

if [ "${#COLUMNS_SPEC[@]}" -eq 0 ]; then
	COLUMNS_SPEC=(neutral)
	for p in "$ROOT"/presets/*.json; do
		[ -f "$p" ] && COLUMNS_SPEC+=("$(basename "$p" .json)")
	done
fi

COL_LABEL=(); COL_ROOT=(); COL_LOOK=()
for spec in "${COLUMNS_SPEC[@]}"; do
	label=""; checkout="$ROOT"; lk="$spec"
	case "$spec" in *=*) label="${spec%%=*}"; lk="${spec#*=}";; esac
	case "$lk" in
		*:*)
			checkout="${lk%%:*}"; lk="${lk#*:}"
			[ "$checkout" != main ] || checkout="$MAIN"
			[ -x "$checkout/scripts/grade.sh" ] || { echo "look-sheet: no scripts/grade.sh in checkout '$checkout'" >&2; exit 1; }
			checkout="$(cd "$checkout" && pwd)";;
	esac
	case "$lk" in
		neutral) file="$checkout/look.json";;
		*/*|*.json) file="$lk";;
		*) file="$checkout/presets/$lk.json";;
	esac
	[ -f "$file" ] || { echo "look-sheet: no look file for column '$spec' ($file)" >&2; exit 1; }
	if [ -z "$label" ]; then
		label="$(basename "$file" .json)"
		[ "$label" != look ] || label=neutral
		if [ "$checkout" = "$ROOT" ]; then :
		elif [ "$checkout" = "$MAIN" ]; then label="main $label"
		else label="$(basename "$checkout") $label"
		fi
	fi
	COL_LABEL+=("$label"); COL_ROOT+=("$checkout"); COL_LOOK+=("$(cd "$(dirname "$file")" && pwd)/$(basename "$file")")
done

# ---- clips -----------------------------------------------------------------------------------

footage_in() {  # footage_in <dir>  -> clip paths, sorted, one per line
	find "$1" -maxdepth 1 \( -iname '*.mov' -o -iname '*.mp4' \) ! -name '.*' | sort
}

CLIPS=()
if [ "$#" -eq 0 ]; then
	src="$ROOT/src"
	[ -n "$(footage_in "$src")" ] || src="$MAIN/src"
	set -- "$src"
fi
for arg in "$@"; do
	if [ -d "$arg" ]; then
		found=()
		while IFS= read -r f; do found+=("$f"); done < <(footage_in "$arg")
		n="${#found[@]}"
		# Spread across the folder rather than the first four: a shoot's first clips are one scene.
		k=4; [ "$n" -ge "$k" ] || k="$n"
		for (( i = 0; i < k; i++ )); do CLIPS+=("${found[$(( i * n / k ))]}"); done
	elif [ -f "$arg" ]; then
		CLIPS+=("$(cd "$(dirname "$arg")" && pwd)/$(basename "$arg")")
	else
		echo "look-sheet: not a clip or folder: $arg" >&2; exit 1
	fi
done
if [ "${#CLIPS[@]}" -eq 0 ]; then
	echo "look-sheet: no footage (looked in $*); put clips in src/ or name them" >&2
	exit 3
fi

# ---- tiles -----------------------------------------------------------------------------------

# One work dir per tile. A still is named by clip and timecode only, so two looks in one dir would
# overwrite each other, and two renders sharing a cache race on one cube's .partial file. Kept
# between runs because the cubes in it are fresh by content.
tile_work() {  # tile_work <col> <clip>
	printf '%s/look-sheet/%s\n' "${LOGGRADE_CACHE:-$ROOT/.loggrade}" \
		"$(printf '%s' "${COL_ROOT[$1]} ${COL_LOOK[$1]} $2" | cksum | cut -d' ' -f1)"
}

render_tile() {  # render_tile <col> <clip> <raw>  -> the render (16-bit still, or a proof frame) at <raw>
	local c="$1" clip="$2" raw="$3" work log path
	work="$(tile_work "$c" "$clip")"; log="$raw.log"
	mkdir -p "$work"
	if [ "$DELIVERED" = 1 ]; then
		JSON=1 LOOK_FILE="${COL_LOOK[$c]}" GRADE_WORK_DIR="$work" LOGGRADE_CACHE="$work/cache" \
			PROOF="$(awk -v t="$T" 'BEGIN { print t + 0.2 }')" STAB=0 DELIVERABLES=reels WIDTH=1080 \
			"${COL_ROOT[$c]}/scripts/grade.sh" "$clip" > "$log.json" 2> "$log" || return 1
		path="$(jq -r 'select(.event == "output") | .path' "$log.json" | head -1)"
		[ -s "$path" ] || return 1
		# The file's own tags decide the matrix and range, as they do for a player. zscale, not
		# swscale: see DISPLAY_TO_SRGB.
		ffmpeg -v error -y -ss "$T" -i "$path" -frames:v 1 -vf "zscale=range=full,format=rgb48be" "$raw" 2>> "$log"
	else
		JSON=1 LOOK_FILE="${COL_LOOK[$c]}" GRADE_WORK_DIR="$work" LOGGRADE_CACHE="$work/cache" \
			FRAME="$T" FRAME_HEIGHT="$H" "${COL_ROOT[$c]}/scripts/grade.sh" "$clip" > "$log.json" 2> "$log" || return 1
		path="$(jq -r 'select(.event == "frame") | .path' "$log.json" | head -1)"
		[ -s "$path" ] || return 1
		cp "$path" "$raw"
	fi
}

# Four renders at a time: each is a 4K decode with its own threads, and more only queue.
NC="${#COL_LABEL[@]}"; NR="${#CLIPS[@]}"
JOBS=()
finish_batch() {
	local j r c
	for j in ${JOBS[@]+"${JOBS[@]}"}; do
		r="${j%%:*}"; c="${j#*:}"; c="${c%%:*}"
		wait "${j##*:}" && continue
		echo "look-sheet: ${COL_LABEL[$c]} failed on $(basename "${CLIPS[$r]}"):" >&2
		tail -3 "$TMP/raw_${r}_${c}.png.log" >&2 || true
	done
	JOBS=()
}
for (( r = 0; r < NR; r++ )); do
	for (( c = 0; c < NC; c++ )); do
		render_tile "$c" "${CLIPS[$r]}" "$TMP/raw_${r}_${c}.png" &
		JOBS+=("$r:$c:$!")
		[ "${#JOBS[@]}" -lt 4 ] || finish_batch
	done
done
finish_batch

CELL_W=0
for f in "$TMP"/raw_*.png; do
	[ -s "$f" ] || continue
	w="$(ffprobe -v error -show_entries stream=width,height -of csv=p=0 "$f" | head -1 \
		| awk -F, -v h="$H" '{ printf "%d", $1 * h / $2 }')"
	[ "$w" -le "$CELL_W" ] || CELL_W="$w"
done
[ "$CELL_W" -gt 0 ] || { echo "look-sheet: every render failed" >&2; exit 1; }
CELL_W=$(( (CELL_W + 1) / 2 * 2 ))

N=0
cell() {  # cell <image|""> <label> [display]  -> the next numbered cell; "" makes a blank one
	local in="$1" label="$2" conv="" fit
	printf '%s' "$label" > "$TMP/label.txt"
	[ "${3:-}" != display ] || conv="format=rgb48be,$DISPLAY_TO_SRGB,"
	fit="scale=${CELL_W}:${H}:force_original_aspect_ratio=decrease:flags=lanczos,pad=${CELL_W}:${H}:(ow-iw)/2:(oh-ih)/2:color=0x202020"
	if [ -z "$in" ]; then
		ffmpeg -v error -y -f lavfi -i "color=c=0x202020:s=${CELL_W}x${H}" -frames:v 1 -pix_fmt rgb24 \
			"$TMP/cell_$(printf '%04d' "$N").png"
	else
		ffmpeg -v error -y -i "$in" -frames:v 1 -vf "${conv}${fit},format=rgb24,drawtext=fontfile=$FONT:textfile=$TMP/label.txt:x=10:y=10:fontsize=20:fontcolor=white:box=1:boxcolor=black@0.6:boxborderw=6" \
			"$TMP/cell_$(printf '%04d' "$N").png"
	fi
	N=$((N + 1))
}

if [ "$REFS" = 1 ]; then
	refdir="$ROOT/references"; [ -d "$refdir" ] || refdir="$MAIN/references"
	refs=()
	while IFS= read -r f; do refs+=("$f"); done < <(find "$refdir" -maxdepth 1 -type f \
		\( -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.tif' -o -iname '*.tiff' -o -iname '*.heic' \) 2>/dev/null | sort)
	[ "${#refs[@]}" -gt 0 ] || echo "look-sheet: no images in $refdir; no reference row" >&2
	i=0
	for f in ${refs[@]+"${refs[@]}"}; do
		# ffmpeg ignores an embedded ICC profile, and these scans carry Adobe RGB: read as sRGB they
		# lost a quarter of their chroma (Ivy edit 02). ColorSync matches them to sRGB, as Preview does.
		sips -Z "$(( CELL_W > H ? CELL_W : H ))" -m "/System/Library/ColorSync/Profiles/sRGB Profile.icc" \
			"$f" --out "$TMP/ref_$i.png" >/dev/null
		cell "$TMP/ref_$i.png" "reference $(basename "${f%.*}")"
		i=$((i + 1))
	done
	while [ $(( N % NC )) -ne 0 ]; do cell "" ""; done
fi

for (( r = 0; r < NR; r++ )); do
	for (( c = 0; c < NC; c++ )); do
		label="${COL_LABEL[$c]}  $(basename "${CLIPS[$r]%.*}")"
		if [ -s "$TMP/raw_${r}_${c}.png" ]; then
			cell "$TMP/raw_${r}_${c}.png" "$label" display
		else
			cell "" ""
		fi
	done
done

if [ -z "$OUT" ]; then
	mkdir -p "$ROOT/.loggrade/sheets"
	OUT="$ROOT/.loggrade/sheets/look-sheet-$(date '+%Y%m%d-%H%M%S').png"
fi
ffmpeg -v error -y -framerate 1 -i "$TMP/cell_%04d.png" -vf "tile=${NC}x$(( N / NC )):padding=4:color=0x101010" \
	-frames:v 1 "$OUT"
# Says what the pixels already are, so no viewer has to guess.
sips --embedProfile "/System/Library/ColorSync/Profiles/sRGB Profile.icc" "$OUT" --out "$OUT" >/dev/null
printf '%s\n' "$OUT"
[ "$OPEN" = 0 ] || open -a Preview "$OUT"
