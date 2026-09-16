# Plan: one LogGrade.app for both Macs

Steps 1–3 done on the Intel Mac (2026-09-15); step 4 and everything on the Apple Mac are not.
Written 2026-09-14.

**Goal.** Build once on the Intel Mac, copy the bundle to the Apple silicon Mac, double-click, and
it runs natively on both. Personal use on two machines, so no Apple Developer account.

**Decision: one universal bundle rather than two apps.** One file to copy, one build, and no way to
send the wrong one. The app is a few MB, and doubling it costs nothing.

---

## What is true today (measured 2026-09-15)

- `make-app.sh` builds `--arch arm64 --arch x86_64` and refuses any bundled executable that is not
  universal. Its tools come from `app/fetch-tools.sh`, pinned by `app/tools.sha256`; that script's
  header records each source, version, licence and why.
- ffmpeg is two different builds: evermeet 9.0.1 for x86_64 (the `~/.local/bin` one, same sha256)
  and OSXExperts 9.0 for arm64, the only static arm64 build found with libvidstab.
- Toolchain: Swift 5.9.2, Xcode 15.2, macOS 13 SDK. `Package.swift` is pinned to 5.9, and that pin
  stays.
- `python3` is required at render time, not only in tests. `grade.sh` calls
  `make-tone-lut.py`, `make-correct-lut.py`, `make-halation-luts.py` and `solve-exposure.py`. Those
  scripts use only the standard library. `/usr/bin/python3` exists on every Mac as a developer-tools
  placeholder, so the preflight now runs it and names `xcode-select --install` when it refuses.
- The preflight used to ignore the tools inside the bundle, so a Mac without its own ffmpeg was
  told ffmpeg was missing. It now searches the engine's directory first, as a render does.

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
- **The halves are NOT the same build, deliberately.** No static arm64 9.0.1 with libvidstab
  exists, and replacing the Intel half would move the image on the Mac where it is judged, with
  nothing to catch it: `--conformance` runs the same new binary on both sides, and
  `tests/render-golden.sh` skips on a different ffmpeg build or architecture rather than failing.
  The cost is on the Apple Mac: 9.0 against 9.0.1, NEON against x86 SIMD, so its renders may not
  be byte-identical to this Mac's. That is to be measured there, not assumed.
- Required in both halves: every filter and encoder the scripts name, including `vidstabdetect`,
  `zscale`, `libx264`, `prores_ks`. The arm64 half cannot run here, so it was checked by `strings`.
- Statically linked only. A Homebrew ffmpeg depends on libraries under `/opt/homebrew`, so it
  would break on any Mac without Homebrew.
- jq: the official GitHub releases ship `jq-macos-arm64` and `jq-macos-amd64`.
- Merge each pair with `lipo -create`, from `~/.local/share/loggrade-tools/{x86_64,arm64}/`.

### 3. Sign every executable, not just the bundle
Apple silicon **kills unsigned arm64 code** on launch. An ad-hoc signature is enough. A
`lipo`-merged binary carries no signature, and `codesign --sign - "$APP"` does not reach
executables under `Contents/Resources/engine/`. So sign each one first, then the bundle:

```sh
for t in ffmpeg ffprobe jq; do codesign --force --sign - "$APP/Contents/Resources/engine/$t"; done
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
```

A failed signature stops the build. `--deep` alone passed a bundle whose tools were unsigned, so
the bats test verifies each tool too.

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

- On this Mac (done): the bats bundle test checks `lipo -verify_arch` and signatures on the app
  and all three tools, and went red with ffprobe single-arch. One `PROOF=2` render ran through the
  bundle's own engine and tools. Not done: launching the bundle from the Finder.
- On the Apple Mac, the only place the arm64 half can be proven (none done yet):
  - Launch, and confirm Activity Monitor shows *Kind: Apple*, not *Intel*, for LogGrade and for
    ffmpeg during a render. The startup screen should list no problems; without the developer
    tools it names `xcode-select --install`.
  - Render one clip, including stabilisation.
  - Render the same clip at the same settings on both Macs and compare the frames. Record how far
    apart they are; do not expect byte-identical. Name each output after the machine that rendered
    it (CLAUDE.md: two renders of one clip can write the same path).
  - If that Mac runs macOS 13: jq 1.8.2 is stamped `minos 14.0`. Its x86_64 build runs on 13 here;
    confirm the arm64 one does.
