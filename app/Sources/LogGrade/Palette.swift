import GradeKit
import SwiftUI

/// The room the picture hangs in.
///
/// ACHROMATIC ON PURPOSE. Surrounding luminance and cast bias colour perception, which is why
/// grading suites are grey rooms — the Bench's own header said the same thing about its dark
/// theme. So every neutral here is a true grey, and the only saturated things on screen are the
/// photograph and the parade's traces.
///
/// The one accent is RAL 1021, the plate yellow this pipeline measures against. A tool's accent
/// should be a colour it knows the value of.
enum Palette {
    static let surround = Color(red: 0.098, green: 0.098, blue: 0.098)  // #191919
    static let panel = Color(red: 0.125, green: 0.125, blue: 0.125)  // #202020
    static let well = Color(red: 0.055, green: 0.055, blue: 0.055)  // #0E0E0E
    static let hairline = Color(red: 0.180, green: 0.180, blue: 0.180)  // #2E2E2E
    static let ink = Color(red: 0.910, green: 0.910, blue: 0.910)  // #E8E8E8
    static let inkSecondary = Color(red: 0.604, green: 0.604, blue: 0.604)
    static let inkTertiary = Color(red: 0.431, green: 0.431, blue: 0.431)
    static let plate = Color(
        red: Scopes.plateYellow.rgb.0, green: Scopes.plateYellow.rgb.1,
        blue: Scopes.plateYellow.rgb.2)  // #F3C300, RAL 1021
    static let lamp = Color(red: 0.878, green: 0.416, blue: 0.294)  // #E06A4B

    /// The parade's channels: the one sanctioned colour besides the photograph. A trace has to
    /// read as its channel at a glance, and three greys would make the parade a puzzle.
    static let scopeRed = Color(red: 0.90, green: 0.35, blue: 0.32)
    static let scopeGreen = Color(red: 0.45, green: 0.78, blue: 0.45)
    static let scopeBlue = Color(red: 0.42, green: 0.60, blue: 0.90)
}

/// The type scale: four roles for text, and four named exceptions.
///
/// FOUR ROLES, NOT TEN SIZES. There were ten — 8, 9.5, 10, 10.5, 11, 12, 12.5, 13, 15, 33 — chosen
/// one control at a time, which is how an interface ends up looking assembled rather than designed.
/// The sizes below are macOS's own metrics for a dense inspector: 13 is the system control size,
/// 11 is the small control size AppKit uses in inspectors and palettes, 10 is its caption.
///
/// Weight carries the hierarchy rather than size, which is what keeps a panel this dense readable:
/// a heading is the same size as a value and heavier.
enum Type {
    static let heading = Font.system(size: 13, weight: .semibold)
    static let label = Font.system(size: 11)
    static let value = Font.system(size: 11, design: .monospaced)
    static let caption = Font.system(size: 10)

    // THE EXCEPTIONS, named so they stay four. Each appears in one place and is not a role to
    // reach for in a new control.
    /// The app's name at the head of the clip column.
    static let title = Font.system(size: 15, weight: .semibold)
    /// The app's name on the startup screen, the one moment nothing else competes with it.
    static let splash = Font.system(size: 22, weight: .semibold)
    /// A toast's symbol, which carries the message's kind before its words are read.
    static let symbol = Font.system(size: 15)
    /// The lock beside the conversion's title: a mark on a heading, not a word.
    static let glyph = Font.system(size: 9)
}

/// Spacing, on a 4-point grid.
///
/// Apple's layout guides are multiples of 8 with 4 as the half-step. There were fourteen values
/// before, which is the same problem the type scale had: no two panels agreed on what "a gap"
/// meant, so nothing lined up across them.
///
/// NOT EVERYTHING IS ON IT YET. Most gaps are one of these five, but the panel inset (18), a few
/// row gaps in the clip column and the delivery panel (3, 6, 9, 10, 14) and the picture's
/// `Space.s + 2` predate the grid and are left as they measure — moving them is a visual change,
/// not a tidy-up. Don't copy them into a new view.
enum Space {
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let xl: CGFloat = 24
}

/// A measured value: monospaced with tabular figures, so a column of readouts lines up and can be
/// compared at a glance. That is the difference between an instrument and a form.
struct Readout: View {
    let text: String
    var muted = false

    var body: some View {
        Text(text)
            .font(Type.value)
            .monospacedDigit()
            .foregroundColor(muted ? Palette.inkTertiary : Palette.inkSecondary)
    }
}
