import GradeKit
import SwiftUI

/// One hue curve: twelve knots across the hue circle, dragged up and down.
///
/// A DRAG PICKS THE NEAREST KNOT WHERE IT STARTS and moves only that one, however far the pointer
/// wanders sideways, so sweeping across the strip to reach the blues cannot drag every colour it
/// passes. The hue axis wraps: the last span joins back to the first, as the curve does.
struct HueCurveEditor: View {
    @ObservedObject var model: GradeModel
    let curve: Look.Hue.Curve
    @State private var dragging: Int?

    private static let height: CGFloat = 96
    private let knots = HueCube.knots

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let values = (0..<knots).map { model.look.hue.value(curve, $0) }
            ZStack(alignment: .topLeading) {
                Rectangle().fill(Palette.well)
                strip(width: w)
                    .frame(height: 6)
                    .offset(y: h - 6)
                Path { p in
                    p.move(to: CGPoint(x: 0, y: h / 2))
                    p.addLine(to: CGPoint(x: w, y: h / 2))
                }.stroke(Palette.hairline, lineWidth: 1)
                Path { p in
                    let steps = 180
                    for i in 0...steps {
                        let hue = 360.0 * Double(i) / Double(steps)
                        let point = CGPoint(
                            x: w * CGFloat(i) / CGFloat(steps),
                            y: y(for: HueCube.spline(values, hue), height: h))
                        if i == 0 { p.move(to: point) } else { p.addLine(to: point) }
                    }
                }.stroke(Palette.plate, lineWidth: 1.4)
                ForEach(0...knots, id: \.self) { i in
                    let value = values[i % knots]
                    Circle()
                        .fill(dragging == i % knots ? Palette.ink : Palette.inkSecondary)
                        .frame(width: 7, height: 7)
                        .position(
                            x: w * CGFloat(i) / CGFloat(knots), y: y(for: value, height: h))
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { drag in
                        let knot = dragging ?? nearest(drag.startLocation.x, width: w)
                        if dragging == nil {
                            dragging = knot
                            model.beginDrag()
                        }
                        let fraction = 1 - Double(drag.location.y / h) * 2
                        let value = (fraction * curve.limit * 1000).rounded() / 1000
                        guard value != model.look.hue.value(curve, knot) else { return }
                        model.look.hue.setValue(curve, knot, value)
                        model.liveUpdate()
                    }
                    .onEnded { _ in
                        dragging = nil
                        model.renderPreview()
                    }
            )
            .simultaneousGesture(
                TapGesture(count: 2).onEnded {
                    // Double-click puts the whole curve back, as a name does for a slider.
                    for knot in 0..<knots {
                        model.look.hue.setValue(
                            curve, knot, model.defaultLook.hue.value(curve, knot))
                    }
                    model.liveUpdate()
                    model.renderPreview()
                }
            )
            .border(Palette.hairline)
        }
        .frame(height: Self.height)
        .help("Drag a point up or down. Double-click to reset this curve.")
    }

    private func y(for value: Double, height: CGFloat) -> CGFloat {
        height / 2 * (1 - CGFloat(value / curve.limit))
    }

    private func nearest(_ x: CGFloat, width: CGFloat) -> Int {
        Int((Double(x / width) * Double(knots)).rounded()) % knots
    }

    private func strip(width: CGFloat) -> some View {
        LinearGradient(
            stops: (0...24).map { i in
                let c = HueCube.swatch(hue: 360.0 * Double(i) / 24)
                return .init(
                    color: Color(red: c.0, green: c.1, blue: c.2), location: Double(i) / 24)
            },
            startPoint: .leading, endPoint: .trailing)
    }
}
