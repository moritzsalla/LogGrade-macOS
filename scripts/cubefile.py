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


# THE DISPLAY EVERY CUBE ENCODES FOR: Apple playback. QuickTime, Photos and iOS decode a Rec.709-tagged
# file with the inverse of the BT.709 camera curve, not the BT.1886 gamma 2.4 a reference monitor
# uses. Measured through AVFoundation: code 0.511 displays at 0.259 linear, where 2.4 gives 0.20, so a
# rendering built for 2.4 looked milky on every Mac and iPhone, shadows 2.6 times too light. The app's
# preview is tagged the same way (LiveChain), so what is judged there is what an iPhone shows. Final
# Cut sits here; Premiere calls it viewer gamma 1.96 (QuickTime).
def display_decode(v):
    """A display code value to the light Apple playback shows for it."""
    v = max(0.0, v)
    return v / 4.5 if v < 0.081 else ((v + 0.099) / 1.099) ** (1.0 / 0.45)


def display_encode(light):
    """Light to the display code value Apple playback shows as that light."""
    light = min(1.0, max(0.0, light))
    return 4.5 * light if light < 0.018 else 1.099 * light ** 0.45 - 0.099

