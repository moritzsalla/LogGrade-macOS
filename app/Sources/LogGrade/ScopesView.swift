import GradeKit
import SwiftUI

/// Waveform, parade and vectorscope, drawn from the frame the engine rendered.
///
/// They measure the render rather than an approximation of it, which is the one advantage of a
/// preview that is a real render. The vectorscope carries the three calibration colours as
/// targets: a place to measure from, not a place to arrive — the shipped grade sits off spec on
/// purpose, and seeing by how much is the point.
struct ScopesView: View {
    let scopes: Scopes?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            panel("levels") { histogram }
            panel("parade") { parade }
            panel("vector") { vectorscope }
        }
    }

    private func panel<Content: View>(_ title: String,
                                      @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(Type.caption).foregroundColor(Palette.inkTertiary)
            content()
                .frame(height: 78)
                .background(Palette.well)
                .border(Palette.hairline)
        }
    }

    private var histogram: some View {
        GeometryReader { geo in
            if let scopes, let peak = scopes.luma.max(), peak > 0 {
                Path { p in
                    for (i, count) in scopes.luma.enumerated() {
                        let x = Double(i) / 255 * geo.size.width
                        let h = Double(count) / Double(peak) * geo.size.height
                        p.move(to: CGPoint(x: x, y: geo.size.height))
                        p.addLine(to: CGPoint(x: x, y: geo.size.height - h))
                    }
                }.stroke(Palette.inkSecondary, lineWidth: 0.8)
            }
        }
    }

    private var parade: some View {
        GeometryReader { geo in
            if let scopes, let peak = [scopes.red, scopes.green, scopes.blue]
                .compactMap({ $0.max() }).max(), peak > 0 {
                let third = geo.size.width / 3
                ZStack {
                    channel(scopes.red, peak: peak, width: third, height: geo.size.height,
                            colour: Color(red: 0.90, green: 0.35, blue: 0.32), offset: 0)
                    channel(scopes.green, peak: peak, width: third, height: geo.size.height,
                            colour: Color(red: 0.45, green: 0.78, blue: 0.45), offset: third)
                    channel(scopes.blue, peak: peak, width: third, height: geo.size.height,
                            colour: Color(red: 0.42, green: 0.60, blue: 0.90), offset: third * 2)
                }
            }
        }
    }

    private func channel(_ bins: [Int], peak: Int, width: Double, height: Double,
                         colour: Color, offset: Double) -> some View {
        Path { p in
            for (i, count) in bins.enumerated() {
                let x = offset + Double(i) / 255 * width
                let h = Double(count) / Double(peak) * height
                p.move(to: CGPoint(x: x, y: height))
                p.addLine(to: CGPoint(x: x, y: height - h))
            }
        }.stroke(colour, lineWidth: 0.7)
    }

    private var vectorscope: some View {
        GeometryReader { geo in
            ZStack {
                // The neutral axis, so a cast is visible as a drift off centre.
                Path { p in
                    p.move(to: CGPoint(x: geo.size.width / 2, y: 0))
                    p.addLine(to: CGPoint(x: geo.size.width / 2, y: geo.size.height))
                    p.move(to: CGPoint(x: 0, y: geo.size.height / 2))
                    p.addLine(to: CGPoint(x: geo.size.width, y: geo.size.height / 2))
                }.stroke(Palette.hairline, lineWidth: 0.6)

                if let scopes, let peak = scopes.vector.max(), peak > 0 {
                    Canvas { context, size in
                        let n = Scopes.vectorSize
                        let cell = CGSize(width: size.width / Double(n),
                                          height: size.height / Double(n))
                        for y in 0..<n {
                            for x in 0..<n where scopes.vector[y * n + x] > 0 {
                                let weight = min(1, Double(scopes.vector[y * n + x])
                                                 / Double(peak) * 6)
                                context.fill(
                                    Path(CGRect(x: Double(x) * cell.width,
                                                y: Double(y) * cell.height,
                                                width: cell.width, height: cell.height)),
                                    with: .color(Palette.inkSecondary.opacity(0.15 + weight * 0.7)))
                            }
                        }
                    }
                }

                // The calibration colours, as crosses. Targets to measure from.
                ForEach(Scopes.references.indices, id: \.self) { i in
                    let r = Scopes.references[i]
                    let p = Scopes.vectorPosition(r.rgb.0, r.rgb.1, r.rgb.2)
                    Path { path in
                        let c = CGPoint(x: p.x * geo.size.width, y: p.y * geo.size.height)
                        path.move(to: CGPoint(x: c.x - 3, y: c.y))
                        path.addLine(to: CGPoint(x: c.x + 3, y: c.y))
                        path.move(to: CGPoint(x: c.x, y: c.y - 3))
                        path.addLine(to: CGPoint(x: c.x, y: c.y + 3))
                    }.stroke(Palette.plate, lineWidth: 1)
                }
            }
        }
    }
}
