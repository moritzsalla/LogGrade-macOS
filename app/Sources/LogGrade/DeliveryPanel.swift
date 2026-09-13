import AppKit
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
                Toggle("reels, full frame", isOn: $model.project.delivery.reels)
                Toggle("feed, cropped to 4:5", isOn: $model.project.delivery.feed)
            }
            .toggleStyle(.checkbox)
            .font(.system(size: 11))
            .foregroundColor(Palette.inkSecondary)

            // Labels get room rather than wrapping mid-word, which is what "heig / ht" was.
            HStack(spacing: 8) {
                Text("size").font(.system(size: 11)).foregroundColor(Palette.inkSecondary)
                    .fixedSize()
                // Spelled as dimensions, not as "1080p". The output is portrait, so 1080p means a
                // height of 1920 — which is the number stored, and labelling it "height: 1080p"
                // was a fresh contradiction in a pass meant to remove them.
                Picker("", selection: $model.project.delivery.height) {
                    Text("1080 × 1920").tag(1920)
                    Text("1440 × 2560").tag(2560)
                    Text("2160 × 3840").tag(3840)
                }
                .labelsHidden().frame(width: 108)
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

            stabiliseRow

            if model.project.delivery.feed {
                cropRow
            } else {
                Text("Tick feed to place the 4:5 crop. Reels keeps the whole frame, so it needs "
                     + "no crop.")
                    .font(.system(size: 10))
                    .foregroundColor(Palette.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Text("save to").font(.system(size: 11)).foregroundColor(Palette.inkSecondary)
                    .fixedSize()
                Text(model.outputDirectory.map { $0.path } ?? "drop a clip first")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(Palette.inkTertiary)
                    .lineLimit(1).truncationMode(.head)
                Button("choose") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.prompt = "deliver here"
                    if panel.runModal() == .OK, let url = panel.url {
                        model.chooseOutputDirectory(url)
                    }
                }
                .buttonStyle(.borderless).font(.system(size: 10.5))
            }

            ForEach(model.blockers.indices, id: \.self) { i in
                Text(model.blockers[i].description)
                    .font(.system(size: 10.5))
                    .foregroundColor(Palette.lamp)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Only when a rate has been chosen. Shown always, it read as a warning about a
            // setting nobody had touched.
            if model.project.delivery.fps != nil {
                Text("A frame rate that does not divide the source evenly would have to be "
                     + "retimed, which judders. Those are refused before the render starts.")
                    .font(.system(size: 10))
                    .foregroundColor(Palette.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .background(Palette.panel)
    }

    /// Per clip, because it is a property of the shot rather than of the shoot. The engine has
    /// always taken it; until now nothing in the interface set it, so every clip was stabilised
    /// whether it needed to be or not.
    private var stabiliseRow: some View {
        HStack(spacing: 10) {
            Toggle("stabilise this clip", isOn: Binding(get: { model.stabilise },
                                                        set: { model.stabilise = $0 }))
                .toggleStyle(.checkbox)
                .font(.system(size: 11))
                .foregroundColor(Palette.inkSecondary)
                .disabled(model.selectedClip == nil)
            Spacer()
        }
    }

    private var cropRow: some View {
        HStack(spacing: 10) {
            Text("4:5 crop").font(.system(size: 11)).foregroundColor(Palette.inkSecondary)
            if let geometry = model.cropGeometry {
                if model.cropOffset != nil {
                    // TYPED AS WELL AS DRAGGED. A drag finds a framing; only a number repeats one,
                    // and repeating one is how a shoot gets a consistent crop. Arrow keys nudge by
                    // a pixel from here too.
                    TextField("", value: Binding(get: { model.cropOffset ?? 0 },
                                                 set: { model.cropOffset = geometry.clamp($0) }),
                              formatter: Self.pixels)
                        .font(.system(size: 11, design: .monospaced))
                        .monospacedDigit()
                        .multilineTextAlignment(.trailing)
                        .textFieldStyle(.plain)
                        .foregroundColor(Palette.ink)
                        .frame(width: 46)
                    Text("of \(geometry.maximumOffset) px from the top")
                        .font(.system(size: 10.5)).foregroundColor(Palette.inkTertiary)
                    Stepper("") { model.nudgeCrop(by: -8) } onDecrement: { model.nudgeCrop(by: 8) }
                        .labelsHidden()
                    Button("clear") { model.cropOffset = nil }
                        .buttonStyle(.borderless).font(.system(size: 10.5))
                } else {
                    // Named as an action, because it is one and nothing else will do it: the
                    // framing is a composition call per clip and the engine will not render a
                    // feed without it.
                    Text("drag the picture to place it")
                        .font(.system(size: 10.5)).foregroundColor(Palette.lamp)
                }
            } else {
                Text("select a clip first")
                    .font(.system(size: 10.5)).foregroundColor(Palette.inkTertiary)
            }
        }
    }

    /// Whole pixels, POSIX, for the same reason the inspector's readouts are: this number is
    /// written into a project file and read back by the engine.
    private static let pixels: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .none
        f.locale = Locale(identifier: "en_US_POSIX")
        f.allowsFloats = false
        return f
    }()

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

    /// Where the box was when this drag started.
    ///
    /// A DragGesture reports translation cumulatively from where the finger went down, so adding
    /// it to the box's CURRENT position adds it again on every event and the box runs off the
    /// frame after a few pixels of travel. It has to be added to where the box was.
    @State private var startedAt: Int?

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
            }
            // THE WHOLE PICTURE IS THE HANDLE. The gesture used to live on the box's own outline,
            // and `strokeBorder` draws nothing but that outline, so the only draggable part of the
            // crop picker was a one-point line — findable by accident and by nothing else. Sitting
            // on the overlay with an explicit content shape makes the whole frame drag the window,
            // which is also how a crop behaves in a grading suite: you move the picture under the
            // window rather than hunting for a handle.
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let from = startedAt ?? model.cropOffset ?? 0
                        if startedAt == nil { startedAt = from }
                        let travelled = value.translation.height / geo.size.height
                        model.cropOffset = geometry.offset(
                            forFraction: geometry.fraction(forOffset: from) + travelled)
                    }
                    .onEnded { _ in startedAt = nil }
            )
        }
    }
}
