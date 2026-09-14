import GradeKit
import SwiftUI

/// A sheet for one custom shape: its name, its aspect, and whether it crops at the centre.
///
/// IT DOES NOT JUDGE THE SHAPE. Save hands the typed text to `save`, which asks the engine, and a
/// refusal is shown in the words it came back in. A rule restated here would be a second opinion
/// about what the renderer accepts, and the first one written here was already wrong.
struct DeliverableEditor: View {
    let mode: ShapeEditorMode
    let save: (ShapeDraft) -> ShapeRefusal?

    @Environment(\.dismiss) private var dismiss
    @State private var draft: ShapeDraft
    @State private var refusal: ShapeRefusal?

    init(mode: ShapeEditorMode, save: @escaping (ShapeDraft) -> ShapeRefusal?) {
        self.mode = mode
        self.save = save
        _draft = State(initialValue: mode.draft)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            Text(mode.original == nil ? "New shape" : "Edit shape")
                .font(Type.heading)
                .foregroundColor(Palette.ink)
            field("name") {
                TextField("", text: $draft.name)
                    .font(Type.value)
            }
            field("aspect") {
                HStack(spacing: Space.xs) {
                    TextField("w", text: $draft.aspectWidth)
                        .font(Type.value).frame(width: 48)
                    Text(":").font(Type.value).foregroundColor(Palette.inkSecondary)
                    TextField("h", text: $draft.aspectHeight)
                        .font(Type.value).frame(width: 48)
                    Spacer()
                }
            }
            // Said beside the toggle because it is the difference between a shape that blocks
            // Convert until every clip is framed and one that never asks.
            Toggle("crop at the centre of every clip", isOn: $draft.centre)
                .toggleStyle(.checkbox)
                .font(Type.label)
                .foregroundColor(Palette.inkSecondary)
            if let refusal {
                Text(refusal.description)
                    .font(Type.caption)
                    .foregroundColor(Palette.lamp)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: Space.m) {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    refusal = save(draft)
                    if refusal == nil { dismiss() }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Space.l)
        .frame(width: 320)
        .background(Palette.panel)
    }

    private func field<Content: View>(_ label: String,
                                      @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: Space.s) {
            Text(label).font(Type.label).foregroundColor(Palette.inkSecondary)
                .frame(width: 44, alignment: .leading)
            content()
        }
    }
}
