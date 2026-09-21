"""
What every generated .cube shares: a TITLE that doubles as its freshness fingerprint, and a write
that cannot be observed half-done.

FRESHNESS IS BY CONTENT. git does not preserve mtime, so a committed cube always lands newer than
the file it was generated from and would be trusted forever. Each generator stamps its parameters
into the TITLE and skips the write when the TITLE already matches.

That makes the TITLE's number format part of the check, and the three generators each had their
own. Two used %g, which keeps six significant digits: an exposure of 0.1234567 and one of 0.1234568
wrote the same TITLE, so the second run trusted a cube built at the first. `number` is the one
format, and it is exact.
"""
import os


def number(v):
    """A float, spelled so that two different values never spell the same. repr is the shortest
    string that round-trips, so 0.6 stays "0.6" rather than growing noise digits."""
    return repr(float(v))


def title(text):
    return 'TITLE "%s"' % text


def is_current(path, title_line):
    """True when `path` already starts with exactly this TITLE line."""
    try:
        with open(path) as fh:
            return fh.readline().rstrip("\n") == title_line
    except OSError:
        return False


def write_staged(path, text):
    """Write then rename, never write in place. is_current reads only the first line, so a cube
    truncated by an interrupted write keeps a valid-looking TITLE and is trusted as current forever
    — silently grading every clip through a partial table. Staging makes that state unobservable."""
    partial = path + ".partial"
    try:
        with open(partial, "w") as fh:
            fh.write(text)
        os.replace(partial, path)
    except BaseException:
        if os.path.exists(partial):
            os.unlink(partial)
        raise


# THE DISPLAY EVERY CUBE ENCODES FOR: Apple playback. AVFoundation shows a 1-1-1 file through the
# "HDTV" ICC profile CoreVideo builds from those tags: Rec.709 primaries and a pure gamma, curv 0x01F6
# = 502/256. Not BT.1886's 2.4 (a rendering built for it looked milky on every Mac and iPhone) and
# NOT the inverse BT.709 OETF (CGColorSpace.itur_709): the two agree at mid grey (0.259 linear at code
# 0.502) and so passed a mid-grey check, but the OETF's linear toe shows code 23/255 2.2 times too
# light. Delivered proofs of four clips decoded by AVFoundation, as sRGB: this gamma 0.5-0.6/255 off
# on average; the OETF +9 to +13 in shadows (codes < 0.15), +6 in the lower mids. The app's preview is
# tagged with the same CoreVideo space (LiveChain), so what is judged there is what playback shows.
# Premiere calls it viewer gamma 1.96 (QuickTime).
APPLE_DISPLAY_GAMMA = 502.0 / 256.0


def display_decode(v):
    """A display code value to the light Apple playback shows for it."""
    return max(0.0, v) ** APPLE_DISPLAY_GAMMA


def display_encode(light):
    """Light to the display code value Apple playback shows as that light."""
    return min(1.0, max(0.0, light)) ** (1.0 / APPLE_DISPLAY_GAMMA)

