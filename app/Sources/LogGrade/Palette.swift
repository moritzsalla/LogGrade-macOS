import SwiftUI

/// The room the picture hangs in.
///
/// ACHROMATIC ON PURPOSE. Surrounding luminance and cast bias colour perception, which is why
/// grading suites are grey rooms — the Bench's own header says the same thing about its dark
/// theme. So every neutral here is a true grey, and the only saturated thing on screen is the
/// photograph.
///
/// The one accent is RAL 1021, the plate yellow this pipeline measures against. A tool's accent
/// should be a colour it knows the value of.
enum Palette {
    static let surround = Color(red: 0.098, green: 0.098, blue: 0.098)   // #191919
    static let panel = Color(red: 0.125, green: 0.125, blue: 0.125)      // #202020
    static let well = Color(red: 0.055, green: 0.055, blue: 0.055)       // #0E0E0E
    static let hairline = Color(red: 0.180, green: 0.180, blue: 0.180)   // #2E2E2E
    static let ink = Color(red: 0.910, green: 0.910, blue: 0.910)        // #E8E8E8
    static let inkSecondary = Color(red: 0.604, green: 0.604, blue: 0.604)
    static let inkTertiary = Color(red: 0.431, green: 0.431, blue: 0.431)
    static let plate = Color(red: 0.953, green: 0.765, blue: 0.000)      // #F3C300, RAL 1021
    static let lamp = Color(red: 0.878, green: 0.416, blue: 0.294)       // #E06A4B
}

/// A measured value: monospaced with tabular figures, so a column of readouts lines up and can be
/// compared at a glance. That is the difference between an instrument and a form.
struct Readout: View {
    let text: String
    var muted = false

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .regular, design: .monospaced))
            .monospacedDigit()
            .foregroundColor(muted ? Palette.inkTertiary : Palette.inkSecondary)
    }
}
