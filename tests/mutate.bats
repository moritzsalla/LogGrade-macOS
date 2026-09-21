#!/usr/bin/env bats
# tests/mutate.sh edits real source files, so the one thing it must never do is leave a mutant
# behind. Only that is tested here.

bats_require_minimum_version 1.5.0

fail() { echo "ASSERTION FAILED: $*" >&2; return 1; }  # why a function: tests/lib.bats

setup() {
	MUTATE="$BATS_TEST_DIRNAME/mutate.sh"
	F="$BATS_TEST_TMPDIR/guard.sh"
	printf 'guard() {\n\t[ -n "$1" ] || return 1\n}\n' > "$F"
	cp "$F" "$BATS_TEST_TMPDIR/original"
}

@test "mutate.sh restores the file byte for byte when the test fails on the mutant" {
	# Passes on the original, fails only if the mutation really landed.
	run "$MUTATE" "$F" 'return 1' 'MUTANT' -- sh -c '! grep -q MUTANT "$0"' "$F"
	[ "$status" -eq 0 ] || fail "want KILLED (0), got $status: $output"
	[[ "$output" == *KILLED* ]] || fail "no KILLED verdict: $output"
	cmp "$F" "$BATS_TEST_TMPDIR/original" || fail "file not restored"
}

@test "mutate.sh restores the file when it is killed mid-test" {
	local held="$BATS_TEST_TMPDIR/held" release="$BATS_TEST_TMPDIR/release"
	# The baseline run must pass straight through; only the mutant run holds.
	"$MUTATE" "$F" 'return 1' 'MUTANT' -- sh -c '
		grep -q MUTANT "$0" || exit 0
		touch "$1"; while [ ! -e "$2" ]; do sleep 0.1; done' "$F" "$held" "$release" \
		> "$BATS_TEST_TMPDIR/log" 2>&1 &
	local pid=$!
	while [ ! -e "$held" ]; do kill -0 "$pid" 2>/dev/null || fail "exited early: $(cat "$BATS_TEST_TMPDIR/log")"; sleep 0.1; done
	grep -q MUTANT "$F" || fail "mutation was not applied while the test ran"
	# TERM, not INT: a non-interactive shell starts background jobs with SIGINT ignored, and an
	# ignored signal cannot be trapped. Both go through the same restore.
	kill -TERM "$pid"
	touch "$release"
	local rc=0
	wait "$pid" || rc=$?
	[ "$rc" -eq 143 ] || fail "want exit 143 after TERM, got $rc: $(cat "$BATS_TEST_TMPDIR/log")"
	cmp "$F" "$BATS_TEST_TMPDIR/original" || fail "file left mutated after TERM"
}
