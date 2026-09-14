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
LIB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOOK_FILE="${LOOK_FILE:-$LIB_ROOT/look.json}"

# Apple's Log -> Rec.709 conversion. It is NOT in this repo — Apple's licence does not permit
# redistributing it (luts/apple/SOURCE.txt) — so a fresh clone has no such file.
#
# Every stage that needs it checks for it up front, because the ways a missing cube surfaces
# otherwise are not all loud. The exposure probe runs it inside a pipeline ending in `|| true`, so
# a missing cube there comes back as an empty measurement and every clip silently gets the
# reference gamma: a plan that looks complete and matched nothing.
APPLE_CST="$LIB_ROOT/luts/apple/AppleLogToRec709-v1.0.cube"
require_apple_cst() {
	[ -f "$APPLE_CST" ] && return 0
	echo "Apple's Log->Rec709 LUT is missing:" >&2
	echo "  $APPLE_CST" >&2
	echo "It is deliberately not committed — Apple's licence does not permit redistributing it." >&2
	echo "Download it (free Apple ID, ~2 min) per luts/apple/SOURCE.txt, then re-run." >&2
	return 1
}

# Where each stage writes, by clip. Spelled once because two stages read what a third wrote, and a
# path that differs by one component is a cache nobody hits: grade.sh once built the transform path
# from the wrong root and paid ~65s a clip to redo analysis stage 00 had already done.
source_path()        { printf '%s/src/%s.mov\n' "$1" "$2"; }                      # <work> <clip>
baseline_path()      { printf '%s/dist/01-baseline/%s_baseline.mov\n' "$1" "$2"; }  # <work> <clip>
graded_master_path() { printf '%s/dist/02-graded/%s_graded.mov\n' "$1" "$2"; }    # <work> <clip>
transform_path()     { printf '%s/dist/stab/%s.trf\n' "$1" "$2"; }                 # <work> <clip>

# A proof is named so it can never be mistaken for a deliverable in a folder listing.
deliverable_path() {  # deliverable_path <dir> <clip> <suffix> [proof-seconds]
	if [ -n "${4:-}" ]; then
		printf '%s/%s_%s_proof-%ss.mp4\n' "$1" "$2" "$3" "$4"
	else
		printf '%s/%s_%s.mp4\n' "$1" "$2" "$3"
	fi
}

# The look LUT is part of the grade, so it is chosen in look.json like every other look value and
# resolved HERE, once, rather than in each render path. Both scripts used to carry their own copy
# of a hardcoded path: two places to change a look, which is the drift look.json exists to end.
#
# It is a choice now rather than a constant, because the app offers it as one. Two things that
# follow are not obvious:
#
#   - "none" omits the filter entirely instead of passing an identity cube. An identity lookup
#     still pays interpolation error on every pixel for no change, and a 13-point identity grid
#     pays a visible amount of it.
#   - the tone curve was tuned WITH this look in the chain, so a look and a tone belong to each
#     other. Changing one without the other is a different grade, not the same grade in a
#     different film stock. A preset is the pair.
#
# The print cube is resolved the same way from luts/print/, which is the third argument: a print is
# a look in every respect this function cares about, and a second copy of it is what drifts.
resolve_look_lut() {  # resolve_look_lut <name|none|path> <repo-root> [looks|print]  -> a path, or nothing
	local name="$1" root="$2" folder="${3:-looks}" path
	case "$name" in
		none|None|NONE|"") printf '' ; return 0;;
		*/*|*.cube) path="$name";;
		*) path="$root/luts/$folder/${name}.cube";;
	esac
	# The path is spliced into `lut3d=file='...'` so a quote or a filter separator in it closes
	# ffmpeg's quoting from the inside — the same reason require_clip_name exists one level up.
	case "$path" in
		*[\'\"\,\;\[\]]*)
			echo "look LUT path contains filter syntax: $path" >&2
			return 1;;
	esac
	if [ ! -f "$path" ]; then
		echo "$folder LUT not found: $path" >&2
		echo "  look.json names a cube in luts/$folder/ (without the extension)," >&2
		echo "  or \"none\" for no cube at all. Available:" >&2
		# A glob loop rather than `ls`: shellcheck rejects parsing ls output, and this also
		# prints nothing at all when the folder is empty instead of an unmatched pattern.
		for c in "$root/luts/$folder/"*.cube; do
			[ -f "$c" ] || continue
			c="${c##*/}"
			echo "    ${c%.cube}" >&2
		done
		return 1
	fi
	printf '%s\n' "$path"
}

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
		value="$(probe_field "$file" "stream=$field")"
		out="${out:+$out,}${value:-unknown}"
	done
	printf '%s\n' "$out"
}

# ONE field, the only way CLAUDE.md allows for this camera: bare value, first non-empty line,
# because the video stream prints twice with a blank line between. Callers validate the shape they
# expect; this only guarantees they are looking at one line.
#
# `sed` rather than `grep | head -1`: under pipefail, head closing the pipe early can kill the
# writer with SIGPIPE and fail the whole assignment.
probe_field() {  # probe_field <file> <stream=key|format=key>  -> the raw value, or nothing
	ffprobe -v error -select_streams v:0 -show_entries "$2" -of default=nw=1:nk=1 "$1" \
		2>/dev/null | sed -n '/[^[:space:]]/{p;q;}' || true
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

# A number from 0 to 1. The grain weights are spliced into an expression where a value above 1 would
# push the mask past full scale and clip, which renders as a hard edge in the grain rather than as
# an error; refusing is cheaper than finding that on a delivered file.
require_unit() {  # require_unit <label> <value>  -> echoes the value, or fails
	require_number "$1" "$2" >/dev/null || return 1
	if [ "$(awk -v v="$2" 'BEGIN { print (v >= 0 && v <= 1) ? "ok" : "no" }')" != "ok" ]; then
		echo "$1 must be between 0 and 1: got '$2'" >&2
		return 1
	fi
	printf '%s\n' "$2"
}

# A comma-separated list of numbers, such as a CDL wheel's "1,1,1" or a tint. These are handed to
# a generator's argv UNQUOTED, one flag list per call, so whitespace in one would split into extra
# arguments — and a generator that then dies of an argparse error answers --check-neutral with
# nothing, which reads as "not active" and drops the stage in silence. How MANY numbers is the
# consumer's rule, not this one's: the correction generator takes one value as three.
require_numbers() {  # require_numbers <label> <value>  -> echoes the value, or fails
	case "$2" in
		''|,*|*,|*,,*|*[!0-9.eE+,-]*)
			echo "$1 must be numbers separated by commas: got '$2'" >&2
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

# --- the run report: timing, environment, what was actually run ----------------------------
# The report is read LATER, by someone debugging a render with nothing else to go on — so it has to
# carry what is otherwise lost: how long each phase took, on what machine and ffmpeg, and the filter
# graph itself, which shellcheck cannot see into and which is never printed anywhere else.
#
# None of it goes through `emit`. The event stream is a contract the app parses and
# tests/fixtures/events.jsonl pins; a debugging aid has no business changing it.
#
# Every helper here FAILS SOFT. A missing sysctl or a perl that will not start must not abort a
# render under `set -e` for the sake of a line in a text file.

# Milliseconds, as an integer. macOS's `date` has no %N, and bash 3.2 has no float arithmetic, so
# integer milliseconds are what lets phases be summed with `$(( ))` rather than an awk per addition.
# perl's Time::HiRes ships with stock macOS; whole seconds is the fallback, not an abort.
now_ms() {
	perl -MTime::HiRes=time -e 'printf "%d\n", time * 1000' 2>/dev/null \
		|| printf '%s000\n' "$(date +%s)"
}

fmt_ms() {  # fmt_ms <ms>  -> "4.217s" or "3m12.004s"
	local ms="$1"
	if [ "$ms" -ge 60000 ]; then
		printf '%dm%02d.%03ds' $(( ms / 60000 )) $(( ms % 60000 / 1000 )) $(( ms % 1000 ))
	else
		printf '%d.%03ds' $(( ms / 1000 )) $(( ms % 1000 ))
	fi
}

# Writes to the run report and nowhere else. `say` prints to the terminal as well; these lines are
# too long and too many for that — a filter graph is thousands of characters. Scripts that keep no
# report (the staged ones) leave REPORT unset, and then this does nothing.
report_line() {
	[ -n "${REPORT:-}" ] || return 0
	printf '%s\n' "$*" >> "$REPORT"
}

# One field of a file, validated so a stray line cannot pass for a number.
probe_number() {  # probe_number <file> <stream=key|format=key>  -> the number, or "?"
	local v
	v="$(probe_field "$1" "$2")"
	case "$v" in
		''|*[!0-9./]*) v="?";;
	esac
	printf '%s\n' "$v"
}

# What the run ran ON. Half the performance questions asked of a report later are really "was this
# the slow machine" or "was that before the ffmpeg upgrade", and neither is recoverable afterwards.
report_environment() {  # report_environment <repo-root>
	local root="$1" rev cpu cores mem os
	rev=$(git -C "$root" rev-parse --short HEAD 2>/dev/null) || rev="unknown"
	if [ "$rev" != unknown ] && [ -n "$(git -C "$root" status --porcelain --untracked-files=no 2>/dev/null || true)" ]; then
		rev="$rev (uncommitted changes)"
	fi
	cpu=$(sysctl -n machdep.cpu.brand_string 2>/dev/null) || cpu="unknown cpu"
	cores=$(sysctl -n hw.ncpu 2>/dev/null) || cores="?"
	mem=$(sysctl -n hw.memsize 2>/dev/null) || mem=0
	os=$(sw_vers -productVersion 2>/dev/null) || os="?"
	report_line "engine:  $root @ $rev"
	# `sed -n 1p`, not `head -1`: under pipefail, head closing the pipe early can kill the writer
	# with SIGPIPE and fail the whole assignment.
	report_line "ffmpeg:  $(ffmpeg -version 2>/dev/null | sed -n 1p || true)"
	report_line "machine: $cpu, $cores cores, $(( mem / 1073741824 ))GB, macOS $os, bash $BASH_VERSION"
	report_line "look:    $LOOK_FILE sha256:$(shasum -a 256 "$LOOK_FILE" 2>/dev/null | cut -c1-16 || true)"
}

# The command exactly as ffmpeg received it, graph first and on its own, delimited. The graph is the
# part a render goes wrong in and the part `%q` would bury under escapes, so it is printed raw — it
# can be pasted back into a shell in single quotes.
report_command() {  # report_command <label> <ffmpeg-arg>...
	[ -n "${REPORT:-}" ] || return 0
	local label="$1" a prev="" prev2="" args="" n=0
	shift
	for a in "$@"; do
		# A lavfi INPUT is a graph too — the grain plate is one — so it is printed the same way.
		if [ "$prev" = "-filter_complex" ] || [ "$prev" = "-vf" ] \
			|| { [ "$prev" = "-i" ] && [ "$prev2" = "lavfi" ]; }; then
			n=$(( n + 1 ))
			report_line "      --- graph $n ($label, $prev) ---"
			report_line "$a"
			report_line "      --- end graph $n ---"
			args="$args <graph $n>"
		else
			args="$args $(printf '%q' "$a")"
		fi
		prev2="$prev"; prev="$a"
	done
	report_line "      command: ffmpeg$args"
}

# Encode throughput from the file that landed, not from ffmpeg's progress lines: the output's own
# frame count and duration are what a PROOF actually rendered, whatever the source's length.
report_encode() {  # report_encode <label> <file> <elapsed-ms>
	local label="$1" file="$2" ms="$3" frames dur bytes
	frames=$(probe_number "$file" stream=nb_frames)
	dur=$(probe_number "$file" format=duration)
	bytes=$(stat -f%z "$file" 2>/dev/null) || bytes=0
	report_line "$(awk -v l="$label" -v ms="$ms" -v f="$frames" -v d="$dur" -v b="$bytes" 'BEGIN {
		s = ms / 1000; if (s <= 0) s = 0.001
		line = sprintf("      %s took %.3fs", l, s)
		if (f != "?") line = line sprintf(", %d frames at %.2f fps", f, f / s)
		if (d != "?" && d > 0) line = line sprintf(", %.3fx realtime, %.2f Mbit/s", d / s, b * 8 / d / 1000000)
		printf "%s, %.2fMB\n", line, b / 1048576
	}')"
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
	local root="$1" gamma shape
	local cube="$root/luts/tone/shipped.cube"
	gamma="$(require_number tone.gamma "$(look .tone.gamma)")" || return 1
	shape="$(tone_shape_args)" || return 1
	# shellcheck disable=SC2086  # a flag list of validated numbers, split on purpose
	"$root/scripts/make-tone-lut.py" "$cube" --gamma "$gamma" $shape >/dev/null
}

# --- look.json -> generator arguments -------------------------------------------------------
# Each generator's flags are spelled ONCE, here. They were spelled at every call site, and the
# copies had drifted: the staged path's neutrality check left out --lum-mix, and the tone block was
# mapped to flags twice, so a key added on one path would have reached the generator's argparse
# DEFAULT on the other — a different look, rendered in silence.
#
# EVERY VALUE IS VALIDATED INSIDE, AND EVERY CALLER MUST ASSIGN FIRST: `args="$(tone_shape_args)"
# || exit 1`. Spliced straight into a command, a failed read inside `$(...)` is swallowed, the
# generator receives a partial flag list, and a --check-neutral that dies of it answers with
# nothing — which a string comparison reads as "neutral". That is the stage dropped in silence.

# The tone curve's shape. Gamma is not here because it is the one term solved per clip.
#
# Keys are written out literally rather than looped over: the suite's key-contract test finds what
# the scripts read by grepping for each literal read, and a computed key is invisible to it.
tone_shape_args() {  # tone_shape_args  -> "--pivot P --contrast C --toe T --shoulder S --black B"
	local pivot contrast toe shoulder black
	pivot="$(require_number tone.pivot "$(look .tone.pivot)")" || return 1
	contrast="$(require_number tone.contrast "$(look .tone.contrast)")" || return 1
	toe="$(require_number tone.toe "$(look .tone.toe)")" || return 1
	shoulder="$(require_number tone.shoulder "$(look .tone.shoulder)")" || return 1
	black="$(require_number tone.black "$(look .tone.black)")" || return 1
	printf -- '--pivot %s --contrast %s --toe %s --shoulder %s --black %s\n' \
		"$pivot" "$contrast" "$toe" "$shoulder" "$black"
}

# The input correction. The size is a render setting rather than a look value, so it is not here.
correction_args() {  # correction_args  -> "--exposure E ... --lum-mix L"
	local exposure temp tint slope offset power lum_mix
	exposure="$(require_number correct.exposure "$(look .correct.exposure)")" || return 1
	temp="$(require_number correct.temp "$(look .correct.temp)")" || return 1
	tint="$(require_number correct.tint "$(look .correct.tint)")" || return 1
	slope="$(require_numbers correct.slope "$(look .correct.slope)")" || return 1
	offset="$(require_numbers correct.offset "$(look .correct.offset)")" || return 1
	power="$(require_numbers correct.power "$(look .correct.power)")" || return 1
	lum_mix="$(require_number correct.lum_mix "$(look .correct.lum_mix)")" || return 1
	printf -- '--exposure %s --temp %s --tint %s --slope %s --offset %s --power %s --lum-mix %s\n' \
		"$exposure" "$temp" "$tint" "$slope" "$offset" "$power" "$lum_mix"
}

# Whether each pre-conversion stage does anything, as the word its generator prints. The rule lives
# in the generator; these exist so that no caller spells the arguments it is decided on. A failure
# is a failure, never an answer — see the note above.
correction_state() {  # correction_state  -> neutral|active
	local args
	args="$(correction_args)" || return 1
	# shellcheck disable=SC2086
	"$LIB_ROOT/scripts/make-correct-lut.py" --check-neutral $args
}

halation_state() {  # halation_state  -> neutral|active
	local strength
	strength="$(require_number halation.strength "$(look .halation.strength)")" || return 1
	"$LIB_ROOT/scripts/make-halation-luts.py" --check-neutral --strength "$strength"
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
# Decodes one frame and measures it. Separated out of require_portrait because the crop bounds
# need the same two numbers, and the alternative is decoding a second frame to ask again.
#
# It measures a DECODED frame rather than the container's dimensions, deliberately: this camera
# carries rotation as a display-matrix flag, ffmpeg autorotates on decode, and the container's
# width and height are therefore not what the filter graph will see. That is the whole reason
# docs/adr/0005 exists.
source_frame_size() {  # source_frame_size <file>  -> "W H"
	local file="$1" size w h
	# `showinfo` REPORTS THE DECODED FRAME, which is the whole point, and costs only the decode.
	# This used to write the frame out as a PNG and ffprobe the file: on a 4K clip that is an
	# 8-megapixel PNG compressed to disk for the sake of two integers, measured at 9.3 seconds
	# against 0.6 here. Every clip in every run paid it, and so did every preview.
	#
	# Measuring a DECODED frame rather than the container is still the rule: this camera stores
	# rotation as a display-matrix flag and ffmpeg autorotates, so the container says 3840x2160 for
	# a clip that decodes 2160x3840. That is docs/adr/0005, and nothing here reasons about the
	# matrix — it reads what came out of the decoder.
	#
	# `-v info` because showinfo logs at INFO and `-v error` would suppress the only output that
	# matters. Same trap the exposure probe hit with metadata=print.
	size=$(ffmpeg -v info -i "$file" -frames:v 1 -vf showinfo -f null - 2>&1 \
		| grep -oE 's:[0-9]+x[0-9]+' | head -1 | cut -d: -f2)
	w="${size%x*}"
	h="${size#*x}"

	# Refuse what cannot be measured. A missing or non-numeric dimension makes `[ "$h" -le "$w" ]`
	# ERROR, and an `if` reads an erroring condition as FALSE — so the caller used to accept the
	# clip it had just failed to measure.
	case "$w" in ''|*[!0-9]*) w="";; esac
	case "$h" in ''|*[!0-9]*) h="";; esac
	if [ -z "$w" ] || [ -z "$h" ]; then
		echo "could not measure a decoded frame from $file" >&2
		return 1
	fi
	printf '%s %s\n' "$w" "$h"
}

# Frame rate conversion, and only the kind that is not a lie. An integer relation drops or repeats
# whole frames, which is honest and reversible in appearance. Anything else is retiming: without
# motion compensation 24 to 30 judders, and ffmpeg's `fps` filter will do it without comment. So
# this returns a filter for the first case and refuses the second.
#
# Rates arrive as rationals from ffprobe ("24/1"), so the comparison is done in integers rather
# than by parsing a decimal.
fps_filter() {  # fps_filter <source-rate> <target-rate>  -> ",fps=N" or "" or refuses
	local src="$1" out="$2" num den
	num="${src%%/*}"; den="${src#*/}"
	[ "$den" != "$src" ] || den=1
	case "$num$den" in ''|*[!0-9]*) echo "unreadable source rate: $src" >&2; return 1;; esac
	# Equal rates need no filter at all.
	if [ $(( num )) -eq $(( out * den )) ]; then
		printf ''
		return 0
	fi
	# Integer either way round: N source frames per output frame, or the reverse.
	if [ $(( num % (out * den) )) -eq 0 ] || [ $(( (out * den) % num )) -eq 0 ]; then
		printf ',fps=%s\n' "$out"
		return 0
	fi
	echo "REFUSING: $out fps from $src is not an integer relation." >&2
	echo "  Converting it means retiming, and without motion compensation that judders." >&2
	echo "  Deliver at the source rate, or pick a rate that divides it." >&2
	return 1
}

# The crop window, computed rather than hardcoded. It was `crop=2160:2700:0:$CROP_Y`, which assumes
# both the source width and one aspect — true of this camera and of one deliverable, and wrong the
# moment either changes.
#
# Bounds are checked HERE because the alternative is ffmpeg failing several seconds into a render
# with a filter error, after the graph has already been built. An offset past the frame edge was
# unvalidated and 03-final.sh claimed the portrait guard covered it; it does not, it only compares
# width against height.
crop_prefix() {  # crop_prefix <src-w> <src-h> <aspect-w> <aspect-h> <offset|centre>  -> "crop=...,"
	local sw="$1" sh="$2" aw="$3" ah="$4" y="$5" ch max
	ch="$(deliverable_height "$sw" "$aw" "$ah")"
	if [ "$ch" -gt "$sh" ]; then
		echo "crop window ${sw}x${ch} is taller than the source ${sw}x${sh}" >&2
		return 1
	fi
	# A deliverable that is already the source's OWN shape gets no crop filter, and its offset is
	# not an error — there is exactly one window, so there is nothing to place. This is what keeps
	# the 9:16 deliverable byte-identical now that EVERY deliverable resolves its crop through
	# here: it used to be the one whose case branch handed the chain a literal empty string, and a
	# no-op `crop=2160:3840:0:0` in the graph is a change tests/conformance.sh would see.
	if [ "$ch" -eq "$sh" ]; then
		return 0
	fi
	max=$(( sh - ch ))
	# NO DEFAULT. This used to fall back to 750, which is one clip's composition and nobody else's;
	# a caller that has not decided must be told, not guessed for. Reachable even when the run's
	# up-front check passed, because that check reads the first renderable clip and a later one can
	# be a different shape.
	if [ -z "$y" ]; then
		echo "REFUSING: a ${aw}:${ah} window on ${sw}x${sh} needs a vertical offset, and none was given." >&2
		echo "  Where the window sits is a composition call. Pass CROP_Y=<0..$max>, or CROP_Y=centre" >&2
		echo "  to say explicitly that this clip does not need one." >&2
		return 1
	fi
	# `centre` is resolved PER CLIP, against the frame that was actually measured — which is the
	# thing a fixed pixel offset cannot be. It is spelled out by the caller rather than assumed:
	# defaulting to centre gives a batch of files that all look finished and are all framed wrong,
	# and saying "centre" is a decision someone made.
	case "$y" in
		centre|center)
			y=$(( max / 2 ))
			# Even, because an odd vertical crop offset shifts the chroma siting on 4:2:0.
			y=$(( y - y % 2 ));;
	esac
	if [ "$y" -lt 0 ] || [ "$y" -gt "$max" ]; then
		echo "REFUSING: crop offset $y is outside 0..$max for a ${sw}x${ch} window on ${sw}x${sh}." >&2
		echo "  Past the edge ffmpeg fails mid-render, seconds in, with a filter error." >&2
		return 1
	fi
	printf 'crop=%s:%s:0:%s,\n' "$sw" "$ch" "$y"
}

# The clip's post-CST luma mean, from ONE decoded frame rather than a pass. It is what the exposure
# match solves against, and it does not change when a look does — so an interface adjusting a curve
# re-measures the same number on every render, which is why grade.sh lets a caller hand it back.
#
# `metadata=print:file=-`, never a plain `metadata=print`: the latter logs at INFO level, which
# `-v error` suppresses, so the probe returned EMPTY on every clip and every clip silently got the
# reference gamma. The exposure match appeared to run and did nothing.
#
# Lives here rather than inline in grade.sh because two callers need the IDENTICAL command: the
# per-clip match and the batch reference. Two copies of this string is how the INFO-level bug would
# come back in one of them.
probe_yavg() {  # probe_yavg <src> <cst-cube>  -> the mean, or empty
	ffmpeg -v error -ss 1 -i "$1" -frames:v 1 \
		-vf "lut3d=file='${2}':interp=tetrahedral,scale=320:-1,signalstats,metadata=print:file=-" \
		-f null - 2>/dev/null | grep -m1 -oE 'YAVG=[0-9.]+' | cut -d= -f2 || true
}

# --- deliverables -------------------------------------------------------------------------
# A deliverable was two names with their sizes written into a `case` branch, so "any other shape"
# meant editing the pipeline. It is DATA now: an aspect, an optional crop offset, and a name that
# reaches the output filename. Instagram's two shapes survive as presets rather than as the only
# options. See docs/adr/0010.
#
# WHY WIDTH IS THE ANCHOR, not height. Every deliverable is the same portrait master scaled to the
# same horizontal resolution: the platform re-encodes to a fixed width, so two deliverables that
# differed in width would be re-encoded differently for no reason anyone chose. Height follows from
# the aspect. It is also what makes the old numbers fall out unchanged rather than by coincidence —
# 1080 wide is 1920 tall at 9:16 and 1350 at 4:5, which is exactly what the two branches hardcoded.
#
# A spec is either a preset name or `name:aspect-w:aspect-h[:offset]`. The offset is per
# DELIVERABLE because a crop offset is a composition call, and the one case where two cropped
# deliverables want different framing should not need two runs.
deliverable_spec() {  # deliverable_spec <spec>  -> "<name> <aw> <ah> <offset|-> <suffix>"
	local spec="$1" name aw ah off
	# The preset suffixes are the ones already on disk. They are kept verbatim so that opening the
	# set up does not rename anybody's existing deliverables.
	case "$spec" in
		reels) printf 'reels 9 16 - reels-stories_9x16\n'; return 0;;
		feed)  printf 'feed 4 5 - feed_4x5\n'; return 0;;
	esac
	case "$spec" in
		*:*) ;;
		*)
			echo "REFUSING: unknown deliverable '$spec'." >&2
			echo "  Expected a preset (reels, feed) or name:aspect-w:aspect-h[:offset]," >&2
			echo "  e.g. square:1:1 or wide:16:9:400." >&2
			return 1;;
	esac
	IFS=: read -r name aw ah off <<< "$spec"
	# The name reaches a path component and the deliverable label in the event stream, so it goes
	# through the same guard a clip name does rather than a weaker one written here.
	name="$(require_clip_name "$name")" || return 1
	case "$aw$ah" in
		''|*[!0-9]*)
			echo "REFUSING: deliverable '$name' has a non-integer aspect '${aw}:${ah}'." >&2
			return 1;;
	esac
	if [ "$aw" -le 0 ] || [ "$ah" -le 0 ]; then
		echo "REFUSING: deliverable '$name' has a zero aspect term." >&2
		return 1
	fi
	off="$(crop_offset "deliverable $name offset" "$off")" || return 1
	printf '%s %s %s %s %s_%sx%s\n' "$name" "$aw" "$ah" "$off" "$name" "$aw" "$ah"
}

# Whether this deliverable takes a crop out of a source of the given size, which is a fact about
# the SOURCE's shape rather than about the deliverable's name: 4:5 is a crop of a 9:16 master and
# the whole frame of a 4:5 one. It answers the same question crop_prefix answers by returning an
# empty string, and it exists separately because the refusal that needs it has to fire before any
# clip is opened, where there is no offset to validate yet.
#
# An UNMEASURABLE source counts as cropping. The caller's guard then fires when it may not have
# needed to, which costs a re-run; the other way costs a batch of silently reframed deliverables.
deliverable_crops() {  # deliverable_crops "<src-w> <src-h>" <aw> <ah>  -> 0 if it crops
	local size="$1" aw="$2" ah="$3" sw sh ch
	case "$size" in
		*' '*) ;;
		*) return 0;;
	esac
	sw="${size% *}"; sh="${size#* }"
	ch="$(deliverable_height "$sw" "$aw" "$ah")"
	[ "$ch" -ne "$sh" ]
}

# Height follows the aspect off a width. Even, because libx264 rejects an odd dimension and does it
# at encode time, after the graph is built and the first frames are decoded.
#
# The SAME arithmetic answers three questions — a deliverable's output height, the crop window's
# height on the source, and whether that window is the whole frame — and it is written once
# because the up-front refusal and the per-clip crop must agree about which deliverables crop. The
# app draws its crop box from a Swift copy that CropGeometryTests holds to this function.
deliverable_height() {  # deliverable_height <width> <aw> <ah>  -> <h>
	local h
	h=$(( $1 * $3 / $2 ))
	printf '%s\n' "$(( h - h % 2 ))"
}

# The shared delivery width. HEIGHT is the knob it always was — the 9:16 reference frame — and the
# width falls out of it, so a run that says neither renders 1080 wide. Both delivery paths read it
# here: stage 3 used to default to a literal 1080 and ignore HEIGHT, so HEIGHT=1440 gave the two
# paths different files under the same name.
delivery_width() {  # delivery_width  -> <w>, from WIDTH, else HEIGHT (default 1920) at 9:16
	local h w
	h="$(require_number HEIGHT "${HEIGHT:-1920}")" || return 1
	w="$(require_number WIDTH "${WIDTH:-$(( h * 9 / 16 ))}")" || return 1
	printf '%s\n' "$(( w - w % 2 ))"
}

# A crop offset as typed: pixels, `centre` (either spelling), or nothing. Empty comes back as "-",
# which means NOT GIVEN and is a different thing from 0 — 0 is the top of the frame and a real
# answer. Validated because it is spliced into `crop=W:H:0:<offset>`, where a comma would open a
# second filter.
crop_offset() {  # crop_offset <label> <value>  -> <px>|centre|-
	case "$2" in
		'') printf -- '-\n';;
		centre|center) printf 'centre\n';;
		*) require_number "$1" "$2";;
	esac
}

# The middle value, for deriving an exposure reference from a shoot rather than from one frame of
# one clip. LOWER median on an even count: picking a real clip's measurement beats averaging two
# into a number no clip has, and it makes the choice reproducible rather than dependent on how the
# list happened to be ordered.
median() {  # median  (values on stdin, one per line)  -> the middle one
	local sorted n
	sorted="$(sort -n)"
	n="$(printf '%s\n' "$sorted" | grep -c .)"
	[ "$n" -gt 0 ] || return 1
	printf '%s\n' "$sorted" | sed -n "$(( (n + 1) / 2 ))p"
}

# Portrait means strictly taller than wide; a square frame is refused with the landscape ones. The
# rule is here once because the up-front crop probe has to skip exactly the clips this refuses, or
# a clip that will never render decides whether the run's deliverables crop.
size_is_portrait() {  # size_is_portrait "<w> <h>"  -> 0 if portrait
	case "$1" in
		*' '*) [ "${1#* }" -gt "${1% *}" ];;
		*) return 1;;
	esac
}

require_portrait() {
	local file="$1" size w h
	if ! size="$(source_frame_size "$file")"; then
		echo "REFUSING: could not measure a decoded frame from $file." >&2
		echo "  Refusing rather than guessing — a wrong guess here squashes the delivery." >&2
		return 1
	fi
	w="${size% *}"; h="${size#* }"

	if ! size_is_portrait "$size"; then
		echo "REFUSING: $file decodes as ${w}x${h}, not portrait." >&2
		echo "  Vertical delivery would squash it. Fix the source orientation, then retry." >&2
		return 1
	fi
	# Hand the measurement back: the crop bounds need exactly these two numbers, and the
	# alternative is decoding the frame again to ask the same question.
	printf '%s %s\n' "$w" "$h"
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
	fps="$(probe_field "$1" stream=r_frame_rate)"
	printf '%s\n' "$fps" | grep -qE '^[0-9]+(/[0-9]+)?$' || fps=""
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

# Every output flag a deliverable is encoded with. Both delivery paths passed their own copy, and
# conformance renders only grade.sh's, so a change to one reached a file nobody compared.
# `0:a:0?` MUST stay quoted: `?` is a glob character, and a file named `0:a:00` in the launch
# directory would otherwise expand it. An array, and never empty, so bash 3.2's empty-array trap
# under `set -u` does not apply.
DELIVERY_ENCODE=(-map "[o]" -map "0:a:0?" -shortest
	-c:v libx264 -profile:v high -preset slow -crf 18
	-color_primaries bt709 -color_trc bt709 -colorspace bt709
	-c:a aac -b:a 192k -movflags +faststart)

# The graded master's encode, shared by the two staged stages that write one. Audio mapping is the
# caller's: stage 1 maps nothing and takes ffmpeg's default selection.
# shellcheck disable=SC2034  # used by the stage scripts
PRORES_MASTER=(-c:v prores_ks -profile:v 3 -pix_fmt yuv422p10le -c:a copy)

# The look values that are not part of a delivery: which film cubes, at what strength, and the
# colour trims. Read into globals because every render path needs the same set and grade_chain
# reads them too; each script used to read them itself, and only two of the three honoured the
# LOOK and PRINT overrides.
#
# UNSET IS NOT EMPTY, and the difference is load-bearing. An empty LOOK_LUT is a deliberate choice
# of no look; an unset one means nobody chose, which is look.json's question to answer. So a value
# already set is kept, and only an unset one is read.
#
# Call it at the top level, `load_film_look || exit 1`: it sets globals, which a `$(...)` would
# set in a subshell and throw away.
load_film_look() {
	# The NAME is read on its own line. Nested inside resolve_look_lut's argument, a missing key
	# came back as an empty name — which resolve_look_lut rightly reads as "none" — and the run
	# rendered with no film look at all, having been asked for the one look.json lost.
	local name
	if [ -z "${LOOK_LUT+set}" ]; then
		name="${LOOK:-}"
		[ -n "$name" ] || name="$(look .look.lut)" || return 1
		LOOK_LUT="$(resolve_look_lut "$name" "$LIB_ROOT")" || return 1
	fi
	if [ -z "${PRINT_LUT+set}" ]; then
		name="${PRINT:-}"
		[ -n "$name" ] || name="$(look .print.lut)" || return 1
		PRINT_LUT="$(resolve_look_lut "$name" "$LIB_ROOT" print)" || return 1
	fi
	if [ -z "${LOOK_STRENGTH+set}" ]; then
		LOOK_STRENGTH="$(require_unit look.strength "$(look .look.strength)")" || return 1
	fi
	if [ -z "${PRINT_STRENGTH+set}" ]; then
		PRINT_STRENGTH="$(require_unit print.strength "$(look .print.strength)")" || return 1
	fi
}

# The film look plus the colour trims: everything a render path hands grade_chain. The trims are
# separate because grade_chain takes them as arguments, and a caller measuring the chain at other
# values must not have look.json's read in underneath it.
load_grade_look() {
	load_film_look || return 1
	if [ -z "${SAT+set}" ]; then
		SAT="$(require_number colour.saturation "$(look .colour.saturation)")" || return 1
	fi
	if [ -z "${WARM+set}" ]; then
		WARM="$(require_number colour.warmth "$(look .colour.warmth)")" || return 1
	fi
}

# The look values the delivery tail reads, into globals, for the same reasons. SMOOTHING and
# GRAIN_STRENGTH take an environment override; the grain weights do not, because they are part of
# how the grain was tuned rather than how much of it a run wants.
load_delivery_look() {
	SMOOTHING="$(require_number SMOOTHING "${SMOOTHING:-$(look .stabilisation.smoothing)}")" || return 1
	GRAIN_STRENGTH="$(require_number GRAIN_STRENGTH "${GRAIN_STRENGTH:-$(look .grain.strength)}")" || return 1
	GRAIN_SHADOWS="$(require_unit grain.shadows "$(look .grain.shadows)")" || return 1
	GRAIN_HIGHLIGHTS="$(require_unit grain.highlights "$(look .grain.highlights)")" || return 1
}

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
	# Two callers sourced lib.sh, called this function without loading the look, and received a
	# chain with no look filter in it. Both looked correct; the golden's freshness guard is what
	# caught it. So a look nobody loaded is loaded here, by the same function the scripts call.
	load_film_look || return 1
	printf "%s%s%sformat=yuv444p10le,split=2[gc_y][gc_c];[gc_y]lut1d=file='%s':interp=linear,format=yuv444p10le[gc_t];[gc_t][gc_c]mergeplanes=0x001112:yuv444p10le,%shue=s=%s,colorbalance=rm=%s:bm=-%s" \
		"${4:-}" "$(film_lut_stage "${LOOK_LUT:-}" "$LOOK_STRENGTH" gc_look)" \
		"$(film_lut_stage "${PRINT_LUT:-}" "$PRINT_STRENGTH" gc_print)" \
		"$1" "${5:-}" "$2" "$3" "$3"
}

# One film cube — the look or the print — at a strength, as a prefix with its own trailing comma.
#
# THE PRINT COMES AFTER THE LOOK AND BEFORE THE TONE CURVE. That is a negative printed and then
# exposure-shaped, and it keeps the print's per-channel contrast ahead of the luma-only tone stage,
# which is the stage that stops saturated signage going neon (ADR 0003). Placing the look itself
# after the tone curve instead was measured on IMG_0607 and moved the frame by 3 code values on
# average, which is not worth a different chain.
#
# A STRENGTH BELOW 1 blends the cube's output back toward its input with `mix`, in the chain's own
# 10-bit format — within 0.18 code values on average of doing the same blend in float, so there is
# no reason to leave 10-bit for it. At 1 there is no blend in the graph and at 0 there is no cube:
# absent rather than idle, so a look at full strength and no print renders the chain it always did.
film_lut_stage() {  # film_lut_stage <cube-path|empty> <strength> <label-prefix>
	[ -n "$1" ] || return 0
	case "$(awk -v k="$2" 'BEGIN { print (k == 0) ? "off" : (k == 1) ? "full" : "blend" }')" in
		off) return 0;;
		full) printf "lut3d=file='%s':interp=tetrahedral," "$1";;
		blend)
			printf "split=2[%s_in][%s_src];[%s_src]lut3d=file='%s':interp=tetrahedral[%s_out];" \
				"$3" "$3" "$3" "$1" "$3"
			printf "[%s_in][%s_out]mix=inputs=2:weights=%s %s:scale=1," "$3" "$3" \
				"$(awk -v k="$2" 'BEGIN { printf "%.6f", 1 - k }')" "$2";;
	esac
}

# HALATION, as a spliceable prefix that runs between the correction and Apple's conversion: in
# linear light, where a glow adds the way light does. scripts/make-halation-luts.py generates the
# four cubes named here and its header carries the reasoning for each, including the lut1d domain
# trap they are shaped around; docs/adr/0012 carries why this sits before the conversion at all.
#
# The graph, in order:
#   base  -> linear (offset by -R0, so never negative)
#   src   -> quarter resolution -> per-channel max(0, linear - threshold) -> luma into G only
#         -> split: gblur ONE plane, subtract the unblurred one, clamp at zero  (the edge-only glow)
#         -> route G into R, G and B at tint x strength -> back up to the base's size
#   base + glow -> Apple Log again
#
# THE GLOW IS COMPUTED AT QUARTER RESOLUTION, because it is a blur 23 pixels wide and paying for it
# at 4K bought nothing visible. Measured single-threaded on 0.25s of IMG_0607 in CPU time: the
# conversion alone 2.9s, this stage at full resolution 7.9s, at quarter resolution 4.5s. Against
# the full-resolution glow on a frame: 0.05 code values mean, 5 at the 99.9th percentile, confined to
# the glow's own edges. Wall-clock numbers on this laptop were useless for that comparison — thermal
# throttling moved the same run between 9 and 19 seconds.
#
# The upscale takes its size FROM THE BASE (`scale=rw:rh` against a reference input), not from
# numbers. This camera's rotation is applied as a mid-stream reinitialisation, so the graph first
# configures at 3840x2160 and then at 2160x3840; a fixed size fails `mix` on the second. BILINEAR,
# because bicubic overshoots below zero beside a steep glow and would subtract light.
#
# FLOAT THROUGHOUT, and three of the obvious filters would silently break that. Measured on a
# gbrpf32le frame holding 5.0: `blend=all_mode=addition` returns 1.0, `avgblur` 1.0, `boxblur`
# 0.99998. `mix` and `gblur` return 5.0, which is why they are the ones used. A clamp at 1.0 here
# would cut every highlight Apple Log holds, and the picture would still look plausible.
#
# ONE PLANE IS BLURRED, not three identical ones: gbrp's plane 0 is G, so the luma is written there,
# `gblur=planes=1` touches only it, and the R and B planes stay zero through the subtraction until
# the tint reads them back out of G. Blurring three copies of the same plane cost three times as
# much for the same answer.
#
# `steps=3`, because gblur's default is not a Gaussian. Measured on an impulse at sigma 10: one step
# peaks 77% above the true Gaussian with a tail twenty times too heavy at four sigma; three steps are
# within 15% of its peak, six within 7%. The app's preview uses a true Gaussian and is held to this
# render by LiveChainTests with a tolerance.
#
# Labels are prefixed for the same reason grade_chain's are: callers splice this into a bigger graph.
HALATION_SCALE=4

halation_prefix() {  # halation_prefix <lut-dir> <sigma-px at full resolution> <strength> <tint r,g,b>
	local dir="$1" sigma strength="$3" tr tg tb
	sigma=$(awk -v s="$2" -v f="$HALATION_SCALE" 'BEGIN { printf "%.3f", s / f }')
	IFS=, read -r tr tg tb <<< "$4"
	local kr kg kb
	kr=$(awk -v a="$strength" -v b="$tr" 'BEGIN { printf "%.6f", a * b }')
	kg=$(awk -v a="$strength" -v b="$tg" 'BEGIN { printf "%.6f", a * b }')
	kb=$(awk -v a="$strength" -v b="$tb" 'BEGIN { printf "%.6f", a * b }')
	printf "format=gbrpf32le,split=3[hal_base][hal_src][hal_ref];"
	printf "[hal_base]lut1d=file='%s/applelog-to-linear.cube':interp=linear[hal_lin];" "$dir"
	printf "[hal_src]scale=w=iw/%s:h=ih/%s:flags=area," "$HALATION_SCALE" "$HALATION_SCALE"
	printf "lut1d=file='%s/halation-threshold.cube':interp=linear," "$dir"
	printf "colorchannelmixer=rr=0:rg=0:rb=0:gr=0.2627:gg=0.6780:gb=0.0593:br=0:bg=0:bb=0,"
	printf "split=2[hal_sharp][hal_wide];[hal_wide]gblur=sigma=%s:steps=3:planes=1[hal_blur];" "$sigma"
	printf "[hal_blur][hal_sharp]mix=inputs=2:weights=1 -1:scale=1,"
	printf "lut1d=file='%s/nonnegative.cube':interp=linear," "$dir"
	printf "colorchannelmixer=rr=0:rg=%s:rb=0:gr=0:gg=%s:gb=0:br=0:bg=%s:bb=0[hal_small];" "$kr" "$kg" "$kb"
	printf "[hal_small][hal_ref]scale=w=rw:h=rh:flags=bilinear[hal_glow];"
	printf "[hal_lin][hal_glow]mix=inputs=2:weights=1 1:scale=1,"
	printf "lut1d=file='%s/linear-to-applelog.cube':interp=linear," "$dir"
}

# The glow's radius is a fraction of the frame's height, so it covers the same part of the picture
# at any source resolution. BT.2020 luma weights in the builder above because Apple Log's primaries
# are BT.2020; this camera's frame is 3840 tall, where 0.006 is 23 pixels.
halation_sigma() {  # halation_sigma <frame-height> <radius>  -> sigma in pixels
	awk -v h="$1" -v r="$2" 'BEGIN { printf "%.2f", h * r }'
}

# The warp resamples BEFORE the downscale, so it happens at master resolution rather than at
# delivery size. The trailing comma belongs to the prefix: callers splice the result directly into
# a filter chain, and an absent transform must leave no trace.
# Camera-motion analysis into a transform, staged. Both entry points write the same cache path, so
# they must measure the same way: a settings change made in one would leave the transform depending
# on which script happened to write it.
#
# shakiness=5 suits "static handheld" — the iPhone's own stabilisation has already removed the large
# motion, so what is left is low-amplitude sway. stepsize=6 trades a little accuracy for speed and
# is plenty at this amplitude.
#
# Written to a staging file and installed on success only. An interrupted detect (Ctrl-C, a killed
# background job) otherwise leaves a TRUNCATED .trf in place of a good one, and the failure surfaces
# much later and somewhere else: delivery dies deep in the filter graph with "Cannot parse
# localmotion: unexpected end of file", which does not point back here at all. Learned by doing
# exactly that — a two-second smoke test destroyed a three-minute analysis.
#
# <head> is a prefix with its own trailing comma: the camera CST when detecting on the source, which
# the one-pass path does, and nothing on a master that is already converted. The staging path is a
# global because an EXIT trap runs after this function's locals are gone.
detect_transform() {  # detect_transform <input> <trf> [head-prefix]
	DETECT_PARTIAL="$2.partial"
	mkdir -p "$(dirname "$2")"
	trap 'rm -f "$DETECT_PARTIAL"' EXIT
	if ! ffmpeg -v error -y -i "$1" \
		-vf "${3:-}vidstabdetect=shakiness=5:accuracy=15:stepsize=6:result=${DETECT_PARTIAL}" -f null -; then
		rm -f "$DETECT_PARTIAL"
		echo "stabilisation analysis FAILED (ffmpeg error) for $1" >&2
		return 1
	fi
	if ! require_nonempty "$DETECT_PARTIAL" "stabilisation analysis"; then
		rm -f "$DETECT_PARTIAL"
		return 1
	fi
	mv "$DETECT_PARTIAL" "$2"
	trap - EXIT
}

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
	# The sharpener's 5x5 was measured at 1080x1920, and its radius is in PIXELS — so at another
	# output height it sharpens a different real-world detail size and the look changes. The radius
	# scales with height and the amount does not, which is an ASSUMPTION rather than a measurement:
	# only 1920 has been looked at. It is stated here so the next reader knows which of the two
	# numbers has evidence behind it.
	#
	# unsharp needs odd sizes and rejects anything below 3.
	local r
	r=$(( 5 * $2 / 1920 ))
	[ "$r" -ge 3 ] || r=3
	[ $(( r % 2 )) -eq 1 ] || r=$(( r + 1 ))
	printf '%s%s%szscale=w=%s:h=%s:f=lanczos:d=error_diffusion,format=yuv420p,unsharp=%s:%s:0.4:5:5:0.0' \
		"$3" "$DELIVERY_CHROMA" "$4" "$1" "$2" "$r" "$r"
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

# The grain merge, WEIGHTED BY THE PICTURE'S OWN BRIGHTNESS. On a print, grain is most visible in
# the midtones and recedes into deep shadow and bright highlight; a uniform plate puts as much into a
# black coat as into a grey wall, which reads as noise laid over the picture rather than as part of
# it. `grain.shadows` and `grain.highlights` are the weight at black and at white, 1 at the midtones
# between 0.45 and 0.55 of the range, with a smoothstep either side.
#
# How: the delivered image's luma becomes a mask (`lutyuv`, so the table is built once per frame
# format rather than evaluated per pixel), and `maskedmerge` fades the noisy plate toward a flat grey
# one by it. The flat plate is the noisy one with its luma set to 128, so the two stay in step and
# carry identical chroma — `grainmerge` then remains a no-op on the chroma planes, which is the
# property the plate was built grey for. Measured on a ramp at 0.35 and 0.5: grain sd 1.2 in the
# darkest ninth, 3.2 at the midtones, 1.8 in the brightest, against a flat 3.2 unweighted.
#
# Both weights at 1 leave the mask out of the graph and return the plain blend, which is what keeps a
# default render byte-identical to the precursor's. `maskedmerge` has no `shortest` option, and does
# not need one: its mask comes from the image, which ends, and the blend after it keeps its own
# `shortest=1` for the plate.
delivery_grain_merge() {  # delivery_grain_merge <image-label> <grain-label> <out-label> <shadows> <highlights>
	if [ "$(awk -v s="$4" -v h="$5" 'BEGIN { print (s == 1 && h == 1) ? "flat" : "weighted" }')" = "flat" ]; then
		printf '[%s][%s]%s[%s]' "$1" "$2" "$DELIVERY_BLEND" "$3"
		return
	fi
	local expr
	# Quoted, because the expression holds both of the graph's own separators, `,` and `;`.
	expr="st(0,clip((val-16)/219,0,1));st(1,clip(ld(0)/0.45,0,1));st(2,clip((ld(0)-0.55)/0.45,0,1));255*(($4+(1-$4)*ld(1)*ld(1)*(3-2*ld(1)))+($5-1)*ld(2)*ld(2)*(3-2*ld(2)))"
	printf "[%s]split=2[gw_image][gw_luma];[gw_luma]lutyuv=y='%s':u=128:v=128[gw_mask];" "$1" "$expr"
	printf '[%s]split=2[gw_noise][gw_level];[gw_level]lutyuv=y=128[gw_flat];' "$2"
	printf '[gw_flat][gw_noise][gw_mask]maskedmerge=planes=1[gw_grain];'
	printf '[gw_image][gw_grain]%s[%s]' "$DELIVERY_BLEND" "$3"
}

# One deliverable, source to installed file: the grain plate, the graph around a caller's image
# chain, and the encode. The two delivery paths each assembled this and differ only in what comes
# before the delivery tail — the whole grade on the one-pass path, nothing on stage 3 — so that is
# the one argument they supply. Reads the grain globals load_delivery_look sets; under `set -u` an
# unloaded one stops the run rather than rendering without grain.
render_deliverable() {  # render_deliverable <final-out> <label> <input> <w> <h> <fps> <image-chain> [ffmpeg-arg]...
	local out="$1" label="$2" in="$3" w="$4" h="$5" fps="$6" chain="$7"
	shift 7
	render_delivery "$out" "$label" \
		-y -i "$in" -f lavfi -i "$(grain_plate "$w" "$h" "$fps")" \
		-filter_complex "[0:v]${chain}[b];[1:v]$(delivery_grain_branch "$w" "$h" "$GRAIN_STRENGTH")[g];$(delivery_grain_merge b g o "$GRAIN_SHADOWS" "$GRAIN_HIGHLIGHTS")" \
		"${DELIVERY_ENCODE[@]}" "$@"
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
	report_command "$label" "$@" "$tmp"
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
