#!/bin/bash
# Assembles LogGrade.app around the binary SwiftPM builds.
#
# WHY BY HAND. A SwiftUI executable without a bundle has no Info.plist, so macOS gives it no dock
# icon, no menu bar and no way to be a Finder drop target — and a window opened from one arrives
# behind everything. The bundle is four files and a directory layout, which is cheaper than
# maintaining an Xcode project for a personal tool, and it keeps the build a script rather than a
# GUI action.
#
# WHAT GOES INSIDE. The engine too: scripts/, luts/ and look.json are copied in, because the app
# should not stop working when a checkout moves. A debug build points at the working copy instead,
# so engine scripts stay editable without a rebuild — see LOGGRADE_ENGINE.
#
# WHICH CONFIGURATION. Debug by default, because that is the one that points at the working copy
# of the engine. It costs something real though: the live preview grades a frame on the CPU per
# slider tick, measured at 44ms in debug against 3.9ms in release — about 22 frames a second
# against a limit nothing reaches. Use --release when you are grading rather than building.
#
# Usage:  ./app/make-app.sh [--release]
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG=debug
[ "${1:-}" != "--release" ] || CONFIG=release

command -v swift >/dev/null || { echo "swift not installed"; exit 1; }
swift build --package-path "$ROOT/app" -c "$CONFIG"
BIN="$ROOT/app/.build/$CONFIG/LogGrade"
[ -x "$BIN" ] || { echo "no binary at $BIN"; exit 1; }

APP="$ROOT/dist/LogGrade.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/engine"
cp "$BIN" "$APP/Contents/MacOS/LogGrade"

# The engine, vendored. ffmpeg comes too: a launched app inherits no useful PATH, and this
# machine's ffmpeg lives in ~/.local/bin, which nothing in a GUI environment knows about.
cp -R "$ROOT/scripts" "$ROOT/luts" "$ROOT/look.json" "$APP/Contents/Resources/engine/"
for tool in ffmpeg ffprobe jq; do
	src="$(command -v "$tool" || true)"
	if [ -n "$src" ]; then
		cp "$src" "$APP/Contents/Resources/engine/"
	else
		echo "WARNING: $tool not found, the bundle will need it on the system" >&2
	fi
done

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key><string>LogGrade</string>
	<key>CFBundleIdentifier</key><string>local.loggrade</string>
	<key>CFBundleName</key><string>LogGrade</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>0.1</string>
	<key>LSMinimumSystemVersion</key><string>13.0</string>
	<key>NSHighResolutionCapable</key><true/>
	<key>CFBundleDocumentTypes</key>
	<array>
		<dict>
			<key>CFBundleTypeName</key><string>QuickTime Movie</string>
			<key>CFBundleTypeRole</key><string>Viewer</string>
			<key>LSItemContentTypes</key>
			<array><string>com.apple.quicktime-movie</string></array>
		</dict>
	</array>
</dict>
</plist>
PLIST

# Signed to run locally, which needs no developer account. An unsigned bundle is quarantined and
# refuses to launch; ad-hoc signing is enough for something that is never distributed.
codesign --force --sign - "$APP" >/dev/null 2>&1 || echo "WARNING: ad-hoc signing failed" >&2
echo "built $APP ($CONFIG)"
