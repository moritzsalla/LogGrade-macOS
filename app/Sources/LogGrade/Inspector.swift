import GradeKit
import SwiftUI

/// The chain, one stage per section, ordered by how often a session reaches for it rather than by
/// execution order — the everyday tonal moves first, the two lookup stages and the effect after,
/// export settings last. Execution order is unchanged and stays in `grade_chain()` (scripts/lib.sh);
/// nothing here decides it.
struct InspectorView: View {
    @ObservedObject var model: GradeModel
    /// Bound from `presetRow`'s name field. Clicking a slider or a button already moves focus
    /// away on its own; this catches the rest of the panel — labels, padding, anywhere without its
    /// own control — so the field does not keep the keyboard forever just because the next click
    /// landed on inert space.
    @FocusState private var presetNameFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                presetRow
                convertNote
                correctStage
                toneStage
                trimsStage
                filmLookStage
                hueStage
                halationStage
                deliveryStage
            }
            .padding(.vertical, 18)
            .padding(.trailing, 16)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        // ON THE SCROLL VIEW, not its content. Most stages start collapsed (`openStages`
        // defaults to only Tone), so the content is far shorter than the panel; a gesture on the
        // content alone misses every tap below the last row. The scroll view's own frame already
        // fills the column, and giving its CONTENT `maxHeight: .infinity` instead would collapse
        // scrolling to the viewport rather than the stages' true height.
        .contentShape(Rectangle())
        .onTapGesture { presetNameFocused = false }
        .background(Palette.panel)
    }

    /// A CAPTION, NOT A STAGE. It has no controls — always on, nothing to switch or open — so a
    /// full collapsible section made you skip past an empty row before reaching the first control
    /// that does something. Still worth the one line, and the help button: it is real colour work
    /// on the way to the picture, and someone will ask why nothing here is adjustable.
    @ViewBuilder private var convertNote: some View {
        HStack(spacing: Space.xs) {
            Text(conversionNote)
                .font(Type.caption)
                .foregroundColor(Palette.inkTertiary)
            HelpButton(text: conversionHelp)
        }
        .padding(.leading, Self.inset)
        .padding(.bottom, Space.l)
    }

    private var conversionNote: String {
        switch model.look.convertCube {
        case Look.neutralConversion: return "Rendered from Apple Log, holding the highlights."
        default: return "Rendered through film: \(model.look.convertCube)."
        }
    }

    private var conversionHelp: String {
        let metered =
            "\n\nEach clip's exposure and white balance are metered from the log picture before "
            + "this, so a shoot lands together; Correct adds to what it measured."
        switch model.look.convertCube {
        case Look.neutralConversion:
            return "This app's own rendering, built from Apple's published formula: it takes the "
                + "log picture to a finished one in a single step, so nothing downstream works on "
                + "highlights that have already been squeezed. It is the starting point — the "
                + "stages below adjust it, and a film preset replaces it." + metered
        default:
            return "This preset replaces the conversion with a film stock simulated from its "
                + "datasheets (spektrafilm), rendered straight from the log picture so the "
                + "highlights keep their latitude. The stock is the tone and colour, so leave the "
                + "film look and tone neutral." + metered
        }
    }

    private var correctStage: some View {
        stage(
            "Correct", bypass: .correct,
            help: "Exposure, white balance and the three wheels — shadows, midtones and "
                + "highlights, lift/gamma/gain in ASC CDL terms — run before the "
                + "conversion, on the log picture, where the highlights above white "
                + "still exist. Brightening here keeps the highlights instead of "
                + "flattening them against a ceiling.\n\nLuminance mix decides how much "
                + "of a wheel move lands on brightness against colour. At 0 the move is "
                + "colour only, because separating channels shifts saturation whether "
                + "you meant it to or not."
        ) {
            control(
                "Exposure", $model.look.correct.exposure, -3...3, format: "%+.2f",
                default: model.defaultLook.correct.exposure)
            control(
                "Temperature", $model.look.correct.temp, -1...1,
                default: model.defaultLook.correct.temp)
            control(
                "Tint", $model.look.correct.tint, -1...1,
                default: model.defaultLook.correct.tint)
            wheel(.offset, "Shadows")
            wheel(.power, "Midtones")
            wheel(.slope, "Highlights")
            control(
                "Luminance", $model.look.correct.lumMix, 0...1,
                default: model.defaultLook.correct.lumMix)
        }
    }

    @State private var hueCurve: Look.Hue.Curve = .sat

    /// Three curves in one space, switched, because they share an axis: the hue strip under them.
    private var hueStage: some View {
        stage(
            "Hue curves", bypass: .hue,
            help: "Move one colour without the others: its hue, its saturation or its "
                + "lightness. The strip along the bottom is the colour each point acts on; "
                + "drag a point up or down.\n\nThey act on the colours after the film "
                + "look, so the greens here are the greens on screen. Grey and near-grey "
                + "are left alone, so skin and sky do not tint when a neighbouring colour "
                + "moves. Double-click a curve to reset it."
        ) {
            Picker("", selection: $hueCurve) {
                Text("Saturation").tag(Look.Hue.Curve.sat)
                Text("Hue").tag(Look.Hue.Curve.rot)
                Text("Lightness").tag(Look.Hue.Curve.lum)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .controlSize(.small)
            HueCurveEditor(model: model, curve: hueCurve)
                .padding(.trailing, Space.xs)
        }
    }

    private var halationStage: some View {
        stage(
            "Halation", bypass: .halation,
            help: "The warm glow film grows around bright things, where light reflects "
                + "off the film base and exposes the red layer a second time.\n\nIt is "
                + "added in linear light before the conversion, and only past edges: a "
                + "bright field does not glow onto itself. Threshold is in scene light, "
                + "where 1 is diffuse white. Radius is a fraction of the frame's height. "
                + "Strength 0 leaves the stage out entirely."
        ) {
            control(
                "Strength", $model.look.halation.strength, 0...1.5,
                default: model.defaultLook.halation.strength)
            control(
                "Threshold", $model.look.halation.threshold, 0.25...6,
                format: "%.2f", default: model.defaultLook.halation.threshold)
            control(
                "Radius", $model.look.halation.radius, 0.001...0.03, format: "%.4f",
                default: model.defaultLook.halation.radius)
            ForEach(Array(["R", "G", "B"].enumerated()), id: \.offset) { channel, name in
                control(
                    "Tint \(name)",
                    Binding(
                        get: { model.look.halation.tint(channel) },
                        set: { model.look.halation.setTint(channel, $0) }),
                    0...1, format: "%.2f",
                    default: model.defaultLook.halation.tint(channel))
            }
        }
    }

    private var filmLookStage: some View {
        stage(
            "Film look", bypass: .filmLook,
            help: "A film-emulation lookup, applied after the conversion.\n\nThe tone "
                + "curve below was set with this cube already in the chain, so changing "
                + "one without the other is a different grade rather than another "
                + "stock. Switch them together using a preset."
        ) {
            cubePicker($model.look.lookLUT, options: model.availableLooks)
            control(
                "Strength", $model.look.lookStrength, 0...1, format: "%.2f",
                default: model.defaultLook.lookStrength)
            printSubsection
        }
    }

    /// FOLDED INTO FILM LOOK, NOT ITS OWN STAGE. The default is "none" — off — and a whole
    /// section that is usually empty was a row to explain or hide rather than one worth reading
    /// (backlog). It still needs its own switch: `.print` bypasses independently of `.filmLook`
    /// at the engine (`Look.bypassing`), so a look can stay on with the print off, or the print
    /// can stay reachable with the look off — the switch below overrides Film look's own
    /// `.disabled(!enabled)` for exactly that reason.
    private var printSubsection: some View {
        let enabled = !model.bypassed.contains(.print)
        return VStack(alignment: .leading, spacing: Space.s) {
            HStack(spacing: Space.xs) {
                Text("Print")
                    .font(Type.label)
                    .foregroundColor(enabled ? Palette.inkSecondary : Palette.inkTertiary)
                HelpButton(
                    text: "The paper stock the negative was printed on — Kodak 2383 is the "
                        + "cinema print stock — applied after the film look. Off by default: "
                        + "it adds the print's own contrast and colour, which at full strength "
                        + "over a tuned tone curve is usually too much.")
                Spacer(minLength: 0)
                bypassToggle(
                    isOn: Binding(
                        get: { enabled },
                        set: { model.setEnabled(.print, $0) }),
                    label: "print")
            }
            VStack(alignment: .leading, spacing: Space.s) {
                cubePicker($model.look.printLUT, options: model.availablePrints)
                control(
                    "Strength", $model.look.printStrength, 0...1, format: "%.2f",
                    default: model.defaultLook.printStrength)
            }
            .opacity(enabled ? 1 : 0.4)
            .disabled(!enabled)
        }
        .padding(.top, Space.xs)
        // OVERRIDES FILM LOOK'S OWN `.disabled`, for the whole subsection. `.print` bypasses
        // independently of `.filmLook` at the engine, so this switch — and, when it is on, the
        // picker and strength above it — must stay reachable even with the look switched off.
        .disabled(false)
    }

    private var toneStage: some View {
        stage(
            "Tone", bypass: .tone,
            help: "Brightness and contrast, applied to the luma plane only so the "
                + "colour is untouched. Applying a curve per channel crushes a "
                + "saturated colour's two low channels harder than its high one, which "
                + "is what makes signage glow.\n\nMidtone is a gamma, so higher is "
                + "darker. The graph beside the picture is this curve."
        ) {
            control(
                "Midtone", $model.look.tone.gamma, 1...2.6,
                default: model.defaultLook.tone.gamma)
            control(
                "Contrast", $model.look.tone.contrast, 0.8...1.8,
                default: model.defaultLook.tone.contrast)
            control(
                "Pivot", $model.look.tone.pivot, 0.25...0.65,
                default: model.defaultLook.tone.pivot)
            control(
                "Shoulder", $model.look.tone.shoulder, 0...0.8,
                default: model.defaultLook.tone.shoulder)
            control(
                "Toe", $model.look.tone.toe, 0...0.8,
                default: model.defaultLook.tone.toe)
            control(
                "Black", $model.look.tone.black, -0.08...0.08, format: "%+.3f",
                default: model.defaultLook.tone.black)
        }
    }

    private var trimsStage: some View {
        stage(
            "Colour", bypass: .trims,
            help: "The last small moves, after the curve. Warmth acts on the midtones "
                + "only, so it barely moves a bright sky or a deep shadow."
        ) {
            control(
                "Saturation", $model.look.colour.saturation, 0.6...1.6,
                default: model.defaultLook.colour.saturation)
            control(
                "Warmth", $model.look.colour.warmth, -0.12...0.12, format: "%+.3f",
                default: model.defaultLook.colour.warmth)
        }
    }

    private var deliveryStage: some View {
        stage(
            "Delivery", bypass: .delivery,
            help: "Grain and stabilisation are applied to the video, never to the "
                + "preview. Both need moving footage to judge, so a still leaves them "
                + "out rather than showing a version that is not what renders.\n\n"
                + "Grain shadows and highlights set how much grain reaches black and "
                + "white, as film prints do: most in the midtones, less at either end. "
                + "Both at 1 is flat grain.\n\nThe switch turns off grain, sharpening and "
                + "chroma denoise; the stabiliser is switched per clip. With every stage "
                + "off, the export is Apple's conversion alone.",
            last: true
        ) {
            control(
                "Grain", $model.look.grainStrength, 0...20, format: "%.0f",
                default: model.defaultLook.grainStrength)
            control(
                "Grain shadows", $model.look.grainShadows, 0...1, format: "%.2f",
                default: model.defaultLook.grainShadows)
            control(
                "Grain highs", $model.look.grainHighlights, 0...1, format: "%.2f",
                default: model.defaultLook.grainHighlights)
            control(
                "Stabiliser", $model.look.stabilisationSmoothing, 0...60, format: "%.0f",
                default: model.defaultLook.stabilisationSmoothing)
        }
    }

    /// One wheel, as three channel sliders.
    ///
    /// NOT A COLOUR WHEEL, deliberately. A wheel is quicker to throw a look with and worse at
    /// repeating one, and repeatability is what this app is for: the same grade across nineteen
    /// clips. Three rows you can also type into give that, and they reuse the drag-live-then-
    /// render plumbing every other control already has.
    ///
    /// The ranges are the ones the engine's generator is sane over, and the generator refuses a
    /// power of zero, which is why gamma starts above it.
    @ViewBuilder private func wheel(_ which: Look.Correct.Wheel, _ title: String) -> some View {
        let range: ClosedRange<Double> = which == .offset ? -0.2...0.2 : 0.5...2
        ForEach(Array(["R", "G", "B"].enumerated()), id: \.offset) { channel, name in
            control(
                "\(title) \(name)",
                Binding(
                    get: { model.look.correct.value(which, channel) },
                    set: { model.look.correct.setValue(which, channel, $0) }),
                range, format: which == .offset ? "%+.3f" : "%.3f",
                default: which.neutral)
        }
    }

    @State private var newPresetName = ""

    /// The preset: a look cube with its tone and trims, switched as one. Above the chain, because
    /// it is what the chain starts from.
    private var presetRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("preset").font(Type.label).foregroundColor(Palette.inkSecondary)
                Picker(
                    "",
                    selection: Binding(
                        get: { model.project.activePreset },
                        set: { model.apply(preset: $0) })
                ) {
                    ForEach(model.project.presets.map(\.name), id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden().frame(width: 150)
                // BORDERED, NOT TINTED. The accent is spent on the picture only — the selected
                // clip's edge and the curve, not a control (docs/APP_DESIGN.md) — so prominence
                // here comes from shape against "save"'s plain text, not colour.
                Button("auto") { model.autoTone() }
                    .buttonStyle(.bordered).controlSize(.small).font(Type.label)
                    .disabled(model.selectedClip == nil)
                // Back to the active preset, not to neutral: the preset is the finished starting
                // point, and the controls are fine tuning on top of it.
                Button("reset") { model.resetAdjustments() }
                    .buttonStyle(.bordered).controlSize(.small).font(Type.label)
                    .disabled(!model.hasAdjustments || model.project.active == nil)
                if model.hasUnsavedChanges {
                    Text("adjusted").font(Type.caption).foregroundColor(Palette.plate)
                }
            }
            HStack(spacing: 6) {
                TextField("save the grade as…", text: $newPresetName)
                    .textFieldStyle(.roundedBorder)
                    .font(Type.label)
                    .frame(width: 160)
                    .focused($presetNameFocused)
                    .onSubmit {
                        model.savePreset(named: newPresetName)
                        newPresetName = ""
                        presetNameFocused = false
                    }
                Button("save") {
                    model.savePreset(
                        named: newPresetName.isEmpty
                            ? model.project.activePreset
                            : newPresetName)
                    newPresetName = ""
                    presetNameFocused = false
                }
                .buttonStyle(.borderless).font(Type.label)
            }
        }
        .padding(.leading, Self.inset)
        .padding(.bottom, 18)
    }

    static let inset: CGFloat = 18

    /// One stage of the chain, collapsible, with a switch that takes it out of the grade.
    ///
    /// COLLAPSIBLE BECAUSE MOST OF IT IS NOT IN USE AT ONCE. Thirty-four controls in one column is
    /// a wall, and a grading session touches one stage at a time. Which ones are open is
    /// remembered, so the panel you left is the panel you come back to.
    ///
    /// The long explanation that used to sit under each stage is behind the help button now. Apple
    /// puts reference text in a popover rather than in the panel, and a paragraph of prose under
    /// every control is the fastest way to make a dense inspector unreadable.
    ///
    /// EVERY STAGE HERE BYPASSES. Convert doesn't — it has no controls — so it is `convertNote`,
    /// not this.
    ///
    /// SWITCHED OFF, THE CONTROLS DIM BUT KEEP THEIR VALUES, so switching back is the grade you
    /// had. A slider left live while its stage is off moves nothing, which reads as broken.
    private func stage<Content: View>(
        _ title: String, bypass: Look.Stage,
        help: String? = nil, last: Bool = false,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        let open = Binding(
            get: { model.openStages.contains(title) },
            set: { model.setStage(title, open: $0) })
        let enabled = !model.bypassed.contains(bypass)
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
                bypassToggle(
                    isOn: Binding(
                        get: { enabled },
                        set: { model.setEnabled(bypass, $0) }),
                    label: title)
            }
            .contentShape(Rectangle())
        }
        .padding(.leading, Self.inset)
        .padding(.bottom, last ? 0 : Space.l)
    }

    /// The small switch beside a stage's name, and beside Print's inside Film look — same look
    /// wherever a bypass is offered, built once so the two cannot drift.
    private func bypassToggle(isOn: Binding<Bool>, label: String) -> some View {
        Toggle("", isOn: isOn)
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
            // Neutral, not the accent (docs/APP_DESIGN.md).
            .tint(Palette.inkSecondary)
            .help(
                isOn.wrappedValue
                    ? "Switch \(label.lowercased()) off" : "Switch \(label.lowercased()) on")
    }

    /// A film cube by stem, or none. The look and the print are the same control over different
    /// folders, so they share one body and cannot come to refresh the picture differently.
    private func cubePicker(_ selection: Binding<String>, options: [String]) -> some View {
        Picker("", selection: selection) {
            Text("None").tag("none")
            ForEach(options, id: \.self) { Text($0).tag($0) }
        }
        .labelsHidden()
        .onChange(of: selection.wrappedValue) { _ in
            model.liveUpdate()  // instantly, from the cubes already in memory
            model.renderPreview()  // then the exact frame, as with every control
        }
    }

    /// A label, a track, and a readout you can type into. Dragging finds a value; typing repeats
    /// one, and a grading tool needs both.
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
                    // DOUBLE-CLICK THE NAME TO PUT IT BACK. Every grading tool does this, and
                    // without it the only way to undo one control is to remember the number it
                    // held. The name is the target rather than the track, so the gesture cannot be
                    // confused with a drag that happens to start with two quick clicks.
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        guard let original else { return }
                        set(original)
                        model.refreshCurve()
                        model.liveUpdate()
                        model.renderPreview()
                    }
                    .help(original == nil ? "" : "Double-click to reset")
                Slider(value: binding, in: range) { editing in
                    if editing {
                        model.beginDrag()
                    } else {
                        model.refreshCurve()
                        // On release: the exact render confirms the live one.
                        model.renderPreview()
                    }
                }
                .controlSize(.mini)
                .tint(Palette.inkTertiary)
                // DURING the drag, not only after it. A grading control that shows nothing until
                // you let go is a control you cannot find a value with.
                .onChange(of: value) { _ in model.liveUpdate() }
                // A typed value is final, like a release, so it gets the exact render a release
                // gets.
                ValueField(value: binding, format: format) {
                    model.refreshCurve()
                    model.renderPreview()
                }
            }
        }
    }

    /// The number beside a slider: text until you click it, a field while you type.
    ///
    /// THE FIELD IS THE EXPENSIVE PART. A SwiftUI `TextField` on macOS is an `NSTextField` behind
    /// a bridge, and the inspector rebuilds on every tick of a drag — so thirty-four live text
    /// fields were being reconstructed sixty times a second, to show numbers nobody was typing
    /// into. As `Text` they cost almost nothing, and the field appears on the one you click.
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
        // readout shows. A fixed maximum of three rounded Radius ("%.4f") on every edit.
        let precision =
            format.split(separator: ".").last
            .flatMap { Int($0.prefix(while: \.isNumber)) } ?? 3
        f.minimumFractionDigits = min(precision, 2)
        f.maximumFractionDigits = precision
        f.positivePrefix = format.contains("+") ? "+" : ""
        return f
    }
}

/// Small explanatory text, the same weight everywhere so it recedes behind the controls.
private struct Note: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(Type.caption)
            .foregroundColor(Palette.inkTertiary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 300, alignment: .leading)
    }
}

/// The tone curve, drawn from the engine's own table, in the colour the tool measures.
struct CurveView: View {
    let curve: ToneCurve?

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Rectangle().fill(Palette.well)
                Path { p in
                    p.move(to: CGPoint(x: 0, y: geo.size.height))
                    p.addLine(to: CGPoint(x: geo.size.width, y: 0))
                }.stroke(Palette.hairline, lineWidth: 1)
                if let curve {
                    Path { p in
                        let steps = 128
                        for i in 0...steps {
                            let x = Double(i) / Double(steps)
                            let point = CGPoint(
                                x: x * geo.size.width,
                                y: (1 - curve.value(at: x)) * geo.size.height)
                            if i == 0 { p.move(to: point) } else { p.addLine(to: point) }
                        }
                    }.stroke(Palette.plate, lineWidth: 1.4)
                }
            }
            .border(Palette.hairline)
        }
    }
}
