---
name: drive-loggrade
description: Build, launch, drive and screenshot the LogGrade macOS app in this repo. Use it whenever a task touches the running app — "test it in the app", "run the app", "open the app with a clip", "screenshot the window/panel/inspector/export panel", "check the UI change visually", "does it look right", README screenshots, reproducing or confirming a UI bug, clicking a control to see what happens. Use this instead of the generic `run` skill, osascript/System Events, or hand-written winid/click Swift scripts; those cost past sessions dozens of turns.
---

# Drive LogGrade

One helper: `app/drive/loggrade.sh`, run from the checkout you are in. It drives *that* checkout's `dist/LogGrade.app`. Don't write window-id, click or activation scripts of your own.

```sh
./app/make-app.sh                     # only when launch says missing or STALE: release, universal, minutes -> run_in_background
app/drive/loggrade.sh launch          # restarts this bundle, opens the first src/*.mov (main checkout's src/ from a worktree),
                                      #   returns pid= once the picture has rendered (~6s warm)
app/drive/loggrade.sh shot $S/app.png # the main window; then Read the PNG (capped at 1400px)
app/drive/loggrade.sh tree > $S/t.txt # AX tree: role "title" desc= id= val= @x,y wxh — rg it, don't cat it
app/drive/loggrade.sh click "save project"
app/drive/loggrade.sh quit
```

(`$S` = your scratchpad. Spell the helper's path out; the harness refuses a command held in a variable.)

- `launch a.mov b.mov` opens specific clips; no clip anywhere means the startup screen, said on stderr.
- `click TEXT [SECS]` / `wait TEXT [SECS]`: exact, case-insensitive match on title, description, identifier or value, polled up to 15s. SwiftUI puts a button's label in `desc=` and a picker's choice in `val=`. Several matches: the first in tree order is pressed, the rest listed on stderr; a window control beats a menu item of the same name. A control without AXPress (a row, a text field) gets a real mouse click.
- `shot OUT --screen`: for a popover, open menu or sheet. Plain `shot` (`screencapture -l`) draws child windows at the wrong offset; `--screen` brings the app forward and captures the screen under the window.
- `shot OUT X,Y,W,H`: a close-up, in the screen points `tree` prints (the PNG is scaled and Retina, so don't crop it by tree coordinates; `sips -c` silently does nothing here anyway).
- The export panel is the section headed **"deliver"** at the bottom of the left sidebar (preset picker, "save to", "Export clip", concurrency picker). After `launch` it is `shot $S/deliver.png 0,690,340,250`; re-read `rg 'val="deliver"|Export clip' $S/t.txt` if the layout moved.

## Traps

- **Permissions.** `app/drive/loggrade.sh perm` prints `accessibility=` and `screen-recording=` as this shell sees them. `shot` refuses without Screen Recording (the capture would be the wallpaper); `tree`/`click`/`wait` fail with a message without Accessibility. Then stop and tell the user: *System Settings > Privacy & Security > Screen Recording (or Accessibility) > enable the terminal or app running Claude Code, then restart it.* Nothing in-session can grant it.
- **No activation loops.** `shot` and `click` work on a covered, background window. Only typing needs focus: `click` the field, then `osascript -e 'tell application "System Events" to keystroke "…"'`.
- **Stale build.** `launch` refuses when anything in `app/Sources`, `scripts`, `luts`, `presets` or `look.json` is newer than the bundle, and names the files. Rebuild; `LOGGRADE_STALE_OK=1` only for a deliberate old-build comparison.
- **Worktree builds stay in the worktree.** The user's app is the main checkout's `dist/LogGrade.app`; it changes only when `make-app.sh` runs there after a merge. `launch` uses `open -n`, so the user's open copy is left alone. Never `killall LogGrade`.
- **Release by default.** A `--debug` build's preview is ~100× slower; that is not a bug.
- **Shared preferences.** Every copy uses the `local.loggrade` defaults (window frame, open inspector stages, `lastProject`, reopened at launch). If you save a project while driving, delete it and `defaults delete local.loggrade lastProject`, or the user's app reopens your test project.
- After an export, `wait "Export finished" 600` (the toast) before the next shot.
