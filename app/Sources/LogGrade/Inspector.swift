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

    enum Mark2 {
        case locked      // filled: not yours to move
        case editable    // open
        case unpreviewed // dotted: real, but a still cannot show it
    }
    typealias Mark = Mark2

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                stage("Apple Log to Rec.709", mark: .locked) {
                    Text("Apple's own conversion. Its colour is more accurate than anything "
                         + "hand-rolled here, and the cube carries a display rendering Apple has "
                         + "not published.")
                        .modifier(Note())
                }
                stage("correct", mark: .editable,
                      note: "before the conversion, where the log still holds twelve stops") {
                    control("exposure", $model.look.correct.exposure, -3...3, format: "%+.2f")
                    control("temperature", $model.look.correct.temp, -1...1)
                    control("tint", $model.look.correct.tint, -1...1)
                    control("luminance mix", $model.look.correct.lumMix, 0...1)
                    Text(model.look.correct.isNeutral
                         ? "neutral, so the filter is left out of the graph"
                         : "active, as a 33-point cube")
                        .modifier(Note())
                }
                stage("look", mark: .editable) {
                    Picker("", selection: $model.look.lookLUT) {
                        Text("none").tag("none")
                        ForEach(model.availableLooks, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .onChange(of: model.look.lookLUT) { _ in model.renderPreview() }
                    Text("the tone below was tuned with this cube in the chain, so the two belong "
                         + "to each other")
                        .modifier(Note())
                }
                stage("tone", mark: .editable, note: "on the luma plane, chroma untouched") {
                    HStack(alignment: .top, spacing: 12) {
                        VStack(spacing: 5) {
                            control("midtone", $model.look.tone.gamma, 1...2.6)
                            control("contrast", $model.look.tone.contrast, 0.8...1.8)
                            control("pivot", $model.look.tone.pivot, 0.25...0.65)
                            control("shoulder", $model.look.tone.shoulder, 0...0.8)
                            control("toe", $model.look.tone.toe, 0...0.8)
                            control("black", $model.look.tone.black, -0.08...0.08, format: "%+.3f")
                        }
                        CurveView(curve: model.curve).frame(width: 104, height: 104)
                    }
                    Text("the curve is the engine's own table, generated on each change, not a "
                         + "copy of its maths")
                        .modifier(Note())
                }
                stage("trims", mark: .editable) {
                    control("saturation", $model.look.colour.saturation, 0.6...1.6)
                    control("warmth", $model.look.colour.warmth, -0.12...0.12, format: "%+.3f")
                }
                stage("delivery", mark: .unpreviewed, note: "a still cannot show these", last: true) {
                    control("grain", $model.look.grainStrength, 0...20, format: "%.0f")
                    control("stabiliser", $model.look.stabilisationSmoothing, 0...60, format: "%.0f")
                }
            }
            .padding(.vertical, 18)
            .padding(.trailing, 16)
        }
        .background(Palette.panel)
    }

    /// One stage, with its dot on the rail. The rail continues through the row, so the chain reads
    /// as one line from the conversion down to delivery.
    private func stage<Content: View>(_ title: String, mark: Mark, note: String? = nil,
                                      last: Bool = false,
                                      @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Rail(mark: mark, last: last)
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundColor(Palette.ink)
                    if mark == .locked {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 8))
                            .foregroundColor(Palette.inkTertiary)
                    }
                    if let note {
                        Text(note)
                            .font(.system(size: 10.5))
                            .foregroundColor(Palette.inkTertiary)
                    }
                }
                content()
            }
            .padding(.bottom, last ? 0 : 20)
        }
    }

    /// A label, a track, and a readout you can type into. Dragging is for finding a value; typing
    /// is for repeating one, and a grading tool needs both.
    private func control(_ label: String, _ value: Binding<Double>,
                         _ range: ClosedRange<Double>, format: String = "%.3f") -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(Palette.inkSecondary)
                .frame(width: 84, alignment: .leading)
            Slider(value: value, in: range) { editing in
                if !editing {
                    model.refreshCurve()
                    model.renderPreview()   // on release: a render is seconds, not milliseconds
                }
            }
            .controlSize(.mini)
            .tint(Palette.inkTertiary)
            TextField("", value: value, formatter: Self.formatter(format))
                .font(.system(size: 11, design: .monospaced))
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
                .textFieldStyle(.plain)
                .foregroundColor(Palette.ink)
                .frame(width: 52)
                .onSubmit { model.refreshCurve(); model.renderPreview() }
        }
    }

    private static func formatter(_ format: String) -> NumberFormatter {
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
            .padding(.top, 5)
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
            .font(.system(size: 10.5))
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
