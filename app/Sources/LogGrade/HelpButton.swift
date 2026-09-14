import SwiftUI

/// The small "?" that opens a popover, which is where macOS puts reference text.
///
/// WHY NOT IN THE PANEL. Every stage of this chain has a paragraph behind it worth reading once —
/// why the correction runs before Apple's conversion, why the tone curve only touches luma — and
/// all of it used to sit under the controls as running prose. Read once it is useful; read on
/// every visit it is a wall between you and the sliders. A popover keeps it one click away and out
/// of the way, which is what Apple's own inspectors do.
struct HelpButton: View {
    let text: String
    @State private var shown = false

    var body: some View {
        Button { shown.toggle() } label: {
            Image(systemName: "questionmark.circle")
                .font(Type.label)
                .foregroundColor(Palette.inkTertiary)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $shown, arrowEdge: .trailing) {
            Text(text)
                .font(Type.label)
                .foregroundColor(Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 260, alignment: .leading)
                .padding(Space.m)
        }
    }
}
