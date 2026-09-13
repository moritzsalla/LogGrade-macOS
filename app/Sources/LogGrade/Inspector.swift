import GradeKit
import SwiftUI

/// The chain, drawn as a spine.
///
/// A hairline rail runs down the inspector with one dot per stage: filled for the conversion,
/// which is locked, open for the stages you can move, and hollow-dotted for the ones a still
/// cannot show. Resolve shows a node graph and Baselight a layer stack for the same reason — the
/// ORDER is the grade — and here the order is also a measured artefact: corrections before the
/// conversion, tone after the look and on luma only. Drawing it as a line means the structure
/// carries that rather than a paragraph having to.
struct InspectorView: View {
    @ObservedObject var model: GradeModel

    /// The height of a stage's title row, shared by the rail so the dot lines up with the words
    /// rather than with a guess.
    static let headingRow: CGFloat = 18

    enum Mark2 {
        case locked      // filled: not yours to move
        case editable    // open
        case unpreviewed // dotted: real, but a still cannot show it
    }
    typealias Mark = Mark2

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                presetRow
                stage("Convert", mark: .locked,
                      help: "Apple Log to Rec.709, using Apple's own conversion. It is always "
                          + "applied and cannot be adjusted: its colour is more accurate than "
                          + "anything this app could do instead, and the cube carries a display "
                          + "rendering Apple has not published.") {
                    Text("Apple Log to Rec.709")
                        .font(Type.caption)
                        .foregroundColor(Palette.inkTertiary)
                }
                stage("Correct", mark: .editable,
                      help: "Exposure, white balance and the three wheels run before the "
                          + "conversion, on the log picture, where twelve stops of highlight "
                          + "still exist. Brightening here keeps the highlights instead of "
                          + "flattening them against a ceiling.\n\nLuminance mix decides how much "
                          + "of a wheel move lands on brightness against colour. At 0 the move is "
                          + "colour only, because separating channels shifts saturation whether "
                          + "you meant it to or not.") {
                    control("Exposure", $model.look.correct.exposure, -3...3, format: "%+.2f")
                    control("Temperature", $model.look.correct.temp, -1...1)
                    control("Tint", $model.look.correct.tint, -1...1)
                    wheel(.offset, "Lift")
                    wheel(.power, "Gamma")
                    wheel(.slope, "Gain")
                    control("Luminance", $model.look.correct.lumMix, 0...1)
                }
                stage("Film look", mark: .editable,
                      help: "A film-emulation lookup, applied after the conversion.\n\nThe tone "
                          + "curve below was set with this cube already in the chain, so changing "
                          + "one without the other is a different grade rather than another "
                          + "stock. Switch them together using a preset.") {
                    Picker("", selection: $model.look.lookLUT) {
                        Text("None").tag("none")
                        ForEach(model.availableLooks, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .onChange(of: model.look.lookLUT) { _ in
                        model.liveUpdate()      // instantly, from the cubes already in memory
                        model.renderPreview()   // then the exact frame, as with every control
                    }
                }
                stage("Tone", mark: .editable,
                      help: "Brightness and contrast, applied to the luma plane only so the "
                          + "colour is untouched. Applying a curve per channel crushes a "
                          + "saturated colour's two low channels harder than its high one, which "
                          + "is what makes signage glow.\n\nMidtone is a gamma, so higher is "
                          + "darker. The graph beside the picture is this curve.") {
                    control("Midtone", $model.look.tone.gamma, 1...2.6)
                    appliedGammaNote
                    control("Contrast", $model.look.tone.contrast, 0.8...1.8)
                    control("Pivot", $model.look.tone.pivot, 0.25...0.65)
                    control("Shoulder", $model.look.tone.shoulder, 0...0.8)
                    control("Toe", $model.look.tone.toe, 0...0.8)
                    control("Black", $model.look.tone.black, -0.08...0.08, format: "%+.3f")
                }
                stage("Trims", mark: .editable,
                      help: "The last small moves, after the curve. Warmth acts on the midtones "
                          + "only, so it barely moves a bright sky or a deep shadow.") {
                    control("Saturation", $model.look.colour.saturation, 0.6...1.6)
                    control("Warmth", $model.look.colour.warmth, -0.12...0.12, format: "%+.3f")
                }
                stage("Delivery", mark: .unpreviewed,
                      help: "Grain and stabilisation are applied to the video, never to the "
                          + "preview. Both need moving footage to judge, so a still leaves them "
                          + "out rather than showing a version that is not what renders.",
                      last: true) {
                    control("Grain", $model.look.grainStrength, 0...20, format: "%.0f")
                    control("Stabiliser", $model.look.stabilisationSmoothing, 0...60, format: "%.0f")
                }
            }
            .padding(.vertical, 18)
            .padding(.trailing, 16)
        }
        .background(Palette.panel)
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
            control("\(title) \(name)", Binding(
                get: { model.look.correct.value(which, channel) },
                set: { model.look.correct.setValue(which, channel, $0) }),
                    range, format: which == .offset ? "%+.3f" : "%.3f")
        }
    }

    /// THE SLIDER IS NOT THE NUMBER THAT RENDERS, and the interface has to say so rather than
    /// print a value nothing applies. Exposure matching solves a gamma per clip from this one, so
    /// that every clip in a shoot gets the same look instead of the same curve.
    @ViewBuilder private var appliedGammaNote: some View {
        if let applied = model.appliedGamma,
           abs(applied - model.look.tone.gamma) > 0.005 {
            Text(String(format: "This clip renders at %.3f. The slider sets the midtone for the "
                        + "shoot; each clip is solved from its own brightness so they match.",
                        applied))
                .modifier(Note())
        }
    }

    /// The preset: a look cube with its tone and trims, switched as one. Above the chain, because
    /// it is what the chain starts from.
    @State private var newPresetName = ""

    private var presetRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("preset").font(Type.label).foregroundColor(Palette.inkSecondary)
                Picker("", selection: Binding(
                    get: { model.project.activePreset },
                    set: { model.apply(preset: $0) })) {
                    ForEach(model.project.presets.map(\.name), id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden().frame(width: 150)
                if model.hasUnsavedChanges {
                    Text("adjusted").font(Type.caption).foregroundColor(Palette.plate)
                }
            }
            HStack(spacing: 6) {
                TextField("save the grade as…", text: $newPresetName)
                    .textFieldStyle(.roundedBorder)
                    .font(Type.label)
                    .frame(width: 160)
                    .onSubmit { model.savePreset(named: newPresetName); newPresetName = "" }
                Button("save") {
                    model.savePreset(named: newPresetName.isEmpty ? model.project.activePreset
                                                                  : newPresetName)
                    newPresetName = ""
                }
                .buttonStyle(.borderless).font(Type.label)
            }
        }
        .padding(.leading, 37)
        .padding(.bottom, 18)
    }

    /// One stage, with its dot on the rail. The rail continues through the row, so the chain reads
    /// as one line from the conversion down to delivery.
    /// One stage of the chain, collapsible, with its dot on the rail.
    ///
    /// COLLAPSIBLE BECAUSE MOST OF IT IS NOT IN USE AT ONCE. Thirty-four controls in one column is
    /// a wall, and a grading session touches one stage at a time. Which ones are open is
    /// remembered, so the panel you left is the panel you come back to.
    ///
    /// The long explanation that used to sit under each stage is behind the help button now. Apple
    /// puts reference text in a popover rather than in the panel, and a paragraph of prose under
    /// every control is the fastest way to make a dense inspector unreadable.
    private func stage<Content: View>(_ title: String, mark: Mark, help: String? = nil,
                                      last: Bool = false,
                                      @ViewBuilder content: @escaping () -> Content) -> some View {
        let open = Binding(get: { model.openStages.contains(title) },
                           set: { model.setStage(title, open: $0) })
        return HStack(alignment: .top, spacing: Space.m) {
            Rail(mark: mark, last: last)
            DisclosureGroup(isExpanded: open) {
                VStack(alignment: .leading, spacing: Space.s) { content() }
                    .padding(.top, Space.s)
            } label: {
                HStack(spacing: Space.xs) {
                    Text(title)
                        .font(Type.heading)
                        .foregroundColor(Palette.ink)
                    if mark == .locked {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 9))
                            .foregroundColor(Palette.inkTertiary)
                    }
                    if let help { HelpButton(text: help) }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .disclosureGroupStyle(.automatic)
            .padding(.bottom, last ? 0 : Space.l)
        }
    }

    /// A label, a track, and a readout you can type into. Dragging finds a value; typing repeats
    /// one, and a grading tool needs both.
    private func control(_ label: String, _ value: Binding<Double>,
                         _ range: ClosedRange<Double>, format: String = "%.3f") -> some View {
        HStack(spacing: Space.s) {
            Text(label)
                .font(Type.label)
                .foregroundColor(Palette.inkSecondary)
                .frame(width: 84, alignment: .leading)
            Slider(value: value, in: range) { editing in
                if editing {
                    model.beginDrag()
                } else {
                    model.endDrag()
                    model.refreshCurve()
                    model.renderPreview()   // on release: the exact render confirms the live one
                }
            }
            .controlSize(.mini)
            .tint(Palette.inkTertiary)
            // DURING the drag, not only after it. A grading control that shows nothing until you
            // let go is a control you cannot find a value with.
            .onChange(of: value.wrappedValue) { _ in model.liveUpdate() }
            ValueField(value: value, format: format)
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
        @State private var editing = false
        @FocusState private var focused: Bool

        var body: some View {
            Group {
                if editing {
                    TextField("", value: $value, formatter: InspectorView.formatter(format))
                        .textFieldStyle(.plain)
                        .focused($focused)
                        .onSubmit { editing = false }
                        .onChange(of: focused) { if !$0 { editing = false } }
                        .onAppear { focused = true }
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
        f.minimumFractionDigits = format.contains(".0f") ? 0 : 2
        f.maximumFractionDigits = format.contains(".0f") ? 0 : 3
        f.positivePrefix = format.contains("+") ? "+" : ""
        return f
    }
}

/// The rail: a dot for this stage and the line to the next one.
private struct Rail: View {
    let mark: InspectorView.Mark2
    let last: Bool

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch mark {
                case .locked:
                    Circle().fill(Palette.plate).frame(width: 7, height: 7)
                case .editable:
                    Circle().strokeBorder(Palette.inkSecondary, lineWidth: 1.2)
                        .frame(width: 7, height: 7)
                case .unpreviewed:
                    Circle().strokeBorder(Palette.inkTertiary, style: StrokeStyle(lineWidth: 1.2,
                                                                                  dash: [1.6, 1.6]))
                        .frame(width: 7, height: 7)
                }
            }
            // CENTRED ON THE TITLE'S LINE, not nudged down by a magic number. The dot used to
            // carry a hand-tuned top padding that was correct for the old flat layout and wrong
            // once each stage became a disclosure group with its own chevron and insets.
            .frame(height: InspectorView.headingRow)
            if !last {
                Rectangle()
                    .fill(mark == .unpreviewed ? Palette.hairline.opacity(0.5) : Palette.hairline)
                    .frame(width: 1)
                    .frame(maxHeight: .infinity)   // the line IS the chain; it has to reach
            }
        }
        .frame(width: 7)
        .padding(.leading, 18)
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
                            let point = CGPoint(x: x * geo.size.width,
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
