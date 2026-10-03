import AppKit
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
    // Follows the system appearance. Light mode keeps the same rule: true greys only.
    static let surround = adaptive(light: 0.925, dark: 0.098)  // #ECECEC / #191919
    static let panel = adaptive(light: 0.965, dark: 0.125)  // #F6F6F6 / #202020
    static let well = adaptive(light: 0.870, dark: 0.055)  // #DEDEDE / #0E0E0E
    static let hairline = adaptive(light: 0.820, dark: 0.180)  // #D1D1D1 / #2E2E2E
    static let ink = adaptive(light: 0.100, dark: 0.910)  // #1A1A1A / #E8E8E8
    static let inkSecondary = adaptive(light: 0.360, dark: 0.604)
    static let inkTertiary = adaptive(light: 0.540, dark: 0.431)
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

/// The type scale: four roles for text.
///
/// FOUR ROLES, NOT TEN SIZES. There were ten — 8, 9.5, 10, 10.5, 11, 12, 12.5, 13, 15, 33 — chosen
/// one control at a time, which is how an interface ends up looking assembled rather than designed.
/// The roles are macOS's own text styles (headline 13, subheadline 11, caption 10), so they
/// track the system's metrics rather than numbers typed here.
///
/// Weight carries the hierarchy rather than size, which is what keeps a panel this dense readable:
/// a heading is the same size as a value and heavier.
enum Type {
    static let heading = Font.headline
    static let label = Font.subheadline
    static let value = Font.subheadline.monospaced()
    static let caption = Font.caption
}

/// Spacing, on a 4-point grid.
///
/// Apple's layout guides are multiples of 8 with 4 as the half-step. There were fourteen values
/// before, which is the same problem the type scale had: no two panels agreed on what "a gap"
/// meant, so nothing lined up across them.
///
/// Every gap is one of these five.
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

extension Palette {
    fileprivate static func adaptive(light: CGFloat, dark: CGFloat) -> Color {
        Color(
            nsColor: NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                let v = isDark ? dark : light
                return NSColor(srgbRed: v, green: v, blue: v, alpha: 1)
            })
    }
}
