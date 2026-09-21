#!/bin/bash
# Drive the built app from a shell: launch it on a clip, screenshot its window, read and press its
# controls through the accessibility API, quit it. The skill .claude/skills/drive-loggrade says
# when and how; this file is why each step is shaped the way it is.
#
# THE BUNDLE IS THIS CHECKOUT'S dist/LogGrade.app (or $LOGGRADE_APP), and every command after
# launch finds its process by that bundle's executable path, never by the name: the user's own
# copy from the main checkout may be open beside it, and both are called LogGrade.
#
# Usage:
#   loggrade.sh perm                 accessibility / screen-recording, as the shell sees them
#   loggrade.sh launch [clip.mov…]   (re)start the bundle; default clip is the first src/*.mov.
#                                    Returns once the picture has rendered, pid= on stdout
#   loggrade.sh shot OUT.png         the main window, covered or not
#   loggrade.sh shot OUT.png --screen  the screen under it: brings it to the front, shows popovers
#   loggrade.sh shot OUT.png X,Y,W,H   a close-up, in the screen points `tree` prints
#   loggrade.sh tree                 accessibility tree of every window
#   loggrade.sh wait TEXT [SECS]     until a control with that title/description/value exists
#   loggrade.sh click TEXT [SECS]    press it (AXPress; a mouse click where there is none)
#   loggrade.sh quit
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
APP="${LOGGRADE_APP:-$ROOT/dist/LogGrade.app}"
EXE="$APP/Contents/MacOS/LogGrade"

# Compiled once per source revision: `swift ax.swift` costs seconds of compile on every call.
ax() {
	local src="$HERE/ax.swift" cache bin
	cache="${XDG_CACHE_HOME:-$HOME/Library/Caches}/loggrade-drive"
	bin="$cache/ax-$(shasum -a 256 "$src" | cut -c1-12)"
	if [ ! -x "$bin" ]; then
		mkdir -p "$cache"
		swiftc -O "$src" -o "$bin.tmp" >&2
		mv "$bin.tmp" "$bin"
	fi
	"$bin" "$@"
}

app_pid() {
	# pgrep -f matches the full command line; the bundle path pins it to this checkout's build.
	pgrep -f "^$EXE" | head -1 || true
}

need_pid() {
	local pid
	pid="$(app_pid)"
	[ -n "$pid" ] || { echo "not running: $EXE (run: $0 launch)" >&2; exit 1; }
	echo "$pid"
}

# The bundle is copied from these at build time, so any of them newer than the binary means the
# window shows code this checkout no longer has.
stale_sources() {
	find "$ROOT/app/Sources" "$ROOT/scripts" "$ROOT/luts" "$ROOT/presets" "$ROOT/look.json" \
		-newer "$EXE" -type f 2>/dev/null | head -3
}

default_clip() {
	# A worktree's src/ is empty (footage is gitignored), so fall back to the main checkout's.
	local main dir clip
	main="$(git -C "$ROOT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
	for dir in "$ROOT/src" "${main%/.git}/src"; do
		for clip in "$dir"/*.mov "$dir"/*.MOV; do
			[ -f "$clip" ] && { echo "$clip"; return; }
		done
	done
}

# The window appears seconds before the picture does; a screenshot taken on the window alone shows
# "Preparing the first frame". Ready is the export button present and no "Preparing" text left.
wait_for_picture() {
	local tree
	for _ in $(seq 1 240); do
		tree="$(ax tree "$1")"
		if grep -q 'Export clip' <<<"$tree" && ! grep -q 'Preparing' <<<"$tree"; then return; fi
		sleep 0.5
	done
	echo "window up, but the picture was not ready after 120s" >&2
}

cmd="${1:-}"
[ $# -eq 0 ] || shift
case "$cmd" in
	perm)
		ax perm
		;;
	launch)
		[ -x "$EXE" ] || { echo "no app at $APP. Build it: $ROOT/app/make-app.sh (minutes; run it in the background)" >&2; exit 1; }
		stale="$(stale_sources)"
		if [ -n "$stale" ]; then
			echo "STALE BUILD: newer than the bundle:" >&2
			echo "$stale" >&2
			echo "Rebuild with $ROOT/app/make-app.sh, or LOGGRADE_STALE_OK=1 to launch it anyway." >&2
			[ "${LOGGRADE_STALE_OK:-}" = 1 ] || exit 1
		fi
		old="$(app_pid)"
		[ -z "$old" ] || ax quit "$old"
		clips=("$@")
		if [ ${#clips[@]} -eq 0 ]; then
			clip="$(default_clip)"
			if [ -n "$clip" ]; then clips=("$clip"); else echo "no clip in src/: opening the startup screen" >&2; fi
		fi
		# -n: a second instance even when the user's own LogGrade is open. Without it LaunchServices
		# hands the clip to whichever copy is already running, and the screenshot shows the wrong build.
		open -n -a "$APP" ${clips[@]+"${clips[@]}"}
		for _ in $(seq 1 80); do
			pid="$(app_pid)"
			if [ -n "$pid" ] && [ -n "$(ax windows "$pid" | head -1)" ]; then
				ax fit "$pid"
				[ ${#clips[@]} -eq 0 ] || wait_for_picture "$pid"
				echo "pid=$pid"
				exit 0
			fi
			sleep 0.25
		done
		echo "no window from $EXE after 20s" >&2
		exit 1
		;;
	shot)
		out="${1:?usage: shot OUT.png [--screen]}"
		pid="$(need_pid)"
		ax perm | grep -q 'screen-recording=yes' || {
			echo "NO SCREEN RECORDING PERMISSION: a capture would show the wallpaper, not the app." >&2
			echo "The user must enable their terminal in System Settings > Privacy & Security > Screen Recording." >&2
			exit 1
		}
		# The first line is the largest window, the main one.
		main="$(ax windows "$pid" | head -1)"
		[ -n "$main" ] || { echo "pid $pid has no on-screen window" >&2; exit 1; }
		region="${2:-}"
		[ "$region" != --screen ] || region="$(echo "$main" | cut -f3)"
		if [ -n "$region" ]; then
			# A popover or an open menu is a child window, and -l draws a window's children at the
			# wrong offset. The screen itself is right, once nothing covers the app. A close-up comes
			# this way too: tree coordinates are screen points, which a crop of the scaled PNG is not.
			ax front "$pid"
			sleep 0.5
			screencapture -o -x -R "$region" "$out"
		else
			# -l captures the window even when other windows cover it, so nothing has to be activated.
			screencapture -o -x -l "$(echo "$main" | cut -f1)" "$out"
		fi
		# The Read tool rejects large images. -Z also enlarges, so only shrink.
		if [ "$(sips -g pixelWidth -g pixelHeight "$out" | awk '/pixel/ {if ($2 > m) m = $2} END {print m}')" -gt 1400 ]; then
			sips -Z 1400 "$out" >/dev/null
		fi
		echo "$out"
		;;
	tree)
		ax tree "$(need_pid)"
		;;
	wait)
		ax wait "$(need_pid)" "$@"
		;;
	click)
		ax press "$(need_pid)" "$@"
		;;
	quit)
		pid="$(app_pid)"
		[ -z "$pid" ] || ax quit "$pid"
		;;
	*)
		sed -n '/^# Usage:/,/^set -/p' "$0" | sed '$d' >&2
		exit 2
		;;
esac
