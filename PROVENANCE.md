# Provenance

The engine in `scripts/`, its tests, the LUTs, `look.json` and the docs are a fork of `ffgrade`,
imported verbatim at commit:

    80e8c16c109c3b3f542997f103ca744e3291c987

The precursor is frozen and read-only. Fixes made here never reach it. It is provenance, not the
standard the image is held to (ADR 0014). `tests/conformance.sh` reports whether the default render
still matches it, and `tests/render-golden.sh` holds the default image.

Both rest on a measurement: two renders of one clip, minutes apart, produced byte-identical files
and identical packet-stream hashes, with no `-bitexact`. This ffmpeg build stamps no timestamp into
the container. If a future build does, compare `ffmpeg -i out.mp4 -map 0 -c copy -f md5 -` instead
of the files.

Apple's two conversion cubes are gitignored here for the same licensing reason as there
(`luts/apple/SOURCE.txt`).
