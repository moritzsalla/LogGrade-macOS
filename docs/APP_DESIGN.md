# App design rules

Each rule came from grading real clips or from a screenshot, not from theory.

- **The photograph is the only saturated thing on screen.** Surround, panels and ink are neutral
  greys, because any cast in the chrome biases judgement.
- **The accent is spent on three things only:** the rail's locked-stage dot, the selected clip's
  edge, and the curve. A yellow slider track everywhere competes with the picture. The lamp colour
  is for refusals only, and there is no green.
- **Numbers use a POSIX formatter.** Values are written into `look.json` with dots, and a locale
  decimal comma made the panel disagree with the file.
- **Readouts are SF Mono with tabular figures.** Labels are SF Pro, in sentence case.
- **Type and spacing are on a scale:** four type roles and five spacings, on macOS's own metrics.
- **Derive state, never copy it.** Thumbnails, the Convert count and the drop target each broke
  because state lived in two places. Derive it, or route it through one door.
- **A busy indicator must not grey the picture.** Use a corner spinner, since the picture is being
  judged at exactly that moment.
- **Disabled controls say why.** Convert can be blocked for four reasons; show which one.
- **Standard menus are required.** ⌘Q, ⌘C, ⌘V and ⌘A only reach a text field through the menu bar's
  responder chain.
- **Reference text goes behind a help button,** not as prose on every visit.
- **For each control, ask how long its effect takes to see.** A control you cannot watch while
  moving it is one nobody can find a value with (ADR 0009).
