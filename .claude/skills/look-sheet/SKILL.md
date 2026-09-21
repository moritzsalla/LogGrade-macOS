---
name: look-sheet
description: Render a contact sheet of real clips across looks, presets or checkouts, to judge a look by eye. Use whenever a look, grade, tone, colour, grain, halation or preset change needs judging, whenever the user asks to see, compare, preview or proof renders ("show me", "compare X against Y", "before/after", "side by side", "so I can pick"), when comparing a worktree against main, and always before asking the user to sign off a look. Use it instead of writing a proof or contact-sheet script; they were rewritten ten times and each copy got the colour wrong.
---

# Look sheet

`scripts/look-sheet.sh` renders every tile through `grade.sh` and tiles them: a row per clip, a column
per look, an optional reference row on top. `-h` lists the flags. Run from the checkout whose change is
being judged; footage comes from the main checkout's `src/` when this one has none.

```sh
./scripts/look-sheet.sh -n                                   # neutral + every preset, sample of src/
./scripts/look-sheet.sh -n -c neutral -c portra800           # two looks
./scripts/look-sheet.sh -n -c main:portra160 -c portra160    # main's preset vs this worktree's
./scripts/look-sheet.sh -n -r -c portra160 ~/Movies/"Nina facade plants prores shots"  # + the scans
./scripts/look-sheet.sh -n -d -c super8                      # grain and sharpening: the delivered file
```

- `src/` may hold one clip; the Nina folder above has 19, and the script samples four across a folder.
- Four clips by three looks plus references took 3 minutes on the Intel Mac; `-d` renders a proof
  per tile and is slower. Run big sheets in the background.
- Without `-d`, a tile is the grade only (the app's preview): no grain, sharpening or crop. Judge
  grain and definition with `-d`.

## Reading it

Read the PNG yourself first, then show it with one sentence per column on what differs. Pass `-n`
while iterating, and open the final one once (drop `-n`, or `open -a Preview <path>`).
Rows are clips, so compare down a column for consistency and across a row for the choice.
With `-r`, the references are the partner's analog scans: the target, not a column to pick.

## The colour trap

Don't hand-roll a sheet. A render's codes are shown by Apple playback through gamma 1.961, and a PNG
without a profile opens as sRGB, so a plain ffmpeg tile shows every look ~9/255 too dark ("all look a
bit dark"); reference scans carry Adobe RGB, which ffmpeg drops. The script converts both to sRGB and
tags the sheet; the measurement is beside `DISPLAY_TO_SRGB` in the script.
