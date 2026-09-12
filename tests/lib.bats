#!/usr/bin/env bats
# Tests for scripts/lib.sh — the safety layer.
#
# WHY THIS FILE EXISTS. Every helper in lib.sh was written in response to a real incident, and
# then two of them shipped BROKEN and stayed broken because nothing ever exercised them:
#
#   - `safe_retag` died on every call with "unbound variable" (bash 3.2 + `set -u` + an empty
#     array), silently skipping the retag it exists to perform and leaving masters mistagged.
#   - `verify_bt709` could never pass on ANY file, because ffprobe prints these files' video
#     stream twice and it compared that against a single expected line.
#
# Neither is caught by shellcheck — verified: it reports nothing on the empty-array pattern while
# bash 3.2 fails on it immediately. Only running the code finds them.
#
# So the bar for every test here: delete the guard it covers and the test must go red. A test that
# cannot fail is worse than no test, because it reads as coverage.
#
# Run:  bats tests/

# `run --separate-stderr` is how the event-stream tests assert that stdout carries machine-readable
# output and NOTHING else, which is the contract the app depends on. Flags on `run` arrived in bats
# 1.5, and without this declaration bats warns on every such call rather than failing — so the
# requirement is stated here instead of being discovered from the noise.
bats_require_minimum_version 1.5.0

setup_file() {
	command -v ffmpeg >/dev/null || skip "ffmpeg not installed"
	export FIXTURES="$BATS_FILE_TMPDIR/fixtures"
	mkdir -p "$FIXTURES"

	# Tiny synthetic clips — one frame each, so the suite stays fast.
	#
	# NOTE ON HOW THESE ARE BUILT. Passing -color_primaries/-color_trc/-colorspace to prores_ks
	# does NOT produce a correctly tagged file: it writes "bt709,unknown,unknown". That is the
	# very bug the pipeline's retag pass exists for, and the first version of this suite tripped
	# over it — a fixture named "correctly tagged" that wasn't, failing a test of a function that
	# was working fine. So the tagged fixtures are built the way the pipeline builds real output:
	# encode first, then apply tags in a separate `-c copy` remux.
	_mk() {  # _mk <w> <h> <primaries> <trc> <matrix> <out>
		local w=$1 h=$2 prim=$3 trc=$4 mtx=$5 out=$6
		ffmpeg -y -f lavfi -i "color=c=gray:s=${w}x${h}:d=0.1:r=24" \
			-frames:v 1 -c:v prores_ks -profile:v 3 -pix_fmt yuv422p10le \
			"$out.raw.mov" -v error
		ffmpeg -y -i "$out.raw.mov" -map 0:v:0 -c copy \
			-color_primaries "$prim" -color_trc "$trc" -colorspace "$mtx" \
			"$out" -v error
		rm -f "$out.raw.mov"
	}
	_mk 64 128 bt709 bt709 bt709 "$FIXTURES/portrait_tagged.mov"
	_mk 128 64 bt709 bt709 bt709 "$FIXTURES/landscape_tagged.mov"
	# Deliberately MIStagged as bt2020 — the "bleached out" state this pipeline exists to prevent.
	_mk 64 128 bt2020 bt709 bt2020nc "$FIXTURES/portrait_bt2020.mov"
}

# NOTE ON THE FOOTAGE LOOKUPS BELOW. Each real-footage test finds a clip and skips without one,
# and the lookup ends in `|| true` on purpose: setup() sources lib.sh, which sets `pipefail`, so an
# empty src/ made `ls` fail the whole pipeline and the test FAILED on the assignment rather than
# reaching its own skip. It was invisible in the precursor, where src/ always had footage, and it
# is exactly the shape this suite exists to catch — a guard that cannot be reached.
setup() {
	SCRIPTS="$BATS_TEST_DIRNAME/../scripts"
	# lib.sh sets -euo pipefail; that is fine to inherit inside a bats test body.
	source "$SCRIPTS/lib.sh"
}

# Mean luma of the first frame, 10-bit scale. `metadata=print` logs at INFO, so -v error would
# suppress the only output that matters — the same trap grade.sh's exposure probe hit.
_yavg() {  # _yavg <file>
	ffmpeg -v info -i "$1" -frames:v 1 -vf signalstats,metadata=print:file=- -f null - 2>/dev/null \
		| sed -n 's/.*lavfi\.signalstats\.YAVG=//p' | head -1
}

# ASSERTION FORM MATTERS HERE. bats 1.14 does NOT fail a test on a bare `[[ ]]` that returns false
# in the middle of a test body: `[[` is a shell keyword, and the mechanism bats uses to spot a
# failure only tracks simple commands, so the false result is discarded and the test's verdict
# comes from its LAST command. `[` is a builtin and IS tracked, which is why `[ ]` assertions
# behave as expected. Verified with a two-line probe, and it had already hidden a real defect: a
# tag test stayed green while the message it asserts on was renamed.
#
# So every `[[ ]]` here ends in `|| fail ...`, which is a function call and therefore a simple
# command. Do not remove the guard to tidy a line up.
fail() {
	echo "ASSERTION FAILED: $*" >&2
	return 1
}

# --- require_nonempty --------------------------------------------------------

@test "require_nonempty accepts a file with content" {
	echo data > "$BATS_TEST_TMPDIR/f"
	run require_nonempty "$BATS_TEST_TMPDIR/f" "test"
	[ "$status" -eq 0 ]
}

@test "require_nonempty rejects a zero-byte file" {
	: > "$BATS_TEST_TMPDIR/empty"
	run require_nonempty "$BATS_TEST_TMPDIR/empty" "test"
	[ "$status" -ne 0 ]
	[[ "$output" == *"missing or empty"* ]] || fail "[[ \"$output\" == *\"missing or empty\"* ]]"
}

@test "require_nonempty rejects a missing file" {
	run require_nonempty "$BATS_TEST_TMPDIR/nope" "test"
	[ "$status" -ne 0 ]
}

# --- require_portrait --------------------------------------------------------
# The guard that stops a landscape master being silently squashed into 1080x1920.
# 11 of this shoot's 19 clips are landscape, so this is not a hypothetical.

@test "require_portrait accepts a portrait clip" {
	run require_portrait "$FIXTURES/portrait_tagged.mov"
	[ "$status" -eq 0 ]
}

@test "require_portrait refuses a landscape clip" {
	run require_portrait "$FIXTURES/landscape_tagged.mov"
	[ "$status" -ne 0 ]
	[[ "$output" == *"REFUSING"* ]] || fail "[[ \"$output\" == *\"REFUSING\"* ]]"
	[[ "$output" == *"landscape"* ]] || fail "[[ \"$output\" == *\"landscape\"* ]]"
}

@test "require_portrait reports the real dimensions, not a guess" {
	run require_portrait "$FIXTURES/landscape_tagged.mov"
	[[ "$output" == *"128x64"* ]] || fail "[[ \"$output\" == *\"128x64\"* ]]"
}

@test "require_portrait refuses a clip it cannot measure" {
	# The guard's whole job is to refuse rather than let a landscape clip be squashed silently, so
	# "I could not tell" must land on refuse. It did not: an empty dimension makes the numeric test
	# ERROR, and an `if` reads an erroring condition as false, so the clip was accepted. Same
	# fail-open shape as the trailing comma on this camera's csv output, which is what this guard
	# was written to replace in the first place.
	#
	# A probe that answers nothing is the honest way to reproduce it — shadow ffprobe on PATH and
	# leave ffmpeg real, so the decode still succeeds and only the measurement is lost.
	local bin="$BATS_TEST_TMPDIR/stub-bin"
	mkdir -p "$bin"
	printf '#!/bin/sh\nexit 0\n' > "$bin/ffprobe"
	chmod +x "$bin/ffprobe"
	PATH="$bin:$PATH" run require_portrait "$FIXTURES/portrait_tagged.mov"
	[ "$status" -ne 0 ]
	[[ "$output" == *"REFUSING"* ]] || fail "[[ \"$output\" == *\"REFUSING\"* ]]"
}

@test "require_portrait leaves no temp files behind" {
	# mktemp CREATES the file it names; the code appends .png to that name, so the file mktemp made
	# is not the file that gets removed. One leak per call, on every clip of every batch.
	local before after
	before=$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'portrait*' 2>/dev/null | wc -l)
	run require_portrait "$FIXTURES/portrait_tagged.mov"
	[ "$status" -eq 0 ]
	after=$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'portrait*' 2>/dev/null | wc -l)
	[ "$before" -eq "$after" ] || { echo "leaked: $before -> $after"; false; }
}

# --- verify_bt709 ------------------------------------------------------------
# Shipped broken: compared ffprobe's output (which prints the stream TWICE for these files,
# plus a blank line) against one expected line, so it failed on correctly tagged files.

@test "verify_bt709 PASSES on a correctly tagged file" {
	run verify_bt709 "$FIXTURES/portrait_tagged.mov"
	[ "$status" -eq 0 ]
}

@test "verify_bt709 FAILS on a bt2020-tagged file" {
	run verify_bt709 "$FIXTURES/portrait_bt2020.mov"
	[ "$status" -ne 0 ]
	[[ "$output" == *"TAG CHECK FAILED"* ]] || fail "[[ \"$output\" == *\"TAG CHECK FAILED\"* ]]"
}

@test "probe_tags dedups ffprobe's repeated stream on a REAL camera file" {
	# This MUST use real footage. ffprobe repeats the video stream (and adds a blank line) only
	# for files with the camera's [STREAM_GROUP] structure — a synthetic lavfi/prores fixture
	# prints a single line, so it cannot exercise the dedup at all. Verified by mutation: with
	# the dedup removed, a synthetic-fixture version of this test still passed. Real file: 3
	# lines. Synthetic: 1.
	# Footage lives under the work dir, which is NOT the repo when media is kept outside it
	# (see scripts/lib.sh resolve_work_dir). Resolve it the same way the pipeline does.
	local work real
	work=$(resolve_work_dir "$BATS_TEST_DIRNAME/.." 2>/dev/null) || work="$BATS_TEST_DIRNAME/.."
	real=$(ls "$work"/src/*.mov 2>/dev/null | head -1) || true
	[ -n "$real" ] && [ -f "$real" ] || skip "no source footage in $work/src"
	# Guard the guard: confirm the raw output really is multi-line, or this test proves nothing.
	local raw
	raw=$(ffprobe -v error -select_streams v:0 \
		-show_entries stream=color_space,color_transfer,color_primaries \
		-of csv=p=0 "$real" | wc -l | tr -d ' ')
	[ "$raw" -gt 1 ] || skip "this clip does not trigger the repeat; test would be vacuous"
	run probe_tags "$real"
	[ "${#lines[@]}" -eq 1 ]
}

@test "verify_bt709 gives a verdict (not a parse artefact) on a REAL camera file" {
	# Footage lives under the work dir, which is NOT the repo when media is kept outside it
	# (see scripts/lib.sh resolve_work_dir). Resolve it the same way the pipeline does.
	local work real
	work=$(resolve_work_dir "$BATS_TEST_DIRNAME/.." 2>/dev/null) || work="$BATS_TEST_DIRNAME/.."
	real=$(ls "$work"/src/*.mov 2>/dev/null | head -1) || true
	[ -n "$real" ] && [ -f "$real" ] || skip "no source footage in $work/src"
	# Source footage is bt2020-tagged, so this must FAIL — and fail with the tag message, not
	# because the comparison tripped over multi-line output.
	run verify_bt709 "$real"
	[ "$status" -ne 0 ]
	[[ "$output" == *"TAG CHECK FAILED"* ]] || fail "[[ \"$output\" == *\"TAG CHECK FAILED\"* ]]"
	[[ "$output" == *"bt2020"* ]] || fail "[[ \"$output\" == *\"bt2020\"* ]]"
}

# --- safe_retag --------------------------------------------------------------
# Shipped broken on bash 3.2 (macOS): an empty array under `set -u` raised "unbound variable",
# so the retag never ran. shellcheck does not flag this — only executing it does.

@test "safe_retag works with NO extra args (the bash 3.2 empty-array case)" {
	cp "$FIXTURES/portrait_bt2020.mov" "$BATS_TEST_TMPDIR/x.mov"
	run safe_retag "$BATS_TEST_TMPDIR/x.mov"
	[ "$status" -eq 0 ]
	[[ "$output" != *"unbound variable"* ]] || fail "[[ \"$output\" != *\"unbound variable\"* ]]"
	run probe_tags "$BATS_TEST_TMPDIR/x.mov"
	[ "$output" = "bt709,bt709,bt709" ]
}

@test "safe_retag works WITH extra args" {
	cp "$FIXTURES/portrait_bt2020.mov" "$BATS_TEST_TMPDIR/y.mov"
	run safe_retag "$BATS_TEST_TMPDIR/y.mov" -metadata "comment=test"
	[ "$status" -eq 0 ]
	run probe_tags "$BATS_TEST_TMPDIR/y.mov"
	[ "$output" = "bt709,bt709,bt709" ]
}

@test "safe_retag leaves the original intact when the remux fails" {
	# A text file is not remuxable; the original must survive rather than be replaced by a
	# zero-byte failure. This is the incident that destroyed a finished 170MB render.
	echo "not a video" > "$BATS_TEST_TMPDIR/z.mov"
	before=$(cat "$BATS_TEST_TMPDIR/z.mov")
	run safe_retag "$BATS_TEST_TMPDIR/z.mov"
	[ "$status" -ne 0 ]
	[ "$(cat "$BATS_TEST_TMPDIR/z.mov")" = "$before" ]
	[ ! -f "$BATS_TEST_TMPDIR/z_tagged.mov" ]
}

# --- check_disk_space --------------------------------------------------------

@test "check_disk_space passes when space is plentiful" {
	run check_disk_space "$BATS_TEST_TMPDIR" 1
	[ "$status" -eq 0 ]
	[[ "$output" == *"disk OK"* ]] || fail "[[ \"$output\" == *\"disk OK\"* ]]"
}

@test "check_disk_space fails when asking for an absurd amount" {
	run check_disk_space "$BATS_TEST_TMPDIR" 99999999
	[ "$status" -ne 0 ]
	[[ "$output" == *"LOW DISK SPACE"* ]] || fail "[[ \"$output\" == *\"LOW DISK SPACE\"* ]]"
}
@test "check_disk_space works on a directory that does not exist yet" {
	# The stages call this BEFORE `mkdir -p`, so on a first run into a fresh work dir the path is
	# absent. df then fails, the arithmetic expansion gets an empty operand, and the stage dies
	# with a bash syntax error instead of a disk verdict — a guard that aborts the run it was
	# meant to protect.
	run check_disk_space "$BATS_TEST_TMPDIR/dist/03-final" 1
	[ "$status" -eq 0 ]
	[[ "$output" == *"available in $BATS_TEST_TMPDIR/dist/03-final"* ]] || fail "[[ \"$output\" == *\"available in $BATS_TEST_TMPDIR/dist/03-final\"* ]]"
	[[ "$output" != *"syntax error"* ]] || fail "[[ \"$output\" != *\"syntax error\"* ]]"
}

@test "every stage checks free space on the volume it writes to" {
	# The work dir became opt-in, and three of the four call sites kept asking about the REPO's
	# volume while writing to the work dir's. With no .workdir present those are the same path, so
	# the defect is invisible locally — which is exactly why it shipped. Point the work dir
	# somewhere else and the two separate.
	local work="$BATS_TEST_TMPDIR/elsewhere" s
	mkdir -p "$work/src" "$work/dist/01-baseline" "$work/dist/02-graded"
	cp "$FIXTURES/portrait_tagged.mov" "$work/src/CLIP.mov"
	cp "$FIXTURES/portrait_tagged.mov" "$work/dist/01-baseline/CLIP_baseline.mov"
	cp "$FIXTURES/portrait_tagged.mov" "$work/dist/02-graded/CLIP_graded.mov"
	for s in 01-baseline 02-grade 03-final; do
		GRADE_WORK_DIR="$work" run "$SCRIPTS/$s.sh" CLIP
		[[ "$output" == *"available in $work/dist"* ]] \
			|| { echo "$s.sh measured the wrong volume:"; echo "$output"; false; }
	done
	# grade.sh is the path README tells you to run, and it had no disk guard at all while the four
	# staged scripts did. A test named "every stage" that skipped it is how that went unnoticed.
	GRADE_WORK_DIR="$work" DRY=1 MATCH=0 STAB=0 run "$SCRIPTS/grade.sh" "$work/src/CLIP.mov"
	[[ "$output" == *"available in $work/dist"* ]] \
		|| { echo "grade.sh measured no volume at all:"; echo "$output"; false; }
}


# --- safe_retag's SECOND guard ------------------------------------------------
# The exit-code check catches a crashing ffmpeg; the `-s` check behind it is for ffmpeg exiting 0
# having written nothing.
#
# HONEST NOTE ON COVERAGE: mutation testing shows removing that `-s` check changes NOTHING
# observable — `mv` then fails on the missing file and `set -e` aborts, so the original survives
# either way. No test can distinguish the two implementations, because there is no behavioural
# difference to detect. The guard is redundant defence-in-depth and the escaping mutation is
# correct, not a gap.
#
# So this test asserts the PROPERTY that matters (the original is never destroyed), not the
# specific message. It would catch a future refactor that dropped `set -e` or reordered the mv.

@test "safe_retag never destroys the original when ffmpeg produces nothing" {
	mkdir -p "$BATS_TEST_TMPDIR/bin"
	printf '#!/bin/bash\nexit 0\n' > "$BATS_TEST_TMPDIR/bin/ffmpeg"
	chmod +x "$BATS_TEST_TMPDIR/bin/ffmpeg"
	cp "$FIXTURES/portrait_bt2020.mov" "$BATS_TEST_TMPDIR/keep.mov"
	before=$(md5 -q "$BATS_TEST_TMPDIR/keep.mov")
	PATH="$BATS_TEST_TMPDIR/bin:$PATH" run safe_retag "$BATS_TEST_TMPDIR/keep.mov"
	[ "$status" -ne 0 ]
	[ "$(md5 -q "$BATS_TEST_TMPDIR/keep.mov")" = "$before" ]
}

# --- argument quoting ---------------------------------------------------------

@test "safe_retag's -map argument survives a hostile working directory" {
	# `-map 0:a:0?` contains a glob character. Unquoted, bash only survives it because unmatched
	# globs pass through literally — so a file whose name matches would silently change the
	# argument. (zsh errors on it outright, which is how this was found.)
	cd "$BATS_TEST_TMPDIR"
	touch '0:a:00'
	cp "$FIXTURES/portrait_bt2020.mov" "$BATS_TEST_TMPDIR/q.mov"
	run safe_retag "$BATS_TEST_TMPDIR/q.mov"
	[ "$status" -eq 0 ]
	run probe_tags "$BATS_TEST_TMPDIR/q.mov"
	[ "$output" = "bt709,bt709,bt709" ]
}

# --- resolve_work_dir ----------------------------------------------------------
# This function decides WHERE every stage reads and writes. Two shipped defects traced back to it
# being untested: three stages checked free space on the repo's volume while writing to the work
# dir's, and grade.sh resolved its stabilisation cache two levels off. Neither was visible locally,
# because with no .workdir present the work dir IS the repo root and the wrong path is the right
# one by accident. Every test below therefore sets a work dir that is genuinely elsewhere.

@test "resolve_work_dir falls back to the repo root when nothing is configured" {
	local root="$BATS_TEST_TMPDIR/root"
	mkdir -p "$root"
	run env -u GRADE_WORK_DIR bash -c \
		"source '$SCRIPTS/lib.sh'; resolve_work_dir '$root'"
	[ "$status" -eq 0 ]
	[ "$output" = "$root" ]
}

@test "resolve_work_dir prefers GRADE_WORK_DIR over a .workdir file" {
	local root="$BATS_TEST_TMPDIR/root2" env_dir="$BATS_TEST_TMPDIR/from-env"
	mkdir -p "$root" "$env_dir" "$BATS_TEST_TMPDIR/from-file"
	printf '%s\n' "$BATS_TEST_TMPDIR/from-file" > "$root/.workdir"
	GRADE_WORK_DIR="$env_dir" run resolve_work_dir "$root"
	[ "$status" -eq 0 ]
	[ "$output" = "$env_dir" ]
}

@test "resolve_work_dir reads .workdir, skipping comments and trailing whitespace" {
	local root="$BATS_TEST_TMPDIR/root3" target="$BATS_TEST_TMPDIR/chosen"
	mkdir -p "$root" "$target" "$BATS_TEST_TMPDIR/ignored"
	# A comment first, then the real path with trailing blanks, then a decoy second line.
	printf '# the media lives on the external disk\n%s   \n%s\n' \
		"$target" "$BATS_TEST_TMPDIR/ignored" > "$root/.workdir"
	run env -u GRADE_WORK_DIR bash -c \
		"source '$SCRIPTS/lib.sh'; resolve_work_dir '$root'"
	[ "$status" -eq 0 ]
	[ "$output" = "$target" ]
}

@test "resolve_work_dir expands a leading ~ in .workdir" {
	local root="$BATS_TEST_TMPDIR/root4"
	mkdir -p "$root"
	# $HOME always exists, so this checks expansion without inventing a directory.
	printf '~\n' > "$root/.workdir"
	run env -u GRADE_WORK_DIR bash -c \
		"source '$SCRIPTS/lib.sh'; resolve_work_dir '$root'"
	[ "$status" -eq 0 ]
	[ "$output" = "$HOME" ]
}

@test "resolve_work_dir refuses a configured directory that does not exist" {
	local root="$BATS_TEST_TMPDIR/root5"
	mkdir -p "$root"
	GRADE_WORK_DIR="$BATS_TEST_TMPDIR/absent" run resolve_work_dir "$root"
	[ "$status" -ne 0 ]
	# The message must name both escape hatches, or the reader cannot act on it.
	[[ "$output" == *"does not exist"* ]] || fail "[[ \"$output\" == *\"does not exist\"* ]]"
	[[ "$output" == *"GRADE_WORK_DIR"* ]] || fail "[[ \"$output\" == *\"GRADE_WORK_DIR\"* ]]"
	[[ "$output" == *".workdir"* ]] || fail "[[ \"$output\" == *\".workdir\"* ]]"
}

# --- smoke: the scripts must actually RUN -------------------------------------
# These exist because the rest of this suite once passed in full while FOUR functions were missing
# from lib.sh and every stage script died on the first line with "command not found". shellcheck
# does not run the code, the parity check does not touch lib.sh, and the unit tests only call the
# handful of functions they cover — so nothing noticed the pipeline was completely broken.
#
# A suite that cannot detect "the program does not start" is not a suite.

@test "lib.sh defines every function the stage scripts call" {
	# DERIVED, NOT LISTED. This used to hardcode ten names and was not updated when the delivery
	# chain moved into lib.sh, so it silently stopped covering source_fps, stab_prefix,
	# grain_plate, delivery_image_chain, delivery_grain_branch and render_delivery — six of the
	# sixteen, including the one that protects approved deliverables. A test named for "every
	# function" that checks a fixed subset is the coverage-shaped hole CLAUDE.md rules out, so the
	# list now comes from the scripts themselves and cannot go stale again.
	local fn missing=""
	source "$BATS_TEST_DIRNAME/../scripts/lib.sh"
	for fn in $(grep -hoE '^[a-z_]+\(\)' "$BATS_TEST_DIRNAME/../scripts/lib.sh" | tr -d '()'); do
		[ "$(type -t "$fn")" = "function" ] || missing="$missing $fn"
	done
	[ -z "$missing" ] || fail "lib.sh declares but does not define:$missing"

	# And every helper a stage script calls must actually exist in lib.sh — the direction that
	# catches a rename on one side only.
	for fn in $(grep -hoE '\b(probe_tags|verify_bt709|safe_retag|check_disk_space|require_nonempty|require_portrait|resolve_work_dir|look|ensure_tone_lut|transform_is_fresh|source_fps|stab_prefix|grain_plate|delivery_image_chain|delivery_grain_branch|render_delivery)\b' \
	         "$BATS_TEST_DIRNAME"/../scripts/0*.sh "$BATS_TEST_DIRNAME"/../scripts/grade.sh | sort -u); do
		[ "$(type -t "$fn")" = "function" ] || missing="$missing $fn"
	done
	[ -z "$missing" ] || fail "stage scripts call functions lib.sh does not define:$missing"
}

@test "every stage script starts and reports usage rather than dying" {
	for s in 01-baseline 02-grade 03-final 00-stabilise-detect; do
		run "$BATS_TEST_DIRNAME/../scripts/$s.sh" __NO_SUCH_CLIP__
		# It must fail on the MISSING CLIP, not on a broken script.
		[[ "$output" != *"command not found"* ]] || { echo "$s.sh: $output"; false; }
		[[ "$output" != *"unbound variable"* ]]  || { echo "$s.sh: $output"; false; }
		[[ "$output" == *"not found"* ]]         || { echo "$s.sh gave: $output"; false; }
	done
}

@test "every stage script reports usage when given NO arguments" {
	# The test above asserts "unbound variable" never appears, which is exactly what a bare `$1`
	# under `set -u` produces — but it always passed an argument, so it could not see it. All four
	# stage scripts died with "line NN: $1: unbound variable"; only grade.sh printed a usage line.
	for s in 01-baseline 02-grade 03-final 00-stabilise-detect grade; do
		run "$BATS_TEST_DIRNAME/../scripts/$s.sh"
		[ "$status" -ne 0 ] || fail "$s.sh exited 0 with no arguments"
		[[ "$output" != *"unbound variable"* ]] || fail "$s.sh died on \$1 instead of saying usage: $output"
		[[ "$output" == *"usage:"* ]] || fail "$s.sh gave no usage line: $output"
	done
}

@test "grade.sh plans a real clip end to end (dry run)" {
	local work src
	work=$(resolve_work_dir "$BATS_TEST_DIRNAME/.." 2>/dev/null) || work="$BATS_TEST_DIRNAME/.."
	src=$(ls "$work"/src/*.mov 2>/dev/null | head -1) || true
	[ -n "$src" ] || skip "no source footage"
	# Real footage in, but the OUTPUT goes to a temp dir. Without GRADE_WORK_DIR this ran against
	# the repo root, so every check.sh run left a dist/reports/run-*.txt and a per-clip tone cube
	# in the tree someone actually delivers from — 38 report files had accumulated.
	mkdir -p "$BATS_TEST_TMPDIR/dryrun"
	GRADE_WORK_DIR="$BATS_TEST_TMPDIR/dryrun" DRY=1 run "$BATS_TEST_DIRNAME/../scripts/grade.sh" "$src"
	[ "$status" -eq 0 ]
	[[ "$output" == *"clip(s)"* ]] || fail "[[ \"$output\" == *\"clip(s)\"* ]]"
	[[ "$output" != *"command not found"* ]] || fail "[[ \"$output\" != *\"command not found\"* ]]"
}

@test "grade.sh reads the transform cache that stage 00 writes" {
	# grade.sh reassigned WORK from the work-dir root to its own scratch dir, then built the
	# transform path from the reassigned value — landing two levels off, at
	# <work>/dist/.grade-work/dist/stab/. So it never saw a transform stage 00 had already
	# computed and silently paid ~65s per clip to redo it. One name doing two jobs.
	#
	# Transforms are motion-only and survive a re-grade, so one cache is correct. Content here is
	# irrelevant: this asserts the PATH both entry points agree on, not the warp.
	local work="$BATS_TEST_TMPDIR/gwork"
	mkdir -p "$work/src" "$work/dist/stab"
	cp "$FIXTURES/portrait_tagged.mov" "$work/src/CLIP.mov"
	printf 'stand-in for a real transform\n' > "$work/dist/stab/CLIP.trf"
	GRADE_WORK_DIR="$work" DRY=1 MATCH=0 run "$SCRIPTS/grade.sh" "$work/src/CLIP.mov"
	[ "$status" -eq 0 ]
	[[ "$output" == *"$work/dist/stab/CLIP.trf"* ]] \
		|| { echo "grade.sh did not find the shared transform:"; echo "$output"; false; }
}

@test "a transform older than its source is not reused" {
	# Transforms are measured against the DECODED frame, so re-orienting a source invalidates its
	# transform: the file then describes motion in a frame that no longer exists. Once the cache is
	# shared (above), a stale entry is silently reused by both entry points — the warp fights
	# footage it was never measured on. Same freshness rule ensure_tone_lut already applies to
	# shipped.cube against look.json.
	local work="$BATS_TEST_TMPDIR/stale"
	mkdir -p "$work/src" "$work/dist/stab"
	printf 'transform computed BEFORE the source was re-oriented\n' > "$work/dist/stab/CLIP.trf"
	cp "$FIXTURES/portrait_tagged.mov" "$work/src/CLIP.mov"
	# Stamped, not just touched: bash 3.2's -nt compares whole seconds, so same-second files would
	# make this pass for the wrong reason.
	touch -t 202609010000 "$work/dist/stab/CLIP.trf"
	touch -t 202609020000 "$work/src/CLIP.mov"
	GRADE_WORK_DIR="$work" DRY=1 MATCH=0 run "$SCRIPTS/grade.sh" "$work/src/CLIP.mov"
	[ "$status" -eq 0 ]
	[[ "$output" == *"stale"* ]] \
		|| { echo "grade.sh reused a stale transform:"; echo "$output"; false; }
	[[ "$output" != *"stabilising from"* ]] || fail "[[ \"$output\" != *\"stabilising from\"* ]]"
}

@test "grade.sh takes its tone values from look.json, not from itself" {
	# "Look values live in look.json, never hardcoded in a script" is a settled rule, and the
	# production path was breaking it: it read colour, grain and stabilisation from look.json but
	# carried its own copy of the whole tone block. So a grade sent from the Bench updated
	# shipped.cube and the staged path while grade.sh kept rendering the previous tone — the
	# two-copies-one-edited failure that look() exists to end, one layer up.
	local work="$BATS_TEST_TMPDIR/lookwork" look="$BATS_TEST_TMPDIR/other-look.json"
	mkdir -p "$work/src"
	cp "$FIXTURES/portrait_tagged.mov" "$work/src/CLIP.mov"
	# A gamma nothing in the repo contains, so a pass can only come from reading this file.
	cat > "$look" <<'JSON'
{
  "tone": { "gamma": 1.44, "pivot": 0.39, "contrast": 1.09,
            "toe": 0.0, "shoulder": 0.1, "black": 0.025 },
  "colour": { "saturation": 1.27, "warmth": 0.005 },
  "grain": { "strength": 8 },
  "stabilisation": { "smoothing": 30 },
  "match": { "reference_yavg": 609 }
}
JSON
	LOOK_FILE="$look" GRADE_WORK_DIR="$work" DRY=1 MATCH=0 STAB=0 \
		run "$SCRIPTS/grade.sh" "$work/src/CLIP.mov"
	[ "$status" -eq 0 ]
	[[ "$output" == *"gamma=1.44"* ]] \
		|| { echo "grade.sh ignored look.json's tone block:"; echo "$output"; false; }
}

# --- solve-gamma.py ------------------------------------------------------------
# The exposure solve was a python3 -c program assembled by string interpolation inside grade.sh,
# so nothing could reach it. A degenerate probe raised inside it — math.log(0) on a near-black
# frame, a zero denominator at y == 1.0 — and under `set -euo pipefail` that killed the whole
# batch at clip n rather than rendering that clip with the frozen curve.

@test "solve-gamma returns the reference gamma when the clip matches the reference" {
	run "$SCRIPTS/solve-gamma.py" 609 609 2.02
	[ "$status" -eq 0 ]
	[ "$output" = "2.020" ]
}

@test "solve-gamma moves the curve for a clip darker than the reference" {
	run "$SCRIPTS/solve-gamma.py" 400 609 2.02
	[ "$status" -eq 0 ]
	[ "$output" != "2.020" ]
}

@test "solve-gamma falls back rather than dividing by zero on a blown frame" {
	# y == 1.0 makes log(y) zero. This used to abort the batch.
	run "$SCRIPTS/solve-gamma.py" 1023 609 2.02
	[ "$status" -eq 0 ]
	[ "$output" = "2.020" ]
}

@test "solve-gamma falls back rather than taking log(0) on a black frame" {
	run "$SCRIPTS/solve-gamma.py" 0 609 2.02
	[ "$status" -eq 0 ]
	[ "$output" = "2.020" ]
}

@test "solve-gamma clamps instead of extrapolating a curve nobody has looked at" {
	# Four stops under the tuning exposure has no meaningful solve, only a nearest sane curve.
	run "$SCRIPTS/solve-gamma.py" 12 609 2.02
	[ "$status" -eq 0 ]
	[ "$output" = "1.200" ]
}

@test "solve-gamma rejects a non-numeric probe instead of interpolating it into a program" {
	run "$SCRIPTS/solve-gamma.py" "1); import os; os.exit(0" 609 2.02
	[ "$status" -ne 0 ]
	[[ "$output" == *"non-numeric"* ]] || fail "[[ \"$output\" == *\"non-numeric\"* ]]"
}

@test "safe_retag leaves a correctly tagged file untouched" {
	# Encoders don't reliably STAMP the tags, which is why safe_retag exists — but they don't
	# reliably get them wrong either, and the function remuxed unconditionally. On the staged path
	# that is a full read+write of two ~2.3GB ProRes masters per clip, roughly 9GB of I/O, to
	# change nothing. lib.sh's own header has always described verify-then-fix.
	#
	# Inode, not mtime: a remux writes a temp file and moves it over the original, so the inode
	# changes even when the bytes would not.
	local f="$BATS_TEST_TMPDIR/already-ok.mov" before after
	cp "$FIXTURES/portrait_tagged.mov" "$f"
	before=$(stat -f%i "$f")
	run safe_retag "$f"
	[ "$status" -eq 0 ]
	after=$(stat -f%i "$f")
	[ "$before" = "$after" ] || { echo "rewrote a file that was already correct"; false; }
	# ...and it must still report the verdict, not fall silent.
	[[ "$output" == *"tags OK"* ]] || fail "[[ \"$output\" == *\"tags OK\"* ]]"
}

@test "re-rendering a master does not invalidate its transform" {
	# The cache is shared, but the two entry points judged freshness against two different
	# references: grade.sh against the source, the final stages against the graded master. So a
	# transform written by grade.sh went stale the moment a master re-rendered, and the delivery
	# silently went out unstabilised.
	#
	# The source footage is the only correct reference. Transforms are motion-only and survive a
	# re-grade — change the look, tone or saturation and the same warp still applies — so the
	# graded master's mtime says nothing about whether the camera moved.
	local work="$BATS_TEST_TMPDIR/prov"
	mkdir -p "$work/src" "$work/dist/02-graded" "$work/dist/stab"
	cp "$FIXTURES/portrait_tagged.mov" "$work/src/CLIP.mov"
	printf 'transform measured on this source\n' > "$work/dist/stab/CLIP.trf"
	# The master is re-rendered AFTER the transform. That is a re-grade, not a re-shoot.
	cp "$FIXTURES/portrait_tagged.mov" "$work/dist/02-graded/CLIP_graded.mov"
	# Stamp the order explicitly. bash 3.2's -nt compares whole seconds, and all three files are
	# created inside one second here, so without this the transform is not "newer" than anything.
	touch -t 202609010000 "$work/src/CLIP.mov"
	touch -t 202609020000 "$work/dist/stab/CLIP.trf"
	touch -t 202609030000 "$work/dist/02-graded/CLIP_graded.mov"
	GRADE_WORK_DIR="$work" run "$SCRIPTS/03-final.sh" CLIP reels
	[[ "$output" == *"stabilising with"* ]] \
		|| { echo "called a valid transform stale after a re-grade:"; echo "$output"; false; }
}

@test "transform_is_fresh refuses when the source it was measured from is gone" {
	# Cannot prove freshness, so do not warp. A stale transform fights footage it was never
	# measured on, which is visibly wrong output; dropping stabilisation is merely less good.
	local trf="$BATS_TEST_TMPDIR/orphan.trf"
	printf 'x\n' > "$trf"
	run transform_is_fresh "$trf" "$BATS_TEST_TMPDIR/no-such-source.mov"
	[ "$status" -ne 0 ]
}

@test "every stage creates its own output directory" {
	# The staged scripts relied on dist/*/.gitkeep existing in the REPO, so with a work dir set
	# they wrote into a directory that does not exist — and ffmpeg reported it only at the end of
	# a full-length encode. The suite could not catch it, because the test above pre-creates every
	# output folder. This one deliberately does not.
	local work="$BATS_TEST_TMPDIR/bare" s
	mkdir -p "$work/src"
	cp "$FIXTURES/portrait_tagged.mov" "$work/src/CLIP.mov"
	mkdir -p "$work/dist/01-baseline" "$work/dist/02-graded"
	cp "$FIXTURES/portrait_tagged.mov" "$work/dist/01-baseline/CLIP_baseline.mov"
	cp "$FIXTURES/portrait_tagged.mov" "$work/dist/02-graded/CLIP_graded.mov"
	# dist/03-final is the one nothing has created.
	[ ! -d "$work/dist/03-final" ]
	for s in reels feed; do
		GRADE_WORK_DIR="$work" run "$SCRIPTS/03-final.sh" CLIP "$s"
		# Assert the directory itself, not the absence of an error message: this fixture is too
		# small to survive the full delivery chain, and an unrelated encode failure must not let
		# this pass vacuously.
		[ -d "$work/dist/03-final" ] \
			|| { echo "03-final.sh $s did not create its output dir:"; echo "$output"; false; }
		rm -rf "$work/dist/03-final"
	done
}

# --- render_delivery -----------------------------------------------------------

@test "a failed re-render leaves the approved deliverable byte-identical" {
	# `ffmpeg -y` pointed at the delivery path truncates the existing file before it knows whether
	# the graph even initialises. Measured on this repo: an approved mp4 re-rendered with a broken
	# graph was left at 0 bytes, ffmpeg exiting 234. require_nonempty reported the failure loudly
	# and the deliverable was already gone — and per docs/adr/0004, getting it back means
	# regenerating the baseline and the master first.
	local out="$BATS_TEST_TMPDIR/approved.mp4" before
	ffmpeg -y -f lavfi -i "color=c=gray:s=64x128:d=0.1:r=24" -frames:v 1 \
		-c:v libx264 -pix_fmt yuv420p "$out" -v error
	before=$(md5 -q "$out")

	# A filter graph that fails at initialisation, which is the dangerous shape: ffmpeg has already
	# opened the output by then.
	run render_delivery "$out" "deliberately broken encode" \
		-y -f lavfi -i "color=c=gray:s=64x128:d=0.1:r=24" \
		-filter_complex "[0:v]nosuchfilter=1[o]" -map "[o]" -frames:v 1
	[ "$status" -ne 0 ]
	[ -s "$out" ] || { echo "the approved deliverable was destroyed"; false; }
	[ "$(md5 -q "$out")" = "$before" ] || { echo "the approved deliverable was modified"; false; }
	[ ! -f "$BATS_TEST_TMPDIR/approved.partial.mp4" ] || { echo "left a staging file behind"; false; }
}

@test "render_delivery installs a good render and tags it" {
	local out="$BATS_TEST_TMPDIR/fresh.mp4"
	run render_delivery "$out" "encode" \
		-y -f lavfi -i "color=c=gray:s=64x128:d=0.1:r=24" \
		-filter_complex "[0:v]${DELIVERY_SETPARAMS}[o]" -map "[o]" -frames:v 1 \
		-c:v libx264 -pix_fmt yuv420p
	[ "$status" -eq 0 ]
	[ -s "$out" ]
	run probe_tags "$out"
	[ "$output" = "bt709,bt709,bt709" ]
}

# --- ensure_tone_lut -----------------------------------------------------------
# This had no test at all, and its freshness check was mtime-only. git does not preserve mtimes, so
# on every fresh clone the committed cube lands NEWER than look.json and was trusted forever: with
# look.json backdated and a parameter changed, the stale curve stayed in place in silence. The
# guarantee held only on the machine where the edit happened.

_tone_root() {  # build a throwaway repo root with its own look.json and generator
	local root="$1" gamma="$2"
	mkdir -p "$root/luts/tone" "$root/scripts"
	cp "$BATS_TEST_DIRNAME/../scripts/make-tone-lut.py" "$root/scripts/"
	cat > "$root/look.json" <<JSON
{ "tone": { "gamma": $gamma, "pivot": 0.39, "contrast": 1.09,
            "toe": 0.0, "shoulder": 0.1, "black": 0.025 } }
JSON
}

@test "ensure_tone_lut regenerates a cube that disagrees with look.json" {
	local root="$BATS_TEST_TMPDIR/tone-stale"
	_tone_root "$root" 2.02
	# A cube built at a DIFFERENT gamma, then stamped newer than look.json — exactly the state a
	# fresh clone produces, and the state the old mtime check called fresh.
	"$root/scripts/make-tone-lut.py" "$root/luts/tone/shipped.cube" \
		--gamma 1.5 --pivot 0.39 --contrast 1.09 --toe 0.0 --shoulder 0.1 --black 0.025 >/dev/null
	touch -t 202609010000 "$root/look.json"
	touch -t 202609020000 "$root/luts/tone/shipped.cube"

	LOOK_FILE="$root/look.json" run ensure_tone_lut "$root"
	[ "$status" -eq 0 ]
	run head -1 "$root/luts/tone/shipped.cube"
	[[ "$output" == *"gamma=2.02"* ]] \
		|| { echo "kept a cube built at the wrong gamma: $output"; false; }
}

@test "ensure_tone_lut does not rewrite a cube that already matches" {
	local root="$BATS_TEST_TMPDIR/tone-current" before after
	_tone_root "$root" 2.02
	LOOK_FILE="$root/look.json" ensure_tone_lut "$root"
	before=$(stat -f%i "$root/luts/tone/shipped.cube")
	LOOK_FILE="$root/look.json" run ensure_tone_lut "$root"
	[ "$status" -eq 0 ]
	after=$(stat -f%i "$root/luts/tone/shipped.cube")
	[ "$before" = "$after" ] || { echo "regenerated an already-current cube"; false; }
}

@test "the tone cube records the gamma it was built at" {
	# The old TITLE recorded every parameter except gamma — the one that was actually re-tuned
	# (2.09 -> 2.02), so a committed cube could not be traced back to the curve it encodes.
	run head -1 "$BATS_TEST_DIRNAME/../luts/tone/shipped.cube"
	[[ "$output" == *"gamma="* ]] || fail "[[ \"$output\" == *\"gamma=\"* ]]"
}

@test "the production filter graph renders a real clip end to end" {
	# NOTHING else in this suite executes this graph. shellcheck cannot see inside a filter string
	# — it reported clean on both of the previously shipped load-bearing bugs — the parity check
	# touches only the tone curve, and every other grade.sh test stops at DRY=1. So dropping a
	# label here went green and failed three minutes into a 19-clip run, after the render had
	# already truncated the deliverable it was overwriting.
	#
	# Real footage only: a synthetic clip does not have this camera's stream structure, and
	# CLAUDE.md is explicit that tests covering those behaviours must skip rather than fake it.
	local src work out w h
	src=$(ls "$BATS_TEST_DIRNAME/../src"/*.mov 2>/dev/null | head -1) || true
	[ -n "$src" ] || skip "no source footage in src/"
	work="$BATS_TEST_TMPDIR/render"
	mkdir -p "$work"

	# 0.1 seconds through the whole chain: CST, look LUT, luma-only tone via mergeplanes,
	# saturation, warmth, chroma denoise, the dithered 10->8 reduction, sharpener, grain blend.
	# MATCH stays on so the exposure probe runs too — it once returned empty on every clip
	# because `metadata=print` logs at INFO level, which `-v error` suppresses.
	PROOF=0.1 STAB=0 GRADE_WORK_DIR="$work" run "$SCRIPTS/grade.sh" "$src"
	[ "$status" -eq 0 ] || { echo "$output"; false; }
	[[ "$output" =~ YAVG=[0-9] ]] || { echo "the exposure probe returned nothing:"; echo "$output"; false; }

	out=$(ls "$work"/dist/proofs/*.mp4 2>/dev/null | head -1)
	[ -n "$out" ] || { echo "no proof was written:"; echo "$output"; false; }
	w=$(ffprobe -v error -select_streams v:0 -show_entries stream=width -of default=nw=1:nk=1 "$out" | head -1)
	h=$(ffprobe -v error -select_streams v:0 -show_entries stream=height -of default=nw=1:nk=1 "$out" | head -1)
	[ "$w" = "1080" ] && [ "$h" = "1920" ] || { echo "delivered ${w}x${h}, wanted 1080x1920"; false; }
	# A wrongly tagged file is double-transformed by any player that trusts the tag. That is what
	# "bleached out" was, and the encoder ignoring the flags is why safe_retag exists.
	run probe_tags "$out"
	[ "$output" = "bt709,bt709,bt709" ]
}

@test "verify_bt709 PASSES on a real camera-structured file once its tags are correct" {
	# THE MISSING CASE. The other real-footage test asserts verify_bt709 returns a VERDICT, and it
	# stays green even with probe_tags' dedup removed: the source is bt2020-tagged, so the call
	# fails either way and the multi-line output still satisfies every assertion. The case that
	# catches the original bug is verify_bt709 PASSING on a file whose ffprobe prints the video
	# stream twice — which is the exact state it shipped in, unable to pass on anything.
	#
	# Found a live defect: on a camera-structured file the csv answer carries a TRAILING COMMA
	# ("bt709,bt709,bt709,"), so the comparison could never match no matter how the file was
	# tagged. CLAUDE.md documents that comma for dimensions; probe_tags had the same shape.
	local src excerpt
	src=$(ls "$BATS_TEST_DIRNAME/../src"/*.mov 2>/dev/null | head -1) || true
	[ -n "$src" ] || skip "no source footage in src/"
	excerpt="$BATS_TEST_TMPDIR/camera-structure.mov"
	# -c copy preserves the [STREAM_GROUP] structure, the repeated stream and the trailing comma.
	# A re-encode does not, which is why the synthetic fixtures cannot cover this.
	ffmpeg -v error -y -t 0.1 -i "$src" -c copy "$excerpt"

	safe_retag "$excerpt" >/dev/null
	run verify_bt709 "$excerpt"
	[ "$status" -eq 0 ] || { echo "correctly tagged real file rejected: $output"; false; }
	[[ "$output" == *"tags OK"* ]] || fail "[[ \"$output\" == *\"tags OK\"* ]]"
}

@test "probe_tags returns three clean fields on a real camera file" {
	local src
	src=$(ls "$BATS_TEST_DIRNAME/../src"/*.mov 2>/dev/null | head -1) || true
	[ -n "$src" ] || skip "no source footage in src/"
	run probe_tags "$src"
	# Exactly three comma-separated values, no trailing comma, no blank-line artefact.
	[[ "$output" =~ ^[a-z0-9]+,[a-z0-9]+,[a-z0-9]+$ ]] \
		|| { echo "probe_tags gave [$output]"; false; }
}

@test "check_disk_space reports a legible failure when df cannot answer" {
	# This branch was unreachable from the suite: the ancestor walk always hands df an existing
	# directory, so deleting the numeric validation left all five disk tests green. Without it an
	# empty answer reaches $(( )) and the stage dies with a bash arithmetic syntax error rather
	# than a message naming the path.
	local bin="$BATS_TEST_TMPDIR/nodf"
	mkdir -p "$bin"
	printf '#!/bin/sh\nexit 1\n' > "$bin/df"
	chmod +x "$bin/df"
	PATH="$bin:$PATH" run check_disk_space "$BATS_TEST_TMPDIR" 1
	[ "$status" -ne 0 ]
	[[ "$output" == *"could not measure free space"* ]] || fail "[[ \"$output\" == *\"could not measure free space\"* ]]"
	[[ "$output" != *"syntax error"* ]] || fail "[[ \"$output\" != *\"syntax error\"* ]]"
}

# --- look.json ----------------------------------------------------------------

@test "look.json answers every key the scripts ask for" {
	# look() has no fallbacks on purpose: a missing value must stop the run rather than quietly
	# substitute a different look. That makes the set of keys a contract, and nothing checked the
	# two sides of it against each other — so adding match.reference_yavg silently widened the gap
	# that already stopped the Bench's output from working.
	local key missing=""
	for key in $(grep -ho 'look \.[a-z_.]*' "$BATS_TEST_DIRNAME"/../scripts/*.sh \
	             | awk '{print $2}' | sort -u); do
		jq -e "$key" "$BATS_TEST_DIRNAME/../look.json" >/dev/null 2>&1 || missing="$missing $key"
	done
	[ -z "$missing" ] || fail "look.json is missing:$missing"
}

@test "look refuses a missing key rather than substituting a different look" {
	local look="$BATS_TEST_TMPDIR/partial.json"
	printf '{ "tone": { "gamma": 2.02 } }\n' > "$look"
	LOOK_FILE="$look" run look .grain.strength
	[ "$status" -ne 0 ]
	[[ "$output" == *"missing .grain.strength"* ]] || fail "unhelpful message: $output"
}

@test "no script renders straight to a delivery path" {
	# The behavioural test above proves render_delivery protects the file it replaces. This pins
	# the invariant that every render actually goes through it: `ffmpeg -y` aimed at an output
	# variable truncates the existing file before the graph is known to initialise, and that is
	# how a failed re-render destroys an approved deliverable. I reintroduced exactly this while
	# rewriting stage 3, one commit after fixing it elsewhere.
	local offenders
	# Comment lines are excluded, or the note explaining the rule trips the rule.
	offenders=$(grep -n 'ffmpeg .*-y.*"\$\(OUT\|out\)"' "$BATS_TEST_DIRNAME"/../scripts/*.sh \
		| grep -v ':[0-9]*:[[:space:]]*#' || true)
	[ -z "$offenders" ] || fail "renders straight to the delivery path:$offenders"
}

# --- output integrity: the deliverable that already exists ---------------------
# `ffmpeg -y` pointed at a delivery path truncates it before the graph is known to initialise, so a
# failed re-render destroys an approved file. render_delivery stages, checks and tags before
# installing. These pin BOTH halves of that: the staging behaviour, and the tag check that decides
# whether a staged file is allowed to land.

@test "a failed re-render through 03-final.sh leaves the approved deliverable byte-identical" {
	# grade.sh was converted to render_delivery and 03-final.sh was not, so the staged path still
	# truncated the file the one-pass path protected — same directory, same filename. Measured: an
	# approved 2176-byte mp4 left at 0 bytes.
	#
	# No special trigger needed. The synthetic fixture cannot survive the delivery chain (zscale
	# reports "code 3074: no path between colorspaces" on it, while a real graded master passes the
	# identical graph), so a plain run is a reliable failing render.
	local work="$BATS_TEST_TMPDIR/keepdeliv" out before
	mkdir -p "$work/src" "$work/dist/02-graded" "$work/dist/03-final"
	cp "$FIXTURES/portrait_tagged.mov" "$work/src/CLIP.mov"
	cp "$FIXTURES/portrait_tagged.mov" "$work/dist/02-graded/CLIP_graded.mov"

	out="$work/dist/03-final/CLIP_reels-stories_9x16.mp4"
	ffmpeg -y -f lavfi -i "color=c=red:s=64x128:d=0.1:r=24" -frames:v 1 \
		-c:v libx264 -pix_fmt yuv420p "$out" -v error
	before=$(md5 -q "$out")

	GRADE_WORK_DIR="$work" run "$SCRIPTS/03-final.sh" CLIP reels
	[ "$status" -ne 0 ] || skip "the fixture rendered successfully; this test needs a failing render"
	[ -s "$out" ] || fail "the approved deliverable was truncated"
	[ "$(md5 -q "$out")" = "$before" ] || fail "the approved deliverable was modified"
	[ ! -f "$work/dist/03-final/CLIP_reels-stories_9x16.partial.mp4" ] \
		|| fail "left a staging file in the folder someone uploads from"
}

@test "render_delivery refuses to install a file it could not tag" {
	# The ffmpeg result and the emptiness check were both guarded with `if !`; the retag was a bare
	# call. That fails open wherever `set -e` is suppressed — including this `run` — and installed a
	# file measuring unknown,unknown,unknown, returning 0. A wrongly tagged file is the
	# double-transform lib.sh exists to prevent.
	local out="$BATS_TEST_TMPDIR/untaggable.mp4"
	safe_retag() { return 1; }     # the remux fails, however it fails
	run render_delivery "$out" "encode" \
		-y -f lavfi -i "color=c=gray:s=64x128:d=0.1:r=24" \
		-filter_complex "[0:v]${DELIVERY_SETPARAMS}[o]" -map "[o]" -frames:v 1 \
		-c:v libx264 -pix_fmt yuv420p
	[ "$status" -ne 0 ] || fail "installed a file it could not tag, and reported success"
	[ ! -e "$out" ] || fail "installed an untagged file at $out"
	[ ! -e "$BATS_TEST_TMPDIR/untaggable.partial.mp4" ] || fail "left a staging file behind"
}

@test "a clip whose render fails does not take the rest of the batch with it" {
	# Measured: a two-clip run whose first render failed never attempted the second, printed no
	# summary line, and left the report ending mid-file. grade.sh already skips a non-portrait clip
	# and continues; a render failure went straight through `set -e` instead. In a 19-clip
	# unattended run a failure at clip 3 silently costs the other 16.
	#
	# The trigger is the documented one: a TRUNCATED .trf stamped newer than its source, so it
	# passes the freshness check, is not re-detected, and then dies deep in the filter graph with
	# "Cannot parse localmotion: unexpected end of file". Only AAA gets one, so BBB is the clip
	# that must still render.
	local work="$BATS_TEST_TMPDIR/batch"
	mkdir -p "$work/src" "$work/dist/stab"
	cp "$FIXTURES/portrait_tagged.mov" "$work/src/AAA.mov"
	cp "$FIXTURES/portrait_tagged.mov" "$work/src/BBB.mov"
	printf 'VID.STAB 1\n\n' > "$work/dist/stab/AAA.trf"
	# bash 3.2's -nt compares whole seconds and these are created inside one, so stamp the order.
	touch -t 202609010000 "$work/src/AAA.mov" "$work/src/BBB.mov"
	touch -t 202609020000 "$work/dist/stab/AAA.trf"

	GRADE_WORK_DIR="$work" MATCH=0 run "$SCRIPTS/grade.sh" "$work/src"
	[[ "$output" == *"FAIL  AAA"* ]] || fail "the failing clip was not reported as failed: $output"
	[ -s "$work/dist/03-final/BBB_reels-stories_9x16.mp4" ] \
		|| fail "the batch stopped at the failing clip; BBB was never rendered: $output"
	[[ "$output" == *"1 failed"* ]] || fail "the summary did not count the failure: $output"
	[ "$status" -ne 0 ] || fail "a run with a failed clip exited 0"
}

@test "a usage error creates nothing in the output tree" {
	# grade.sh made its output directories and an empty run-*.txt BEFORE checking that it had any
	# clips, so `./grade.sh` with no arguments left litter in the folder someone delivers from —
	# and one stray report per suite run, since the no-argument test above calls exactly that.
	local work="$BATS_TEST_TMPDIR/usage"
	mkdir -p "$work"
	GRADE_WORK_DIR="$work" run "$SCRIPTS/grade.sh"
	[ "$status" -ne 0 ] || fail "no-argument run exited 0"
	[ ! -d "$work/dist" ] || fail "a usage error created $(find "$work/dist" -type f | tr '\n' ' ')"
}

# --- the grade chain: one builder, two render paths ---------------------------
# The look LUT, the luma-only tone curve and the colour ops were assembled separately by grade.sh
# and 02-grade.sh. They had already drifted once before that (grade.sh carried its own copy of the
# tone block, so a grade from the Bench moved the one-pass path and left the staged one behind),
# and the suite renders only the one-pass graph — so the staged one could break and stay green.

@test "the grade chain is built in exactly one place" {
	# Structural, because the behavioural test below cannot see a THIRD caller appearing. The
	# tell is mergeplanes: it is the one filter that only the grade head uses, so any stage script
	# naming it has started building its own copy again.
	local offenders
	# Comments are excluded, or the pointers explaining the rule trip the rule.
	offenders=$(grep -n 'mergeplanes' "$SCRIPTS"/*.sh \
		| grep -v '/lib\.sh:' | grep -v ':[0-9]*:[[:space:]]*#' || true)
	[ -z "$offenders" ] || fail "builds its own grade chain instead of calling grade_chain:$offenders"
}

@test "the staged grade graph initialises and renders" {
	# 02-grade.sh's graph was executed by NOTHING. shellcheck cannot see inside a filter string,
	# the parity check touches only the tone curve, and the one real render in this suite goes
	# through grade.sh. So the staged path's half of the shared builder had no cover at all, and
	# it IS a different graph: no CST prefix, no setparams.
	#
	# WHAT THIS DOES AND DOES NOT CATCH. Mutation-tested: breaking the mergeplanes mask fails it.
	# Dropping either `format=yuv444p10le` does NOT — not here and not in the real-footage render
	# either. The "Invalid argument" that pair was added for is not reproducible on ffmpeg 9.0.1,
	# which negotiates both branches to a matching format on its own. Do not read that as licence
	# to delete them: the failure is documented from a real incident, negotiation is exactly the
	# kind of thing that changes between builds, and nothing would tell you it had come back.
	#
	# A SYNTHETIC baseline is legitimate here, unlike the ffprobe tests: what is under test is
	# whether a filter graph initialises and produces pixels, which does not depend on this
	# camera's stream structure. A baseline is by definition already Rec.709 ProRes.
	local work="$BATS_TEST_TMPDIR/staged" base out
	base="$work/dist/01-baseline/CCC_baseline.mov"
	mkdir -p "$(dirname "$base")"
	ffmpeg -y -f lavfi -i "testsrc2=s=240x426:d=0.2:r=24" \
		-c:v prores_ks -profile:v 3 -pix_fmt yuv422p10le "$base.raw.mov" -v error
	# Tagged in a separate remux, for the reason setup_file gives: prores_ks ignores the flags.
	ffmpeg -y -i "$base.raw.mov" -map 0:v:0 -c copy \
		-color_primaries bt709 -color_trc bt709 -colorspace bt709 "$base" -v error

	GRADE_WORK_DIR="$work" run "$SCRIPTS/02-grade.sh" CCC
	[ "$status" -eq 0 ] || { echo "$output"; false; }
	out="$work/dist/02-graded/CCC_graded.mov"
	[ -s "$out" ] || fail "the staged graph produced nothing: $output"
	# THE TONE CURVE MUST BE LOAD-BEARING, and proving that took three attempts — each earlier
	# one passed against a mutation it was written to catch:
	#   1. `pix_fmt is 10-bit` is vacuous. `-pix_fmt yuv422p10le` on the command line decides the
	#      answer whatever the graph did, so it passed against a chain mutated to emit 8-bit.
	#   2. `luma moved from the baseline` is nearly vacuous. colorbalance shifts luma too, so a
	#      mergeplanes mask taking the UNTONED branch still moved it — baseline 493.92, bypassed
	#      647.998, real chain 552.71 — and passed.
	#      (Bypassing it means 0x101112, not 0x011112: each byte of the mask is INPUT then PLANE,
	#      so 01 asks for input 0's chroma as luma, which is a different corruption that moves
	#      luma too. A mutation that is not the one you meant proves nothing.)
	# Rendering the same baseline through the same builder with an IDENTITY tone LUT and requiring
	# the two to differ pins the curve itself, and stays true whatever look.json currently says.
	local ident="$BATS_TEST_TMPDIR/identity.cube" flat="$work/flat.mov"
	"$SCRIPTS/make-tone-lut.py" "$ident" --gamma 1 --pivot 0.5 --contrast 1 \
		--toe 0 --shoulder 0 --black 0 >/dev/null
	ffmpeg -y -i "$base" \
		-filter_complex "[0:v]$(grade_chain "$ident" "$(look .colour.saturation)" "$(look .colour.warmth)")[o]" \
		-map "[o]" -c:v prores_ks -profile:v 3 -pix_fmt yuv422p10le "$flat" -v error
	local y_graded y_flat
	y_graded=$(_yavg "$out")
	y_flat=$(_yavg "$flat")
	[ -n "$y_graded" ] && [ -n "$y_flat" ] || fail "could not measure luma: '$y_graded' '$y_flat'"
	[ "$y_graded" != "$y_flat" ] \
		|| fail "the tone LUT changed nothing ($y_graded either way): the curve is not reaching the output"
}

@test "every file path named in prose or in a script actually exists" {
	# Removing rotation left a runbook step telling you to pass an argument that had been silently
	# dropped, and CLAUDE.md's own rule is that deleting a concept means grepping for its name in
	# prose too. A pointer to a moved or deleted file is the same failure one level up, and it is
	# the failure mode a docs layout built on pointers invites — so it gets a guard rather than a
	# convention.
	local root="$BATS_TEST_DIRNAME/.." missing="" ref f
	# Paths that look like repo paths: a directory prefix this repo actually has, then a filename.
	for ref in $(grep -rhoE '(docs|scripts|tests|luts|bench)/[A-Za-z0-9_/.-]+\.(md|sh|py|json|cube|html)' \
			"$root"/*.md "$root"/docs "$root"/scripts "$root"/tests 2>/dev/null | sort -u); do
		f="${ref%%[.,)]}"
		# luts/apple/ is deliberately absent on a fresh clone (Apple's licence), and the filmic
		# cubes are generated and gitignored. Both document their own absence in a SOURCE.txt.
		case "$f" in luts/apple/*|luts/filmic/*) continue ;; esac
		[ -e "$root/$f" ] || missing="$missing $f"
	done
	[ -z "$missing" ] || fail "referenced but not present:$missing"
}

# --- what reaches the filter graph --------------------------------------------
# An ffmpeg filter description is a LANGUAGE: `,` and `;` separate filters and chains, `'` quotes a
# value, `[` `]` delimit labels. Every look value is spliced into one by string interpolation, so a
# value carrying any of those ADDS FILTERS rather than being read as a number — and ffmpeg filters
# can write files (`metadata=print:file=`) and read them (`movie=`). There is no eval anywhere here,
# so this is not shell injection; the ceiling is ffmpeg doing file I/O as whoever ran the script.
#
# It matters because neither input is hand-typed. look.json is transcribed from the Bench's artifact
# db, which is shared and multi-writer, and a clip FILENAME arrives from the camera or from whoever
# handed over the card. Nothing on the read side checked either one.
#
# Ported from a branch of the precursor that never landed, because it predates the chain dedupe and
# would have reinstated an inlined copy of the graph. See PROVENANCE.md.

@test "require_number accepts a number and rejects a filter fragment" {
	run require_number SAT 1.27
	[ "$status" -eq 0 ]
	[ "$output" = "1.27" ]

	run require_number BLACK "-0.08"
	[ "$status" -eq 0 ]

	run require_number SAT "1.27,metadata=print:file=/tmp/x"
	[ "$status" -ne 0 ]
	[[ "$output" == *"must be numeric"* ]] || fail "unhelpful message: $output"

	run require_number SAT ""
	[ "$status" -ne 0 ]
}

@test "require_clip_name refuses a path and refuses filter syntax" {
	run require_clip_name IMG_0609
	[ "$status" -eq 0 ]
	[ "$output" = "IMG_0609" ]

	run require_clip_name "../../escaped"
	[ "$status" -ne 0 ]
	[[ "$output" == *"clip name"* ]] || fail "gave no reason: $output"

	run require_clip_name "IMG_0609'"
	[ "$status" -ne 0 ]

	run require_clip_name ""
	[ "$status" -ne 0 ]
}

@test "grade.sh refuses a SMOOTHING that would splice a filter into the graph" {
	local work="$BATS_TEST_TMPDIR/inj-smooth" marker="$BATS_TEST_TMPDIR/smooth-written"
	mkdir -p "$work/src"
	cp "$FIXTURES/portrait_tagged.mov" "$work/src/CLIP.mov"
	SMOOTHING="30,metadata=print:file=$marker" GRADE_WORK_DIR="$work" MATCH=0 \
		run "$SCRIPTS/grade.sh" "$work/src/CLIP.mov"
	[ "$status" -ne 0 ]
	# Assert the GUARD's verdict, not just a non-zero exit: a synthetic fixture fails this graph
	# for its own reasons, so `status != 0` stayed true with the guard removed and the test read as
	# coverage while covering nothing. Found by mutation.
	[[ "$output" == *"SMOOTHING must be numeric"* ]] || fail "not refused by the guard: $output"
	[ ! -f "$marker" ] || fail "the spliced filter ran and wrote $marker"
}

@test "grade.sh refuses a PROOF that would append ffmpeg arguments" {
	# PROOF is spliced UNQUOTED on purpose (-t $PROOF), so whitespace in it becomes extra ffmpeg
	# options rather than a duration. `-f mp4 <path>` then appends a second output file, which
	# walks straight past render_delivery's staging.
	local work="$BATS_TEST_TMPDIR/inj-proof" injected="$BATS_TEST_TMPDIR/injected.mp4"
	mkdir -p "$work/src"
	cp "$FIXTURES/portrait_tagged.mov" "$work/src/CLIP.mov"
	PROOF="1 -f mp4 $injected" GRADE_WORK_DIR="$work" MATCH=0 STAB=0 \
		run "$SCRIPTS/grade.sh" "$work/src/CLIP.mov"
	[ "$status" -ne 0 ]
	[[ "$output" == *"PROOF"* ]] || fail "did not name the offending variable: $output"
	[ ! -f "$injected" ] || fail "ffmpeg wrote the injected output $injected"
}

@test "03-final.sh refuses a non-numeric crop offset" {
	local work="$BATS_TEST_TMPDIR/inj-crop" marker="$BATS_TEST_TMPDIR/crop-written"
	mkdir -p "$work/src" "$work/dist/02-graded"
	cp "$FIXTURES/portrait_tagged.mov" "$work/src/CLIP.mov"
	cp "$FIXTURES/portrait_tagged.mov" "$work/dist/02-graded/CLIP_graded.mov"
	GRADE_WORK_DIR="$work" run "$SCRIPTS/03-final.sh" CLIP feed "750,metadata=print:file=$marker"
	[ "$status" -ne 0 ]
	[ ! -f "$marker" ] || fail "the spliced filter ran and wrote $marker"
}

@test "every stage refuses a clip argument that escapes the work dir" {
	# The clip name is used raw as a path component. `mkdir -p "$(dirname "$OUT")"` — added when the
	# stages stopped relying on the checked-in dist/*/.gitkeep markers — is what turns a traversal
	# argument into a successful write: before it, the absent directory stopped the render.
	local work="$BATS_TEST_TMPDIR/escape" s
	mkdir -p "$work/src" "$work/dist/01-baseline" "$work/dist/02-graded"
	for s in 00-stabilise-detect 01-baseline 02-grade 03-final; do
		GRADE_WORK_DIR="$work" run "$SCRIPTS/$s.sh" "../../escaped"
		[ "$status" -ne 0 ] || fail "$s.sh accepted a traversing clip name"
		[[ "$output" == *"clip name"* ]] || fail "$s.sh gave no reason: $output"
	done
	[ ! -d "$BATS_TEST_TMPDIR/escaped" ] || fail "a stage created a directory outside the work dir"
}

@test "grade.sh refuses a clip whose FILENAME would break the filter graph" {
	# The clip name reaches lut1d=file='...' and vidstabtransform=input='...' via the tone-LUT and
	# transform paths, so a quote in it closes ffmpeg's quoting from the inside.
	local work="$BATS_TEST_TMPDIR/quotename"
	mkdir -p "$work/src"
	cp "$FIXTURES/portrait_tagged.mov" "$work/src/IMG_0609'.mov"
	GRADE_WORK_DIR="$work" MATCH=0 STAB=0 run "$SCRIPTS/grade.sh" "$work/src/IMG_0609'.mov"
	[ "$status" -ne 0 ] || fail "accepted a clip name containing a quote"
	[[ "$output" == *"clip name"* ]] || fail "gave no reason: $output"
}

@test "a look.json value that is not a number is refused, not rendered" {
	local work="$BATS_TEST_TMPDIR/badlook" look="$BATS_TEST_TMPDIR/hostile-look.json"
	mkdir -p "$work/src"
	cp "$FIXTURES/portrait_tagged.mov" "$work/src/CLIP.mov"
	cat > "$look" <<'JSON'
{
  "tone": { "gamma": 2.02, "pivot": 0.39, "contrast": 1.09,
            "toe": 0.0, "shoulder": 0.1, "black": 0.025 },
  "colour": { "saturation": "1.27,metadata=print:file=/tmp/pwned", "warmth": 0.005 },
  "grain": { "strength": 8 },
  "stabilisation": { "smoothing": 30 },
  "match": { "reference_yavg": 609 }
}
JSON
	LOOK_FILE="$look" GRADE_WORK_DIR="$work" MATCH=0 STAB=0 \
		run "$SCRIPTS/grade.sh" "$work/src/CLIP.mov"
	[ "$status" -ne 0 ] || fail "rendered with a non-numeric saturation"
	[[ "$output" == *"must be numeric"* ]] || fail "gave no reason: $output"
}

@test "every stage says what it wanted when given no clip at all" {
	# This pins the USAGE guard specifically, and asserts the usage wording rather than accepting
	# either message. Written the loose way it survived the removal of both guards that can refuse
	# an empty name — each was individually redundant, so neither was covered. require_clip_name's
	# own empty branch is covered by its unit test above.
	#
	# Without the usage guard an empty argument becomes "$WORK/src/.mov" and the stage fails later
	# with a confusing not-found, or writes a transform named ".trf".
	local work="$BATS_TEST_TMPDIR/noarg" s
	mkdir -p "$work/src" "$work/dist/01-baseline" "$work/dist/02-graded"
	for s in 00-stabilise-detect 01-baseline 02-grade 03-final; do
		GRADE_WORK_DIR="$work" run "$SCRIPTS/$s.sh"
		[ "$status" -ne 0 ] || fail "$s.sh accepted an empty clip name"
		[[ "$output" == *"usage:"* ]] || fail "$s.sh did not say what it wanted: $output"
	done
}

# --- the event stream ---------------------------------------------------------
# The app drives this engine, and it cannot parse prose written for a person: the human lines are
# deliberately reworded whenever the wording is wrong, which is exactly what a consumer must not
# depend on. So JSON=1 emits one object per line and every refusal names a code on stderr.
#
# What these tests pin is the CONTRACT, not the wording: stdout is machine-readable and nothing
# else, the report still contains the human lines, and each refusal is named.

@test "JSON=1 puts nothing but parseable objects on stdout" {
	local work="$BATS_TEST_TMPDIR/json-dry"
	mkdir -p "$work/src"
	cp "$FIXTURES/portrait_tagged.mov" "$work/src/CLIP.mov"
	JSON=1 DRY=1 MATCH=0 STAB=0 GRADE_WORK_DIR="$work" \
		run --separate-stderr "$SCRIPTS/grade.sh" "$work/src/CLIP.mov"
	[ "$status" -eq 0 ]
	[ -n "$output" ] || fail "JSON=1 produced no events at all"
	# Every line, or the stream is not a stream. python3 rather than a grep for braces: a shape
	# test would pass on `{"event":"x",}`.
	printf '%s\n' "$output" | python3 -c '
import json, sys
for i, line in enumerate(sys.stdin.read().splitlines(), 1):
    if not line.strip(): continue
    try: json.loads(line)
    except Exception as e: sys.exit("line %d is not JSON (%s): %s" % (i, e, line))
' || fail "stdout was not one JSON object per line:$output"
	[[ "$output" == *'"event":"run_start"'* ]] || fail "no run_start event: $output"
	[[ "$output" == *'"event":"clip_planned"'* ]] || fail "no clip_planned event: $output"
	[[ "$output" == *'"event":"run_done"'* ]] || fail "no run_done event: $output"
}

@test "JSON=1 keeps the human lines in the report rather than dropping them" {
	# The report is what a person reads afterwards, so it is never the half that gets dropped. This
	# is the property that lets a consumer own stdout without anything being lost.
	local work="$BATS_TEST_TMPDIR/json-report"
	mkdir -p "$work/src"
	cp "$FIXTURES/portrait_tagged.mov" "$work/src/CLIP.mov"
	JSON=1 DRY=1 MATCH=0 STAB=0 GRADE_WORK_DIR="$work" \
		run --separate-stderr "$SCRIPTS/grade.sh" "$work/src/CLIP.mov"
	[ "$status" -eq 0 ]
	[[ "$output" != *"clip(s)"* ]] || fail "a human line reached stdout under JSON=1: $output"
	local report
	report=$(ls "$work"/dist/reports/run-*.txt | head -1)
	grep -q "clip(s)" "$report" || fail "the report lost its header line"
	grep -q "gamma=" "$report" || fail "the report lost the per-clip plan"
}

@test "the YAVG placeholder does not produce invalid JSON" {
	# MATCH=0 leaves YAVG as a literal "-", which a laxer numeric test emits bare as `"yavg":-`.
	# One path, invalid on that path only, and nothing else in the suite would have run it.
	local work="$BATS_TEST_TMPDIR/json-dash"
	mkdir -p "$work/src"
	cp "$FIXTURES/portrait_tagged.mov" "$work/src/CLIP.mov"
	JSON=1 DRY=1 MATCH=0 STAB=0 GRADE_WORK_DIR="$work" \
		run --separate-stderr "$SCRIPTS/grade.sh" "$work/src/CLIP.mov"
	[[ "$output" == *'"yavg":"-"'* ]] || fail "expected a quoted placeholder: $output"
}

@test "every refusal names a code on stderr, beside the human sentence" {
	local work="$BATS_TEST_TMPDIR/codes"
	mkdir -p "$work/src"
	cp "$FIXTURES/portrait_tagged.mov" "$work/src/A.mov"
	cp "$FIXTURES/portrait_tagged.mov" "$work/src/B.mov"

	# A Feed crop across several clips: the offset is a per-clip framing call.
	FEED=1 GRADE_WORK_DIR="$work" run "$SCRIPTS/grade.sh" "$work/src/A.mov" "$work/src/B.mov"
	[ "$status" -ne 0 ]
	[[ "$output" == *"GRADE_CODE=REFUSE_FEED_NO_CROP_Y"* ]] || fail "unnamed refusal: $output"
	[[ "$output" == *"REFUSING: FEED=1"* ]] || fail "the human sentence was replaced, not kept"

	# A missing argument, and no arguments at all.
	GRADE_WORK_DIR="$work" run "$SCRIPTS/grade.sh" "$work/src/NOPE.mov"
	[[ "$output" == *"GRADE_CODE=REFUSE_NOT_FOUND"* ]] || fail "unnamed not-found: $output"
	GRADE_WORK_DIR="$work" run "$SCRIPTS/grade.sh"
	[[ "$output" == *"GRADE_CODE=REFUSE_NO_ARGS"* ]] || fail "unnamed usage error: $output"
}

@test "a skipped clip and a missing transform are both named" {
	local work="$BATS_TEST_TMPDIR/codes2"
	mkdir -p "$work/src"
	cp "$FIXTURES/landscape_tagged.mov" "$work/src/WIDE.mov"
	cp "$FIXTURES/portrait_tagged.mov" "$work/src/TALL.mov"
	# STAB=1 with no transform is the degraded state the engine already prints about; a wrapper has
	# to be able to surface it, because it is the one decision that costs ~65s per clip to get
	# wrong and it used to be made silently.
	DRY=1 MATCH=0 GRADE_WORK_DIR="$work" run "$SCRIPTS/grade.sh" "$work/src"
	[ "$status" -eq 0 ]
	[[ "$output" == *"GRADE_CODE=REFUSE_NOT_PORTRAIT"* ]] || fail "unnamed skip: $output"
	[[ "$output" == *"GRADE_CODE=NO_TRANSFORM"* ]] || fail "unnamed missing transform: $output"
}

@test "the event stream accounts for every clip in the run" {
	# A wrapper drives a queue off these events, so a dropped one shows up as a clip that never
	# finishes. One skipped and one planned, from a folder argument.
	local work="$BATS_TEST_TMPDIR/json-batch"
	mkdir -p "$work/src"
	cp "$FIXTURES/landscape_tagged.mov" "$work/src/WIDE.mov"
	cp "$FIXTURES/portrait_tagged.mov" "$work/src/TALL.mov"
	JSON=1 DRY=1 MATCH=0 STAB=0 GRADE_WORK_DIR="$work" \
		run --separate-stderr "$SCRIPTS/grade.sh" "$work/src"
	[ "$status" -eq 0 ]
	local planned skipped
	planned=$(printf '%s\n' "$output" | grep -c '"event":"clip_planned"' || true)
	skipped=$(printf '%s\n' "$output" | grep -c '"event":"clip_skipped"' || true)
	[ "$planned" -eq 1 ] || fail "expected 1 clip_planned, got $planned:$output"
	[ "$skipped" -eq 1 ] || fail "expected 1 clip_skipped, got $skipped:$output"
	[[ "$output" == *'"skipped":1'* ]] || fail "run_done did not count the skip: $output"
}

@test "a render reports progress, through the one chokepoint every path uses" {
	# render_delivery is where grade.sh, 03-final.sh and the proof path all end up, so a bar in the
	# app needs instrumenting exactly here and nowhere else. Every ffmpeg call in this pipeline runs
	# at -v error and none used -progress, so there was no signal at all to read.
	local out="$BATS_TEST_TMPDIR/prog.mp4"
	JSON=1 run render_delivery "$out" "encode" \
		-y -f lavfi -i "color=c=gray:s=64x128:d=1:r=24" \
		-filter_complex "[0:v]${DELIVERY_SETPARAMS}[o]" -map "[o]" \
		-c:v libx264 -pix_fmt yuv420p
	[ "$status" -eq 0 ]
	[ -s "$out" ]
	[[ "$output" == *'"event":"progress"'* ]] || fail "no progress events: $output"
	[[ "$output" == *'"state":"end"'* ]] || fail "the stream never reported completion: $output"
	printf '%s\n' "$output" | python3 -c '
import json, sys
for line in sys.stdin.read().splitlines():
    if line.strip(): json.loads(line)
' || fail "progress broke the one-object-per-line contract:$output"
}

@test "a failed render reports and cleans up identically on both paths" {
	# The JSON path pipes ffmpeg, which moves the exit status out of $? and into PIPESTATUS. Taken
	# the naive way, `pipefail` aborts the function at the pipeline instead of returning: the caller
	# gets a bare abort rather than a verdict, and the staging file is left for the next run.
	#
	# RUN UNDER PRODUCTION CONDITIONS, not through bats `run`. `run` disables errexit so it can
	# capture a status, which hides this entire failure class — the first version of this test
	# stayed green against the naive code for exactly that reason. A subshell that sources lib.sh
	# gets lib.sh's own `set -euo pipefail`, which is what grade.sh actually renders under.
	local out="$BATS_TEST_TMPDIR/keep.mp4" mode rc text
	ffmpeg -v error -y -f lavfi -i "color=c=red:s=64x128:d=0.1:r=24" -frames:v 1 \
		-c:v libx264 -pix_fmt yuv420p "$out"
	local before; before=$(md5 -q "$out")
	for mode in 0 1; do
		rc=0
		text=$(JSON=$mode bash -c '
			source "$1/lib.sh"
			render_delivery "$2" doomed -y -f lavfi -i "color=c=gray:s=64x128:d=0.1:r=24" \
				-filter_complex "[0:v]nosuchfilter[o]" -map "[o]" -c:v libx264
		' _ "$SCRIPTS" "$out" 2>&1) || rc=$?
		[ "$rc" -ne 0 ] || fail "JSON=$mode: a broken graph reported success"
		[ "$(md5 -q "$out")" = "$before" ] || fail "JSON=$mode: the existing file was damaged"
		[[ "$text" == *"doomed FAILED (ffmpeg error)"* ]] \
			|| fail "JSON=$mode: no verdict, just an abort: $text"
		[ ! -f "$BATS_TEST_TMPDIR/keep.partial.mp4" ] \
			|| fail "JSON=$mode: a staging file was left behind"
	done
}
