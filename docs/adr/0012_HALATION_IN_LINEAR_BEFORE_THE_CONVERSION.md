# Halation is added in linear light, before the conversion, and only past edges

Halation is the warm glow bright things spill into the dark around them. A cube cannot produce it,
because it is spatial. It is its own stage, between the input correction and Apple's conversion.

## Considered options

- **After the conversion.** Rejected. The conversion has already landed every highlight on the
  same ceiling, so a sky and a white car would glow the same. Apple Log still holds about twelve
  stops of that difference, so the glow is computed there, in linear light.
- **Blur the highlights and add all of it.** Rejected by eye: an overcast sky glowed onto itself
  and turned pink.
- **Edge-only: add `blur(highlight) − highlight`, clamped at zero.** Shipped. A bright field is left
  alone, and the glow lands on the dark side of an edge.

## How

`halation_prefix` in `scripts/lib.sh` builds the graph from four 1D cubes that
`make-halation-luts.py` generates. The float traps it is built around (clamping filters, `lut1d`'s
domain, `gblur` steps) and the cost measurements live beside that code. The glow is computed at
quarter resolution, which costs little and is visually the same as full resolution.

## Consequences

- **A strength of 0 removes the stage from the graph.** Even idle, the float round trip moves the
  picture by 0.23 code values on average, so neutral must mean absent.
- **The preview is held two ways.** `LiveHalation`'s arithmetic is compared exactly with the
  generator's cubes. Its blur cannot be, so `LiveChainTests` holds it to the render.
- **The staged path refuses halation and the input correction.** A baseline is already converted.
- **Threshold is in scene light, radius in frame height.** 1.0 is diffuse white. A radius of 0.006
  covers the same part of the picture at any resolution.
