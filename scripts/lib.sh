#!/bin/bash
# Shared safety helpers for every stage script. Source this, don't copy it —
# the retag/verify pattern exists because both mistakes below actually happened once:
#
#   1. prores_ks (and libx264) don't reliably stamp -color_primaries/-color_trc/-colorspace
#      mid-encode. A file can measure bt2020 tags after encode despite those flags being passed,
#      even though the pixels were already correctly transformed — any tag-trusting player then
#      double-transforms the image (this is the "bleached out" bug). Fix: always re-verify with
#      ffprobe after ANY encode step in this pipeline, and re-tag via a fast -c copy remux if wrong.
#   2. -map 0 copies every stream, including ones the target container can't hold (a ProRes .mov's
#      QuickTime timecode data track has no mp4 equivalent) — that remux fails, and if the
#      following `mv` isn't conditional on success, it moves the failed (0-byte) output over a
#      good file, destroying it. This happened for real and cost one full re-render.
#
# Every stage script below must: encode -> check output is non-empty -> verify/fix tags via
# explicit stream mapping -> mv only after confirming the retag succeeded.

set -euo pipefail

# Resolved relative to lib.sh itself, so every stage sees the same file regardless of cwd.
LOOK_FILE="${LOOK_FILE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/look.json}"

# The look LUT is part of the grade, so it is named ONCE here rather than in each render path.
# Both scripts used to carry their own copy of this path: two places to change a look, which is
# exactly the drift look.json exists to end.
LOOK_LUT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/luts/looks/kodak_portra_400_nc.cube"

# ffprobe misreports these files two ways at once, and this function exists to survive both.
#
#   1. The video stream prints TWICE (once inside [STREAM_GROUP], once as a top-level [STREAM])
#      plus a blank separator line. An early version compared the whole multi-line output against
#      one expected value and so false-failed on every correctly tagged file.
#   2. csv output carries a TRAILING COMMA on camera-structured files — "bt709,bt709,bt709," — so
#      taking the first non-empty csv line still could never equal "bt709,bt709,bt709". Measured
#      on a `-c copy` excerpt of a camera original: correctly tagged, still rejected. The repo's
#      own rule covers this ("query fields individually, validate with a regex"); this function
#      was the place still breaking it.
#
# So: one query per field, bare values, first non-empty line each, joined here. Nothing downstream
# has to know which ffprobe quirk it is being protected from.
probe_tags() {
	local file="$1" field value out=""
	for field in color_space color_transfer color_primaries; do
		value=$(ffprobe -v error -select_streams v:0 -show_entries "stream=$field" \
			-of default=nw=1:nk=1 "$file" 2>/dev/null | grep -v '^[[:space:]]*$' | head -1)
		out="${out:+$out,}${value:-unknown}"
	done
	printf '%s\n' "$out"
}

verify_bt709() {
	local file="$1"
	local tags
	tags=$(probe_tags "$file")
	if [ "$tags" != "bt709,bt709,bt709" ]; then
		echo "TAG CHECK FAILED for $file: got '$tags', expected bt709,bt709,bt709" >&2
		return 1
	fi
	echo "tags OK ($file): $tags"
}

# Re-tags a file in place via a fast -c copy remux. Never overwrites the original unless the
# remux actually succeeded and produced a non-empty file.
#
# Takes the file, then any extra ffmpeg output args (e.g. -movflags +faststart). Uses "$@"
# directly rather than an intermediate array: macOS ships bash 3.2, where expanding an EMPTY
# array under `set -u` raises "unbound variable" — which silently blocked every retag until it
# was found. "$@" with no remaining positional args expands to nothing, safely, on 3.2.
safe_retag() {
	local file="$1"
	shift

	# VERIFY BEFORE REWRITING. This function exists because encoders don't reliably stamp the
	# tags — but they don't reliably get them wrong either, and remuxing unconditionally meant a
	# full read+write of two ~2.3GB ProRes masters per clip on the staged path, roughly 9GB of I/O
	# to change nothing. The header above has always described verify-then-fix; this makes the code
	# agree with it. Every caller that needs -movflags +faststart also passes it at encode time, so
	# skipping the remux loses nothing.
	if verify_bt709 "$file" 2>/dev/null; then
		return 0
	fi

	local tmp="${file%.*}_tagged.${file##*.}"

	# `0:a:0?` — the trailing ? makes the audio stream optional, so a silent clip doesn't fail here.
	# It MUST be quoted: `?` is a glob character. bash only survives it unquoted because an
	# unmatched glob passes through literally; zsh errors outright, and a file named `0:a:00` in
	# the working directory would break it under bash too.
	if ! ffmpeg -y -i "$file" -map 0:v:0 -map "0:a:0?" -c copy \
		-color_primaries bt709 -color_trc bt709 -colorspace bt709 \
		"$@" "$tmp" -v error; then
		echo "RETAG FAILED (ffmpeg error) for $file — left as-is, untagged" >&2
		rm -f "$tmp"
		return 1
	fi

	if [ -s "$tmp" ]; then
		mv "$tmp" "$file"
		verify_bt709 "$file"
	else
		echo "RETAG FAILED (empty output) for $file — left as-is, untagged" >&2
		rm -f "$tmp"
		return 1
	fi
}

# Fails loudly before a multi-GB encode starts rather than filling the disk mid-batch.
check_disk_space() {
	local dir="$1"
	local need_gb="$2"
	local probe="$dir" avail_kb avail_gb
	# The stages call this BEFORE `mkdir -p`, so on a first run into a fresh work dir the path does
	# not exist yet. df then fails, the arithmetic below gets an empty operand, and the stage dies
	# with a bash syntax error instead of a disk verdict — the guard aborting the run it exists to
	# protect. Walk up to the nearest existing ancestor: it sits on the same volume, and the volume
	# is the only thing being measured.
	while [ -n "$probe" ] && [ "$probe" != "/" ] && [ ! -d "$probe" ]; do
		probe="$(dirname "$probe")"
	done
	avail_kb=$(df -k "$probe" 2>/dev/null | tail -1 | awk '{print $4}')
	# Validate before the arithmetic rather than after: an empty or non-numeric answer here used to
	# reach $(( )) and abort the script with a syntax error.
	case "$avail_kb" in
		''|*[!0-9]*) echo "could not measure free space for $dir" >&2; return 1;;
	esac
	avail_gb=$((avail_kb / 1024 / 1024))
	if [ "$avail_gb" -lt "$need_gb" ]; then
		echo "LOW DISK SPACE: ${avail_gb}GB available in $dir, wanted ${need_gb}GB+" >&2
		return 1
	fi
	# STDERR, not stdout. Under JSON=1 stdout carries the event stream and nothing else, and this
	# line was landing in the middle of it — the first thing a consumer read was not JSON. A
	# verdict a person glances at is diagnostic output; the machine-readable answer is the event.
	echo "disk OK: ${avail_gb}GB available in $dir" >&2
	emit disk dir "$dir" available_gb "$avail_gb" wanted_gb "$need_gb"
}

# --- validating what reaches a filter graph -----------------------------------
# ffmpeg filter descriptions are a LANGUAGE, not a format string. `,` and `;` separate filters and
# chains, `'` quotes a value, `[` `]` delimit labels. Every look value below is spliced into one by
# printf, so a value carrying any of those ADDS FILTERS rather than being read as a number — and
# ffmpeg filters can write files (`metadata=print:file=`) and read them (`movie=`). There is no
# eval anywhere in this pipeline, so this is not shell injection; the ceiling is ffmpeg doing file
# I/O as whoever ran the script. That is still not a thing to leave open.
#
# WHY THIS IS NOT PARANOIA ABOUT YOUR OWN TYPING. look.json is not hand-authored. Per 02-grade.sh's
# header the grade is "sent back through the artifact db" from the Bench — a shared, multi-writer
# store — and transcribed here. Nothing checked what came back. A clip FILENAME is the other input
# nobody types: it arrives from the camera or from whoever handed you the card.
#
# Validate where a value is READ, not where it is used. There are five readers and a dozen uses.
require_number() {  # require_number <label> <value>  -> echoes the value, or fails
	case "$2" in
		''|*[!0-9.eE+-]*)
			echo "$1 must be numeric: got '$2'" >&2
			return 1;;
	esac
	printf '%s\n' "$2"
}

# Clip names become path components AND reach the filter graph, via the per-clip tone LUT
# (`lut1d=file='<cache>/<clip>_tone.cube'`) and the transform (`vidstabtransform=input='...'`).
#
# Two refusals, for two different failures:
#   - `/` makes the name a path. Stage outputs are built as "$WORK/dist/<stage>/${CLIP}_x.mov", and
#     since the stages started calling `mkdir -p "$(dirname "$OUT")"` — needed once the work dir
#     stopped being the repo — a traversing name is no longer stopped by the directory not
#     existing. It gets created.
#   - A quote or a filter separator closes ffmpeg's `file='...'` quoting from the inside.
#
# Refuse rather than sanitise. Rewriting someone's argument into a different one silently renders
# the wrong clip, which is the fail-open shape this whole file exists to avoid.
require_clip_name() {  # require_clip_name <name>
	case "$1" in
		'')
			echo "REFUSING: empty clip name." >&2
			return 1;;
		*/*)
			echo "REFUSING: clip name '$1' contains '/'." >&2
			echo "  Clip names are not paths — they name a file inside the work dir's src/." >&2
			return 1;;
		*[\'\"\,\;\[\]\\]*|*:*)
			echo "REFUSING: clip name '$1' contains a character ffmpeg reads as filter syntax." >&2
			echo "  It would reach the filter graph through the tone-LUT and transform paths." >&2
			echo "  Rename the clip, then retry." >&2
			return 1;;
	esac
	printf '%s\n' "$1"
}

# --- machine-readable events --------------------------------------------------
# The app this repo exists for has to know what a run is doing without reading prose written for a
# person. So every state the pipeline already prints gets a second, stable expression next to it.
#
#   JSON=1   puts one JSON object per line on stdout, and moves the human lines to the report file
#            only — so a consumer reads ONE format per stream rather than sniffing which line is
#            which. The report is unchanged either way; that is what the test pins.
#   codes    a named code on stderr beside the human text, always, JSON or not. stderr is where a
#            wrapper looks for why a run stopped, and every refusal already goes there while never
#            reaching the report.
#
# Codes are NAMED rather than matched out of message text, because a message is prose and gets
# reworded. That already broke a test in the precursor silently: it asserted on wording that was
# later renamed, and stayed green against the guard it no longer checked.
JSON="${JSON:-0}"

# Escapes a value for a JSON string: the two characters that break the grammar, plus newline and
# tab, which would break the one-object-per-line contract that makes the stream readable at all.
# What reaches this is clip names, paths and numbers — not arbitrary text.
json_str() {
	printf '%s' "$1" | tr '\n\t' '  ' | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

# Emitted bare (as a JSON number) only for something that really is one: at least one digit and
# nothing a number cannot contain. "-" is the YAVG placeholder when MATCH=0 and must stay a string,
# which a laxer test would have emitted as `"yavg":-` — invalid JSON, and only on that one path.
_json_is_num() {
	case "$1" in
		''|*[!0-9.eE+-]*) return 1;;
		*[0-9]*) return 0;;
		*) return 1;;
	esac
}

# emit <event> [key value]...  — one object per line on stdout, only under JSON=1.
# Positional pairs because macOS ships bash 3.2, which has no associative arrays.
emit() {
	[ "$JSON" = "1" ] || return 0
	local event="$1" k v; shift
	printf '{"event":"%s"' "$(json_str "$event")"
	while [ "$#" -gt 1 ]; do
		k="$1"; v="$2"; shift 2
		if _json_is_num "$v"; then
			printf ',"%s":%s' "$(json_str "$k")" "$v"
		else
			printf ',"%s":"%s"' "$(json_str "$k")" "$(json_str "$v")"
		fi
	done
	printf '}\n'
}

# emit_code <NAME> — the machine half of a refusal or a degraded state, BESIDE the human text
# rather than instead of it. Always on stderr: a consumer that never sets JSON=1 still needs to
# know why a clip was skipped, and the human sentence is the thing that gets reworded.
emit_code() { printf 'GRADE_CODE=%s\n' "$1" >&2; }

# Translates ffmpeg's -progress stream into events. ffmpeg writes bare `key=value` lines and ends
# each block with `progress=continue`, or `progress=end` for the last one, so one event per block
# is the natural granularity — roughly two a second.
#
# WHY A TRANSLATOR RATHER THAN LETTING IT THROUGH. `-progress pipe:1` would otherwise interleave
# ffmpeg's own format with the event stream on the same fd, and a consumer would have to sniff
# every line to know which grammar it is in.
progress_events() {  # progress_events <label>   reads -progress output on stdin
	local label="$1" key value frame="" fps="" out_time=""
	while IFS='=' read -r key value; do
		case "$key" in
			frame)       frame="$value";;
			fps)         fps="$value";;
			out_time_ms) out_time="$value";;
			progress)    emit progress label "$label" state "$value" \
			                  frame "${frame:-0}" fps "${fps:-0}" out_time_ms "${out_time:-0}";;
		esac
	done
}

# --- the look -----------------------------------------------------------------
# One source for every look value: look.json at the repo root. Nothing else may hardcode one.
# Before this existed, `SAT=1.27` was written out in two scripts and had already started to drift
# in the obvious way — two copies, one edited.
# NO FALLBACK, on purpose. The parameter that used to be here had no caller and could not get one:
# substituting a default for a missing key is how a run silently renders a different look, which is
# the failure this whole file exists to end. A missing key stops the run. That makes the key set a
# contract between the scripts and look.json, which is worth more than a graceful degrade.
look() {  # look <jq-path>
	local key="$1" v
	v=$(jq -r "$key // empty" "$LOOK_FILE" 2>/dev/null) || v=""
	[ -n "$v" ] || { echo "look.json: missing $key" >&2; return 1; }
	printf '%s\n' "$v"
}

# The shipped tone LUT is GENERATED from look.json's tone block, so the .cube can never silently
# disagree with the numbers that claim to describe it.
#
# FRESHNESS IS BY CONTENT, NOT MTIME. This used to skip regeneration when the cube was newer than
# look.json. git does not preserve mtimes, so on every fresh clone the committed cube lands newer
# and is trusted forever — verified: with look.json backdated and contrast changed to 0.5, the
# stale curve stayed in place in silence, and the guarantee held only on the machine where the edit
# happened. make-tone-lut.py now stamps its parameters into the cube's TITLE and skips the write
# itself when they already match, so this calls it unconditionally. Generating the 4096-entry
# table costs ~0.1s; there was never anything to save by guessing.
ensure_tone_lut() {
	# Two lines, not one: bash expands the whole command line BEFORE `local` performs its
	# assignments, so `local a="$1" b="$a"` sees an unset $a — and under `set -u` that aborts.
	local root="$1"
	local cube="$root/luts/tone/shipped.cube"
	"$root/scripts/make-tone-lut.py" "$cube" \
		--gamma    "$(look .tone.gamma)"    --pivot  "$(look .tone.pivot)" \
		--contrast "$(look .tone.contrast)" --toe    "$(look .tone.toe)" \
		--shoulder "$(look .tone.shoulder)" --black  "$(look .tone.black)" >/dev/null
}

resolve_work_dir() {
	local root="$1" w=""
	if [ -n "${GRADE_WORK_DIR:-}" ]; then
		w="$GRADE_WORK_DIR"
	elif [ -f "$root/.workdir" ]; then
		w=$(sed -e 's/[[:space:]]*$//' -e '/^[[:space:]]*#/d' "$root/.workdir" | head -1)
		case "$w" in "~"*) w="$HOME${w#\~}";; esac
	fi
	[ -n "$w" ] || w="$root"
	if [ ! -d "$w" ]; then
		echo "work directory does not exist: $w" >&2
		echo "  set GRADE_WORK_DIR, or put the path in $root/.workdir" >&2
		return 1
	fi
	printf '%s\n' "$w"
}

# This shoot is MIXED ORIENTATION: of 19 clips, 11 have no rotation matrix (they stay landscape
# 3840x2160), 7 are -90 and IMG_0609 alone is +90 (both of those present as 2160x3840 portrait).
# A vertical delivery script handed a landscape master will happily scale 3840x2160 into
# 1080x1920 — no error, no warning, just a badly squashed file that looks "done". That is the
# dangerous failure in a batch run, so refuse it here instead.
# There is deliberately NO rotation logic in this pipeline — orientation is an ingest concern and
# the source is trusted. This guard exists for one thing only: a genuinely landscape clip reaching
# a vertical deliverable gets silently squashed into 1080x1920, and silent is the problem.
#
# So it decodes one frame and measures it, rather than reasoning about display matrices. ffmpeg
# autorotates on decode, so this reflects what a viewer sees, and it does not care whether the
# source was corrected by re-encoding or by fixing the matrix in Preview.
require_portrait() {
	local file="$1" stem tmp w h
	# mktemp CREATES the file it names, and ".png" is appended to that name — so the file mktemp
	# made is not the file that gets removed. Both have to go, or every call leaks one temp file
	# and a 19-clip batch leaves 19 behind.
	stem="$(mktemp -t portrait)"
	tmp="$stem.png"
	if ! ffmpeg -v error -y -i "$file" -frames:v 1 "$tmp" 2>/dev/null; then
		rm -f "$stem" "$tmp"; echo "could not decode a frame from $file" >&2; return 1
	fi
	w=$(ffprobe -v error -show_entries stream=width -of default=nw=1:nk=1 "$tmp" | head -1)
	h=$(ffprobe -v error -show_entries stream=height -of default=nw=1:nk=1 "$tmp" | head -1)
	rm -f "$stem" "$tmp"

	# Refuse what cannot be measured. A missing or non-numeric dimension makes `[ "$h" -le "$w" ]`
	# ERROR, and an `if` reads an erroring condition as FALSE — so the guard used to accept the clip
	# it had just failed to measure. That is the same fail-open shape as the trailing comma on this
	# camera's csv output, which is the bug this guard exists to replace.
	case "$w" in ''|*[!0-9]*) w="";; esac
	case "$h" in ''|*[!0-9]*) h="";; esac
	if [ -z "$w" ] || [ -z "$h" ]; then
		echo "REFUSING: could not measure a decoded frame from $file." >&2
		echo "  Refusing rather than guessing — a wrong guess here squashes the delivery." >&2
		return 1
	fi

	if [ "$h" -le "$w" ]; then
		echo "REFUSING: $file decodes as ${w}x${h}, not portrait." >&2
		echo "  Vertical delivery would squash it. Fix the source orientation, then retry." >&2
		return 1
	fi
}

require_nonempty() {
	local file="$1"
	local label="$2"
	if [ ! -s "$file" ]; then
		echo "$label FAILED — $file missing or empty" >&2
		return 1
	fi
}

# A stabilisation transform is measured against the DECODED frame, so re-orienting a source
# invalidates it: the .trf then describes motion in a frame that no longer exists, and the warp
# fights footage it was never measured on. Nothing announces that — the render just comes out
# subtly wrong.
#
# This is the one freshness check in the pipeline that is still mtime-based, and deliberately so:
# a .trf has no content fingerprint to compare, and "was it measured after the footage" is exactly
# what an mtime answers. shipped.cube went the other way for a reason that does not apply here —
# git does not preserve mtimes, so a COMMITTED artefact cannot use them. A .trf is never committed.
#
# The reference is always the SOURCE CLIP, never an intermediate. Transforms are motion-only and
# survive a re-grade, so a re-rendered master says nothing about whether the camera moved — and
# comparing against one made every transform grade.sh wrote go stale the moment a master
# re-rendered, silently sending the delivery out unstabilised.
#
# No source, no verdict: refuse. A stale transform fights footage it was never measured on, which
# is visibly wrong output, where dropping stabilisation is merely less good.
transform_is_fresh() {  # transform_is_fresh <trf> <source-clip>
	[ -f "$1" ] || return 1
	[ -f "$2" ] || return 1
	[ "$1" -nt "$2" ]
}

# --- the delivery chain -------------------------------------------------------
# ONE definition of the tail every deliverable shares: the stabilisation warp, the chroma denoise,
# the crop, the 10->8 bit reduction, the sharpener and the grain blend.
#
# This lived in THREE copies — 03-final-reels.sh, 03-final-feed.sh and grade.sh's render() — and
# had already drifted three ways, which is why it is here now: the 40-line grain rationale existed
# in the reels copy only, grade.sh hardcoded the grain plate's frame rate at 24 where the others
# probed it, and only the stage-3 copies checked disk space. Every constant below is measured, and
# the notes say by what. Nothing here is a style preference.

# ffprobe's csv output carries a TRAILING COMMA on this camera's files, and `r=30000/1001,` inside
# a lavfi source string is a parse error, not merely a wrong number. Query the field on its own
# and validate the shape before trusting it. 24 is the fallback because that is what this camera
# shoots; a wrong-but-plausible rate makes temporal grain step instead of updating per frame.
source_fps() {  # source_fps <file>
	local fps
	fps=$(ffprobe -v error -select_streams v:0 -show_entries stream=r_frame_rate \
		-of default=nw=1:nk=1 "$1" 2>/dev/null | grep -E '^[0-9]+(/[0-9]+)?$' | head -1)
	printf '%s\n' "${fps:-24}"
}

# Tag EVERY synthesised branch. A lavfi source carries no colourspace metadata, and ffmpeg
# negotiates formats across the WHOLE graph — so an untagged branch propagates "unknown"
# backwards and a zscale on a different branch fails with "code 3074: no path between
# colorspaces", pointing at a filter that is not the problem. Every filter was bisected
# individually and all passed; only the pair fails.
DELIVERY_SETPARAMS="setparams=colorspace=bt709:color_primaries=bt709:color_trc=bt709:range=limited"

# hqdn3d=<luma_spatial>:<chroma_spatial>:<luma_tmp>:<chroma_tmp>. The luma terms are ZERO on
# purpose: this must not touch image detail. It exists because saturation 1.27 amplifies the
# chroma error already present on high-contrast edges (measured: the street sign's white-on-blue
# lettering gains a visible cyan fringe between baseline and graded), and the 4:2:0 conversion at
# export coarsens it further. Verified chroma-only: luma YAVG 486.97 -> 487.02.
DELIVERY_CHROMA="hqdn3d=0:5:0:6,"

# `shortest=1` on the blend is REQUIRED, and `-shortest` is not a substitute. The grey plate is an
# infinite lavfi source; with filter_complex, `-shortest` does not reliably stop the encode, so the
# render runs forever and the output grows without bound (observed: a 26s clip past 189MB and still
# going, with no moov atom ever written). The blend option terminates on the shortest input, which
# is the video.
# shellcheck disable=SC2034  # spliced into filter graphs by the stage scripts, not used here
DELIVERY_BLEND="blend=all_mode=grainmerge:shortest=1"


# THE GRADE ITSELF, as a spliceable filter chain: look LUT, tone curve, saturation, warmth. Both
# render paths use it — the one-pass grade.sh and the staged 02-grade.sh — and they used to build
# it separately. That had already drifted once (grade.sh carried its own copy of the tone block, so
# a grade sent from the Bench moved one path and not the other), and NOTHING in the suite renders
# the staged graph, so a second divergence would ship in silence. One builder, two callers, the
# same reasoning as the delivery chain below.
#
# TONE ON THE LUMA PLANE ONLY. A per-channel contrast curve crushes a saturated colour's two low
# channels harder than its high one, so saturated things get more saturated — the traffic signage
# went visibly neon long before it was measured. Curving luma and merging the ORIGINAL chroma back
# gives the same tone with colour untouched. `0x001112` = plane 0 from input 0 (the toned luma),
# planes 1 and 2 from input 1. Measurements in docs/PIPELINE.md, "The fix: apply the tone curve to
# LUMA ONLY"; the consequences are ADR 0003, including why the brick's lost saturation must NOT be
# won back with a uniform boost.
#
# `format=yuv444p10le` ON BOTH BRANCHES is required, not decoration: mergeplanes needs matching
# plane dimensions and 4:2:2 chroma is half width, so without it the graph dies on a bare
# "Invalid argument" naming nothing.
#
# Internal labels are prefixed because callers splice this into a bigger graph and choose their
# own — grade.sh already uses [b] for the image branch that continues from here.
#
# <head> and <tag> are prefixes carrying their own trailing comma, like delivery_image_chain's, so
# that an absent one leaves no trace: head is the camera CST for the one-pass path (the staged path
# applied it back in stage 01), and tag is DELIVERY_SETPARAMS wherever the result feeds filters
# that negotiate a colourspace.
grade_chain() {  # grade_chain <tone-lut> <sat> <warm> [head-prefix] [tag-prefix]
	printf "%slut3d=file='%s':interp=tetrahedral,format=yuv444p10le,split=2[gc_y][gc_c];[gc_y]lut1d=file='%s':interp=linear,format=yuv444p10le[gc_t];[gc_t][gc_c]mergeplanes=0x001112:yuv444p10le,%shue=s=%s,colorbalance=rm=%s:bm=-%s" \
		"${4:-}" "$LOOK_LUT" "$1" "${5:-}" "$2" "$3" "$3"
}
# The warp resamples BEFORE the downscale, so it happens at master resolution rather than at
# delivery size. The trailing comma belongs to the prefix: callers splice the result directly into
# a filter chain, and an absent transform must leave no trace.
stab_prefix() {  # stab_prefix <trf> <smoothing>
	printf "vidstabtransform=input='%s':smoothing=%s:optzoom=1:interpol=bicubic,unsharp=5:5:0.2:3:3:0.0," \
		"$1" "$2"
}

# Grain and sharpen come AFTER the downscale, not before: grain sized for the 4K master is crushed
# to invisibility once scaled to 1080p, and sharpening pre-resize is blurred back out by the
# resize.
#
# zscale (not scale) does the reduction because only zscale actually DITHERS the 10->8 bit step.
# Verified: `scale=...,format=yuv420p` and `-sws_dither ed` produce byte-identical output, i.e.
# neither dithers at all, while zscale's error_diffusion differs — and it matters on this footage,
# which has a large flat sky where banding would show.
#
# The dither happens HERE, at the reduction, and not after the blend: the grey plate carries no
# colourspace metadata, so a zscale placed after `blend` has no input space to convert from and
# dies with "code 3074". The plate is already 8-bit, so dithering it again bought nothing anyway.
delivery_image_chain() {  # delivery_image_chain <w> <h> <stab-prefix> <crop-prefix>
	printf '%s%s%szscale=w=%s:h=%s:f=lanczos:d=error_diffusion,format=yuv420p,unsharp=5:5:0.4:5:5:0.0' \
		"$3" "$DELIVERY_CHROMA" "$4" "$1" "$2"
}

# CLUSTERED grain, not per-pixel, generated on a half-resolution plate and blended. Measured:
#
#   1. Per-pixel grain does not survive delivery. Re-encoded at ~4 Mbps its lag-1 autocorrelation
#      goes 0.00 -> 0.39: the compressor smears it into blobs and invents correlation that was
#      never there. Half-resolution grain keeps its own structure through the same re-encode
#      (0.75 -> 0.59).
#   2. Clustered is also CHEAPER: bitrate against no grain is 3.7x per-pixel, 2.9x clustered. More
#      filmic and ~22% cheaper to encode, which is not the usual trade. (`-tune grain` was tested
#      too: 4.3x bitrate for no structural gain. Skipped.)
#   3. It must come after the sharpener. Grain before `unsharp` gets RUNG by it — the isolated
#      residual shows a negative lag-1 (-0.09), the signature of an overshoot either side of every
#      spike, which reads as "crunchy digital" rather than film. It is also WEAKER than intended
#      (sd 2.65 vs 3.67 at the same c0s) because the sharpener averages it away.
#
# The plate is flat grey so its chroma stays neutral and `grainmerge` is a no-op on the chroma
# planes — measured U-plane residual sd 0.000, i.e. verifiably luma-only. That matters because the
# hqdn3d pass exists to clean chroma up, and grain must not put any back.
#
# c0s is the one number that wants an eye rather than a measurement. 8 reads as "subtle";
# clustered grain reads stronger per unit amplitude than per-pixel, so it sits below the old 6.
grain_plate() {  # grain_plate <w> <h> <fps>
	printf 'color=c=gray:s=%sx%s:r=%s' "$(( $1 / 2 ))" "$(( $2 / 2 ))" "$3"
}

delivery_grain_branch() {  # delivery_grain_branch <w> <h> <strength>
	printf 'noise=c0s=%s:c0f=t,scale=%s:%s:flags=bilinear,format=yuv420p,%s' \
		"$3" "$1" "$2" "$DELIVERY_SETPARAMS"
}

# Renders to a staging file and installs it only once the render has succeeded, been checked for
# content, and had its colour tags verified. Takes the FINAL path, a label for messages, then every
# ffmpeg argument except the output path.
#
# WHY THIS EXISTS. `ffmpeg -y` pointed straight at the delivery path TRUNCATES the existing file
# before it knows whether the filter graph even initialises. Measured: an approved mp4 re-rendered
# with a graph that fails at init was left at 0 bytes, ffmpeg exiting 234. require_nonempty then
# reports the failure loudly — but the approved deliverable is already gone, and per
# docs/adr/0004 getting it back means regenerating the baseline and the master first.
#
# This is the same incident this file's header describes for the retag remux, and the same staging
# 00-stabilise-detect.sh uses for its .trf. The render path was the only one without it.
render_delivery() {  # render_delivery <final-out> <label> <ffmpeg-arg>...
	local out="$1" label="$2"
	shift 2
	local tmp="${out%.*}.partial.${out##*.}"
	rm -f "$tmp"          # a staging file left by an earlier interrupted run

	# PROGRESS, and only under JSON=1. Piping ffmpeg changes the process tree and the exit status
	# has to come out of PIPESTATUS rather than $?, so the default path is left exactly as it was
	# rather than carrying that for a consumer that is not listening. `-nostats` because the
	# human-facing stats line is what -progress replaces.
	local rc=0
	if [ "$JSON" = "1" ]; then
		# errexit is suspended for exactly one pipeline: this file sets `pipefail`, so a failing
		# ffmpeg would abort the function before PIPESTATUS could be read — and then the staging
		# file would never be cleaned up and the caller would see a crash instead of a verdict.
		set +e
		ffmpeg "$@" -progress pipe:1 -nostats "$tmp" -v error | progress_events "$label"
		rc="${PIPESTATUS[0]}"
		set -e
	else
		ffmpeg "$@" "$tmp" -v error || rc=$?
	fi
	if [ "$rc" -ne 0 ]; then
		rm -f "$tmp"
		echo "$label FAILED (ffmpeg error) — $out left exactly as it was" >&2
		return 1
	fi
	if ! require_nonempty "$tmp" "$label"; then
		rm -f "$tmp"
		echo "  $out left exactly as it was" >&2
		return 1
	fi
	# Tag before installing, so the file that lands is the one that was verified — and CHECK the
	# result, like the two guards above. A bare call here fails open: it only aborted because the
	# callers run under `set -e`, so any context that suppresses it (bats `run`, an
	# `if render_delivery ...`) installed an untagged file and returned 0. Verified by stubbing
	# safe_retag to fail: the installed file measured unknown,unknown,unknown. That is the
	# double-transform this file's header exists to prevent, arriving through the function written
	# to prevent it.
	if ! safe_retag "$tmp" -movflags +faststart >/dev/null; then
		rm -f "$tmp"
		echo "$label FAILED (could not tag) — $out left exactly as it was" >&2
		return 1
	fi
	mv "$tmp" "$out"
}
