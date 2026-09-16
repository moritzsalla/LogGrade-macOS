# Provenance

The engine in `scripts/`, its tests, the LUTs, `look.json` and the docs are a fork of `ffgrade`,
imported verbatim at commit:

    80e8c16c109c3b3f542997f103ca744e3291c987

The precursor is frozen and read-only. Fixes made here never reach it. It is provenance, not the
standard the image is held to: `tests/render-golden.sh` holds the default image, recorded here.

That rests on a measurement: two renders of one clip, minutes apart, produced byte-identical files
and identical packet-stream hashes, with no `-bitexact`. This ffmpeg build stamps no timestamp into
the container. If a future build does, compare `ffmpeg -i out.mp4 -map 0 -c copy -f md5 -` instead
of the files.

Apple's conversion cubes were gitignored here for a licensing reason, as they are there. This
repo no longer uses them: it renders Apple Log itself (`scripts/make-rendering-lut.py`).
