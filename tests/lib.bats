#!/usr/bin/env bats
# Tests for scripts/lib.sh — the safety layer.
#
# WHY THIS FILE EXISTS. Every helper in lib.sh was written in response to a real incident, and
# then two of them shipped BROKEN and stayed broken because nothing ever exercised them:
#
#   - `safe_retag` died on every call with "unbound variable" (bash 3.2 + `set -u` + an empty
#     array), silently skipping the retag it exists to perform and leaving files mistagged.
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

# TWO TAGS, and scripts/check.sh is what reads them.
#
#   slow    left out by `check.sh --fast`. A test measured at three seconds or more on this machine:
#           the app builds, and renders or probes of real footage. Time a new one with
#           `bats --timing -f '<name>' tests/` rather than guessing.
#   serial  kept out of the parallel pass, because it writes a path another test writes too. The two
#           make-app.sh tests both rebuild dist/LogGrade.app, and one asserts on its contents while
#           the other can be halfway through replacing it. Tag any new test that writes outside
#           $BATS_TEST_TMPDIR.
#
# A serial test runs alongside the parallel pass, one at a time, not after it: those tests
# conflict with each other, not with the rest, and waiting for the builds would give back most of
# what the parallel pass saves.
#
# WAIT FOR A CONDITION, NEVER A DURATION. A fixed 1.5s sleep held serially and failed the first
# parallel run, under load.

# Fails unless every non-blank line on stdin parses as JSON on its own. python3 rather than a grep
# for braces: a shape test would pass on `{"event":"x",}`.
_json_lines() {  # printf '%s\n' "$output" | _json_lines
	python3 -c '
import json, sys
for i, line in enumerate(sys.stdin.read().splitlines(), 1):
    if not line.strip(): continue
    try: json.loads(line)
    except Exception as e: sys.exit("line %d is not JSON (%s): %s" % (i, e, line))
'
}

# A work dir holding CLIP.mov and a transform measured BEFORE it changed. Stamped rather than
# touched: bash 3.2's -nt compares whole seconds, so same-second files would make a freshness test
# pass for the wrong reason.
_stale_transform() {  # _stale_transform <work>
	mkdir -p "$1/src" "$1/.loggrade/stabilisation"
	cp "$FIXTURES/portrait_tagged.mov" "$1/src/CLIP.mov"
	printf 'measured before the source changed\n' > "$1/.loggrade/stabilisation/CLIP.trf"
	touch -t 202609010000 "$1/.loggrade/stabilisation/CLIP.trf"
	touch -t 202609020000 "$1/src/CLIP.mov"
}

setup_file() {
	command -v ffmpeg >/dev/null || skip "ffmpeg not installed"
	export FIXTURES="$BATS_FILE_TMPDIR/fixtures"
	mkdir -p "$FIXTURES"

	# Tiny synthetic clips — one frame each, so the suite stays fast.
	#
	# 72x128 IS 9:16 EXACTLY, and that is load-bearing rather than arbitrary. These were 64x128,
	# i.e. 1:2, for as long as the 9:16 deliverable took no crop: the delivery chain simply scaled
	# them and quietly changed their aspect. Now that a deliverable is an ASPECT, a source that is
	# not 9:16 gets cropped to reach it — correct, and it would make every fixture here exercise a
	# crop path the real 2160x3840 camera source never takes.
	#
	# How they are tagged is not obvious, and is explained in the builder shared with
	# tests/make-event-fixture.sh.
	source "$BATS_TEST_DIRNAME/fixture-clip.sh"
	# TWO SECONDS, and three distinct luma levels. The exposure probe seeks to 1s, so a 0.1s clip
	# measures nothing at all — which is why the fixtures above cannot exercise the exposure match
	# and every test that uses them passes MATCH=0. These can, and the three levels are what make a
	# median a median rather than "the only value there was".
	# The level is a HEX COLOUR, not `gray@n`: the `@n` suffix is ALPHA, so three clips built that
	# way are three identical greys and a median test over them proves nothing. Caught by a test
	# that asserted the middle clip was the anchor and found all three reading 552.
	_mk_probeable() {  # _mk_probeable <hex grey> <w> <h> <out> [rate]
		ffmpeg -y -f lavfi -i "color=c=$1:s=${2}x${3}:d=2:r=${5:-24}" \
			-frames:v $(( 2 * ${5:-24} )) -c:v prores_ks -profile:v 3 -pix_fmt yuv422p10le \
			"$4" -v error
	}
	_mk_probeable 0x303030 72 128 "$FIXTURES/probe_dark.mov"
	_mk_probeable 0x808080 72 128 "$FIXTURES/probe_mid.mov"
	_mk_probeable 0xc0c0c0 72 128 "$FIXTURES/probe_bright.mov"
	# At a rate FPS_OUT=12 cannot divide AND measurable, so that a clip which gets skipped still
	# occupies a slot carrying a distinctly different exposure. A skipped clip whose probe came back
	# empty cannot tell a misaligned index from a correct one — the alignment test passed against a
	# removed guard for exactly that reason.
	_mk_probeable 0x303030 72 128 "$FIXTURES/probe_dark_25fps.mov" 25
	_mk_probeable 0x808080 128 72 "$FIXTURES/probe_mid_landscape.mov"

	make_tagged_clip 72 128 bt709 bt709 bt709 "$FIXTURES/portrait_tagged.mov"
	make_tagged_clip 128 72 bt709 bt709 bt709 "$FIXTURES/landscape_tagged.mov"
	# Deliberately MIStagged as bt2020 — the "bleached out" state this pipeline exists to prevent.
	make_tagged_clip 72 128 bt2020 bt709 bt2020nc "$FIXTURES/portrait_bt2020.mov"
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

# The first real clip wherever the pipeline itself would look for footage, or nothing.
# resolve_work_dir, not the repo's src/: three tests looked only in the repo, so with media kept
# outside it (ADR 0006's .workdir) they skipped — one of them the only render of the production
# graph on real footage — while the tests beside them ran.
_real_clip() {
	local work
	work=$(resolve_work_dir "$BATS_TEST_DIRNAME/.." 2>/dev/null) || work="$BATS_TEST_DIRNAME/.."
	ls "$work"/src/*.mov 2>/dev/null | head -1 || true
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

# --- source_frame_size -------------------------------------------------------

@test "source_frame_size refuses a clip it cannot measure" {
	# Every crop is computed from the measurement, so "I could not tell" must land on refuse. It did not: an empty dimension makes the numeric test
	# ERROR, and an `if` reads an erroring condition as false, so the clip was accepted. Same
	# fail-open shape as the trailing comma on this camera's csv output, which is what this guard
	# was written to replace in the first place.
	#
	# A tool that answers nothing is the honest way to reproduce it. It shadows ffmpeg now rather
	# than ffprobe: the measurement used to write a PNG and ffprobe it, and reads the decoded
	# frame's own size from showinfo instead — so the decode and the measurement are one step and
	# there is no longer a way to lose only the second half.
	local bin="$BATS_TEST_TMPDIR/stub-bin"
	mkdir -p "$bin"
	printf '#!/bin/sh\nexit 0\n' > "$bin/ffmpeg"
	chmod +x "$bin/ffmpeg"
	PATH="$bin:$PATH" run source_frame_size "$FIXTURES/portrait_tagged.mov"
	[ "$status" -ne 0 ] || fail "measured a frame nothing decoded: $output"
	[[ "$output" == *"could not measure a decoded frame"* ]] || fail "not refused by the guard: $output"
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
	local real
	real="$(_real_clip)"; [ -n "$real" ] || skip "no source footage"
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
	local real
	real="$(_real_clip)"; [ -n "$real" ] || skip "no source footage"
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
	# grade.sh calls this BEFORE `mkdir -p`, so on a first run into a fresh work dir the path is
	# absent. df then fails, the arithmetic expansion gets an empty operand, and the run dies
	# with a bash syntax error instead of a disk verdict — a guard that aborts the run it was
	# meant to protect.
	run check_disk_space "$BATS_TEST_TMPDIR/not-yet/export" 1
	[ "$status" -eq 0 ]
	[[ "$output" == *"available in $BATS_TEST_TMPDIR/not-yet/export"* ]] || fail "[[ \"$output\" == *\"available in $BATS_TEST_TMPDIR/not-yet/export\"* ]]"
	[[ "$output" != *"syntax error"* ]] || fail "[[ \"$output\" != *\"syntax error\"* ]]"
}

# bats test_tags=slow
# Every dated export folder in a work dir, one per line; nothing when there is none.
_exports() {  # _exports <work>
	find "$1" -maxdepth 1 -type d -name 'LogGrade export *' 2>/dev/null
}

# bats test_tags=slow
@test "a run exports into one dated folder, and keeps everything else hidden" {
	local work="$BATS_TEST_TMPDIR/layout" exports
	mkdir -p "$work/src"
	cp "$FIXTURES/probe_mid.mov" "$work/src/CLIP.mov"
	MATCH=0 STAB=0 HEIGHT=128 GRADE_WORK_DIR="$work" run "$SCRIPTS/grade.sh" "$work/src/CLIP.mov"
	[ "$status" -eq 0 ] || fail "render failed: $output"
	exports="$(_exports "$work")"
	[ "$(printf '%s\n' "$exports" | grep -c .)" = 1 ] || fail "not one export folder: $(ls -A "$work")"
	[[ "$(basename "$exports")" =~ ^LogGrade\ export\ [0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}\.[0-9]{2}$ ]] \
		|| fail "not named for when it started: $exports"
	[ -s "$exports/CLIP_reels-stories_9x16.mp4" ] || fail "the deliverable is not in it: $(ls -A "$exports")"
	[ "$(ls -A "$exports")" = "CLIP_reels-stories_9x16.mp4" ] || fail "more than deliverables: $(ls -A "$exports")"
	# Beside the export and the footage, only the hidden working folder.
	[ "$(ls "$work" | grep -vxF src | grep -vxF "$(basename "$exports")")" = "" ] \
		|| fail "visible litter in the work dir: $(ls "$work")"
	[ -n "$(ls "$work"/.loggrade/reports/run-*.txt 2>/dev/null)" ] || fail "no report in .loggrade: $(ls -A "$work")"
}

@test "LOGGRADE_CACHE moves every working file out of the work dir" {
	# The app points it under ~/Library/Caches: the user found hidden folders in their footage.
	local work="$BATS_TEST_TMPDIR/cache-elsewhere" other="$BATS_TEST_TMPDIR/another-shoot"
	local root="$BATS_TEST_TMPDIR/caches" a b
	mkdir -p "$work/src"
	cp "$FIXTURES/portrait_tagged.mov" "$work/src/CLIP.mov"
	LOGGRADE_CACHE="$root" MATCH=0 STAB=0 DRY=1 GRADE_WORK_DIR="$work" run "$SCRIPTS/grade.sh" "$work/src/CLIP.mov"
	[ "$status" -eq 0 ] || fail "$output"
	[ ! -e "$work/.loggrade" ] || fail "a .loggrade was still made in the work dir: $(ls -A "$work/.loggrade")"
	[ -n "$(ls "$root"/*/reports/run-*.txt 2>/dev/null)" ] || fail "no report under the cache: $(ls -R "$root" 2>&1)"
	# One folder per work dir under one root: two shoots' IMG_0609 must not share a transform.
	a="$(LOGGRADE_CACHE="$root" transform_path "$work" CLIP)"
	b="$(LOGGRADE_CACHE="$root" transform_path "$other" CLIP)"
	[[ "$a" == "$root/"*"/stabilisation/CLIP.trf" ]] || fail "the transform path ignored the cache: $a"
	[ "$a" != "$b" ] || fail "two work dirs share one cache: $a"
}

@test "grade.sh checks free space on the volume it writes to" {
	# The work dir is opt-in, and a disk check asking about the REPO's volume while writing to the
	# work dir's is invisible locally, where the two are the same path. Point the work dir
	# somewhere else and the two separate.
	local work="$BATS_TEST_TMPDIR/elsewhere"
	mkdir -p "$work/src"
	cp "$FIXTURES/portrait_tagged.mov" "$work/src/CLIP.mov"
	GRADE_WORK_DIR="$work" DRY=1 MATCH=0 STAB=0 run "$SCRIPTS/grade.sh" "$work/src/CLIP.mov"
	[[ "$output" == *"available in $work"* ]] \
		|| fail "grade.sh measured no volume at all: $output"
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
# This function decides WHERE a run reads and writes. Two shipped defects traced back to it
# being untested: disk checks measured the repo's volume while writing to the work dir's, and
# grade.sh resolved its stabilisation cache two levels off. Neither was visible locally,
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
# from lib.sh and every script died on the first line with "command not found". shellcheck
# does not run the code, and the unit tests only call the
# handful of functions they cover — so nothing noticed the pipeline was completely broken.
#
# A suite that cannot detect "the program does not start" is not a suite.

@test "lib.sh defines every function grade.sh calls" {
	# DERIVED, NOT LISTED. This used to hardcode ten names and was not updated when the delivery
	# chain moved into lib.sh, so it silently stopped covering six of the sixteen, among them
	# source_fps, stab_prefix, delivery_image_chain and render_delivery, the one that protects
	# approved deliverables. A test named for "every
	# function" that checks a fixed subset is the coverage-shaped hole CLAUDE.md rules out.
	#
	# So the names come from the script: every word in COMMAND POSITION in grade.sh — line start, after `$(`, a pipe, `&&`, `||`, `;`, or a keyword — minus the functions
	# a script defines for itself. Each must resolve to something after lib.sh is sourced (setup()
	# does that); a helper renamed on one side only resolves to nothing. Line-start words followed by
	# `|` or `)` are case patterns, and a continuation line is an argument list, so both are read for
	# `$(` calls only — except the command after a one-line case arm's `)`, which is a real call.
	local fn missing="" called own
	called=$(perl -ne '
		my $cont = $prev_cont; $prev_cont = /\\$/;
		next if /^\s*#/;
		my $w = qr/([a-z_][a-z0-9_]*)(?![a-z0-9_]|\+?=|\()/;
		while (/(?:\$\(|\s(?:\||\|\||&&|;)\s+|(?:^\s*|;\s*)(?:if|elif|then|else|do|while|until|!)\s+)$w/g) { print "$1\n" }
		print "$1\n" if !$cont && /^\s*([a-z_][a-z0-9_]*)(?![a-z0-9_]|\+?=|\(|\||\))/;
		print "$1\n" if /^\s*(?:&&|\|\|)\s+([a-z_][a-z0-9_]*)/;
		print "$1\n" if /;;\s*$/ && /\)\s+([a-z_][a-z0-9_]*)(?![a-z0-9_]|\+?=|\()/;
	' "$SCRIPTS"/grade.sh | sort -u)
	own=$(grep -hoE '^[[:space:]]*[a-z_]+\(\)' "$SCRIPTS"/grade.sh | tr -d '() \t' || true)

	# The extraction has to be seen to work, or a pattern that matches nothing passes green: every
	# lib.sh function grade.sh names outside a comment must be among the calls it found.
	# Here-strings rather than pipes into `grep -q`: under pipefail the writer can die of SIGPIPE
	# when grep exits on its first match, and the lookup then reads as "not found".
	local code
	code=$(grep -vhE '^[[:space:]]*#' "$SCRIPTS"/grade.sh)
	for fn in $(grep -oE '^[a-z_]+\(\)' "$SCRIPTS/lib.sh" | tr -d '()'); do
		grep -qw "$fn" <<< "$code" || continue
		grep -qx "$fn" <<< "$called" || missing="$missing $fn"
	done
	[ -z "$missing" ] || fail "the call extraction missed lib.sh functions the scripts use:$missing"
	for fn in render_deliverables grade_chain source_frame_size deliverable_crops crop_description; do
		grep -qx "$fn" <<< "$called" || fail "the call extraction did not find $fn: $called"
	done

	for fn in $called; do
		grep -qx "$fn" <<< "$own" && continue
		[ -n "$(type -t "$fn")" ] || missing="$missing $fn"
	done
	[ -z "$missing" ] || fail "grade.sh calls names nothing defines:$missing"
}

@test "grade.sh starts and reports a missing clip rather than dying" {
	run "$SCRIPTS/grade.sh" __NO_SUCH_CLIP__
	# It must fail on the MISSING CLIP, not on a broken script.
	[[ "$output" != *"command not found"* ]] || fail "$output"
	[[ "$output" != *"unbound variable"* ]]  || fail "$output"
	[[ "$output" == *"not found"* ]]         || fail "gave: $output"
}

@test "grade.sh reports usage when given NO arguments" {
	# The test above asserts "unbound variable" never appears, which is exactly what a bare `$1`
	# under `set -u` produces — but it always passes an argument, so it cannot see it.
	run "$SCRIPTS/grade.sh"
	[ "$status" -ne 0 ] || fail "exited 0 with no arguments"
	[[ "$output" != *"unbound variable"* ]] || fail "died on \$1 instead of saying usage: $output"
	[[ "$output" == *"usage:"* ]] || fail "gave no usage line: $output"
}

# bats test_tags=slow
@test "grade.sh plans a real clip end to end (dry run)" {
	local src
	src="$(_real_clip)"; [ -n "$src" ] || skip "no source footage"
	# Real footage in, but the OUTPUT goes to a temp dir. Without GRADE_WORK_DIR this ran against
	# the repo root, so every check.sh run left a .loggrade/reports/run-*.txt and a per-clip cube
	# in the tree someone actually delivers from — 38 report files had accumulated.
	mkdir -p "$BATS_TEST_TMPDIR/dryrun"
	GRADE_WORK_DIR="$BATS_TEST_TMPDIR/dryrun" DRY=1 run "$BATS_TEST_DIRNAME/../scripts/grade.sh" "$src"
	[ "$status" -eq 0 ]
	[[ "$output" == *"clip(s)"* ]] || fail "[[ \"$output\" == *\"clip(s)\"* ]]"
	[[ "$output" != *"command not found"* ]] || fail "[[ \"$output\" != *\"command not found\"* ]]"
}

@test "grade.sh reuses the transform already in the cache" {
	# grade.sh reassigned WORK from the work-dir root to its own scratch dir, then built the
	# transform path from the reassigned value — landing two levels off, at
	# <work>/.loggrade/work/.loggrade/stabilisation/. So it never saw a transform it had already
	# computed and silently paid ~65s per clip to redo it. One name doing two jobs.
	#
	# Transforms are motion-only and survive a re-grade, so one cache is correct. Content here is
	# irrelevant: this asserts the PATH transform_path spells, not the warp.
	local work="$BATS_TEST_TMPDIR/gwork"
	mkdir -p "$work/src" "$work/.loggrade/stabilisation"
	cp "$FIXTURES/portrait_tagged.mov" "$work/src/CLIP.mov"
	printf 'stand-in for a real transform\n' > "$work/.loggrade/stabilisation/CLIP.trf"
	GRADE_WORK_DIR="$work" DRY=1 MATCH=0 run "$SCRIPTS/grade.sh" "$work/src/CLIP.mov"
	[ "$status" -eq 0 ]
	[[ "$output" == *"$work/.loggrade/stabilisation/CLIP.trf"* ]] \
		|| fail "grade.sh did not find the shared transform: $output"
}

@test "a transform older than its source is not reused" {
	# Transforms are measured against the DECODED frame, so re-orienting a source invalidates its
	# transform: the file then describes motion in a frame that no longer exists. Once the cache is
	# reused (above), a stale entry is silently reused too — the warp fights footage it was never
	# measured on.
	local work="$BATS_TEST_TMPDIR/stale"
	_stale_transform "$work"
	GRADE_WORK_DIR="$work" DRY=1 MATCH=0 run "$SCRIPTS/grade.sh" "$work/src/CLIP.mov"
	[ "$status" -eq 0 ]
	[[ "$output" == *"stale"* ]] \
		|| fail "grade.sh reused a stale transform: $output"
	[[ "$output" != *"stabilising from"* ]] || fail "[[ \"$output\" != *\"stabilising from\"* ]]"
}

@test "grade.sh takes its look values from look.json, not from itself" {
	# "Look values live in look.json, never hardcoded in a script" is a settled rule, and the
	# production path once broke it by carrying its own copy of a whole block — the
	# two-copies-one-edited failure that look() exists to end, one layer up.
	local work="$BATS_TEST_TMPDIR/lookwork" look="$BATS_TEST_TMPDIR/other-look.json"
	mkdir -p "$work/src"
	cp "$FIXTURES/portrait_tagged.mov" "$work/src/CLIP.mov"
	# A grain strength nothing in the repo contains, so a pass can only come from reading this file.
	#
	# DERIVED from the real look.json rather than written out here. look() has no fallbacks, so the
	# key set is a contract — and a hand-written copy of it goes stale the moment a key is added.
	python3 - "$BATS_TEST_DIRNAME/../look.json" "$look" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d["grain"]["strength"] = 17
json.dump(d, open(sys.argv[2], "w"))
PY
	LOOK_FILE="$look" GRADE_WORK_DIR="$work" DRY=1 MATCH=0 STAB=0 \
		run env -u GRAIN_STRENGTH "$SCRIPTS/grade.sh" "$work/src/CLIP.mov"
	[ "$status" -eq 0 ]
	[[ "$output" == *"grain=17"* ]] \
		|| fail "grade.sh ignored look.json's grain: $output"
}

@test "safe_retag leaves a correctly tagged file untouched" {
	# Encoders don't reliably STAMP the tags, which is why safe_retag exists — but they don't
	# reliably get them wrong either, and the function remuxed unconditionally: a full read and
	# write of the file to change nothing.
	#
	# Inode, not mtime: a remux writes a temp file and moves it over the original, so the inode
	# changes even when the bytes would not.
	local f="$BATS_TEST_TMPDIR/already-ok.mov" before after
	cp "$FIXTURES/portrait_tagged.mov" "$f"
	before=$(stat -f%i "$f")
	run safe_retag "$f"
	[ "$status" -eq 0 ]
	after=$(stat -f%i "$f")
	[ "$before" = "$after" ] || fail "rewrote a file that was already correct"
	# ...and it must still report the verdict, not fall silent.
	[[ "$output" == *"tags OK"* ]] || fail "[[ \"$output\" == *\"tags OK\"* ]]"
}

@test "scale_transform scales a transform's pixels and nothing else" {
	local trf="$BATS_TEST_TMPDIR/t.trf"
	printf 'VID.STAB 1\n#      accuracy = 15\nFrame 1 (List 0 [])\nFrame 2 (List 2 [(LM -3 5 864 216 112 0.921565 1.826291),(LM 0 1 702 340 111 0.5 4.6)])\n' > "$trf"
	run scale_transform "$trf" 2
	[ "$status" -eq 0 ] || fail "$output"
	[ "$(printf '%s\n' "$output" | sed -n 4p)" = "Frame 2 (List 2 [(LM -6 10 1728 432 224 0.921565 1.826291),(LM 0 2 1404 680 222 0.5 4.6)])" ] \
		|| fail "doubled: $output"
	[ "$(printf '%s\n' "$output" | sed -n 1,3p)" = "$(sed -n 1,3p "$trf")" ] || fail "other lines changed: $output"
	# Halves round away from zero, symmetrically, so a sway left is the mirror of a sway right.
	run scale_transform "$trf" 0.5
	[ "$(printf '%s\n' "$output" | sed -n 4p)" = "Frame 2 (List 2 [(LM -2 3 432 108 56 0.921565 1.826291),(LM 0 1 351 170 56 0.5 4.6)])" ] \
		|| fail "halved: $output"
}

# bats test_tags=slow
@test "a stabilised render detects at half size in source pixels, and warps the shrunk frame" {
	local work="$BATS_TEST_TMPDIR/stab" report trf w
	mkdir -p "$work/src"
	# Detail that sways, big enough for vid.stab's fields at half size; tagged the way
	# make_tagged_clip tags, in a separate remux.
	ffmpeg -y -v error -f lavfi -i "testsrc2=s=520x904:r=24:d=1" \
		-vf "crop=480:864:x='20+12*sin(n*0.7)':y='20+12*cos(n*0.9)'" \
		-c:v prores_ks -profile:v 3 -pix_fmt yuv422p10le "$work/raw.mov"
	ffmpeg -y -v error -i "$work/raw.mov" -map 0:v:0 -c copy \
		-color_primaries bt709 -color_trc bt709 -colorspace bt709 "$work/src/CLIP.mov"
	CROP_OFFSET=centre MATCH=0 STAB=1 HEIGHT=128 PROOF=0.5 GRADE_WORK_DIR="$work" run "$SCRIPTS/grade.sh" "$work/src/CLIP.mov"
	[ "$status" -eq 0 ] || fail "render failed: $output"
	trf="$work/.loggrade/stabilisation/CLIP.trf"
	[ "$(head -1 "$trf")" = "VID.STAB 1" ] || fail "not an ASCII transform: $(head -c 80 "$trf")"
	# Field positions reach past half the frame only if the half-size analysis was scaled back up.
	w="$(ffprobe -v error -select_streams v:0 -show_entries stream=width -of default=nw=1:nk=1 "$work/src/CLIP.mov" | head -1)"
	grep -oE '\(LM -?[0-9]+ -?[0-9]+ [0-9]+ ' "$trf" | awk -v w="$w" '$4 > w / 2 { found = 1 } END { exit !found }' \
		|| fail "no field beyond half of $w: the transform is in half-size pixels"
	report=$(ls "$work"/.loggrade/reports/run-*.txt 2>/dev/null | head -1) || true
	grep -qE "^\[0:v\]zscale=w=[0-9]+:h=[0-9]+:f=lanczos,vidstabtransform=input='[^']*CLIP_stab_[0-9]+x[0-9]+\.trf'" "$report" \
		|| fail "the warp is not on the shrunk frame: $(grep -F '[0:v]' "$report")"
}

@test "the stabilisation pass reports progress under JSON=1, and prints nothing without it" {
	local clip="$BATS_TEST_TMPDIR/sway.mov"
	ffmpeg -y -v error -f lavfi -i "testsrc2=s=200x200:r=24:d=1" \
		-vf "crop=160:160:x='20+8*sin(n*0.7)':y='20+8*cos(n*0.9)'" -c:v prores_ks "$clip"
	JSON=1 run detect_transform "$clip" "$BATS_TEST_TMPDIR/a.trf"
	[ "$status" -eq 0 ] || fail "detect failed: $output"
	[ "$(head -1 "$BATS_TEST_TMPDIR/a.trf")" = "VID.STAB 1" ] || fail "no transform written"
	[[ "$output" == *'"event":"progress","label":"stabilise"'* ]] || fail "no stabilise progress: $output"
	printf '%s\n' "$output" | _json_lines || fail "progress broke the one-object-per-line contract:$output"
	JSON=0 run detect_transform "$clip" "$BATS_TEST_TMPDIR/b.trf"
	[ "$status" -eq 0 ] && [ -z "$output" ] || fail "the plain path printed: $output"
}

@test "transform_is_fresh refuses when the source it was measured from is gone" {
	# Cannot prove freshness, so do not warp. A stale transform fights footage it was never
	# measured on, which is visibly wrong output; dropping stabilisation is merely less good.
	local trf="$BATS_TEST_TMPDIR/orphan.trf"
	printf 'x\n' > "$trf"
	run transform_is_fresh "$trf" "$BATS_TEST_TMPDIR/no-such-source.mov"
	[ "$status" -ne 0 ]
}

@test "a binary transform from before the ASCII detect is measured again, not rescaled" {
	# scale_transform cannot rescale the binary format, so warping from one would be garbage.
	local src="$BATS_TEST_TMPDIR/src.mov" trf="$BATS_TEST_TMPDIR/bin.trf"
	printf 'x' > "$src"
	printf 'TRF1\000\000\000\001' > "$trf"
	touch -t 202609010000 "$src"; touch -t 202609020000 "$trf"
	run transform_is_fresh "$trf" "$src"
	[ "$status" -ne 0 ] || fail "a binary transform passed as fresh"
	printf 'VID.STAB 1\n' > "$trf"; touch -t 202609020000 "$trf"
	run transform_is_fresh "$trf" "$src"
	[ "$status" -eq 0 ] || fail "an ASCII transform newer than its source was called stale"
}

# --- render_delivery -----------------------------------------------------------

@test "a failed re-render leaves the approved deliverable byte-identical" {
	# `ffmpeg -y` pointed at the delivery path truncates the existing file before it knows whether
	# the graph even initialises. Measured on this repo: an approved mp4 re-rendered with a broken
	# graph was left at 0 bytes, ffmpeg exiting 234. require_nonempty reported the failure loudly
	# and the deliverable was already gone, and getting it back means rendering it again.
	local out="$BATS_TEST_TMPDIR/approved.mp4" before
	ffmpeg -y -f lavfi -i "color=c=gray:s=72x128:d=0.1:r=24" -frames:v 1 \
		-c:v libx264 -pix_fmt yuv420p "$out" -v error
	before=$(md5 -q "$out")

	# A filter graph that fails at initialisation, which is the dangerous shape: ffmpeg has already
	# opened the output by then.
	run render_delivery "$out" "deliberately broken encode" \
		-y -f lavfi -i "color=c=gray:s=72x128:d=0.1:r=24" \
		-filter_complex "[0:v]nosuchfilter=1[o]" -map "[o]" -frames:v 1
	[ "$status" -ne 0 ]
	[ -s "$out" ] || fail "the approved deliverable was destroyed"
	[ "$(md5 -q "$out")" = "$before" ] || fail "the approved deliverable was modified"
	[ ! -f "$BATS_TEST_TMPDIR/approved.partial.mp4" ] || fail "left a staging file behind"
}

@test "render_delivery installs a good render and tags it" {
	local out="$BATS_TEST_TMPDIR/fresh.mp4"
	run render_delivery "$out" "encode" \
		-y -f lavfi -i "color=c=gray:s=72x128:d=0.1:r=24" \
		-filter_complex "[0:v]${DELIVERY_SETPARAMS}[o]" -map "[o]" -frames:v 1 \
		-c:v libx264 -pix_fmt yuv420p
	[ "$status" -eq 0 ]
	[ -s "$out" ]
	run probe_tags "$out"
	[ "$output" = "bt709,bt709,bt709" ]
}

# bats test_tags=slow
@test "the production filter graph renders a real clip end to end" {
	# NOTHING else in this suite executes this graph. shellcheck cannot see inside a filter string
	# — it reported clean on both of the previously shipped load-bearing bugs — and every other
	# grade.sh test stops at DRY=1. So dropping a
	# label here went green and failed three minutes into a 19-clip run, after the render had
	# already truncated the deliverable it was overwriting.
	#
	# Real footage only: a synthetic clip does not have this camera's stream structure, and
	# CLAUDE.md is explicit that tests covering those behaviours must skip rather than fake it.
	local src work out w h
	src=$(_real_clip)
	[ -n "$src" ] || skip "no source footage"
	work="$BATS_TEST_TMPDIR/render"
	mkdir -p "$work"

	# 0.1 seconds through the whole chain: the conversion, grain in the negative, the dithered
	# 10->8 reduction, sharpener.
	# MATCH stays on so the exposure meter runs too.
	PROOF=0.1 STAB=0 GRADE_WORK_DIR="$work" run "$SCRIPTS/grade.sh" "$src"
	[ "$status" -eq 0 ] || fail "$output"
	[[ "$output" == *"metered exposure="* ]] || fail "the exposure meter did not run: $output"

	out=$(ls "$work"/.loggrade/proofs/*.mp4 2>/dev/null | head -1) || true
	[ -n "$out" ] || fail "no proof was written: $output"
	w=$(ffprobe -v error -select_streams v:0 -show_entries stream=width -of default=nw=1:nk=1 "$out" | head -1)
	h=$(ffprobe -v error -select_streams v:0 -show_entries stream=height -of default=nw=1:nk=1 "$out" | head -1)
	[ "$w" = "1080" ] && [ "$h" = "1920" ] || fail "delivered ${w}x${h}, wanted 1080x1920"
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
	src=$(_real_clip)
	[ -n "$src" ] || skip "no source footage"
	excerpt="$BATS_TEST_TMPDIR/camera-structure.mov"
	# -c copy preserves the [STREAM_GROUP] structure, the repeated stream and the trailing comma.
	# A re-encode does not, which is why the synthetic fixtures cannot cover this.
	ffmpeg -v error -y -t 0.1 -i "$src" -c copy "$excerpt"

	safe_retag "$excerpt" >/dev/null
	run verify_bt709 "$excerpt"
	[ "$status" -eq 0 ] || fail "correctly tagged real file rejected: $output"
	[[ "$output" == *"tags OK"* ]] || fail "[[ \"$output\" == *\"tags OK\"* ]]"
}

@test "probe_tags returns three clean fields on a real camera file" {
	local src
	src=$(_real_clip)
	[ -n "$src" ] || skip "no source footage"
	run probe_tags "$src"
	# Exactly three comma-separated values, no trailing comma, no blank-line artefact.
	[[ "$output" =~ ^[a-z0-9]+,[a-z0-9]+,[a-z0-9]+$ ]] \
		|| fail "probe_tags gave [$output]"
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

@test "every shipped preset is a complete look whose conversion exists" {
	# The app offers presets/ as they are; one missing a key stops its first render, and one naming
	# a cube that is not on disk fails inside ffmpeg.
	local root="$BATS_TEST_DIRNAME/.." preset key missing="" n=0
	for preset in "$root"/presets/*.json; do
		n=$((n + 1))
		for key in $(grep -ho 'look \.[a-z_.]*' "$root"/scripts/*.sh | awk '{print $2}' | sort -u); do
			jq -e "$key" "$preset" >/dev/null 2>&1 || missing="$missing $(basename "$preset"):$key"
		done
		jq -e '.name | strings' "$preset" >/dev/null || missing="$missing $(basename "$preset"):name"
		LOOK_FILE="$preset" resolve_conversion "$(jq -r .convert.cube "$preset")" >/dev/null \
			|| missing="$missing $(basename "$preset"):cube"
	done
	[ "$n" -ge 3 ] || fail "found $n presets"
	[ -z "$missing" ] || fail "incomplete:$missing"
}

@test "resolve_conversion names a rendering or a film cube, and refuses anything else" {
	run resolve_conversion portra160
	[ "$status" -eq 0 ] && [ "$output" = "$LIB_ROOT/luts/film/portra160.cube" ] || fail "film: $output"
	run resolve_conversion neutral
	[ "$status" -eq 0 ] && [ "$output" = "$LIB_ROOT/luts/rendering/neutral.cube" ] || fail "rendering: $output"
	run resolve_conversion portra_nonexistent
	[ "$status" -ne 0 ] || fail "accepted a cube that is not there"
	[[ "$output" == *"nonexistent.cube in luts/rendering/ or luts/film/"* ]] || fail "$output"
	# The name reaches a path and a filter graph.
	run resolve_conversion ../film/portra160
	[ "$status" -ne 0 ] || fail "accepted a path"
	[[ "$output" == *"must be a cube name"* ]] || fail "$output"
	# Apple's cube was a name here until it was dropped; it must not linger as a special case.
	run resolve_conversion apple
	[ "$status" -ne 0 ] || fail "'apple' still resolves to something"
}

@test "the log denoise is absent at 0 and pinned to 10-bit YUV otherwise" {
	run denoise_prefix 0
	[ -z "$output" ] || fail "strength 0 left a filter: $output"
	run denoise_prefix 1
	# Behind an RGB filter these would otherwise run on R, G and B.
	[[ "$output" == "format=yuv444p10le,vaguedenoiser=threshold=8:planes=6,atadenoise="*":s=5," ]] \
		|| fail "$output"
}

@test "the finish follows finish.*: no chroma denoise in delivery, no sharpener at 0, Super 8 at 18 fps" {
	DENOISE_STRENGTH=1 SHARPEN=0 GAUGE=none run delivery_image_chain 1080 1920 "" "" 1 24
	[[ "$output" != *unsharp* ]] || fail "sharpened at 0: $output"
	DENOISE_STRENGTH=0 SHARPEN=1 GAUGE=super8 run delivery_image_chain 1080 1920 "" "" 1 24
	[[ "$output" != *hqdn3d* ]] || fail "a chroma denoise came back with the log denoise off: $output"
	[[ "$output" == *"unsharp=5:5:1:3:3:0.0[sh_sharp]"*"maskedclamp=planes=1:undershoot=2:overshoot=2"* ]] || fail "the limit did not follow the amount: $output"
	# Pinned before the gauge: behind halation the picture is float RGB, where noise goes wild.
	[[ "$output" == *"format=yuv444p10le,scale=w=324:h=576:flags=area"*"fps=18,zscale="* ]] || fail "$output"
	[[ "$output" == *",fps=24" ]] || fail "did not return to the clip's rate: $output"
	[[ "$output" != *"hue=b="* ]] || fail "the frame-to-frame brightness flicker came back: $output"
	# The clamp is in code values: at 10 bits the same tolerance is four times as many.
	DELIVERY_CODEC=hevc10 DENOISE_STRENGTH=0 SHARPEN=1 GAUGE=none run delivery_image_chain 1080 1920 "" "" 1 24
	[[ "$output" == *"undershoot=8:overshoot=8"* ]] || fail "10-bit clamp not scaled: $output"
	# A plain export has no gauge.
	DENOISE_STRENGTH=0 SHARPEN=0.3 GAUGE=super8 run delivery_image_chain 1080 1920 "" "" 0 24
	[[ "$output" != *fps=18* ]] || fail "FINISH=0 kept the gauge: $output"
}

@test "solve-exposure meters a grey frame to the reference and balances a cast out" {
	# One frame of planar float G, B, R, as ffmpeg's gbrpf32le writes it.
	_frame() {  # _frame <r> <g> <b>   linear values
		python3 -c '
import array, sys
sys.path.insert(0, sys.argv[4])
from applelog import encode
r, g, b = (encode(float(v)) for v in sys.argv[1:4])
n = 16 * 16
sys.stdout.buffer.write(array.array("f", [g] * n + [b] * n + [r] * n).tobytes())
' "$1" "$2" "$3" "$LIB_ROOT/scripts"
	}
	local solve="$LIB_ROOT/scripts/solve-exposure.py" stops temp tint
	read -r stops temp tint < <(_frame 0.18 0.18 0.18 | "$solve" 16 16 0)
	[ "$stops" = "0.000" ] && [ "$temp" = "0.000" ] && [ "$tint" = "0.000" ] || fail "grey at reference: $stops $temp $tint"
	# Two stops under: brightened, but damped, not all the way.
	read -r stops temp tint < <(_frame 0.045 0.045 0.045 | "$solve" 16 16 0)
	awk -v s="$stops" 'BEGIN { exit !(s > 0.5 && s < 2) }' || fail "two stops under metered $stops"
	# A warm cast: red up, blue down, so temp comes out negative (cooling).
	read -r stops temp tint < <(_frame 0.2 0.18 0.16 | "$solve" 16 16 0)
	awk -v t="$temp" 'BEGIN { exit !(t < -0.05) }' || fail "a warm cast solved temp $temp"
	# An unreadable frame is no correction, not a failed batch.
	run "$solve" 16 16 0 < /dev/null
	[ "$status" -eq 0 ] && [ "$output" = "0 0 0" ] || fail "empty frame: $status $output"
}

@test "look refuses a missing key rather than substituting a different look" {
	local look="$BATS_TEST_TMPDIR/partial.json"
	printf '{ "finish": { "sharpen": 0.6 } }\n' > "$look"
	LOOK_FILE="$look" run look .grain.strength
	[ "$status" -ne 0 ]
	[[ "$output" == *"missing .grain.strength"* ]] || fail "unhelpful message: $output"
}

@test "no script renders straight to a delivery path" {
	# The behavioural test above proves render_delivery protects the file it replaces. This pins
	# the invariant that every render actually goes through it: `ffmpeg -y` aimed at an output
	# variable truncates the existing file before the graph is known to initialise, and that is
	# how a failed re-render destroys an approved deliverable. It has come back once already, one
	# commit after being fixed elsewhere.
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

@test "render_delivery refuses to install a file it could not tag" {
	# The ffmpeg result and the emptiness check were both guarded with `if !`; the retag was a bare
	# call. That fails open wherever `set -e` is suppressed — including this `run` — and installed a
	# file measuring unknown,unknown,unknown, returning 0. A wrongly tagged file is the
	# double-transform lib.sh exists to prevent.
	local out="$BATS_TEST_TMPDIR/untaggable.mp4"
	safe_retag() { return 1; }     # the remux fails, however it fails
	run render_delivery "$out" "encode" \
		-y -f lavfi -i "color=c=gray:s=72x128:d=0.1:r=24" \
		-filter_complex "[0:v]${DELIVERY_SETPARAMS}[o]" -map "[o]" -frames:v 1 \
		-c:v libx264 -pix_fmt yuv420p
	[ "$status" -ne 0 ] || fail "installed a file it could not tag, and reported success"
	[ ! -e "$out" ] || fail "installed an untagged file at $out"
	[ ! -e "$BATS_TEST_TMPDIR/untaggable.partial.mp4" ] || fail "left a staging file behind"
}

# bats test_tags=slow
@test "a clip whose render fails does not take the rest of the batch with it" {
	# Measured: a two-clip run whose first render failed never attempted the second, printed no
	# summary line, and left the report ending mid-file. grade.sh already skips an unmeasurable clip
	# and continues; a render failure went straight through `set -e` instead. In a 19-clip
	# unattended run a failure at clip 3 silently costs the other 16.
	#
	# The trigger is the documented one: a TRUNCATED .trf stamped newer than its source, so it
	# passes the freshness check, is not re-detected, and then dies deep in the filter graph with
	# "Cannot parse localmotion: unexpected end of file". Only AAA gets one, so BBB is the clip
	# that must still render.
	local work="$BATS_TEST_TMPDIR/batch"
	mkdir -p "$work/src" "$work/.loggrade/stabilisation"
	cp "$FIXTURES/portrait_tagged.mov" "$work/src/AAA.mov"
	cp "$FIXTURES/portrait_tagged.mov" "$work/src/BBB.mov"
	printf 'VID.STAB 1\n\n' > "$work/.loggrade/stabilisation/AAA.trf"
	# bash 3.2's -nt compares whole seconds and these are created inside one, so stamp the order.
	touch -t 202609010000 "$work/src/AAA.mov" "$work/src/BBB.mov"
	touch -t 202609020000 "$work/.loggrade/stabilisation/AAA.trf"

	EXPORT_DIR="$work/export" GRADE_WORK_DIR="$work" MATCH=0 run "$SCRIPTS/grade.sh" "$work/src"
	[[ "$output" == *"FAIL  AAA"* ]] || fail "the failing clip was not reported as failed: $output"
	[ -s "$work/export/BBB_reels-stories_9x16.mp4" ] \
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
	[ -z "$(ls -A "$work")" ] || fail "a usage error created $(find "$work" -mindepth 1 | tr '\n' ' ')"
}

@test "every file path named in prose or in a script actually exists" {
	# Removing rotation left a runbook step telling you to pass an argument that had been silently
	# dropped, and CLAUDE.md's own rule is that deleting a concept means grepping for its name in
	# prose too. A pointer to a moved or deleted file is the same failure one level up, and it is
	# the failure mode a docs layout built on pointers invites — so it gets a guard rather than a
	# convention.
	local root="$BATS_TEST_DIRNAME/.." missing="" ref f
	# Paths that look like repo paths: a directory prefix this repo actually has, then a filename.
	#
	# THE EXTENSION LIST IS ORDERED, and jsonl comes before json on purpose: alternation is
	# first-match, so `json` alone matched `events.jsonl` as `events.json` and then reported a file
	# that does exist as missing. A guard that invents a broken pointer is worse than one that
	# misses a real one, because the next person deletes the guard.
	#
	# -I and the exclusion are load-bearing. A .pyc under tests/__pycache__ embeds the source path
	# it was compiled from, so importing a test helper once was enough to make this guard report
	# generated bytecode as a broken pointer. It greps PROSE and SCRIPTS; binaries and build caches
	# are not its business, and __pycache__ is gitignored, which is the repo already saying so.
	# fixtures/ is excluded because a golden records the files its render READ, as they were when it
	# was measured, and is refreshed only on a deliberate regenerate: a deleted input is history
	# there, not a broken pointer.
	for ref in $(grep -rhoIE --exclude-dir=__pycache__ --exclude-dir=fixtures \
			'(docs|scripts|tests|luts|bench)/[A-Za-z0-9_/.-]+\.(md|sh|py|jsonl|json|cube|html|txt)' \
			"$root"/*.md "$root"/docs "$root"/scripts "$root"/tests 2>/dev/null | sort -u); do
		f="${ref%%[.,)]}"
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
# It matters because neither input is hand-typed. The look file arrives as the app's LOOK_FILE,
# and came before that from the Bench's shared, multi-writer artifact db; a clip FILENAME arrives
# from the camera or from whoever handed over the card. Nothing on the read side checked either one.
#
# Ported from a branch of the precursor that never landed, because it predates the chain dedupe and
# would have reinstated an inlined copy of the graph.

@test "require_number accepts a number and rejects a filter fragment" {
	run require_number EXPOSURE 1.27
	[ "$status" -eq 0 ]
	[ "$output" = "1.27" ]

	run require_number BLACK "-0.08"
	[ "$status" -eq 0 ]

	run require_number EXPOSURE "1.27,metadata=print:file=/tmp/x"
	[ "$status" -ne 0 ]
	[[ "$output" == *"must be numeric"* ]] || fail "unhelpful message: $output"

	run require_number EXPOSURE ""
	[ "$status" -ne 0 ]
	[[ "$output" == *"EXPOSURE must be numeric: got ''"* ]] || fail "empty refused, but not by the guard: $output"
}

@test "require_clip_name refuses a path and refuses filter syntax" {
	run require_clip_name IMG_0609
	[ "$status" -eq 0 ]
	[ "$output" = "IMG_0609" ]

	run require_clip_name "../../escaped"
	[ "$status" -ne 0 ]
	[[ "$output" == *"contains '/'"* ]] || fail "not refused as a path: $output"

	run require_clip_name "IMG_0609'"
	[ "$status" -ne 0 ]
	[[ "$output" == *"ffmpeg reads as filter syntax"* ]] || fail "not refused as filter syntax: $output"

	run require_clip_name ""
	[ "$status" -ne 0 ]
	[[ "$output" == *"empty clip name"* ]] || fail "not refused as empty: $output"
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

@test "grade.sh refuses a non-numeric crop offset" {
	local work="$BATS_TEST_TMPDIR/inj-crop" marker="$BATS_TEST_TMPDIR/crop-written"
	mkdir -p "$work/src"
	cp "$FIXTURES/portrait_tagged.mov" "$work/src/CLIP.mov"
	CROP_OFFSET="750,metadata=print:file=$marker" DELIVERABLES=feed MATCH=0 STAB=0 PROOF=0.1 \
		GRADE_WORK_DIR="$work" run "$SCRIPTS/grade.sh" "$work/src/CLIP.mov"
	[ "$status" -ne 0 ]
	# The words, not just the status: a render that fails for any other reason also exits non-zero
	# and writes no marker.
	[[ "$output" == *"CROP_OFFSET must be numeric"* ]] || fail "not refused at the offset: $output"
	[ ! -f "$marker" ] || fail "the spliced filter ran and wrote $marker"
}

@test "grade.sh refuses an unknown deliverable with its code, before anything is created" {
	# A spec read through a here-string swallows the refusal: the script carries on with empty
	# aspect terms and dies on an arithmetic syntax error, with no code for a wrapper to read.
	local work="$BATS_TEST_TMPDIR/bad-deliv"
	mkdir -p "$work/src"
	cp "$FIXTURES/portrait_tagged.mov" "$work/src/CLIP.mov"
	DELIVERABLES=nope MATCH=0 STAB=0 GRADE_WORK_DIR="$work" run "$SCRIPTS/grade.sh" "$work/src/CLIP.mov"
	[ "$status" -ne 0 ] || fail "accepted an unknown deliverable"
	[[ "$output" == *"REFUSING: unknown deliverable 'nope'"* ]] || fail "not refused by the spec: $output"
	[[ "$output" == *"GRADE_CODE=REFUSE_DELIVERABLE"* ]] || fail "unnamed refusal: $output"
	[[ "$output" != *"syntax error"* ]] || fail "died in arithmetic instead of refusing: $output"
	[ -z "$(ls -A "$work" | grep -vxF src)" ] || fail "created something for a refused deliverable: $(ls -A "$work")"
}

@test "grade.sh refuses a clip whose FILENAME would break the filter graph" {
	# The clip name reaches lut3d=file='...' and vidstabtransform=input='...' via the correction-cube
	# and transform paths, so a quote in it closes ffmpeg's quoting from the inside.
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
	# Derived, so this fails on the hostile VALUE rather than on a key the fixture forgot — which
	# would leave the test green for the wrong reason the next time look.json grows.
	python3 - "$BATS_TEST_DIRNAME/../look.json" "$look" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d["correct"]["saturation"] = "1.27,metadata=print:file=/tmp/pwned"
json.dump(d, open(sys.argv[2], "w"))
PY
	LOOK_FILE="$look" GRADE_WORK_DIR="$work" MATCH=0 STAB=0 \
		run "$SCRIPTS/grade.sh" "$work/src/CLIP.mov"
	[ "$status" -ne 0 ] || fail "rendered with a non-numeric saturation"
	[[ "$output" == *"must be numeric"* ]] || fail "gave no reason: $output"
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
	# Every line, or the stream is not a stream.
	printf '%s\n' "$output" | _json_lines || fail "stdout was not one JSON object per line:$output"
	# This test was merged RED, because a truncated read of the suite output was mistaken for a
	# pass. What it caught on the first honest run was check_disk_space writing its verdict to
	# stdout, so the first line a consumer saw was not JSON at all.
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
	report=$(ls "$work"/.loggrade/reports/run-*.txt 2>/dev/null | head -1) || true
	[ -n "$report" ] || fail "no run report was written: $output"
	grep -q "clip(s)" "$report" || fail "the report lost its header line"
	grep -q "metered exposure=" "$report" || fail "the report lost the per-clip plan"
}

# The report is what a slow or broken render is debugged from afterwards, so what it records has to
# come out of a REAL render: a DRY run never times an encode and never builds the graph. HEIGHT=128
# is what lets a 72x128 fixture finish the delivery chain; at 1080x1920 it fails reinitialising.
# bats test_tags=slow
@test "the run report records the machine, the knobs, the graph and the timing of a real render" {
	local work="$BATS_TEST_TMPDIR/report-proof" look="$BATS_TEST_DIRNAME/../look.json"
	mkdir -p "$work/src"
	cp "$FIXTURES/probe_mid.mov" "$work/src/CLIP.mov"
	# JSON=1 so the same run also proves none of it leaks onto the event stream.
	JSON=1 HEIGHT=128 PROOF=0.5 STAB=0 LOOK_FILE="$look" GRADE_WORK_DIR="$work" \
		run --separate-stderr "$SCRIPTS/grade.sh" "$work/src/CLIP.mov"
	[ "$status" -eq 0 ] || fail "render failed: $output $stderr"
	[[ "$output" != *"took"* ]] || fail "a report line reached the event stream: $output"
	local report
	report=$(ls "$work"/.loggrade/reports/run-*.txt 2>/dev/null | head -1) || true
	[ -n "$report" ] || fail "no run report was written: $output"
	grep -qE '^ffmpeg: +ffmpeg version' "$report" || fail "no ffmpeg version: $(cat "$report")"
	grep -qE '^machine: .*[0-9]+ cores' "$report" || fail "no machine line: $(cat "$report")"
	grep -qE '^look: +.*look\.json sha256:[0-9a-f]{16}$' "$report" || fail "no look hash: $(cat "$report")"
	grep -qE '^knobs: .*deliverables=reels .*height=128 .*proof=0\.5 ' "$report" || fail "no knobs: $(cat "$report")"
	grep -qE 'source: 72x128 at 24/1 fps, 2\.0+s, 48 frames' "$report" || fail "no source facts: $(cat "$report")"
	grep -qE 'exposure meter took [0-9]+\.[0-9]{3}s$' "$report" || fail "meter untimed: $(cat "$report")"
	# 0.5s at 24fps is 12 frames: counted from the file that landed, not assumed from the source.
	grep -qE 'reels-stories_9x16 encode took [0-9]+\.[0-9]{3}s, 12 frames at [0-9.]+ fps, [0-9.]+x realtime, [0-9.]+ Mbit/s' \
		"$report" || fail "no encode speed: $(cat "$report")"
	grep -qE -- '--- graph [0-9]+ \(reels-stories_9x16 encode, -filter_complex\) ---' "$report" \
		|| fail "no delimited filter graph: $(cat "$report")"
	# Matched end to end rather than by its first filter, which a denoise or halation would change,
	# and with the grain's mix before the stock's cube: grain in the negative.
	grep -qE "^\[0:v\].*mix=inputs=4:.*lut3d=file='[^']*neutral\.cube'.*\[o\]$" "$report" \
		|| fail "the graph was not recorded whole, grain before the conversion: $(cat "$report")"
	grep -qE '^finished .*, wall time [0-9]+\.[0-9]{3}s$' "$report" || fail "no wall time: $(cat "$report")"
	grep -qE '^  encode +[0-9]+\.[0-9]{3}s$' "$report" || fail "no phase summary: $(cat "$report")"
}

# Every stage off must be the CST and the delivery shape, with nothing idle left in: an identity
# cube still moves pixels by its interpolation. The whole graph is compared, not a list of absent words, because a leftover format= is a stage too.
# bats test_tags=slow
@test "a look with every stage off renders the CST and nothing else" {
	local work="$BATS_TEST_TMPDIR/all-off" look="$BATS_TEST_TMPDIR/all-off.json"
	mkdir -p "$work/src"
	cp "$FIXTURES/probe_mid.mov" "$work/src/CLIP.mov"
	jq '.correct = {exposure: 0, temp: 0, tint: 0, contrast: 1, saturation: 1}
		| .halation.strength = 0 | .grain.strength = 0' \
		"$BATS_TEST_DIRNAME/../look.json" > "$look"
	LOOK_FILE="$look" MATCH=0 FINISH=0 STAB=0 HEIGHT=128 PROOF=0.5 GRADE_WORK_DIR="$work" \
		run "$SCRIPTS/grade.sh" "$work/src/CLIP.mov"
	[ "$status" -eq 0 ] || fail "render failed: $output"
	local report expected
	report=$(ls "$work"/.loggrade/reports/run-*.txt 2>/dev/null | head -1) || true
	[ -n "$report" ] || fail "no run report was written: $output"
	expected="[0:v]zscale=w=72:h=128:f=lanczos,format=yuv444p10le,lut3d=file='$(resolve_conversion neutral)':interp=tetrahedral,${DELIVERY_SETPARAMS},zscale=w=72:h=128:f=lanczos:d=error_diffusion,format=yuv420p[o]"
	grep -qxF -- "$expected" "$report" \
		|| fail "the all-off graph is not the CST alone: $(grep -F '[0:v]' "$report")"
}

@test "the run report times a preview frame and records its graph" {
	local work="$BATS_TEST_TMPDIR/report-frame"
	mkdir -p "$work/src"
	cp "$FIXTURES/portrait_tagged.mov" "$work/src/CLIP.mov"
	FRAME=0 FRAME_HEIGHT=128 MATCH=0 GRADE_WORK_DIR="$work" \
		run "$SCRIPTS/grade.sh" "$work/src/CLIP.mov"
	[ "$status" -eq 0 ] || fail "frame failed: $output"
	local report
	report=$(ls "$work"/.loggrade/reports/run-*.txt 2>/dev/null | head -1) || true
	[ -n "$report" ] || fail "no run report was written: $output"
	grep -qE 'frame render took [0-9]+\.[0-9]{3}s' "$report" || fail "frame untimed: $(cat "$report")"
	grep -qE -- '--- graph [0-9]+ \(frame, -filter_complex\) ---' "$report" || fail "no frame graph: $(cat "$report")"
	grep -qE '^  frame render +[0-9]+\.[0-9]{3}s$' "$report" || fail "no phase summary: $(cat "$report")"
}

@test "fmt_ms formats whole minutes without losing the milliseconds" {
	[ "$(fmt_ms 4217)" = "4.217s" ] || fail "got $(fmt_ms 4217)"
	[ "$(fmt_ms 7)" = "0.007s" ] || fail "got $(fmt_ms 7)"
	[ "$(fmt_ms 192004)" = "3m12.004s" ] || fail "got $(fmt_ms 192004)"
}

@test "MATCH=0 renders a clip as shot, and says so in the event stream" {
	local work="$BATS_TEST_TMPDIR/json-meter"
	mkdir -p "$work/src"
	cp "$FIXTURES/portrait_tagged.mov" "$work/src/CLIP.mov"
	JSON=1 DRY=1 MATCH=0 STAB=0 GRADE_WORK_DIR="$work" \
		run --separate-stderr "$SCRIPTS/grade.sh" "$work/src/CLIP.mov"
	[[ "$output" == *'"metered_exposure":0'* ]] || fail "metering ran with MATCH=0: $output"
	printf '%s\n' "$output" | _json_lines
}

@test "every refusal names a code on stderr, beside the human sentence" {
	local work="$BATS_TEST_TMPDIR/codes"
	mkdir -p "$work/src"
	cp "$FIXTURES/portrait_tagged.mov" "$work/src/A.mov"
	cp "$FIXTURES/portrait_tagged.mov" "$work/src/B.mov"

	# A Feed crop across several clips: the offset is a per-clip framing call.
	DELIVERABLES=reels,feed GRADE_WORK_DIR="$work" run "$SCRIPTS/grade.sh" "$work/src/A.mov" "$work/src/B.mov"
	[ "$status" -ne 0 ]
	[[ "$output" == *"GRADE_CODE=REFUSE_CROP_NO_OFFSET"* ]] || fail "unnamed refusal: $output"
	[[ "$output" == *"REFUSING: 'feed' crops"* ]] || fail "the human sentence was replaced, not kept"

	# A missing argument, and no arguments at all.
	GRADE_WORK_DIR="$work" run "$SCRIPTS/grade.sh" "$work/src/NOPE.mov"
	[[ "$output" == *"GRADE_CODE=REFUSE_NOT_FOUND"* ]] || fail "unnamed not-found: $output"
	GRADE_WORK_DIR="$work" run "$SCRIPTS/grade.sh"
	[[ "$output" == *"GRADE_CODE=REFUSE_NO_ARGS"* ]] || fail "unnamed usage error: $output"
}

@test "a skipped clip and a missing transform are both named" {
	local work="$BATS_TEST_TMPDIR/codes2"
	mkdir -p "$work/src"
	printf 'not a video\n' > "$work/src/BROKEN.mov"
	cp "$FIXTURES/portrait_tagged.mov" "$work/src/TALL.mov"
	# STAB=1 with no transform is the degraded state the engine already prints about; a wrapper has
	# to be able to surface it, because it is the one decision that costs ~65s per clip to get
	# wrong and it used to be made silently.
	DRY=1 MATCH=0 GRADE_WORK_DIR="$work" run "$SCRIPTS/grade.sh" "$work/src"
	[ "$status" -eq 0 ]
	[[ "$output" == *"GRADE_CODE=REFUSE_UNMEASURED"* ]] || fail "unnamed skip: $output"
	[[ "$output" == *"GRADE_CODE=NO_TRANSFORM"* ]] || fail "unnamed missing transform: $output"
}

@test "the event stream accounts for every clip in the run" {
	# A wrapper drives a queue off these events, so a dropped one shows up as a clip that never
	# finishes. One skipped and one planned, from a folder argument.
	local work="$BATS_TEST_TMPDIR/json-batch"
	mkdir -p "$work/src"
	printf 'not a video\n' > "$work/src/BROKEN.mov"
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
	# render_delivery is where every deliverable and proof grade.sh renders ends up, so a bar in the
	# app needs instrumenting exactly here and nowhere else. Every ffmpeg call in this pipeline runs
	# at -v error and none used -progress, so there was no signal at all to read.
	local out="$BATS_TEST_TMPDIR/prog.mp4"
	JSON=1 run render_delivery "$out" "encode" \
		-y -f lavfi -i "color=c=gray:s=72x128:d=1:r=24" \
		-filter_complex "[0:v]${DELIVERY_SETPARAMS}[o]" -map "[o]" \
		-c:v libx264 -pix_fmt yuv420p
	[ "$status" -eq 0 ]
	[ -s "$out" ]
	[[ "$output" == *'"event":"progress"'* ]] || fail "no progress events: $output"
	[[ "$output" == *'"state":"end"'* ]] || fail "the stream never reported completion: $output"
	printf '%s\n' "$output" | _json_lines || fail "progress broke the one-object-per-line contract:$output"
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
	ffmpeg -v error -y -f lavfi -i "color=c=red:s=72x128:d=0.1:r=24" -frames:v 1 \
		-c:v libx264 -pix_fmt yuv420p "$out"
	local before; before=$(md5 -q "$out")
	for mode in 0 1; do
		rc=0
		text=$(JSON=$mode bash -c '
			source "$1/lib.sh"
			render_delivery "$2" doomed -y -f lavfi -i "color=c=gray:s=72x128:d=0.1:r=24" \
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

# --- the preview frame --------------------------------------------------------
# The app's exact preview. It exists because a slider has to be judged against what the render
# actually produces, and the alternative it replaced — the Bench's pre-baked JPEG — bypassed both
# the real CST and the look LUT, so it mispredicted every reading.

@test "FRAME renders one still through the grade chain and no deliverable" {
	local work="$BATS_TEST_TMPDIR/frame"
	mkdir -p "$work/src"
	cp "$FIXTURES/portrait_tagged.mov" "$work/src/CLIP.mov"
	FRAME=0 FRAME_HEIGHT=128 MATCH=0 GRADE_WORK_DIR="$work" \
		run "$SCRIPTS/grade.sh" "$work/src/CLIP.mov"
	[ "$status" -eq 0 ] || fail "$output"
	local png="$work/.loggrade/frames/CLIP_t0s_graded.png"
	[ -s "$png" ] || fail "no preview frame at $png: $output"
	run ffprobe -v error -select_streams v:0 -show_entries stream=codec_name,height \
		-of default=nw=1:nk=1 "$png"
	[[ "$output" == *"png"* ]] || fail "not a PNG: $output"
	# A preview is not a delivery. Nothing may land where someone uploads from.
	[ -z "$(_exports "$work")" ] || fail "FRAME wrote a deliverable"
}

@test "an ungraded preview decodes once and still matches the separate size, meter and picture" {
	# The one-decode path must be indistinguishable from the steps it replaces. Textured, because a
	# flat grey hid a pixel-format negotiation that moved the meter on real footage (temp -0.013 vs
	# -0.012 on IMG_0444) when both branches shared one split.
	local work="$BATS_TEST_TMPDIR/one-decode" clip ev_one ev_sep field
	mkdir -p "$work/one" "$work/sep"
	clip="$work/TEX.mov"
	ffmpeg -v error -y -f lavfi -i "testsrc2=s=128x72:d=2:r=24" -frames:v 48 \
		-c:v prores_ks -profile:v 3 -pix_fmt yuv422p10le "$clip"
	ev_one="$(FRAME=1 FRAME_HEIGHT=36 FRAME_STAGE=source MATCH=1 JSON=1 STAB=0 \
		GRADE_WORK_DIR="$work/one" "$SCRIPTS/grade.sh" "$clip" 2>/dev/null | grep clip_planned)" \
		|| fail "one-decode preview failed"
	# A size hint turns the one-decode path off, so this run takes the separate steps.
	ev_sep="$(FRAME=1 FRAME_HEIGHT=36 FRAME_STAGE=source MATCH=1 JSON=1 STAB=0 \
		FRAME_SOURCE_SIZE="128 72" GRADE_WORK_DIR="$work/sep" "$SCRIPTS/grade.sh" "$clip" 2>/dev/null \
		| grep clip_planned)" || fail "separate-steps preview failed"
	for field in width height metered_exposure metered_temp metered_tint; do
		[ "$(printf '%s' "$ev_one" | sed -n "s/.*\"$field\":\([-0-9.]*\).*/\1/p")" = \
			"$(printf '%s' "$ev_sep" | sed -n "s/.*\"$field\":\([-0-9.]*\).*/\1/p")" ] \
			|| fail "$field differs: one=$ev_one sep=$ev_sep"
	done
	cmp -s "$work/one/.loggrade/frames/TEX_t1s_source.png" "$work/sep/.loggrade/frames/TEX_t1s_source.png" \
		|| fail "the one-decode picture is not the separate one"
	# A hint outside a preview is refused, so a delivery can never skip measuring its own clip.
	FRAME_METERED="0 0 0" DRY=1 MATCH=0 STAB=0 GRADE_WORK_DIR="$work/sep" run "$SCRIPTS/grade.sh" "$clip"
	[ "$status" -ne 0 ] || fail "a delivery accepted a metering hint"
	[[ "$output" == *"FRAME previews only"* ]] || fail "refused without saying why: $output"
}

@test "FRAME on a landscape clip needs no crop offset, because a still is not cropped" {
	# The live preview asks for a frame with the project's deliverables and no CROP_OFFSET. The
	# up-front crop refusal ran for it anyway, so every landscape clip showed "a crop offset is a
	# per-clip framing call" instead of a picture.
	local work="$BATS_TEST_TMPDIR/frame-wide"
	mkdir -p "$work/src"
	cp "$FIXTURES/landscape_tagged.mov" "$work/src/WIDE.mov"
	DELIVERABLES=reels FRAME=0 FRAME_HEIGHT=72 MATCH=0 STAB=0 GRADE_WORK_DIR="$work" \
		run "$SCRIPTS/grade.sh" "$work/src/WIDE.mov"
	[ "$status" -eq 0 ] || fail "a still was refused: $output"
	[[ "$output" != *"REFUSE_CROP_NO_OFFSET"* ]] || fail "refused a crop for a still: $output"
	[ -s "$work/.loggrade/frames/WIDE_t0s_graded.png" ] || fail "no preview frame: $output"
	[ -z "$(_exports "$work")" ] || fail "FRAME wrote a deliverable"
	# The refusal still stands for what an export would write.
	DELIVERABLES=reels MATCH=0 STAB=0 DRY=1 GRADE_WORK_DIR="$work" \
		run "$SCRIPTS/grade.sh" "$work/src/WIDE.mov"
	[[ "$output" == *"GRADE_CODE=REFUSE_CROP_NO_OFFSET"* ]] || fail "a plan no longer refuses: $output"
}

@test "FRAME_STAGE=source gives the picture with no grade on it at all" {
	# The app's live preview grades this frame itself, so that the correction stage — which runs
	# BEFORE Apple's conversion and therefore cannot be recovered from a converted frame — follows
	# a slider too. If this ever returned the graded frame the preview would apply the whole chain
	# twice and look plausible while being wrong.
	local work="$BATS_TEST_TMPDIR/stage"
	mkdir -p "$work/src"
	cp "$FIXTURES/portrait_tagged.mov" "$work/src/CLIP.mov"
	FRAME=0 FRAME_HEIGHT=128 MATCH=0 GRADE_WORK_DIR="$work" \
		run "$SCRIPTS/grade.sh" "$work/src/CLIP.mov"
	[ "$status" -eq 0 ] || fail "$output"
	FRAME=0 FRAME_HEIGHT=128 MATCH=0 FRAME_STAGE=source GRADE_WORK_DIR="$work" \
		run "$SCRIPTS/grade.sh" "$work/src/CLIP.mov"
	[ "$status" -eq 0 ] || fail "$output"
	local graded="$work/.loggrade/frames/CLIP_t0s_graded.png"
	local source="$work/.loggrade/frames/CLIP_t0s_source.png"
	[ -s "$graded" ] || fail "no graded frame: $output"
	# SEPARATE FILES. One name for both stages meant the second render silently replaced the first,
	# which is how a test in the Swift suite once compared a frame against itself.
	[ -s "$source" ] || fail "no source frame: $output"
	! cmp -s "$graded" "$source" || fail "the source stage rendered the graded chain"
}

@test "FRAME_STAGE refuses a value that is neither stage" {
	# A work dir of its own: without one a broken refusal would render into the repo.
	local work="$BATS_TEST_TMPDIR/frame-stage"
	mkdir -p "$work"
	run env GRADE_WORK_DIR="$work" FRAME=0 FRAME_STAGE=halfway "$SCRIPTS/grade.sh" "$FIXTURES/portrait_tagged.mov"
	[ "$status" -ne 0 ] || fail "an unknown stage was accepted"
	[[ "$output" == *"FRAME_STAGE must be 'graded' or 'source'"* ]] || fail "not refused by the guard: $output"
	[[ "$output" == *"REFUSE_FRAME_STAGE"* ]] || fail "no refusal code: $output"
	[ -z "$(ls -A "$work")" ] || fail "created output before refusing the stage"
}

@test "FRAME and PROOF together are refused rather than silently resolved" {
	local work="$BATS_TEST_TMPDIR/frame-proof"
	mkdir -p "$work/src"
	cp "$FIXTURES/portrait_tagged.mov" "$work/src/CLIP.mov"
	FRAME=1 PROOF=1 GRADE_WORK_DIR="$work" run "$SCRIPTS/grade.sh" "$work/src/CLIP.mov"
	[ "$status" -ne 0 ] || fail "accepted both modes at once"
	[[ "$output" == *"GRADE_CODE=REFUSE_PROOF_AND_FRAME"* ]] || fail "unnamed refusal: $output"
}

@test "FRAME announces where the still landed, for a consumer that has to load it" {
	local work="$BATS_TEST_TMPDIR/frame-json"
	mkdir -p "$work/src"
	cp "$FIXTURES/portrait_tagged.mov" "$work/src/CLIP.mov"
	JSON=1 FRAME=0 FRAME_HEIGHT=128 MATCH=0 GRADE_WORK_DIR="$work" \
		run --separate-stderr "$SCRIPTS/grade.sh" "$work/src/CLIP.mov"
	[ "$status" -eq 0 ]
	[[ "$output" == *'"event":"frame"'* ]] || fail "no frame event: $output"
	[[ "$output" == *'"path":"'*"CLIP_t0s_graded.png"* ]] || fail "the event did not name the file: $output"
	printf '%s\n' "$output" | _json_lines || fail "the frame event broke the stream contract:$output"
}

@test "FRAME does not pay for a stabilisation pass it cannot show" {
	# vidstabdetect costs ~65s per clip and the still has no warp in it. A preview that waited for
	# that would not be a preview.
	local work="$BATS_TEST_TMPDIR/frame-stab"
	mkdir -p "$work/src"
	cp "$FIXTURES/portrait_tagged.mov" "$work/src/CLIP.mov"
	FRAME=0 FRAME_HEIGHT=128 MATCH=0 STAB=1 GRADE_WORK_DIR="$work" \
		run "$SCRIPTS/grade.sh" "$work/src/CLIP.mov"
	[ "$status" -eq 0 ]
	[ ! -f "$work/.loggrade/stabilisation/CLIP.trf" ] || fail "FRAME ran the detect pass anyway"
	[[ "$output" != *"stabilising from"* ]] || fail "FRAME claimed to stabilise a still: $output"
}

@test "the correction generator writes the same cube to stdout as to a file" {
	# CorrectionCubeTests holds the app's cube to the generator's stdout. If the two paths could
	# differ, that test would be holding the app to a cube the render never uses.
	local f="$BATS_TEST_TMPDIR/correct.cube" args="--exposure 0.5 --temp 0.2 --tint 0 --contrast 1.1 --saturation 0.9 --size 5"
	# shellcheck disable=SC2086
	run "$SCRIPTS/make-correct-lut.py" "$f" $args
	[ "$status" -eq 0 ]
	# shellcheck disable=SC2086
	run --separate-stderr "$SCRIPTS/make-correct-lut.py" --stdout $args
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" > "$BATS_TEST_TMPDIR/from-stdout.cube"
	cmp "$f" "$BATS_TEST_TMPDIR/from-stdout.cube" \
		|| fail "the stdout cube is not the cube that gets rendered"
}

@test "the correction generator keeps its commentary out of the cube" {
	# A progress line mixed into the table is read as an entry by whatever parses it.
	run --separate-stderr "$SCRIPTS/make-correct-lut.py" --stdout --exposure 0.5 --size 3
	[ "$status" -eq 0 ]
	[[ "$output" == TITLE* ]] || fail "stdout did not begin with the cube's TITLE: ${output:0:80}"
	[[ "$stderr" == *"stdout"* ]] || fail "no confirmation on stderr: $stderr"
	# `grep -qv` would have been the obvious assertion and is wrong under pipefail: -q closes the
	# pipe on the first match, printf dies of SIGPIPE, and the pipeline reports 141 whatever the
	# content was. Negate a positive match instead, which reads the whole input when it passes.
	! printf '%s\n' "$output" | grep -q '^wrote' || fail "commentary leaked into the cube"
}

@test "the correction generator refuses an ambiguous destination" {
	run "$SCRIPTS/make-correct-lut.py" "$BATS_TEST_TMPDIR/x.cube" --stdout --exposure 0.5
	[ "$status" -ne 0 ] || fail "accepted both a file and stdout"
	[[ "$output" == *"exactly one of OUT or --stdout"* ]] || fail "not refused at the destination: $output"
	[ ! -e "$BATS_TEST_TMPDIR/x.cube" ] || fail "wrote the file anyway"
	run "$SCRIPTS/make-correct-lut.py" --exposure 0.5
	[ "$status" -ne 0 ] || fail "accepted neither a file nor stdout"
	[[ "$output" == *"exactly one of OUT or --stdout"* ]] || fail "not refused at the destination: $output"
}

# --- stale transforms ---------------------------------------------------------
# A transform is measured from the DECODED source. If the source changes, the transform describes
# motion in frames that no longer exist, and applying it makes the warp fight the footage.

@test "a dry run says a stale transform will be recomputed, not ignored" {
	# grade.sh's stale branch is only reachable in a dry run, because a real run recomputes it a
	# few lines earlier. The message said "rendering unstabilised", which is what neither case
	# does — and this is the one decision in a plan that costs ~65s per clip to get wrong.
	local work="$BATS_TEST_TMPDIR/stale-dry"
	_stale_transform "$work"
	DRY=1 MATCH=0 GRADE_WORK_DIR="$work" run "$SCRIPTS/grade.sh" "$work/src/CLIP.mov"
	[ "$status" -eq 0 ]
	[[ "$output" == *"will recompute"* ]] || fail "did not say what a real run would do: $output"
	[[ "$output" != *"rendering unstabilised"* ]] || fail "still claims it renders unstabilised"
}

# --- delivery shape -----------------------------------------------------------
# The output sizes were two literals in the render calls and the crop window was a third. The app
# offers height, aspect and frame rate as choices, so they are computed — and the two that can be
# asked for impossibly are refused before a render starts rather than failing inside ffmpeg.

@test "crop_prefix computes the window from the source rather than assuming 2160x3840" {
	run crop_prefix 2160 3840 4 5 750
	[ "$status" -eq 0 ]
	[ "$output" = "crop=2160:2700:0:750," ] || fail "wrong window: $output"
	# A different source width must move the window with it.
	run crop_prefix 1080 1920 4 5 100
	[ "$status" -eq 0 ]
	[ "$output" = "crop=1080:1350:0:100," ] || fail "window did not follow the source: $output"
}

@test "crop_prefix refuses an offset past the frame edge, before any render starts" {
	# Unvalidated, the offset failed inside ffmpeg seconds into a render.
	run crop_prefix 2160 3840 4 5 1141
	[ "$status" -ne 0 ] || fail "accepted an offset one pixel past the edge"
	[[ "$output" == *"0..1140"* ]] || fail "did not say what the bound is: $output"
	run crop_prefix 2160 3840 4 5 -1
	[ "$status" -ne 0 ] || fail "accepted a negative offset"
	run crop_prefix 2160 3840 4 5 1140
	[ "$status" -eq 0 ] || fail "refused the last valid offset: $output"
}

@test "the sharpener's radius and the grain's size follow the output's short edge" {
	# Both were tuned at a 1080 short edge and are in PIXELS, so at another size they would act on a
	# different real-world detail size. Scaled by the short edge, a landscape export gets the same
	# radius as the portrait one it matches.
	run delivery_image_chain 1080 1920 "" "" 1
	[[ "$output" == *"unsharp=5:5:0.6:3:3"* ]] || fail "1920 should be the measured radius: $output"
	run delivery_image_chain 2160 3840 "" "" 1
	[[ "$output" == *"unsharp=11:11:0.6:3:3"* ]] || fail "radius did not scale: $output"
	# unsharp rejects a radius below 3, so a small output must not ask for one.
	run delivery_image_chain 360 640 "" "" 1
	[[ "$output" == *"unsharp=3:3:0.6:3:3"* ]] || fail "radius went below the floor: $output"
	run delivery_image_chain 1920 1080 "" "" 1
	[[ "$output" == *"unsharp=5:5:0.6:3:3"* ]] || fail "a 1080p landscape export lost the radius: $output"
	# Grain softened by 0.8 px at a 1080 short edge: the same kernel for the landscape 1080p, a wider
	# one at 2160, never below 0.5 px, and no prefix at all at strength 0.
	local portrait landscape big small
	portrait=$(grain_prefix 1080 1920 24 12 | grep -o "0m='[0-9 ]*'" | head -1)
	landscape=$(grain_prefix 1920 1080 24 12 | grep -o "0m='[0-9 ]*'" | head -1)
	big=$(grain_prefix 2160 3840 24 12 | grep -o "0m='[0-9 ]*'" | head -1)
	small=$(grain_prefix 72 128 24 12 | grep -o "0m='[0-9 ]*'" | head -1)
	[ "$portrait" = "0m='1 44 458 1000 458 44 1'" ] || fail "the tuned size's grain moved: $portrait"
	[ "$landscape" = "$portrait" ] || fail "a landscape 1080p export got other grain: $landscape"
	[ "$(echo "$big" | wc -w)" -gt "$(echo "$portrait" | wc -w)" ] || fail "2160 grain did not grow: $big"
	[ "$small" = "0m='0 135 1000 135 0'" ] || fail "tiny grain went below 0.5 px: $small"
	[ -z "$(grain_prefix 1080 1920 24 0)" ] || fail "strength 0 still built grain"
}

@test "fps_filter accepts an integer relation and refuses retiming" {
	run fps_filter 24/1 24
	[ "$status" -eq 0 ]
	[ -z "$output" ] || fail "the same rate should need no filter: $output"
	run fps_filter 24/1 12
	[ "$status" -eq 0 ]
	[ "$output" = ",fps=12" ] || fail "halving should drop whole frames: $output"
	run fps_filter 24/1 48
	[ "$status" -eq 0 ]
	[ "$output" = ",fps=48" ] || fail "doubling should repeat whole frames: $output"
	# The case that tempts people and the one that judders.
	run fps_filter 24/1 30
	[ "$status" -ne 0 ] || fail "accepted 24 to 30, which needs retiming"
	[[ "$output" == *"judder"* ]] || fail "gave no reason: $output"
}

@test "a frame rate that needs retiming skips the clip rather than delivering judder" {
	local work="$BATS_TEST_TMPDIR/fps"
	mkdir -p "$work/src"
	cp "$FIXTURES/portrait_tagged.mov" "$work/src/CLIP.mov"
	FPS_OUT=30 MATCH=0 STAB=0 GRADE_WORK_DIR="$work" run "$SCRIPTS/grade.sh" "$work/src/CLIP.mov"
	[[ "$output" == *"GRADE_CODE=REFUSE_FPS_RETIME"* ]] || fail "unnamed refusal: $output"
	[[ "$output" == *"needs retiming"* ]] || fail "said nothing useful: $output"
	[ -z "$(_exports "$work")" ] || fail "delivered anyway"
}

# --- deliverables as data ------------------------------------------------------
# A deliverable was a `case` branch carrying its own pixel sizes, so the set was closed at two and
# every shape in it assumed this camera's frame. These cover the replacement: the shapes are data,
# the geometry is computed from the source that is actually on disk, and the two presets still
# resolve to exactly the numbers the branches hardcoded.

@test "the presets still resolve to the sizes their case branches hardcoded" {
	# The byte-identity guard, in the cheap form. tests/render-golden.sh renders the default image
	# and compares, which takes a real render; this fails in milliseconds and names which number moved.
	run deliverable_spec reels
	[ "$output" = "reels 9 16 - reels-stories_9x16" ] || fail "reels moved: $output"
	run deliverable_spec feed
	[ "$output" = "feed 4 5 - feed_4x5" ] || fail "feed moved: $output"
	[ "$(deliverable_height 1080 9 16)" = "1920" ] || fail "reels is no longer 1080x1920"
	[ "$(deliverable_height 1080 4 5)" = "1350" ] || fail "feed is no longer 1080x1350"
}

@test "a deliverable can be an arbitrary shape, not one of two names" {
	run deliverable_spec square:1:1
	[ "$status" -eq 0 ] || fail "refused a custom shape: $output"
	[ "$output" = "square 1 1 - square_1x1" ] || fail "unexpected spec: $output"
	run deliverable_spec wide:16:9:400
	[ "$output" = "wide 16 9 400 wide_16x9" ] || fail "the per-deliverable offset was lost: $output"
	[ "$(deliverable_height 1080 1 1)" = "1080" ] || fail "1:1 is not square"
}

@test "a deliverable name that would reach the filter graph is refused" {
	# It becomes a path component and an ffmpeg argument, exactly like a clip name, so it goes
	# through the same guard rather than a weaker one written beside it.
	run deliverable_spec 'a/b:1:1'
	[ "$status" -ne 0 ] || fail "accepted a name containing a path separator"
	run deliverable_spec "q'x:1:1"
	[ "$status" -ne 0 ] || fail "accepted a name containing filter syntax"
	run deliverable_spec nope
	[ "$status" -ne 0 ] || fail "accepted an unknown preset"
	[[ "$output" == *"name:aspect-w:aspect-h"* ]] || fail "did not say what it wanted: $output"
	run deliverable_spec 'a:0:1'
	[ "$status" -ne 0 ] || fail "accepted a zero aspect term"
}

@test "a deliverable with an empty aspect term is refused, not resolved" {
	# Concatenating the two terms before checking them made `x::1` look like `1`, and the empty one
	# then slipped past `-le 0` by erroring. Both sides, because the concatenation hid either.
	for spec in 'x::1' 'x:1:' 'x::'; do
		run deliverable_spec "$spec"
		[ "$status" -ne 0 ] || fail "accepted $spec as: $output"
		[[ "$output" == *"has a non-integer aspect"* ]] || fail "$spec: $output"
	done
}

@test "a deliverable name with whitespace is refused, because its callers split on it" {
	# It resolved with status 0 and `read -r name aw ah off suffix` then took `a` as the name and
	# `b` as the aspect — a silent misparse, not an error.
	run deliverable_spec 'a b:1:1'
	[ "$status" -ne 0 ] || fail "accepted a name containing a space: $output"
	[[ "$output" == *"deliverable name 'a b' contains whitespace"* ]] || fail "$output"
	run require_clip_name 'IMG 0609'
	[ "$status" -eq 0 ] || fail "a clip name with a space: $output"
}

@test "a deliverable that is already the source's shape takes no crop filter" {
	# THE BYTE-IDENTITY RULE. Every deliverable resolves its crop through crop_prefix now, where
	# the 9:16 one used to be handed a literal empty string by its own branch. A no-op
	# `crop=2160:3840:0:0` would render the same picture and still change the graph, which is a
	# difference tests/render-golden.sh sees.
	run crop_prefix 2160 3840 9 16 750
	[ "$status" -eq 0 ] || fail "refused the source's own shape: $output"
	[ -z "$output" ] || fail "emitted a crop for a deliverable that does not crop: $output"
	# ...and a shape that IS a crop still gets one, computed from the source rather than assumed.
	run crop_prefix 2160 3840 4 5 750
	[ "$output" = "crop=2160:2700:0:750," ] || fail "the 4:5 window moved: $output"
}

@test "whether a deliverable crops is decided by the source, not by its name" {
	# 4:5 is a crop of a 9:16 master and the WHOLE FRAME of a 4:5 one. The refusal that uses this
	# fires before any clip is opened, so it cannot ask crop_prefix — it has no offset yet.
	deliverable_crops "2160 3840" 9 16 && fail "said 9:16 crops a 9:16 source"
	deliverable_crops "2160 3840" 4 5 || fail "said 4:5 does not crop a 9:16 source"
	deliverable_crops "2160 2700" 4 5 && fail "said 4:5 crops a 4:5 source"
	deliverable_crops "3840 2160" 9 16 || fail "said 9:16 does not crop a landscape source"
	deliverable_crops "3840 2160" 16 9 && fail "said 16:9 crops a 16:9 source"
	# An unmeasurable source is ASSUMED to crop: the guard then fires when it need not have, which
	# costs a re-run, where guessing the other way costs a batch of silently reframed files.
	deliverable_crops "" 9 16 || fail "an unmeasurable source was assumed safe"
}

@test "a cropped deliverable across several clips is refused, and named" {
	local work="$BATS_TEST_TMPDIR/crop"
	mkdir -p "$work/src"
	cp "$FIXTURES/portrait_tagged.mov" "$work/src/A.mov"
	cp "$FIXTURES/portrait_tagged.mov" "$work/src/B.mov"
	DELIVERABLES=reels,feed MATCH=0 STAB=0 GRADE_WORK_DIR="$work" \
		run "$SCRIPTS/grade.sh" "$work/src/A.mov" "$work/src/B.mov"
	[ "$status" -ne 0 ] || fail "reframed a batch from one clip's composition"
	[[ "$output" == *"GRADE_CODE=REFUSE_CROP_NO_OFFSET"* ]] || fail "unnamed refusal: $output"
	[[ "$output" == *"'feed' crops"* ]] || fail "did not name the deliverable: $output"
	# The UNCROPPED one must not trip it, or every folder run would refuse.
	DELIVERABLES=reels MATCH=0 STAB=0 DRY=1 GRADE_WORK_DIR="$work" \
		run "$SCRIPTS/grade.sh" "$work/src/A.mov" "$work/src/B.mov"
	[ "$status" -eq 0 ] || fail "an uncropped deliverable was refused across a batch: $output"
}

@test "a deliverable whose crop cannot fit the source is refused before it is delivered" {
	local work="$BATS_TEST_TMPDIR/toofit"
	mkdir -p "$work/src"
	cp "$FIXTURES/portrait_tagged.mov" "$work/src/CLIP.mov"
	# A 1:4 window on 72x128 is 32 wide, so it can move 40 pixels and no further.
	DELIVERABLES=tall:1:4:41 MATCH=0 STAB=0 GRADE_WORK_DIR="$work" \
		run "$SCRIPTS/grade.sh" "$work/src/CLIP.mov"
	[[ "$output" == *"does not fit"* ]] || fail "gave no reason: $output"
	[ -z "$(_exports "$work")" ] || fail "delivered anyway"
}

@test "a cropping deliverable with no offset is refused even for a single clip" {
	# THE DEFAULT IS GONE. It was 750 — IMG_0609's composition — which meant a single-clip run
	# silently framed every other clip in the world to one afternoon's parking ceiling. The batch
	# case was already refused; this is the same rule applied to the case the default existed for.
	local work="$BATS_TEST_TMPDIR/nodefault"
	mkdir -p "$work/src"
	cp "$FIXTURES/portrait_tagged.mov" "$work/src/ONE.mov"
	DELIVERABLES=feed MATCH=0 STAB=0 GRADE_WORK_DIR="$work" run "$SCRIPTS/grade.sh" "$work/src/ONE.mov"
	[ "$status" -ne 0 ] || fail "invented an offset for a single clip: $output"
	[[ "$output" == *"GRADE_CODE=REFUSE_CROP_NO_OFFSET"* ]] || fail "unnamed refusal: $output"
	[[ "$output" == *"no sensible"* ]] || fail "did not say why there is no default: $output"
	[ -z "$(_exports "$work")" ] || fail "delivered anyway"
	# An explicit offset still works, and so does an explicit "I do not need one".
	DELIVERABLES=feed CROP_OFFSET=centre MATCH=0 STAB=0 DRY=1 GRADE_WORK_DIR="$work" \
		run "$SCRIPTS/grade.sh" "$work/src/ONE.mov"
	[ "$status" -eq 0 ] || fail "CROP_OFFSET=centre was not accepted: $output"
}

@test "centre is resolved against each clip's own frame, not once for the run" {
	# A fixed pixel offset cannot be right for two differently shaped sources; a centred one is
	# right for both. That is the whole reason centre is available and 750 is not.
	run crop_prefix 2160 3840 4 5 centre
	[ "$output" = "crop=2160:2700:0:570," ] || fail "not centred on a 3840-tall source: $output"
	run crop_prefix 2160 2880 4 5 centre
	[ "$output" = "crop=2160:2700:0:90," ] || fail "centre did not follow the source height: $output"
	# Even, because an odd offset shifts the chroma siting on 4:2:0.
	run crop_prefix 2160 3841 4 5 centre
	[ "${output##*:}" = "570," ] || fail "centre landed on an odd row: $output"
}

@test "a landscape source is cropped left to right, never squashed" {
	# A window of the deliverable's aspect fills one source axis, so on a landscape frame a 9:16
	# window is full height and moves horizontally. The y path is tried first, which is what keeps
	# a portrait source's filter byte-identical.
	run crop_window 3840 2160 9 16
	[ "$output" = "1214 2160 x" ] || fail "wrong landscape window: $output"
	run crop_prefix 3840 2160 9 16 centre
	[ "$output" = "crop=1214:2160:1312:0," ] || fail "not centred horizontally: $output"
	run crop_prefix 3840 2160 9 16 2626
	[ "$output" = "crop=1214:2160:2626:0," ] || fail "refused the last valid offset: $output"
	run crop_prefix 3840 2160 9 16 2627
	[ "$status" -ne 0 ] || fail "accepted an offset past the right edge: $output"
	[[ "$output" == *"0..2626"* ]] || fail "did not say what the bound is: $output"
	run crop_prefix 3840 2160 16 9 centre
	[ -z "$output" ] || fail "cropped a landscape source to its own shape: $output"
	run crop_prefix 3841 2160 9 16 centre
	[ "$output" = "crop=1214:2160:1312:0," ] || fail "centre landed on an odd column: $output"
}

@test "a batch is refused when only a later clip's shape makes a deliverable crop" {
	# The first clip is 9:16 and takes reels whole; the second is landscape and needs a window.
	# Deciding on the first clip alone let the landscape one through with no offset.
	local work="$BATS_TEST_TMPDIR/mixed"
	mkdir -p "$work/src"
	cp "$FIXTURES/portrait_tagged.mov" "$work/src/A.mov"
	cp "$FIXTURES/landscape_tagged.mov" "$work/src/B.mov"
	DELIVERABLES=reels MATCH=0 STAB=0 DRY=1 GRADE_WORK_DIR="$work" \
		run "$SCRIPTS/grade.sh" "$work/src/A.mov" "$work/src/B.mov"
	[ "$status" -ne 0 ] || fail "a landscape clip went through reels with no offset: $output"
	[[ "$output" == *"GRADE_CODE=REFUSE_CROP_NO_OFFSET"* ]] || fail "unnamed refusal: $output"
}

# HEIGHT=128 so a fixture finishes the delivery chain; see the run report test.
# bats test_tags=slow
@test "a landscape clip renders into a portrait deliverable at the deliverable's size" {
	local work="$BATS_TEST_TMPDIR/landscape-render" out w h
	mkdir -p "$work/src"
	cp "$FIXTURES/probe_mid_landscape.mov" "$work/src/WIDE.mov"
	CROP_OFFSET=centre HEIGHT=128 PROOF=0.5 MATCH=0 STAB=0 GRADE_WORK_DIR="$work" \
		run "$SCRIPTS/grade.sh" "$work/src/WIDE.mov"
	[ "$status" -eq 0 ] || fail "render failed: $output"
	[[ "$output" == *"cropped 40x72 at 44,0"* ]] || fail "did not report the horizontal window: $output"
	out=$(ls "$work"/.loggrade/proofs/*.mp4 2>/dev/null | head -1) || true
	[ -n "$out" ] || fail "no proof was written: $output"
	w=$(ffprobe -v error -select_streams v:0 -show_entries stream=width -of default=nw=1:nk=1 "$out" | head -1)
	h=$(ffprobe -v error -select_streams v:0 -show_entries stream=height -of default=nw=1:nk=1 "$out" | head -1)
	[ "$w" = "72" ] && [ "$h" = "128" ] || fail "delivered ${w}x${h}, wanted 72x128"
}

@test "crop_prefix refuses an offset it was never given, rather than inventing one" {
	run crop_prefix 2160 3840 4 5 ""
	[ "$status" -ne 0 ] || fail "accepted an empty offset: $output"
	[[ "$output" == *"needs an offset"* ]] || fail "gave no reason: $output"
	[[ "$output" == *"CROP_OFFSET=centre"* ]] || fail "did not say how to say 'no preference': $output"
}

@test "a deliverable's own offset may be centre, and it beats the run's" {
	run deliverable_spec feed:4:5:centre
	[ "$output" = "feed 4 5 centre feed_4x5" ] || fail "centre was not carried: $output"
	run deliverable_spec feed:4:5:nonsense
	[ "$status" -ne 0 ] || fail "accepted a word that is not an offset"
}

# --- exposure metering ---------------------------------------------------------
# Each clip's own log-average and grey balance, measured from one decoded frame and applied in
# LINEAR light before the conversion.

# bats test_tags=slow
@test "metering brightens a dark clip and darkens a bright one, damped" {
	local work="$BATS_TEST_TMPDIR/meter"
	mkdir -p "$work/src"
	cp "$FIXTURES/probe_dark.mov"   "$work/src/A.mov"
	cp "$FIXTURES/probe_mid.mov"    "$work/src/B.mov"
	cp "$FIXTURES/probe_bright.mov" "$work/src/C.mov"
	STAB=0 DRY=1 JSON=1 GRADE_WORK_DIR="$work" \
		run "$SCRIPTS/grade.sh" "$work/src/A.mov" "$work/src/B.mov" "$work/src/C.mov"
	[ "$status" -eq 0 ] || fail "metering failed: $output"
	_metered() {  # _metered <clip>
		printf '%s' "$output" | sed -n "s/.*\"clip\":\"$1\".*\"metered_exposure\":\([-0-9.]*\).*/\\1/p" | head -1
	}
	local a b c
	a="$(_metered A)"; b="$(_metered B)"; c="$(_metered C)"
	[ -n "$a" ] && [ -n "$b" ] && [ -n "$c" ] || fail "a clip was not metered: $output"
	# The dark clip is lifted and the bright one pulled down, neither past the two-stop bound the
	# meter clamps to (these fixtures are flat greys four stops apart, which real footage is not).
	awk -v a="$a" -v c="$c" 'BEGIN { exit !(a > 0 && c < 0 && a <= 2 && c >= -2) }' \
		|| fail "metered A=$a B=$b C=$c"
	awk -v a="$a" -v b="$b" -v c="$c" 'BEGIN { exit !(a > b && b > c) }' \
		|| fail "metering did not order the three clips: A=$a B=$b C=$c"
}

@test "MATCH refuses a mode it does not have, rather than picking one" {
	local work="$BATS_TEST_TMPDIR/mode"
	mkdir -p "$work/src"
	cp "$FIXTURES/portrait_tagged.mov" "$work/src/CLIP.mov"
	MATCH=yes STAB=0 DRY=1 GRADE_WORK_DIR="$work" run "$SCRIPTS/grade.sh" "$work/src/CLIP.mov"
	[ "$status" -ne 0 ] || fail "accepted an unknown MATCH mode"
	[[ "$output" == *"GRADE_CODE=REFUSE_MATCH_MODE"* ]] || fail "unnamed refusal: $output"
	# batch was a mode until metering replaced it: it must refuse, not fall through to "on".
	MATCH=batch STAB=0 DRY=1 GRADE_WORK_DIR="$work" run "$SCRIPTS/grade.sh" "$work/src/CLIP.mov"
	[ "$status" -ne 0 ] || fail "accepted MATCH=batch, which no longer exists"
}

@test "the per-clip measurements stay aligned with their clips when one is skipped" {
	# The frame sizes are found BY POSITION, so an early skip that did not advance the index would
	# hand every clip after it the previous clip's size — a wrong crop on a file that looks
	# finished, which is the whole failure class this pipeline is built against.
	local work="$BATS_TEST_TMPDIR/align"
	mkdir -p "$work/src"
	# A is skipped for a frame rate FPS_OUT=12 cannot divide, and is 72x128; B renders and is
	# 128x72, so reading A's slot would crop B in the wrong orientation entirely.
	cp "$FIXTURES/probe_dark_25fps.mov" "$work/src/A_skipped.mov"
	cp "$FIXTURES/probe_mid_landscape.mov" "$work/src/B_kept.mov"
	FPS_OUT=12 STAB=0 DRY=1 JSON=1 CROP_OFFSET=centre GRADE_WORK_DIR="$work" \
		run "$SCRIPTS/grade.sh" "$work/src/A_skipped.mov" "$work/src/B_kept.mov"
	[ "$status" -eq 0 ] || fail "the run failed: $output"
	[[ "$output" == *'"clip":"A_skipped"'*'"code":"REFUSE_FPS_RETIME"'* ]] \
		|| fail "the 25fps clip was not skipped: $output"
	local a_size b_size
	a_size="$(ffprobe -v error -select_streams v:0 -show_entries stream=width -of default=nw=1:nk=1 \
		"$work/src/A_skipped.mov" | head -1)"
	b_size="$(printf '%s' "$output" | sed -n 's/.*"clip":"B_kept".*"width":\([0-9]*\).*/\1/p' | head -1)"
	[ -n "$b_size" ] || fail "no size for the kept clip: $output"
	[ "$b_size" != "$a_size" ] || fail "the kept clip reported the skipped clip's frame ($b_size)"
}

# --- the input correction -----------------------------------------------------
# Exposure, white balance, contrast and saturation, as one generated cube that runs BEFORE Apple's
# conversion — in log, where highlights up to 12x diffuse white still exist. A neutral correction leaves the
# filter out of the graph, because an identity cube still pays interpolation error on every pixel.

@test "the correction generator round-trips Apple's published transfer function" {
	# The formula is published, so this is exact rather than fitted. If it ever stops round-tripping,
	# the maths has been edited rather than the parameters.
	run python3 -c '
import importlib.util, sys
spec = importlib.util.spec_from_file_location("mc", sys.argv[1])
mc = importlib.util.module_from_spec(spec); spec.loader.exec_module(mc)
worst = max(abs(mc.encode(mc.decode(i/1000.0)) - i/1000.0) for i in range(1001))
print("%.1e %.4f" % (worst, mc.decode(1.0)))
' "$SCRIPTS/make-correct-lut.py"
	[ "$status" -eq 0 ] || fail "$output"
	local worst headroom
	worst="${output% *}"; headroom="${output#* }"
	python3 -c "import sys; sys.exit(0 if float('$worst') < 1e-9 else 1)" \
		|| fail "the transfer function no longer round-trips: $worst"
	# 12x diffuse white in linear, about 3.6 stops above it — not twelve stops.
	[ "$headroom" = "12.0000" ] || fail "decode(1.0) should be 12x diffuse white, got $headroom"
}

@test "a neutral correction is reported as neutral, and any move as active" {
	run "$SCRIPTS/make-correct-lut.py" --check-neutral
	[ "$status" -eq 0 ]
	[ "$output" = "neutral" ] || fail "defaults are not neutral: $output"
	for arg in "--exposure 0.1" "--temp 0.1" "--tint 0.1" "--contrast 1.1" "--saturation 0.9"; do
		# shellcheck disable=SC2086
		run "$SCRIPTS/make-correct-lut.py" --check-neutral $arg
		[ "$output" = "active" ] || fail "$arg reported as $output"
	done
}

@test "the correction cube is skipped entirely when it would do nothing" {
	# The engine must not render every pixel through a lookup that returns it: that costs time, and
	# interpolation error on every pixel of a look nobody changed.
	local work="$BATS_TEST_TMPDIR/neutral"
	mkdir -p "$work/src"
	cp "$FIXTURES/portrait_tagged.mov" "$work/src/CLIP.mov"
	DRY=1 MATCH=0 STAB=0 GRADE_WORK_DIR="$work" run "$SCRIPTS/grade.sh" "$work/src/CLIP.mov"
	[ "$status" -eq 0 ]
	[[ "$output" != *"correction:"* ]] || fail "announced a correction that does nothing: $output"
	[ ! -f "$work/.loggrade/work/correct.cube" ] || fail "generated a cube for a neutral correction"
}

# bats test_tags=slow
@test "an active correction reaches the render and changes the picture" {
	local work="$BATS_TEST_TMPDIR/active" look="$BATS_TEST_TMPDIR/warm.json"
	mkdir -p "$work/src"
	cp "$FIXTURES/portrait_tagged.mov" "$work/src/CLIP.mov"
	python3 - "$BATS_TEST_DIRNAME/../look.json" "$look" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d["correct"]["exposure"] = 0.75
json.dump(d, open(sys.argv[2], "w"))
PY
	LOOK_FILE="$look" FRAME=0 FRAME_HEIGHT=128 MATCH=0 GRADE_WORK_DIR="$work" \
		run "$SCRIPTS/grade.sh" "$work/src/CLIP.mov"
	[ "$status" -eq 0 ] || fail "$output"
	[[ "$output" == *"correction: --exposure 0.75 "* ]] || fail "said nothing about it: $output"
	[ -s "$work/.loggrade/work/correct.cube" ] || fail "no cube was generated"
	# And it changed the picture. A string test cannot tell whether the filter did anything.
	mv "$work/.loggrade/frames/CLIP_t0s_graded.png" "$work/corrected.png"
	FRAME=0 FRAME_HEIGHT=128 MATCH=0 GRADE_WORK_DIR="$work" \
		run "$SCRIPTS/grade.sh" "$work/src/CLIP.mov"
	[ "$status" -eq 0 ]
	! cmp -s "$work/corrected.png" "$work/.loggrade/frames/CLIP_t0s_graded.png" \
		|| fail "a 0.75 stop exposure correction changed nothing"
}

@test "the correction precedes Apple's conversion in both graphs" {
	# ORDER IS THE DECISION. Apple Log holds highlights up to 12x diffuse white, about 3.6 stops
	# above it, which the Rec.709 cube lands on a display ceiling of 1.0, so a correction applied after it works on display-referred pixels and clips
	# highlights the source still holds. Before it, the same move is a log-domain correction.
	#
	# A source assertion: the built graph is not printed anywhere, and a render test can only show that the correction did something, not
	# where it sat. Both the delivery graph and the preview must have it ahead of the conversion.
	local n
	#
	# Halation sits between the two: it acts on light, so it follows the exposure the correction set
	# and precedes the conversion that would land every highlight on the same display ceiling.
	# The export's grain goes between halation and the conversion too: it is grain in the negative.
	n=$(grep -cE "CORRECT_PREFIX\}\\\$\{HALATION_PREFIX\}(\\\$\{grain\})?lut3d=file='\\\$\{CST\}'" "$SCRIPTS/grade.sh" || true)
	[ "$n" -eq 2 ] || fail "expected correction, halation, CST in that order in both graphs, found $n"
	# And nowhere after it.
	! grep -qE "CST\}':interp=tetrahedral,\\\$\{(CORRECT|HALATION)_PREFIX\}" "$SCRIPTS/grade.sh" \
		|| fail "a pre-conversion stage was placed after the conversion"
}

@test "the correction cube is regenerated by content, never by timestamp" {
	# By the TITLE, not the mtime: git does not preserve mtime, so a committed cube
	# always lands newer than the file it came from and would be trusted forever.
	local cube="$BATS_TEST_TMPDIR/c.cube"
	run "$SCRIPTS/make-correct-lut.py" "$cube" --exposure 0.5 --size 5
	[ "$status" -eq 0 ]
	run "$SCRIPTS/make-correct-lut.py" "$cube" --exposure 0.5 --size 5
	[[ "$output" == *"already current"* ]] || fail "rewrote a cube that already matched: $output"
	run "$SCRIPTS/make-correct-lut.py" "$cube" --exposure 0.6 --size 5
	[[ "$output" != *"already current"* ]] || fail "kept a cube built at a different exposure"
	grep -q 'exposure=0.6' "$cube" || fail "the cube does not record what it was built at"
}

@test "a cube built at a value that differs past six digits is not trusted as current" {
	# The TITLE is the freshness check, so its number format IS the check. Two generators wrote it
	# with %g, six significant digits: 0.1234567 and 0.1234568 stamped the same TITLE, and the
	# second run kept the cube built at the first. Every generator now goes through cubefile.py.
	local dir="$BATS_TEST_TMPDIR/precise"
	mkdir -p "$dir"
	run "$SCRIPTS/make-correct-lut.py" "$dir/c.cube" --exposure 0.1234567 --size 3
	[ "$status" -eq 0 ] || fail "$output"
	run "$SCRIPTS/make-correct-lut.py" "$dir/c.cube" --exposure 0.1234568 --size 3
	[[ "$output" != *"already current"* ]] || fail "the correction kept a cube built at another exposure"

	run "$SCRIPTS/make-halation-luts.py" "$dir/h" --threshold 1.0000001
	[ "$status" -eq 0 ] || fail "$output"
	run "$SCRIPTS/make-halation-luts.py" "$dir/h" --threshold 1.0000002
	[ "$output" = "wrote halation-threshold.cube" ] || fail "halation kept a cube built at another threshold: $output"
}

@test "the correction generator refuses an absurd cube size" {
	run "$SCRIPTS/make-correct-lut.py" --stdout --size 200
	[ "$status" -ne 0 ] || fail "accepted an absurd cube size"
	[[ "$output" == *"outside 2..64"* ]] || fail "refused the size without saying why: $output"
}

# Writes a copy of look.json with one jq assignment applied, and prints its path.
_look_with() {  # _look_with <name> <jq-assignment>
	local out="$BATS_TEST_TMPDIR/$1.json"
	jq "$2" "$BATS_TEST_DIRNAME/../look.json" > "$out"
	printf '%s\n' "$out"
}

@test "a correction value that cannot be read stops the run rather than dropping the stage" {
	# The generator decides neutrality, and a generator handed a split argument dies of argparse
	# and answers with nothing. Compared as a string, nothing is "not active": the correction was
	# left out of the render in silence. It must refuse instead.
	local work="$BATS_TEST_TMPDIR/badcorrect" look
	mkdir -p "$work/src"
	cp "$FIXTURES/portrait_tagged.mov" "$work/src/CLIP.mov"
	look="$(_look_with badcorrect '.correct.contrast = "1.2 1"')"

	LOOK_FILE="$look" DRY=1 MATCH=0 STAB=0 GRADE_WORK_DIR="$work" run "$SCRIPTS/grade.sh" "$work/src/CLIP.mov"
	[ "$status" -ne 0 ] || fail "grade.sh planned a run without the correction: $output"
	[[ "$output" == *"correct.contrast must be numeric"* ]] \
		|| fail "grade.sh did not say which value: $output"
}

@test "encode settings, analysis settings and cache paths are spelled in lib.sh and nowhere else" {
	# Each of these was once written into more than one script, and the byte comparisons render only
	# one path, so an edit to a copy reached files nobody compared: the delivery encode, the
	# stabilisation analysis and its cache path, the Apple cube's path.
	local offenders
	# The render entry point only. check.sh names Apple's cube and src/ too, to warn that a green run
	# skipped the render tests; it renders nothing and does not source lib.sh.
	offenders=$(grep -nE 'libx264|prores_ks|vidstabdetect|AppleLogToRec709|\.loggrade/stabilisation/|/src/' \
		"$SCRIPTS"/grade.sh | grep -v ':[0-9]*:[[:space:]]*#' || true)
	[ -z "$offenders" ] || fail "spelled outside lib.sh:$offenders"
}

@test "every generator's flags are spelled in lib.sh and nowhere else" {
	# The correction was mapped to flags in two places, and the copies had drifted by a flag. A flag
	# written at a call site is the start of the next copy.
	local offenders
	offenders=$(grep -nE -- '--(exposure|temp|tint|contrast|saturation) ' \
		"$SCRIPTS"/*.sh | grep -v '/lib\.sh:' | grep -v ':[0-9]*:[[:space:]]*#' || true)
	[ -z "$offenders" ] || fail "spells a generator flag outside lib.sh:$offenders"
}

# --- halation -----------------------------------------------------------------
# A glow computed in linear light between the correction and the conversion. The graph is
# halation_prefix in lib.sh and the cubes come from make-halation-luts.py; the traps both are shaped
# around are in their headers. These tests drive the builder on FLOAT frames written byte for byte,
# because what is under test is what ffmpeg does to exact values, and a YUV fixture would bury that
# under a conversion's own rounding.

# Runs a gbrpf32le frame through a filter chain and prints every sample of the result, one per line,
# planes in ffmpeg's order: G, then B, then R.
_float_through() {  # _float_through <in.raw> <w> <h> <chain>
	ffmpeg -v error -f rawvideo -pix_fmt gbrpf32le -s "${2}x${3}" -i "$1" \
		-filter_complex "[0:v]${4}null[o]" -map "[o]" -f rawvideo -pix_fmt gbrpf32le - \
		| python3 -c 'import sys, struct; d = sys.stdin.buffer.read(); print("\n".join("%.6f" % v for v in struct.unpack("%df" % (len(d) // 4), d)))'
}

@test "an idle halation stage hands back the frame it was given, highlights included" {
	# The stage decodes to linear and encodes back, and two ffmpeg behaviours can quietly wreck
	# that while every picture still looks plausible:
	#   - lut1d ignores a negative DOMAIN_MIN, so the inverse cube reads shifted by 0.056 unless the
	#     linear values are offset to stay positive (measured 20 code values out before the offset);
	#   - `blend` addition, avgblur and boxblur clamp float at 1.0, which cuts every highlight above
	#     diffuse white — most of what Apple Log holds.
	# A near-zero strength keeps the whole graph in place while adding nothing, so the output must be
	# the input across the full code range.
	local dir="$BATS_TEST_TMPDIR/hal" raw="$BATS_TEST_TMPDIR/ramp.raw"
	"$SCRIPTS/make-halation-luts.py" "$dir" --threshold 1.0 >/dev/null
	python3 -c '
import struct, sys
w, h = 256, 4
ramp = [i / (w - 1) for i in range(w)] * h
open(sys.argv[1], "wb").write(struct.pack("%df" % (w * h * 3), *(ramp * 3)))
' "$raw"
	run _float_through "$raw" 256 4 "$(halation_prefix "$dir" 4 0.000001 1,1,1)"
	[ "$status" -eq 0 ] || fail "$output"
	local worst
	worst=$(printf '%s\n' "$output" | python3 -c '
import sys
out = [float(l) for l in sys.stdin]
ramp = [i / 255 for i in range(256)] * 4 * 3
assert len(out) == len(ramp), (len(out), len(ramp))
print("%.6f" % max(abs(a - b) for a, b in zip(out, ramp)))
')
	python3 -c "import sys; sys.exit(0 if $worst < 0.001 else 1)" \
		|| fail "the idle stage moved a sample by $worst of full scale (a 10-bit code value is 0.001)"
}

@test "halation glows past an edge, not across a bright field" {
	# EDGE-ONLY is the design: blurring the highlights and adding all of it turned an overcast sky
	# uniformly pink, because a large bright area glows onto itself. What the eye reads as halation
	# is the part that spills past an edge, so the stage adds blur(highlight) - highlight, clamped.
	#
	# Left half bright (Apple Log 0.9, about six times diffuse white), right half dark. Red-only tint,
	# so G and B double as a check that nothing else moved.
	local dir="$BATS_TEST_TMPDIR/hal" raw="$BATS_TEST_TMPDIR/edge.raw"
	"$SCRIPTS/make-halation-luts.py" "$dir" --threshold 1.0 >/dev/null
	python3 -c '
import struct, sys
w, h = 512, 16
row = [0.9 if x < w // 2 else 0.3 for x in range(w)]
open(sys.argv[1], "wb").write(struct.pack("%df" % (w * h * 3), *(row * h * 3)))
' "$raw"
	# Sigma 16 pixels. The far side is 250 pixels past the edge, which is further than the glow's
	# tail reaches: in log, the dark side is sensitive enough that 60 pixels still read as glow.
	run _float_through "$raw" 512 16 "$(halation_prefix "$dir" 16 1 1,0,0)"
	[ "$status" -eq 0 ] || fail "$output"
	printf '%s\n' "$output" | python3 -c '
import sys
v = [float(l) for l in sys.stdin]
w, h = 512, 16
n = w * h
g, b, r = v[:n], v[n:2 * n], v[2 * n:]
mid = h // 2 * w
def at(plane, x): return plane[mid + x]
problems = []
if at(r, 260) - 0.3 < 0.01:
    problems.append("no red glow just past the edge: %.4f" % at(r, 260))
if abs(at(r, 8) - 0.9) > 0.002 or abs(at(r, 248) - 0.9) > 0.002:
    problems.append("the bright field glowed onto itself: %.4f, %.4f" % (at(r, 8), at(r, 248)))
if abs(at(r, 506) - 0.3) > 0.002:
    problems.append("the glow reached the far side of the frame: %.4f" % at(r, 506))
if max(abs(at(p, x) - (0.9 if x < w // 2 else 0.3)) for p in (g, b) for x in range(w)) > 0.002:
    problems.append("a red-only tint moved green or blue")
sys.exit("; ".join(problems) or None)
' || fail "the glow is not edge-only"
}

@test "a neutral halation is left out of the graph" {
	# Even an idle float round trip moves the picture by a fraction of a code value against the
	# 10-bit path (0.23 code values on average, ADR 0012), so a strength of 0 must remove the stage
	# entirely.
	run "$SCRIPTS/make-halation-luts.py" --check-neutral --strength 0
	[ "$output" = "neutral" ] || fail "strength 0 reported as $output"
	run "$SCRIPTS/make-halation-luts.py" --check-neutral --strength 0.01
	[ "$output" = "active" ] || fail "strength 0.01 reported as $output"

	local work="$BATS_TEST_TMPDIR/neutral-hal" look="$BATS_TEST_TMPDIR/neutral-hal.json"
	mkdir -p "$work/src"
	cp "$FIXTURES/portrait_tagged.mov" "$work/src/CLIP.mov"
	jq '.halation.strength = 0' "$BATS_TEST_DIRNAME/../look.json" > "$look"
	LOOK_FILE="$look" FRAME=0 FRAME_HEIGHT=128 MATCH=0 GRADE_WORK_DIR="$work" \
		run "$SCRIPTS/grade.sh" "$work/src/CLIP.mov"
	[ "$status" -eq 0 ] || fail "$output"
	[[ "$output" != *"halation:"* ]] || fail "announced a halation that does nothing: $output"
	[ ! -d "$work/.loggrade/work/halation" ] || fail "generated cubes for a neutral halation"
}

# bats test_tags=slow
@test "an active halation reaches the render and changes the picture" {
	local work="$BATS_TEST_TMPDIR/active-hal" look="$BATS_TEST_TMPDIR/active-hal.json" clip
	mkdir -p "$work/src"
	clip="$work/src/EDGE.mov"
	# An edge, because a flat field is exactly what an edge-only glow leaves alone.
	ffmpeg -y -f lavfi -i "color=c=black:s=72x128:d=0.1:r=24,drawbox=x=0:y=0:w=36:h=128:color=white:t=fill" \
		-frames:v 1 -c:v prores_ks -profile:v 3 -pix_fmt yuv422p10le "$clip" -v error
	jq '.halation.strength = 0.8 | .halation.radius = 0.05' "$BATS_TEST_DIRNAME/../look.json" > "$look"
	LOOK_FILE="$look" FRAME=0 FRAME_HEIGHT=128 MATCH=0 GRADE_WORK_DIR="$work" \
		run "$SCRIPTS/grade.sh" "$clip"
	[ "$status" -eq 0 ] || fail "$output"
	[[ "$output" == *"halation: strength=0.8"* ]] || fail "said nothing about it: $output"
	mv "$work/.loggrade/frames/EDGE_t0s_graded.png" "$work/glowing.png"
	jq '.halation.strength = 0' "$look" > "$look.off"
	LOOK_FILE="$look.off" FRAME=0 FRAME_HEIGHT=128 MATCH=0 GRADE_WORK_DIR="$work" \
		run "$SCRIPTS/grade.sh" "$clip"
	[ "$status" -eq 0 ] || fail "$output"
	! cmp -s "$work/glowing.png" "$work/.loggrade/frames/EDGE_t0s_graded.png" \
		|| fail "a strength of 0.8 changed nothing"
}

@test "a halation tint that is not three numbers is refused before it reaches a graph" {
	local work="$BATS_TEST_TMPDIR/bad-tint" look="$BATS_TEST_TMPDIR/bad-tint.json" tint
	mkdir -p "$work/src"
	cp "$FIXTURES/portrait_tagged.mov" "$work/src/CLIP.mov"
	for tint in "1,0.3" "1,0.3,0.05,1" "1,0.3,0.05[x]"; do
		jq --arg t "$tint" '.halation.strength = 0.5 | .halation.tint = $t' \
			"$BATS_TEST_DIRNAME/../look.json" > "$look"
		LOOK_FILE="$look" FRAME=0 FRAME_HEIGHT=128 MATCH=0 GRADE_WORK_DIR="$work" \
			run "$SCRIPTS/grade.sh" "$work/src/CLIP.mov"
		[ "$status" -ne 0 ] || fail "rendered with tint '$tint'"
		[[ "$output" == *"halation.tint"* ]] || fail "tint '$tint' refused without naming it: $output"
		[ ! -d "$work/.loggrade/frames" ] || fail "tint '$tint' got as far as rendering"
	done
}

# bats test_tags=slow
@test "the one-pass render crops and shrinks before it grades, and sizes the glow for that frame" {
	# The grade is per pixel or a fraction of the frame, so it runs at delivery size: a quarter of the
	# work at 4K. The glow is in the shrunk frame's pixels, and a crop must not make it grow.
	run delivery_geometry 1080 1920 ""
	[ "$output" = "zscale=w=1080:h=1920:f=lanczos,format=yuv444p10le," ] || fail "$output"
	# The warp runs on the shrunk frame, not the 4K one.
	run delivery_geometry 1080 1920 "vidstabtransform=input='t.trf',"
	[ "$output" = "zscale=w=1080:h=1920:f=lanczos,vidstabtransform=input='t.trf',format=yuv444p10le," ] \
		|| fail "the warp is not after the shrink: $output"
	run delivery_halation_sigma 2160 3840 0.006 0.5
	[ "$output" = "11.52" ] || fail "full frame at half size: $output"
	# Reels needs 1920 of 3840 rows, feed 1350 of a 2700-row window: both a half, so a 1080x1920
	# frame serves both, and feed's window moves onto it at half every number.
	run delivery_scale 3840 "1920:-" "1350:crop=2160:2700:0:750,"
	[ "$output" = "0.500000" ] || fail "scale: $output"
	run scaled_crop "crop=2160:2700:0:750," 0.5 1080 1920
	[ "$output" = "crop=1080:1350:0:374," ] || fail "window on the shared frame: $output"
	# A window that rounds past the edge is held inside the frame.
	run scaled_crop "crop=2160:2700:0:1141," 0.5 1080 1920
	[ "$output" = "crop=1080:1350:0:570," ] || fail "not held inside: $output"
	# And in the render itself, the reduction comes before the conversion, not after the grade.
	local work="$BATS_TEST_TMPDIR/shrink-first" report
	mkdir -p "$work/src"
	cp "$FIXTURES/probe_mid.mov" "$work/src/CLIP.mov"
	MATCH=0 STAB=0 HEIGHT=128 PROOF=0.1 GRADE_WORK_DIR="$work" run "$SCRIPTS/grade.sh" "$work/src/CLIP.mov"
	[ "$status" -eq 0 ] || fail "render failed: $output"
	report=$(ls "$work"/.loggrade/reports/run-*.txt 2>/dev/null | head -1) || true
	[ -n "$report" ] || fail "no run report: $output"
	grep -qE "^\[0:v\]zscale=w=72:h=128:f=lanczos,format=yuv444p10le,.*lut3d=file='[^']*neutral\.cube'" "$report" \
		|| fail "the graph does not shrink before the conversion: $(grep -F '[0:v]' "$report")"
}

# bats test_tags=slow
@test "a clip's deliverables render in one pass, and every one of them lands" {
	# One ffmpeg, one decode, one grade, split per deliverable. The sharpener defines labels, and two
	# of them in one graph must not collide: ffmpeg refuses the whole graph if they do, which is what a
	# lost renumbering looks like. The grain is in the shared chain, once.
	local work="$BATS_TEST_TMPDIR/one-pass" report look="$BATS_TEST_TMPDIR/one-pass.json"
	mkdir -p "$work/src"
	cp "$FIXTURES/portrait_tagged.mov" "$work/src/CLIP.mov"
	jq '.finish.sharpen = 0.6 | .grain.strength = 4' "$BATS_TEST_DIRNAME/../look.json" > "$look"
	LOOK_FILE="$look" DELIVERABLES=reels,feed CROP_OFFSET=centre MATCH=0 STAB=0 HEIGHT=128 PROOF=0.2 \
		GRADE_WORK_DIR="$work" run "$SCRIPTS/grade.sh" "$work/src/CLIP.mov"
	[ "$status" -eq 0 ] || fail "render failed: $output"
	[ -s "$work/.loggrade/proofs/CLIP_reels-stories_9x16_proof-0.2s.mp4" ] || fail "no reels: $output"
	[ -s "$work/.loggrade/proofs/CLIP_feed_4x5_proof-0.2s.mp4" ] || fail "no feed: $output"
	report=$(ls "$work"/.loggrade/reports/run-*.txt 2>/dev/null | head -1) || true
	[ "$(grep -c -- '--- graph [0-9]* (reels-stories_9x16+feed_4x5 encode, -filter_complex) ---' "$report")" = 1 ] \
		|| fail "not one pass for both: $(grep -F -- '--- graph' "$report")"
	grep -qE '^\[0:v\].*\[gr_img\].*split=2\[s0\]\[s1\];.*\[sh1_in\]' "$report" \
		|| fail "the second deliverable's labels are not its own: $(grep -F '[0:v]' "$report")"
}

# --- grain in the negative ---------------------------------------------------

# bats test_tags=slow
@test "grain in the negative is its specified size, shared by the channels, and adds no offset" {
	# Per-channel sd strength * 0.00064 in log, 90% of the variance common to R, G and B, mean zero.
	# Measured as built: sd 0.0074-0.0077, correlation 0.90, mean -0.0003. The traps it guards are in
	# grain_prefix's header: an ignored per-plane seed made green 27% too strong, a gray-to-RGB
	# conversion left red and blue without shared grain, a truncating blur darkened by 0.0015.
	local dir="$BATS_TEST_TMPDIR/grain" w=270 h=480
	mkdir -p "$dir"
	ffmpeg -v error -y -f lavfi -i "color=c=gray:s=${w}x${h}:r=24:d=0.2" \
		-filter_complex "[0:v]$(grain_prefix "$w" "$h" 24 12)format=gbrpf32le[o]" -map "[o]" \
		-frames:v 2 -f rawvideo -pix_fmt gbrpf32le "$dir/grain.raw" || fail "the grain graph failed"
	python3 - "$dir/grain.raw" "$w" "$h" <<'PY' || fail "grain off its specification"
import math, struct, sys
w, h = int(sys.argv[2]), int(sys.argv[3])
data = open(sys.argv[1], "rb").read()
frame = w * h * 3 * 4
vals = struct.unpack("<%df" % (w * h * 3), data[frame:2 * frame])
g, b, r = (vals[i * w * h:(i + 1) * w * h] for i in range(3))
base = 128 / 255
def stats(c):
    m = sum(c) / len(c)
    return m, math.sqrt(sum((v - m) ** 2 for v in c) / len(c))
def corr(a, c):
    (ma, sa), (mc, sc) = stats(a), stats(c)
    return sum((x - ma) * (y - mc) for x, y in zip(a, c)) / len(a) / (sa * sc)
problems = []
for name, c in (("red", r), ("green", g), ("blue", b)):
    m, sd = stats(c)
    if abs(sd - 12 * 0.00064) > 12 * 0.00064 * 0.08: problems.append("%s sd %.5f" % (name, sd))
    if abs(m - base) > 0.0008: problems.append("%s mean offset %+.5f" % (name, m - base))
for name, c in (("green", g), ("blue", b)):
    k = corr(r, c)
    if abs(k - 0.9) > 0.05: problems.append("red-%s correlation %.3f" % (name, k))
print("; ".join(problems))
sys.exit(1 if problems else 0)
PY
}

@test "every delivery format setting is refused by name before anything renders" {
	local work="$BATS_TEST_TMPDIR/bad-format" setting words
	mkdir -p "$work/src"
	cp "$FIXTURES/portrait_tagged.mov" "$work/src/CLIP.mov"
	# Each: an environment, then the words its refusal must say.
	while IFS='|' read -r setting words; do
		env $setting FRAME=0 FRAME_HEIGHT=128 MATCH=0 GRADE_WORK_DIR="$work" \
			"$SCRIPTS/grade.sh" "$work/src/CLIP.mov" < /dev/null > "$work/out.txt" 2>&1 && fail "rendered with $setting"
		grep -qF -- "$words" "$work/out.txt" || fail "$setting refused without saying '$words': $(cat "$work/out.txt")"
		[ ! -d "$work/.loggrade/frames" ] || fail "$setting got as far as rendering"
	done <<'CASES'
DELIVERY_CODEC=av1|DELIVERY_CODEC must be h264, hevc, hevc10, prores422 or prores422hq
DELIVERY_QUALITY=best|DELIVERY_QUALITY must be auto, high or max
DELIVERY_CONTAINER=mkv|DELIVERY_CONTAINER must be mp4 or mov
DELIVERY_AUDIO=yes|DELIVERY_AUDIO must be 0 or 1
DELIVERY_CODEC=prores422hq DELIVERY_CONTAINER=mp4|DELIVERY_CONTAINER=mp4 cannot hold prores422hq
DELIVERY_CODEC=prores422 DELIVERY_CONTAINER=mov DELIVERY_QUALITY=max|a ProRes file's quality is its profile
DELIVERY_BITS=10|DELIVERY_BITS is gone: set DELIVERY_CODEC instead
CASES
}

@test "each codec gets its own pixel format, encoder and audio, and h264 auto is the encode it was" {
	_format() {  # _format <env...>  -> pix_fmt, then the encode args, one line
		env "$@" bash -c 'source "$1"; load_delivery_format || exit 1; delivery_encode_args
			printf "%s|%s|%s\n" "$(delivery_pix_fmt)" "${DELIVERY_ARGS[*]}" "$(deliverable_path d c s)"' _ "$SCRIPTS/lib.sh"
	}
	local out
	out="$(_format)"
	[[ "$out" == "yuv420p|"*"-map 0:a:0? -c:a aac -b:a 192k -c:v libx264 -profile:v high -preset medium -crf 18|d/c_s.mp4" ]] \
		|| fail "the default encode moved: $out"
	out="$(_format DELIVERY_CODEC=hevc10)"
	[[ "$out" == "yuv420p10le|"*"libx265 -preset slow -crf 18 -pix_fmt yuv420p10le -tag:v hvc1"* ]] \
		|| fail "hevc10 is not the 10-bit encode it was: $out"
	out="$(_format DELIVERY_CODEC=hevc DELIVERY_QUALITY=high DELIVERY_AUDIO=0)"
	[[ "$out" == "yuv420p|"*"-an -c:v libx265 -preset slow -crf 18 -pix_fmt yuv420p "* ]] || fail "hevc high, no audio: $out"
	[[ "$out" != *"0:a:0"* ]] || fail "DELIVERY_AUDIO=0 still maps audio: $out"
	out="$(_format DELIVERY_CODEC=prores422hq DELIVERY_CONTAINER=mov)"
	[[ "$out" == "yuv422p10le|"*"-c:a pcm_s16le -c:v prores_ks -profile:v 3 -pix_fmt yuv422p10le"*"|d/c_s.mov" ]] \
		|| fail "ProRes 422 HQ: $out"
	# 4:2:2 is 10-bit numbers everywhere a depth decides them, and is never dithered to 4:2:0 first.
	# Set, not prefixed: a prefix on a function call lasts only for that call.
	DELIVERY_CODEC=prores422; DELIVERY_CONTAINER=mov
	load_delivery_format
	DENOISE_STRENGTH=0 SHARPEN=1 GAUGE=none run delivery_image_chain 1080 1920 "" "" 1 24
	[[ "$output" == *"d=error_diffusion,format=yuv422p10le,"*"undershoot=8:overshoot=8"* ]] || fail "ProRes finish: $output"
	[[ "$output" != *yuv420p* ]] || fail "ProRes passed through 4:2:0: $output"
}

@test "a frame rate within 0.1% of the source is the source's, not a retime" {
	run fps_filter 30000/1001 30
	[ "$status" -eq 0 ] && [ -z "$output" ] || fail "30 from an iPhone's 29.97: $output"
	run fps_filter 24/1 25
	[ "$status" -ne 0 ] || fail "25 from 24 is a retime and must stay refused"
	run fps_filter 60/1 30
	[ "$output" = ",fps=30" ] || fail "60 to 30 drops every other frame: $output"
}

# bats test_tags=slow
@test "every codec delivers a tagged file of the format it names, from real footage" {
	local src work codec container want_codec want_pix want_audio out streams
	src=$(_real_clip)
	[ -n "$src" ] || skip "no source footage"
	while read -r codec container want_codec want_pix want_audio; do
		work="$BATS_TEST_TMPDIR/codec-$codec"
		mkdir -p "$work"
		DELIVERY_CODEC="$codec" DELIVERY_CONTAINER="$container" PROOF=1 STAB=0 HEIGHT=640 \
			GRADE_WORK_DIR="$work" run "$SCRIPTS/grade.sh" "$src" < /dev/null
		# ffmpeg reads stdin, which is this loop's list of codecs, so it is given nothing.
		[ "$status" -eq 0 ] || fail "$codec render failed: $output"
		out=$(find "$work/.loggrade/proofs" -name "*.$container")
		[ -s "$out" ] || fail "$codec wrote no .$container proof: $output"
		[ "$(probe_tags "$out")" = "bt709,bt709,bt709" ] || fail "$codec is not tagged Rec.709: $(probe_tags "$out")"
		[ "$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name,pix_fmt -of csv=p=0 "$out" | head -1)" \
			= "$want_codec,$want_pix" ] || fail "$codec delivered $(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name,pix_fmt -of csv=p=0 "$out")"
		streams=$(ffprobe -v error -select_streams a -show_entries stream=codec_name -of default=nw=1:nk=1 "$out" | head -1)
		[ "$streams" = "$want_audio" ] || fail "$codec audio: '$streams', expected '$want_audio'"
	done <<'CODECS'
h264 mp4 h264 yuv420p aac
hevc mp4 hevc yuv420p aac
hevc10 mov hevc yuv420p10le aac
prores422 mov prores yuv422p10le pcm_s16le
prores422hq mov prores yuv422p10le pcm_s16le
CODECS
	# And no audio when asked for none.
	work="$BATS_TEST_TMPDIR/codec-silent"
	mkdir -p "$work"
	DELIVERY_AUDIO=0 PROOF=1 STAB=0 HEIGHT=640 GRADE_WORK_DIR="$work" run "$SCRIPTS/grade.sh" "$src"
	[ "$status" -eq 0 ] || fail "silent render failed: $output"
	out=$(find "$work/.loggrade/proofs" -name '*.mp4')
	[ "$(ffprobe -v error -show_entries stream=codec_type -of default=nw=1:nk=1 "$out")" = video ] \
		|| fail "DELIVERY_AUDIO=0 still delivered audio"
}

@test "a FINISH that is not 0 or 1 is refused before anything renders" {
	local work="$BATS_TEST_TMPDIR/bad-finish"
	mkdir -p "$work/src"
	cp "$FIXTURES/portrait_tagged.mov" "$work/src/CLIP.mov"
	FINISH=no FRAME=0 FRAME_HEIGHT=128 MATCH=0 GRADE_WORK_DIR="$work" \
		run "$SCRIPTS/grade.sh" "$work/src/CLIP.mov"
	[ "$status" -ne 0 ] || fail "rendered with FINISH=no"
	[[ "$output" == *"FINISH must be 0 or 1"* ]] || fail "refused without naming FINISH: $output"
	[ ! -d "$work/.loggrade/frames" ] || fail "FINISH=no got as far as rendering"
}

@test "a grained render finishes rather than following the infinite noise plates" {
	# The noise plates are endless lavfi sources; `mix` ends on its first input, the picture. Without
	# `duration=first` a render runs on and the output grows without bound, which is what an
	# unterminated plate did once before (a 26 s clip past 189 MB, no moov atom ever written).
	local work="$BATS_TEST_TMPDIR/grain-proof" look="$BATS_TEST_TMPDIR/grain-proof.json"
	mkdir -p "$work/src"
	cp "$FIXTURES/portrait_tagged.mov" "$work/src/CLIP.mov"
	jq '.grain.strength = 12' "$BATS_TEST_DIRNAME/../look.json" > "$look"
	LOOK_FILE="$look" PROOF=0.1 STAB=0 MATCH=0 GRADE_WORK_DIR="$work" \
		run "$SCRIPTS/grade.sh" "$work/src/CLIP.mov"
	[ "$status" -eq 0 ] || fail "$output"
	local out
	out=$(find "$work/.loggrade/proofs" -name '*.mp4' | head -1)
	[ -s "$out" ] || fail "no proof was written: $output"
}

@test "the halation cubes are regenerated by content, and only the one a change affects" {
	local dir="$BATS_TEST_TMPDIR/hal-fresh"
	run "$SCRIPTS/make-halation-luts.py" "$dir" --threshold 1.0
	[ "$status" -eq 0 ]
	run "$SCRIPTS/make-halation-luts.py" "$dir" --threshold 1.0
	[[ "$output" == *"already current"* ]] || fail "rewrote cubes that already matched: $output"
	run "$SCRIPTS/make-halation-luts.py" "$dir" --threshold 2.0
	[ "$output" = "wrote halation-threshold.cube" ] || fail "a threshold change rewrote: $output"
	grep -q 'threshold=2' "$dir/halation-threshold.cube" || fail "the cube does not record its threshold"
	run "$SCRIPTS/make-halation-luts.py" "$dir" --threshold -1
	[ "$status" -ne 0 ] || fail "accepted a negative threshold"
	[[ "$output" == *"--threshold outside"* ]] || fail "not refused at the threshold: $output"
	grep -q 'threshold=2' "$dir/halation-threshold.cube" || fail "a refused threshold still rewrote the cube"
}

@test "the shipped rendering is the one its generator produces, at the revision it records" {
	# FRESHNESS BY CONTENT, and the content is the maths as well as the parameters. Stamping only
	# the parameters left a committed cube "already current" after the rendering itself changed —
	# every render silently using the cube it replaced, which is exactly what this guard exists to
	# stop. Found by changing the gamut fit and watching nothing rebake.
	local root="$BATS_TEST_DIRNAME/.." cube="$BATS_TEST_TMPDIR/rev.cube" title args
	title="$(head -1 "$root/luts/rendering/neutral.cube")"
	[[ "$title" == *" rev"* ]] || fail "the shipped cube records no revision: $title"
	# Rebuilt from the TITLE's own parameters: a cube that cannot be reproduced from what it
	# records is one nobody can re-tune.
	args="$(printf '%s' "$title" | sed -n 's/.*(\(.*\))"/\1/p' | tr ' ' '\n' \
		| sed 's/^/--/; s/=/ /' | tr '\n' ' ')"
	# shellcheck disable=SC2086  # a flag list built from the cube's own TITLE
	run "$SCRIPTS/make-rendering-lut.py" "$cube" $args
	[ "$status" -eq 0 ] || fail "the TITLE does not round-trip into the generator: $output"
	cmp -s "$cube" "$root/luts/rendering/neutral.cube" \
		|| fail "the shipped cube is not what its own TITLE regenerates"
}

@test "the recorded event stream still matches what the engine emits" {
	# The app parses these events, and a parser is only as good as the shape it was written
	# against. This pins the contract by CONTENT: field names, order and types, with the work dir
	# and the volume's free space tokenised because neither is reproducible.
	#
	# It is also the fixture the app's own tests read, so they need no ffmpeg and no footage.
	local fixture="$BATS_TEST_DIRNAME/fixtures/events.jsonl" now
	[ -f "$fixture" ] || fail "no recorded stream at $fixture"
	# SKIP ONLY ON 3, which is the generator's documented "no ffmpeg". A bare `|| skip` swallowed
	# every other failure as a pass, and it hid a real one: the generator's own clips were 1:2, so
	# once a deliverable became an aspect its two-clip run was refused, the generator exited 1, and
	# this test reported a skip instead of the broken contract it exists to catch. A missing tool is
	# a skip; a generator that fails is a failure.
	local rc=0
	now="$("$BATS_TEST_DIRNAME/make-event-fixture.sh" --check)" || rc=$?
	[ "$rc" -ne 3 ] || skip "ffmpeg not installed"
	[ "$rc" -eq 0 ] || fail "the fixture generator failed (exit $rc): $now"
	if [ "$now" != "$(cat "$fixture")" ]; then
		printf 'recorded:\n%s\nnow:\n%s\n' "$(cat "$fixture")" "$now"
		fail "the event stream changed. If that was intended, re-run tests/make-event-fixture.sh and say in the commit what moved."
	fi
	# And it is a stream, not a blob: one object per line, each parseable on its own.
	printf '%s\n' "$now" | _json_lines || fail "the recorded stream is not one object per line"
	[[ "$now" == *'"event":"run_done"'* ]] \
		|| fail "the stream has no run_done, so a consumer cannot tell it ended"
}

# --- audio --------------------------------------------------------------------
# A high-pass on the delivered audio only. The cutoff is measured in docs/PIPELINE.md, "Encode".

# RMS in dBFS of a file's audio below <hz>, through a 4-pole lowpass so the louder band above does
# not leak in. awk reads to the end rather than `exit`: under pipefail a closed pipe kills ffmpeg
# with SIGPIPE and fails the assignment.
_low_band_db() {  # _low_band_db <file> <hz>
	ffmpeg -hide_banner -nostats -i "$1" -map 0:a:0 \
		-af "lowpass=f=$2,lowpass=f=$2,astats=measure_perchannel=none" -f null - 2>&1 \
		| awk -F': ' '/Overall/ { o = 1 } o && /RMS level dB/ { v = $2 } END { print v }'
}

# bats test_tags=slow
@test "the delivered audio loses its low band to the high-pass, and 0 turns it off" {
	local src on off hz db_on db_off
	src=$(_real_clip)
	[ -n "$src" ] || skip "no source footage"
	# Two work dirs: both proofs are named by clip and length, so one dir would compare a file with
	# itself.
	mkdir -p "$BATS_TEST_TMPDIR/hp-on" "$BATS_TEST_TMPDIR/hp-off"
	PROOF=3 STAB=0 GRADE_WORK_DIR="$BATS_TEST_TMPDIR/hp-on" run "$SCRIPTS/grade.sh" "$src"
	[ "$status" -eq 0 ] || fail "default render failed: $output"
	PROOF=3 STAB=0 AUDIO_HIGHPASS_HZ=0 GRADE_WORK_DIR="$BATS_TEST_TMPDIR/hp-off" \
		run "$SCRIPTS/grade.sh" "$src"
	[ "$status" -eq 0 ] || fail "unfiltered render failed: $output"
	on=$(find "$BATS_TEST_TMPDIR/hp-on/.loggrade/proofs" -name '*.mp4')
	off=$(find "$BATS_TEST_TMPDIR/hp-off/.loggrade/proofs" -name '*.mp4')
	[ -s "$on" ] && [ -s "$off" ] || fail "a proof is missing: '$on' '$off'"

	hz=$(( DELIVERY_AUDIO_HIGHPASS_HZ / 2 ))
	db_on=$(_low_band_db "$on" "$hz")
	db_off=$(_low_band_db "$off" "$hz")
	[[ "$db_on" =~ ^-[0-9]+\.[0-9]+$ && "$db_off" =~ ^-[0-9]+\.[0-9]+$ ]] \
		|| fail "could not measure the low band: on '$db_on', off '$db_off'"
	# Measured on IMG_0607's first 3 s at 60 Hz: -63.3 dB off, -67.9 on. Two renders with the
	# filter off differ by nothing, so a 2 dB floor is not noise and leaves room for quieter clips.
	[ "$(awk -v a="$db_off" -v b="$db_on" 'BEGIN { print (a - b >= 2) ? "ok" : "no" }')" = ok ] \
		|| fail "below $hz Hz: $db_off dB unfiltered, $db_on dB filtered; expected 2 dB less"
}

# bats test_tags=slow
@test "a clip with no audio delivers with the high-pass on, and gains no audio stream" {
	local src clip work out streams
	src=$(_real_clip)
	[ -n "$src" ] || skip "no source footage"
	clip="$BATS_TEST_TMPDIR/SILENT.mov"
	work="$BATS_TEST_TMPDIR/silent"
	mkdir -p "$work"
	# A real excerpt: a synthetic fixture cannot finish the delivery chain.
	ffmpeg -v error -y -i "$src" -t 2 -map 0:v -c copy "$clip" || fail "could not cut a silent clip"
	PROOF=1 STAB=0 GRADE_WORK_DIR="$work" run "$SCRIPTS/grade.sh" "$clip"
	[ "$status" -eq 0 ] || fail "render failed: $output"
	[[ "$output" != *highpass* && "$output" != *Filtergraph* ]] \
		|| fail "the audio filter complained: $output"
	# Without this the test also passes with the filter off, which is not the case it is about.
	grep -q -- "-af highpass=f=$DELIVERY_AUDIO_HIGHPASS_HZ" "$work"/.loggrade/reports/*.txt \
		|| fail "the render did not carry the audio filter"
	out=$(find "$work/.loggrade/proofs" -name '*.mp4')
	[ -s "$out" ] || fail "no proof was written: $output"
	streams=$(ffprobe -v error -show_entries stream=codec_type -of default=nw=1:nk=1 "$out")
	[ "$streams" = video ] || fail "expected only a video stream, got: $streams"
}

@test "an AUDIO_HIGHPASS_HZ that is not a whole number is refused before anything renders" {
	local work="$BATS_TEST_TMPDIR/bad-hz" v
	mkdir -p "$work/src"
	cp "$FIXTURES/portrait_tagged.mov" "$work/src/CLIP.mov"
	# 70.5, -80 and 1e2 all pass require_number; the comma would splice a second filter.
	for v in 70.5 -80 1e2 "60,volume=10"; do
		AUDIO_HIGHPASS_HZ="$v" PROOF=0.1 STAB=0 MATCH=0 GRADE_WORK_DIR="$work" \
			run "$SCRIPTS/grade.sh" "$work/src/CLIP.mov"
		[ "$status" -ne 0 ] || fail "grade.sh accepted '$v'"
		[[ "$output" == *"AUDIO_HIGHPASS_HZ must be a whole number of hertz"* ]] \
			|| fail "grade.sh did not refuse '$v' by name: $output"
		[ ! -e "$work/.loggrade/proofs" ] || fail "grade.sh got as far as rendering with '$v'"
	done
}

@test "the audio high-pass is built in exactly one place" {
	local offenders
	# The boundary is there because grade.sh's report line spells `audio_highpass=`.
	offenders=$(grep -nE '(^|[^[:alnum:]_])highpass=|-af[[:space:]]' "$SCRIPTS"/*.sh \
		| grep -v '/lib\.sh:' | grep -v ':[0-9]*:[[:space:]]*#' || true)
	[ -z "$offenders" ] || fail "an audio filter is spelled outside lib.sh:$offenders"
	offenders=$(grep -nE '(^|[^[:alnum:]_])highpass=' "$SCRIPTS/lib.sh" \
		| grep -v '^[0-9]*:[[:space:]]*#' || true)
	[ "$(printf '%s\n' "$offenders" | grep -c .)" -eq 1 ] \
		|| fail "highpass= should be built in exactly one place in lib.sh:$offenders"
}

# --- the app's toolchain ------------------------------------------------------
# Xcode 15.2 is the newest release for this machine's macOS, which caps Swift at 5.9 and the SDK at
# 14.2. The risk of working across two machines is one-directional: raising the tools version or
# reaching for a newer API on the newer Mac leaves the always-available one unable to build at all.
# Prose cannot hold that line, so a test does.

@test "the Swift package still pins the toolchain this machine can build" {
	local pkg="$BATS_TEST_DIRNAME/../app/Package.swift"
	[ -f "$pkg" ] || skip "no Swift package yet"
	grep -q '^// swift-tools-version:5.9$' "$pkg" \
		|| fail "the tools version moved off 5.9: $(head -1 "$pkg")"
	grep -q 'platforms: \[.macOS(.v13)\]' "$pkg" \
		|| fail "the deployment target moved off macOS 13"
	# @Observable is macOS 14 and the obvious thing to reach for; ObservableObject is the one that
	# builds here. Caught by grep rather than by a build failure on the wrong machine.
	#
	# The pattern needs its boundary: `@Observable` is a PREFIX of `@ObservedObject`, so the
	# obvious grep flagged the correct spelling as the forbidden one and this test failed on code
	# that builds. A guard that cannot tell the two apart is worse than none, because the fix it
	# demands is wrong.
	# And it has to ignore COMMENTS, or the sentence explaining the rule trips the rule. Matching
	# only where no slash precedes it does that: `/// ... @Observable` is excluded, an actual
	# attribute at the start of a line is not.
	! grep -rnE '^[^/]*@Observable([^A-Za-z]|$)' "$BATS_TEST_DIRNAME/../app/Sources" \
		|| fail "@Observable needs macOS 14; use ObservableObject"
}

# bats test_tags=slow,serial
@test "the app bundle script produces something launchable" {
	command -v swift >/dev/null || skip "no swift toolchain"
	local app="$BATS_TEST_DIRNAME/../dist/LogGrade.app"
	# --debug on purpose. This test is about the bundle's SHAPE — an executable, an Info.plist, the
	# engine vendored beside it — none of which optimisation affects, and a release build of the
	# package costs twenty seconds of every suite run to prove nothing this test asserts. The
	# release build IS exercised, by the next test, which is the one that matters because it is the
	# configuration the app actually ships in.
	run "$BATS_TEST_DIRNAME/../app/make-app.sh" --debug
	[ "$status" -eq 0 ] || fail "$output"
	[ -x "$app/Contents/MacOS/LogGrade" ] || fail "no executable in the bundle"
	[ -f "$app/Contents/Info.plist" ] || fail "no Info.plist, so macOS treats it as a stray binary"
	# The engine travels with it: a launched app inherits no useful PATH and should not break
	# because a checkout moved.
	[ -x "$app/Contents/Resources/engine/scripts/grade.sh" ] || fail "the engine was not vendored"
	[ -f "$app/Contents/Resources/engine/look.json" ] || fail "look.json was not vendored"
	# Without it macOS gives the app the generic document icon.
	cmp -s "$app/Contents/Resources/AppIcon.icns" "$BATS_TEST_DIRNAME/../app/AppIcon.icns" \
		|| fail "the bundle does not carry app/AppIcon.icns"
	# UNIVERSAL, every executable in it. Nothing on this Intel Mac notices a missing arm64 slice:
	# on the Apple Mac it is Rosetta, or a prompt to install Rosetta before the first render.
	local exe
	for exe in MacOS/LogGrade Resources/engine/ffmpeg Resources/engine/ffprobe \
		Resources/engine/jq; do
		lipo "$app/Contents/$exe" -verify_arch x86_64 arm64 \
			|| fail "$exe is not universal: $(lipo -archs "$app/Contents/$exe")"
		# Each by itself too: the bundle's verdict does not show that a tool under Resources/
		# carries a signature of its own, and Apple silicon kills arm64 code without one.
		codesign --verify --strict "$app/Contents/$exe" || fail "$exe is not signed"
	done
	codesign --verify --deep --strict "$app" || fail "the bundle's signature does not verify"
}

# bats test_tags=slow,serial
@test "the default build is the optimised one, because the live preview needs it" {
	command -v swift >/dev/null || skip "no swift toolchain"
	# THE CONFIGURATION MATTERS MORE THAN IT LOOKS. The live preview grades a whole frame per
	# control change, and unoptimised that is 1.5 seconds against 12.7ms — a build that does not
	# feel slow so much as broken. So the default has to stay release, and passing --release must
	# not be what gets you there. This is the only test that compiles the app the way it ships.
	run "$BATS_TEST_DIRNAME/../app/make-app.sh"
	[ "$status" -eq 0 ] || fail "$output"
	[[ "$output" == *"(release)"* ]] || fail "make-app.sh did not default to release: $output"
	# A universal build writes here, through Xcode's build system. The old .build/release/ path
	# kept this green after the switch, off a host-only binary left by an earlier build.
	[ -x "$BATS_TEST_DIRNAME/../app/.build/apple/Products/Release/LogGrade" ] \
		|| fail "no optimised binary"
}

@test "the app build refuses tools that are not the pinned ones, before compiling anything" {
	command -v swift >/dev/null || skip "no swift toolchain"
	# An empty directory stands for a fresh Mac. The message has to name the script that fixes it,
	# and the refusal has to come before the build, which is the part that costs minutes.
	LOGGRADE_TOOLS="$BATS_TEST_TMPDIR/no-tools" run "$BATS_TEST_DIRNAME/../app/make-app.sh" --debug
	[ "$status" -ne 0 ] || fail "built without the pinned tools: $output"
	[[ "$output" == *"./app/fetch-tools.sh"* ]] || fail "the refusal does not name the fix: $output"
	# xcbuild's words, not SwiftPM's: a build with two --arch goes through Xcode's build system.
	[[ "$output" != *"Compute target dependency graph"* && "$output" != *"Build succeeded"* ]] \
		|| fail "compiled before refusing: $output"
}

@test "the exposure meter answers a degenerate frame with no correction, not a failure" {
	# A black frame has no log-average to speak of and a flat frame has no grey balance. Either
	# used to be the kind of input that raised inside the solve and took the batch down at clip n.
	local out
	out="$(ffmpeg -v error -f lavfi -i "color=c=black:s=64x64:d=1:r=24" -frames:v 1 \
		-vf "format=gbrpf32le,scale=160:160" -f rawvideo - \
		| "$SCRIPTS/solve-exposure.py" 160 160 -0.4)"
	[ "$out" = "0.000 0.000 0.000" ] || fail "a black frame metered $out"
	# And a mid grey frame is balanced already, so only its exposure moves.
	out="$(ffmpeg -v error -f lavfi -i "color=c=0x808080:s=64x64:d=1:r=24" -frames:v 1 \
		-vf "format=gbrpf32le,scale=160:160" -f rawvideo - \
		| "$SCRIPTS/solve-exposure.py" 160 160 -0.4)"
	local temp tint
	read -r _ temp tint <<< "$out"
	# Not exactly zero: the frame arrives through a YUV to RGB conversion, which lands a nominal
	# grey a thousandth off neutral. A cast worth correcting is two orders of magnitude larger.
	awk -v t="$temp" -v n="$tint" 'BEGIN { exit !(t < 0.01 && t > -0.01 && n < 0.01 && n > -0.01) }' \
		|| fail "a neutral frame asked for a cast: $out"
}

# tests/render-golden.sh holds the default image to this repo's own recorded render. Its
# render cannot run here in seconds, and check.sh runs it for real; these cover the two ways it can
# be relaxed without anyone seeing, and assert the work was not attempted, since a render that
# fails for any other reason would also exit non-zero.

@test "the render golden refuses to move without a reason" {
	local golden="$BATS_TEST_TMPDIR/render-golden.json"
	printf '{"stream_md5":"recorded"}\n' > "$golden"
	GOLDEN="$golden" run "$BATS_TEST_DIRNAME/render-golden.sh" --regenerate
	[ "$status" -eq 2 ] || fail "expected a usage refusal, got $status: $output"
	[[ "$output" == *"--regenerate needs a reason"* ]] || fail "refused without saying why: $output"
	[[ "$output" != *"clip:"* ]] || fail "rendered before refusing: $output"
	[ "$(cat "$golden")" = '{"stream_md5":"recorded"}' ] || fail "the golden was rewritten"
}

@test "a render golden from another ffmpeg build is skipped by name, not compared" {
	local golden="$BATS_TEST_TMPDIR/render-golden.json"
	printf '{"clip":{"name":"IMG_0607.mov","bytes":1},"proof_secs":0.1,"ffmpeg":"ffmpeg version 0-other","arch":"%s","stream_md5":"x","inputs":{}}\n' \
		"$(uname -m)" > "$golden"
	GOLDEN="$golden" run "$BATS_TEST_DIRNAME/render-golden.sh"
	[ "$status" -eq 3 ] || fail "expected a skip, got $status: $output"
	[[ "$output" == *"recorded with 'ffmpeg version 0-other'"* ]] || fail "skipped without naming the build: $output"
	[[ "$output" != *"clip:"* ]] || fail "rendered against a golden from another build: $output"
}

# A sheet of raw Rec.709 codes opens as sRGB and shows every look darker than playback does. Holds a
# tile to the still grade.sh renders, carried through Apple's 1.961 display gamma to sRGB, and the
# sheet to an embedded sRGB profile.
# bats test_tags=slow
@test "a look sheet shows a render the way playback shows it, tagged sRGB" {
	command -v sips >/dev/null || skip "sips is macOS only"
	local sheet="$BATS_TEST_TMPDIR/sheet.png" work="$BATS_TEST_TMPDIR/work" still v tile expected raw
	LOGGRADE_CACHE="$BATS_TEST_TMPDIR/cache" run "$BATS_TEST_DIRNAME/../scripts/look-sheet.sh" \
		-n -t 0 -c neutral -o "$sheet" "$FIXTURES/portrait_tagged.mov"
	[ "$status" -eq 0 ] || fail "look-sheet failed: $output"
	[[ "$(sips -g profile "$sheet")" == *"profile: sRGB"* ]] || fail "sheet not tagged sRGB: $(sips -g profile "$sheet")"

	mkdir -p "$work"
	still="$(JSON=1 FRAME=0 FRAME_HEIGHT=128 GRADE_WORK_DIR="$work" "$BATS_TEST_DIRNAME/../scripts/grade.sh" \
		"$FIXTURES/portrait_tagged.mov" 2>/dev/null | jq -r 'select(.event == "frame") | .path')"
	v="$(ffmpeg -v error -i "$still" -vf "crop=1:1:36:64,format=rgb48le" -f rawvideo - | od -An -tu2 | awk '{ print $2 }')"
	tile="$(ffmpeg -v error -i "$sheet" -vf "crop=1:1:203:400,format=rgb24" -f rawvideo - | od -An -tu1 | awk '{ print $2 }')"
	expected="$(awk -v v="$v" 'BEGIN { l = (v / 65535) ^ 1.961
		printf "%d", 255 * (l <= 0.0031308 ? 12.92 * l : 1.055 * l ^ (1 / 2.4) - 0.055) + 0.5 }')"
	raw="$(awk -v v="$v" 'BEGIN { printf "%d", v / 257 + 0.5 }')"
	awk -v a="$tile" -v b="$expected" 'BEGIN { exit !(a - b <= 1 && b - a <= 1) }' \
		|| fail "tile green $tile, expected $expected from still code $v"
	awk -v a="$expected" -v b="$raw" 'BEGIN { exit !(a - b >= 3) }' \
		|| fail "fixture grey too dark or light to tell the conversion from none ($expected vs $raw)"
}
