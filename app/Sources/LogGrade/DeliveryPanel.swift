import GradeKit
import SwiftUI

/// What comes out, and the two things about it that cannot be guessed.
///
/// The crop offset is a composition call per clip: the precursor's own default is one clip's
/// framing, and applied to a batch it silently reframes every other one into files that look
/// finished. So it is picked on the picture, per clip, and a Feed render is blocked until every
/// clip has one — the same refusal the engine makes, said before a render starts rather than
/// discovered from its exit code.
struct DeliveryPanel: View {
    @ObservedObject var model: GradeModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("deliver")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundColor(Palette.ink)

            HStack(spacing: 14) {
                Toggle("reels 9:16", isOn: $model.project.delivery.reels)
                Toggle("feed 4:5", isOn: $model.project.delivery.feed)
            }
            .toggleStyle(.checkbox)
            .font(.system(size: 11))
            .foregroundColor(Palette.inkSecondary)

            // Labels get room rather than wrapping mid-word, which is what "heig / ht" was.
            HStack(spacing: 8) {
                Text("size").font(.system(size: 11)).foregroundColor(Palette.inkSecondary)
                    .fixedSize()
                Picker("", selection: $model.project.delivery.height) {
                    Text("1080p").tag(1920)
                    Text("1440p").tag(2560)
                    Text("2160p").tag(3840)
                }
                .labelsHidden().frame(width: 84)
                Spacer(minLength: 4)
                Text("fps").font(.system(size: 11)).foregroundColor(Palette.inkSecondary)
                    .fixedSize()
                Picker("", selection: fpsBinding) {
                    Text("source").tag(0)
                    Text("24").tag(24)
                    Text("12").tag(12)
                }
                .labelsHidden().frame(width: 84)
            }

            if model.project.delivery.feed {
                cropRow
            }

            ForEach(model.blockers.indices, id: \.self) { i in
                Text(model.blockers[i].description)
                    .font(.system(size: 10.5))
                    .foregroundColor(Palette.lamp)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("a rate that is not an integer relation to the source needs retiming, which "
                 + "judders, so the engine refuses it rather than interpolating")
                .font(.system(size: 10))
                .foregroundColor(Palette.inkTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .background(Palette.panel)
    }

    private var cropRow: some View {
        HStack(spacing: 10) {
            Text("crop offset").font(.system(size: 11)).foregroundColor(Palette.inkSecondary)
            if let geometry = model.cropGeometry {
                if let offset = model.cropOffset {
                    Readout(text: "\(offset) of \(geometry.maximumOffset) px")
                    Button("clear") { model.cropOffset = nil }
                        .buttonStyle(.borderless).font(.system(size: 10.5))
                } else {
                    Text("undecided — drag the box on the picture")
                        .font(.system(size: 10.5)).foregroundColor(Palette.lamp)
                }
            } else {
                Text("select a clip first")
                    .font(.system(size: 10.5)).foregroundColor(Palette.inkTertiary)
            }
        }
    }

    /// Zero stands for "the source's rate", which is the only lossless answer and therefore the
    /// default. A picker needs a value for it; the project keeps nil.
    private var fpsBinding: Binding<Int> {
        Binding(get: { model.project.delivery.fps ?? 0 },
                set: { model.project.delivery.fps = $0 == 0 ? nil : $0 })
    }
}

/// The 4:5 window, dragged on the picture.
///
/// Drawn over the preview because that is the only way to judge a crop: the question is what is in
/// the frame, and no number answers it. The box is the engine's window — as wide as the master and
/// as tall as the aspect makes it — so what is inside it is what gets delivered.
struct CropOverlay: View {
    @ObservedObject var model: GradeModel
    let geometry: CropGeometry

    var body: some View {
        GeometryReader { geo in
            let height = geo.size.height * geometry.windowFraction
            let offset = geometry.fraction(forOffset: model.cropOffset ?? 0) * geo.size.height
            ZStack(alignment: .top) {
                // Everything outside the window is dimmed rather than hidden: you are choosing
                // what to leave out, so you have to see it.
                Rectangle().fill(Color.black.opacity(0.55))
                    .mask(
                        ZStack {
                            Rectangle()
                            Rectangle().frame(height: height)
                                .offset(y: offset - (geo.size.height - height) / 2)
                                .blendMode(.destinationOut)
                        }.compositingGroup()
                    )
                Rectangle()
                    .strokeBorder(Palette.plate, lineWidth: 1)
                    .frame(height: height)
                    .offset(y: offset)
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                let top = offset + value.translation.height
                                model.cropOffset = geometry.offset(
                                    forFraction: top / geo.size.height)
                            }
                    )
            }
        }
    }
}
