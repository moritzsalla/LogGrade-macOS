import GradeKit
import SwiftUI

/// A look, then optional sections, all closed at first. The preset is meant to be the finished
/// picture, so everything under it is for a clip that needs help or a small creative move.
///
/// NO GRADING CONTROLS BEYOND THESE. Halation belongs to the presets and is tuned in their files,
/// not here (docs/BACKLOG.md). Execution order stays in `grade_chain()` (scripts/lib.sh); nothing
/// here decides it.
struct InspectorView: View {
    @ObservedObject var model: GradeModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                presetRow
                adjustStage
                stabilisationStage
                denoiseStage
                grainStage
            }
            .padding(.vertical, 18)
            .padding(.trailing, 16)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .background(Palette.panel)
    }

    private var adjustStage: some View {
        stage(
            "Adjust", isOn: enabledBinding(.adjust),
            help: "For a clip that needs help, or a small move of your own. Each clip keeps its "
                + "own. Switched off, this clip is the look as it ships."
        ) {
            HStack(spacing: Space.xs) {
                Toggle(
                    "Match exposure",
                    isOn: Binding(get: { model.adjust.match }, set: { model.setMatch($0) })
                )
                .toggleStyle(.checkbox)
                .font(Type.label)
                .foregroundColor(Palette.inkSecondary)
                HelpButton(
                    text: "Evens out brightness and colour between clips shot in different "
                        + "light, so a shoot looks like one shoot.\n\nLeave it on for most "
                        + "footage. Turn it off for a clip that should stay the way you exposed "
                        + "it: a night scene meant to be dark, a bright beach meant to glow, a "
                        + "sunset whose warm cast is the point.")
            }
            control("Exposure", $model.adjust.exposure, -3...3, format: "%+.2f", default: 0)
            control("Warmth", $model.adjust.warmth, -1...1, default: 0)
            control("Tint", $model.adjust.tint, -1...1, default: 0)
            control("Contrast", $model.adjust.contrast, 0.8...1.8, default: 1)
            control("Saturation", $model.adjust.saturation, 0.6...1.6, default: 1)
        }
        // Adjust is per clip, so with no clip there is nothing for it to move.
        .disabled(model.selectedClip == nil)
    }

    /// Per clip, because shake is a property of the shot.
    private var stabilisationStage: some View {
        stage(
            "Stabilisation",
            isOn: Binding(get: { model.stabilise }, set: { model.stabilise = $0 }),
            help: "Smooths handheld shake in this clip. It crops in slightly. Not shown in the "
                + "still; it is in the export."
        ) {
            control(
                "Strength", $model.stabilisationStrength, 0...60, format: "%.0f",
                default: model.defaultLook.stabilisationSmoothing)
        }
        .disabled(model.selectedClip == nil)
    }

    private var denoiseStage: some View {
        stage(
            "Denoise", isOn: enabledBinding(.denoise),
            help: "For dim and night footage. Daylight footage is already clean. Not shown in "
                + "the still, and it makes the export slower."
        ) {
            control(
                "Strength", $model.denoiseStrength, 0...2, format: "%.1f",
                default: model.defaultLook.finish.denoise)
        }
        .disabled(model.selectedClip == nil)
    }

    /// A switch only. Each preset carries its own grain, and that is the point of it.
    private var grainStage: some View {
        stage(
            "Grain", isOn: enabledBinding(.grain),
            help: "The grain of this look's film stock. Not shown in the still; it is in the "
                + "export.",
            last: true
        ) { EmptyView() }
        .disabled(model.selectedClip == nil)
    }

    private func enabledBinding(_ stage: Look.Stage) -> Binding<Bool> {
        Binding(
            get: { !model.bypassed.contains(stage) },
            set: { model.setEnabled(stage, $0) })
    }

    private var presetRow: some View {
        HStack(spacing: 8) {
            Text("look").font(Type.label).foregroundColor(Palette.inkSecondary)
            Picker(
                "",
                selection: Binding(
                    get: { model.lookName },
                    set: { model.apply(preset: $0) })
            ) {
                ForEach(model.project.presets.map(\.name), id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden().frame(width: 150)
            // BORDERED, NOT TINTED. The accent is spent on the picture only (docs/APP_DESIGN.md).
            //
            // NO AUTO BUTTON. It stretched every clip to fill the histogram, which turned an
            // overcast wall bright; the rendering and the per-clip metering are what make a
            // clip right with no step at all.
            Button("reset") { model.resetAdjustments() }
                .buttonStyle(.bordered).controlSize(.small).font(Type.label)
                .disabled(!model.hasAdjustments)
        }
        .padding(.leading, Self.inset)
        .padding(.bottom, 18)
    }

    static let inset: CGFloat = 18

    /// One section, collapsible, with a switch. Which ones are open is remembered.
    ///
    /// SWITCHED OFF, THE CONTROLS DIM BUT KEEP THEIR VALUES, so switching back is what you had. A
    /// slider left live while its section is off moves nothing, which reads as broken.
    private func stage<Content: View>(
        _ title: String, isOn: Binding<Bool>,
        help: String? = nil, last: Bool = false,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        let open = Binding(
            get: { model.openStages.contains(title) },
            set: { model.setStage(title, open: $0) })
        let enabled = isOn.wrappedValue
        return DisclosureGroup(isExpanded: open) {
            VStack(alignment: .leading, spacing: Space.s) { content() }
                .padding(.top, Space.s)
                .opacity(enabled ? 1 : 0.4)
                .disabled(!enabled)
        } label: {
            HStack(spacing: Space.xs) {
                Text(title)
                    .font(Type.heading)
                    .foregroundColor(enabled ? Palette.ink : Palette.inkTertiary)
                if let help { HelpButton(text: help) }
                Spacer(minLength: 0)
                Toggle("", isOn: isOn)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    // Neutral, not the accent (docs/APP_DESIGN.md).
                    .tint(Palette.inkSecondary)
                    .help("Switch \(title.lowercased()) \(enabled ? "off" : "on")")
            }
            .contentShape(Rectangle())
        }
        .padding(.leading, Self.inset)
        .padding(.bottom, last ? 0 : Space.l)
    }

    /// A label, a track, and a readout you can type into. Dragging finds a value; typing repeats
    /// one.
    private func control(
        _ label: String, _ value: Binding<Double>,
        _ range: ClosedRange<Double>, format: String = "%.3f",
        default original: Double? = nil
    ) -> some View {
        ControlRow(
            label: label, value: value.wrappedValue, range: range, format: format,
            original: original, model: model, set: { value.wrappedValue = $0 }
        )
        .equatable()
    }

    /// EQUATABLE, SO A DRAG UPDATES ONE ROW. The inspector rebuilds on every look write, and
    /// without this every visible slider, label and readout was re-diffed and re-laid-out through
    /// AppKit on each tick of a drag on any one of them. Equality is the row's values only: `set`
    /// and `model` write through a key path, so a kept old closure writes to the same place.
    private struct ControlRow: View, Equatable {
        let label: String
        let value: Double
        let range: ClosedRange<Double>
        let format: String
        let original: Double?
        let model: GradeModel
        let set: (Double) -> Void

        static func == (a: Self, b: Self) -> Bool {
            a.value == b.value && a.label == b.label && a.range == b.range
                && a.format == b.format && a.original == b.original
        }

        var body: some View {
            let binding = Binding(get: { value }, set: set)
            HStack(spacing: Space.s) {
                Text(label)
                    .font(Type.label)
                    .foregroundColor(Palette.inkSecondary)
                    .frame(width: 84, alignment: .leading)
                    // DOUBLE-CLICK THE NAME TO PUT IT BACK. The name is the target rather than the
                    // track, so the gesture cannot be confused with a drag that starts with two
                    // quick clicks.
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        guard let original else { return }
                        set(original)
                        model.liveUpdate()
                        model.renderPreview()
                    }
                    .help(original == nil ? "" : "Double-click to reset")
                Slider(value: binding, in: range) { editing in
                    guard !editing else { return }
                    // On release, so the settled picture is kept for switching back.
                    model.renderPreview()
                }
                .controlSize(.mini)
                .tint(Palette.inkTertiary)
                // DURING the drag, not only after it. A control that shows nothing until you let
                // go is a control you cannot find a value with.
                .onChange(of: value) { _ in model.liveUpdate() }
                // A typed value is final, like a release.
                ValueField(value: binding, format: format) {
                    model.renderPreview()
                }
            }
        }
    }

    /// The number beside a slider: text until you click it, a field while you type.
    ///
    /// THE FIELD IS THE EXPENSIVE PART. A SwiftUI `TextField` on macOS is an `NSTextField` behind
    /// a bridge, rebuilt on every tick of a drag; as `Text` it costs almost nothing, and the field
    /// appears on the one you click.
    private struct ValueField: View {
        @Binding var value: Double
        let format: String
        let commit: () -> Void
        @State private var editing = false
        @State private var valueWhenOpened: Double?
        @FocusState private var focused: Bool

        var body: some View {
            Group {
                if editing {
                    TextField("", value: $value, formatter: InspectorView.formatter(format))
                        .textFieldStyle(.plain)
                        .focused($focused)
                        .onSubmit { editing = false }
                        .onChange(of: focused) { if !$0 { editing = false } }
                        // On leaving the field, not on submit: the formatter writes the value
                        // when focus goes, and clicking away is also how a typed value is kept.
                        // Only for a changed value: clicking a readout to look at it is not
                        // worth a three-second render.
                        .onDisappear { if value != valueWhenOpened { commit() } }
                        .onAppear {
                            valueWhenOpened = value
                            focused = true
                        }
                } else {
                    Text(String(format: format, value))
                        .contentShape(Rectangle())
                        .onTapGesture { editing = true }
                }
            }
            .font(Type.value)
            .monospacedDigit()
            .multilineTextAlignment(.trailing)
            .foregroundColor(Palette.ink)
            .frame(width: 52, alignment: .trailing)
        }
    }

    private static var formatters: [String: NumberFormatter] = [:]

    fileprivate static func formatter(_ format: String) -> NumberFormatter {
        if let cached = formatters[format] { return cached }
        let made = buildFormatter(format)
        formatters[format] = made
        return made
    }

    private static func buildFormatter(_ format: String) -> NumberFormatter {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        // POSIX, because these values are written into look.json, which uses dots. A German
        // locale renders 2.02 as "2,02" and the readout then disagrees with the file it produces.
        f.locale = Locale(identifier: "en_US_POSIX")
        // FROM THE FORMAT'S OWN PRECISION, so typing into a field keeps as many digits as its
        // readout shows.
        let precision =
            format.split(separator: ".").last
            .flatMap { Int($0.prefix(while: \.isNumber)) } ?? 3
        f.minimumFractionDigits = min(precision, 2)
        f.maximumFractionDigits = precision
        f.positivePrefix = format.contains("+") ? "+" : ""
        return f
    }
}
