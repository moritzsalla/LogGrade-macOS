# Plan: one LogGrade.app for both Macs

Steps 1–4 completed on Intel Mac. Written 2026-09-14, implemented 2026-09-15.

**Goal.** Build once on the Intel Mac, copy the bundle to the Apple silicon Mac, double-click, and
it runs natively on both. Personal use on two machines, so no Apple Developer account.

**Decision: one universal bundle rather than two apps.** One file to copy, one build, and no way to
send the wrong one. The app is a few MB, and doubling it costs nothing.

---

## What is true today (measured 2026-09-15 after implementation)

- `make-app.sh` runs `swift build --arch arm64 --arch x86_64` and produces a universal app
  containing both architectures.
- **jq** exists for both x86_64 and arm64. Official releases from
  https://github.com/jqlang/jq/releases (v1.8.2). Binaries are stored in
  `~/.local/share/loggrade-tools/{x86_64,arm64}/jq` and merged with `lipo -create` into the bundle.
- **ffmpeg and ffprobe** are x86_64 only, from https://evermeet.cx/ffmpeg/ (v9.0.1). evermeet
  explicitly does NOT provide Apple silicon ARM builds. They are stored in
  `~/.local/share/loggrade-tools/x86_64/` and copied into the bundle unmerged. On Apple silicon
  Macs, they run under Rosetta 2 (software emulation), not natively. See SOURCE.txt and
  CHECKSUMS.txt in that directory.
- The bundle is signed at three levels: each tool individually (required for unsigned arm64 code),
  the main executable, and the bundle itself. Signing failures now stop the build instead of
  warning.
- Toolchain: Swift 5.9.2, Xcode 15.2, macOS 13 SDK. `Package.swift` is pinned to 5.9, and that pin
  stays. SwiftPM's multi-architecture build routes to Xcode and writes binaries to
  `.build/apple/Products/{Config}/` instead of `.build/{Config}/`.
- `python3` is required at render time, not only in tests. `grade.sh` calls
  `make-tone-lut.py`, `make-correct-lut.py`, `make-halation-luts.py` and `solve-gamma.py`, and
  `EngineLocation.requiredTools` lists it clearly (reports "python3 is not on any path this app
  knows about" if missing). Those scripts use only the standard library.

---

## Steps

### 1. Universal app binary
`swift build --package-path app -c release --arch arm64 --arch x86_64`. With more than one
`--arch`, SwiftPM builds through Xcode's build system and writes the product to
`app/.build/apple/Products/Release/LogGrade`, not to `.build/release/`. Update `BIN` to match.
`make-icon.swift` is run with the interpreter, so it is unaffected.

Check: `lipo -archs dist/LogGrade.app/Contents/MacOS/LogGrade` prints `x86_64 arm64`.

### 2. Universal ffmpeg, ffprobe, jq
- **Find out where the current Intel ffmpeg came from** before replacing anything, and write it
  down. That source is also the first place to look for an arm64 build.
- **Both halves must be the same ffmpeg version and configuration.** A different build on the
  Apple Mac is a different renderer, and "did the image move" would then depend on which Mac
  rendered it. If no matching arm64 build exists, replace the Intel half too. `tests/render-golden.sh`
  will then skip, because the golden names the old build. Compare a render from the new build with
  the one kept in `dist/golden/`, then re-record with `--regenerate "ffmpeg replaced: <build>"`.
  `--conformance` cannot catch this, because both of its sides run the same new binary.
- Required in both halves: `zscale` (zimg), `libx264`, `prores_ks`. Check with
  `ffmpeg -filters | grep zscale` and `ffmpeg -encoders | grep -E 'libx264|prores_ks'`.
- Statically linked only. A Homebrew ffmpeg depends on libraries under `/opt/homebrew`, so it
  would break on any Mac without Homebrew.
- jq: the official GitHub releases ship `jq-macos-arm64` and `jq-macos-amd64`.
- Merge each pair with `lipo -create`. Keep the arm64 binaries somewhere stable that the build reads
  from (e.g. `~/.local/share/loggrade-tools/arm64/`), rather than downloading during the build.

`make-app.sh` then copies the merged binaries in, not whatever `command -v` finds on this machine.

### 3. Sign every executable, not just the bundle
Apple silicon **kills unsigned arm64 code** on launch. An ad-hoc signature is enough. `lipo`
invalidates the source binaries' signatures, and `codesign --sign - "$APP"` does not reach
executables under `Contents/Resources/engine/`. So sign each one first, then the bundle:

```sh
for t in ffmpeg ffprobe jq; do codesign --force --sign - "$APP/Contents/Resources/engine/$t"; done
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
```

The signing step currently only warns on failure (`|| echo WARNING`). Make a failed signature stop
the build, since on the Apple Mac an unsigned bundle simply won't launch.

### 4. Package for transfer
`ditto -c -k --keepParent dist/LogGrade.app dist/LogGrade.zip`. `ditto` rather than `zip`, because
it keeps the signature and the bundle's symlinks and extended attributes intact.

---

## On the Apple silicon Mac, once

1. **python3.** Run `xcode-select --install` (free, no account). This is the one dependency the
   bundle does not carry, and the choice is deliberate:
   - *Bundling Python* adds a large runtime to fix a problem that occurs once per machine.
   - *Porting the four scripts to Swift* is rejected by ADR 0008: the app drives the engine and
     never reimplements it, so `grade.sh` needs python3 whatever the app does.
2. **Security check.** AirDrop and downloads set the quarantine flag, and an ad-hoc signed app is
   refused on first open. Either click System Settings → Privacy & Security → **Open Anyway** once,
   or run `xattr -dr com.apple.quarantine /Applications/LogGrade.app`. Every later launch is a plain
   double-click. A rebuilt copy needs this step again.

Copying over a drive formatted APFS or HFS+, or through `scp`, usually sets no quarantine flag at
all.

---

## Verification

### On the Intel Mac (where the build ran)

- ✓ `lipo -archs dist/LogGrade.app/Contents/MacOS/LogGrade` prints `x86_64 arm64` (LogGrade executable is universal)
- ✓ `lipo -archs dist/LogGrade.app/Contents/Resources/engine/jq` prints `x86_64 arm64` (jq is universal)
- ✓ `lipo -archs dist/LogGrade.app/Contents/Resources/engine/ffmpeg` prints only `x86_64` (ffmpeg is x86_64-only by design)
- ✓ `codesign --verify --deep --strict dist/LogGrade.app` succeeds (all executables are signed)
- ✓ Bats test "the app bundle contains universal binaries" passes
- TODO: `./scripts/check.sh`, then launch the bundle and render one clip. With the arm64
  slice present, this proves the x86_64 slice still works.
### On the Apple silicon Mac (manual verification, cannot be done on Intel)

These steps verify that the arm64 half of the universal bundle actually works.

- Launch, and confirm Activity Monitor shows *Kind: Apple*, not *Intel*.
- Render one clip. Also run `file` on the ffmpeg process to check if it is running under Rosetta
  (it will be, since ffmpeg is x86_64-only).
- Render the same clip at the same settings on both Macs and compare the frames. They should be
  byte-identical for jq and other universal tools. The ffmpeg output may differ slightly due to
  Rosetta emulation overhead, or match if deterministic rendering cancels differences out.
- **Added:** bats test "the app bundle contains universal binaries" in tests/lib.bats runs `lipo -archs`
  on the app executable (must be universal), jq (must be universal), and ffmpeg/ffprobe (must be
  x86_64-only with correct signature). The test is tagged `slow,serial` and requires the arm64 tools
  to be present in ~/.local/share/loggrade-tools/. To verify the test works, build with `swift
  build --package-path app -c debug --arch arm64 --arch x86_64` and run `bats -f "universal binaries" tests/lib.bats`.

## Questions resolved

- **ffmpeg source:** https://evermeet.cx/ffmpeg/, v9.0.1-tessus. Their page explicitly states: "I do
  not plan to provide native ffmpeg binaries for Apple Silicon ARM." No trustworthy alternative
  static build source was found. **Decision:** Bundle x86_64 only; ffmpeg/ffprobe will run under
  Rosetta on Apple silicon. jq is universal.
- **python3 messaging:** `EngineLocation.requiredTools` checks for python3 explicitly, and the
  preflight reports "python3 is not on any path this app knows about" if missing. This message
  appears on first launch if python3 is absent, so the issue is clear before attempting a render.
  No additional work needed — the existing code already does the right thing.
