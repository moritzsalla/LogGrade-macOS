import AppKit
import GradeKit
import SwiftUI

/// What comes out, and the two things about it that cannot be guessed.
///
/// The crop offset is a composition call per clip, picked on the picture. A clip nobody placed
/// renders centred, and the panel names it (`Project.unframed`), so a batch of files that all look
/// finished still says which were never looked at.
struct DeliveryPanel: View {
    // Not observed: see `GradeModel.changes`.
    let model: GradeModel
    @ObservedObject private var changes: GradeModel.Changes

    init(model: GradeModel) {
        self.model = model
        _changes = ObservedObject(wrappedValue: model.changes)
    }
    private static let cropStepperPixels = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("deliver")
                .font(Type.heading)
                .foregroundColor(Palette.ink)
            presetRow
            if model.project.exportPreset == .custom {
                aspectRow
                sizeRow
                sizeCostNote
                codecRow
                formatRow
            } else {
                presetSummary
            }
            cropSection
            workloadNote
            saveRow
            blockerList
            fpsNote
        }
        .padding(Space.l)
        .background(Palette.panel)
    }

    /// ONE SHAPE. Custom used to be the Instagram checkboxes plus an "Add shape" editor, which
    /// opened with nothing ticked and so could not export; the presets already are those shapes.
    private var aspectRow: some View {
        HStack(spacing: 8) {
            Text("aspect").font(Type.label).foregroundColor(Palette.inkSecondary).fixedSize()
            Picker(
                "",
                selection: Binding(
                    get: { aspectTag(model.project.customDelivery.targets.first) },
                    set: { tag in
                        guard
                            let (w, h) = Deliverable.customAspects.first(where: {
                                aspectTag($0.0, $0.1) == tag
                            })
                        else { return }
                        model.project.customDelivery.targets = [
                            .custom(aspectWidth: w, aspectHeight: h)
                        ]
                    })
            ) {
                ForEach(Deliverable.customAspects.map { aspectTag($0.0, $0.1) }, id: \.self) {
                    Text($0).tag($0)
                }
            }
            .labelsHidden().frame(width: 84)
            Spacer(minLength: 4)
            Text("fps").font(Type.label).foregroundColor(Palette.inkSecondary).fixedSize()
            Picker("", selection: fpsBinding) {
                Text("source").tag(0)
                Text("30").tag(30)
                Text("24").tag(24)
                Text("12").tag(12)
            }
            .labelsHidden().frame(width: 84)
        }
    }

    private func aspectTag(_ w: Int, _ h: Int) -> String { "\(w):\(h)" }

    private func aspectTag(_ shape: Deliverable?) -> String {
        shape.map { aspectTag($0.aspectWidth, $0.aspectHeight) } ?? ""
    }

    /// By the short edge, with the pixels it comes to for the chosen aspect, so "1080p" is never a
    /// guess about which side is 1080.
    private var sizeRow: some View {
        HStack(spacing: 8) {
            Text("size").font(Type.label).foregroundColor(Palette.inkSecondary).fixedSize()
            Picker("", selection: custom(\.shortSide)) {
                ForEach(Project.Delivery.shortSides, id: \.self) { side in
                    Text(sizeLabel(side)).tag(side)
                }
            }
            .labelsHidden().frame(width: 190)
        }
    }

    private func sizeLabel(_ side: Int) -> String {
        var d = model.project.customDelivery
        d.shortSide = side
        let shape = d.targets.first ?? Deliverable.defaultCustom
        // The engine derives height from width and aspect; mirrored here only for the label.
        let tall = d.width * shape.aspectHeight / shape.aspectWidth
        return "\(side)p · \(d.width) × \(tall - tall % 2)"
    }

    // WHAT THIS COSTS, BEFORE IT COSTS IT. A 2160-tall delivery is four times the pixels of a
    // 1080 one and takes proportionally longer, and Instagram re-encodes everything to 1080 wide
    // anyway — so the larger sizes buy nothing downstream while multiplying the render. The look
    // was also tuned at 1080: grain and the sharpener have radii in pixels, and scaling them with
    // height is an assumption rather than a measurement.
    @ViewBuilder private var sizeCostNote: some View {
        if model.project.customDelivery.shortSide > Project.Delivery.defaultShortSide {
            Label(
                "This renders \(pixelRatio)× longer than 1080p, and grain and sharpening were "
                    + "tuned at 1080p. Instagram re-encodes to 1080 anyway.",
                systemImage: "info.circle"
            )
            .font(Type.caption)
            .foregroundColor(Palette.inkTertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The chosen size's pixels over 1080p's, as the note prints it. In Double: integer division
    /// made 1440 "1×". A String, because an interpolated number in a SwiftUI Text is localised and a
    /// German locale would print "1,8".
    private var pixelRatio: String {
        let linear = Double(model.project.customDelivery.shortSide) / 1080
        let ratio = linear * linear
        return String(format: ratio == ratio.rounded() ? "%.0f" : "%.1f", ratio)
    }

    private var presetRow: some View {
        Picker(
            "",
            selection: Binding(
                get: { model.project.exportPreset },
                set: { model.project.exportPreset = $0 })
        ) {
            ForEach(Project.ExportPreset.allCases, id: \.self) { Text($0.label).tag($0) }
        }
        .labelsHidden()
        .frame(width: 180)
    }

    /// What a preset renders, said once, because a preset with no fields otherwise reads as
    /// nothing having been decided.
    private var presetSummary: some View {
        let d = model.project.delivery
        let shape = d.targets.map { "\($0.aspectWidth):\($0.aspectHeight)" }.joined(separator: ", ")
        return Text("\(shape), 1080 wide, \(d.codec.label), with sound.")
            .font(Type.caption)
            .foregroundColor(Palette.inkTertiary)
    }

    /// Custom's fields write `customDelivery` directly: `project.delivery` is what renders, with
    /// ProRes's forced container and quality applied, and writing that back would lose the mp4
    /// and quality someone set before trying ProRes.
    private func custom<T>(_ path: WritableKeyPath<Project.Delivery, T>) -> Binding<T> {
        Binding(
            get: { model.project.customDelivery[keyPath: path] },
            set: { model.project.customDelivery[keyPath: path] = $0 })
    }

    // Says where 10-bit and ProRes help, because they read as simply better, and a file a platform
    // re-encodes gains nothing from either.
    private var codecRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("codec").font(Type.label).foregroundColor(Palette.inkSecondary).fixedSize()
                Picker("", selection: custom(\.codec)) {
                    ForEach(Project.Delivery.Codec.allCases, id: \.self) {
                        Text($0.label).tag($0)
                    }
                }
                .labelsHidden().frame(width: 130)
                Spacer(minLength: 4)
                Text("quality").font(Type.label).foregroundColor(Palette.inkSecondary).fixedSize()
                Picker("", selection: custom(\.quality)) {
                    Text("auto").tag(Project.Delivery.Quality.auto)
                    Text("high").tag(Project.Delivery.Quality.high)
                    Text("max").tag(Project.Delivery.Quality.max)
                }
                .labelsHidden().frame(width: 76)
                .disabled(model.project.customDelivery.codec.isProRes)
            }
            if let note = codecNote {
                Text(note)
                    .font(Type.caption)
                    .foregroundColor(Palette.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var codecNote: String? {
        switch model.project.customDelivery.codec {
        case .h264: return nil
        case .hevc: return "Smaller files than H.264 at the same quality. Plays on Apple devices."
        case .hevc10:
            return "Smoother skies and gradients on a Mac, an iPhone or in an editor. Social "
                + "platforms convert uploads to 8-bit, so it gains nothing there."
        case .prores422, .prores422hq:
            return "For editing in Final Cut or Resolve: large files, always .mov, quality set by "
                + "the codec."
        }
    }

    private var formatRow: some View {
        HStack(spacing: 8) {
            Text("file").font(Type.label).foregroundColor(Palette.inkSecondary).fixedSize()
            Picker("", selection: custom(\.container)) {
                Text(".mp4").tag(Project.Delivery.Container.mp4)
                Text(".mov").tag(Project.Delivery.Container.mov)
            }
            .labelsHidden().frame(width: 76)
            .disabled(model.project.customDelivery.codec.isProRes)
            Spacer(minLength: 4)
            Toggle("sound", isOn: custom(\.audio))
                .toggleStyle(.checkbox)
                .font(Type.label)
                .foregroundColor(Palette.inkSecondary)
        }
    }

    @ViewBuilder private var cropSection: some View {
        if model.project.delivery.anyTargetNeedsClipOffset(model.selectedFrameSize) {
            cropRow
        } else if let centred = model.project.delivery.cropBoxTarget(model.selectedFrameSize) {
            Text(
                "The \(centred.aspectWidth):\(centred.aspectHeight) crop sits at the centre of "
                    + "every clip, so there is nothing to place."
            )
            .font(Type.caption)
            .foregroundColor(Palette.inkTertiary)
            .fixedSize(horizontal: false, vertical: true)
        } else if model.selectedFrameSize != nil {
            // Only once the clip is measured: an unmeasured frame is answered as 9:16, which would
            // tell a landscape clip it already has a portrait shape. A preset has no shapes to
            // tick, so only Custom is told how to get a crop.
            Text(
                model.project.exportPreset == .custom
                    ? "This clip already has that aspect, so nothing is cropped."
                    : "This clip already has that shape, so nothing is cropped."
            )
            .font(Type.caption)
            .foregroundColor(Palette.inkTertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    // WHAT CONVERT IS ABOUT TO DO, counted rather than discovered. Two deliverables and
    // stabilisation are each a separate pass over every clip, and the difference between one pass
    // and four is the difference between minutes and an evening.
    @ViewBuilder private var workloadNote: some View {
        if !model.clipNames.isEmpty {
            Text(workload)
                .font(Type.caption)
                .foregroundColor(Palette.inkTertiary)
        }
    }

    private var saveRow: some View {
        HStack(spacing: 8) {
            Text("save to").font(Type.label).foregroundColor(Palette.inkSecondary)
                .fixedSize()
            Text(model.outputDirectory.map { $0.path } ?? "drop a clip first")
                .font(Type.value)
                .foregroundColor(Palette.inkTertiary)
                .lineLimit(1).truncationMode(.head)
            // A BORDERED BUTTON WITH A FOLDER ON IT. It was borderless text, which on a dark
            // panel beside a dimmed path reads as a label rather than as the one control that
            // decides where your work lands.
            Button {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                panel.prompt = "deliver here"
                if panel.runModal() == .OK, let url = panel.url {
                    model.chooseOutputDirectory(url)
                }
            } label: {
                Label("Choose…", systemImage: "folder")
                    .font(Type.label)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private var blockerList: some View {
        Group {
            ForEach(model.blockers.indices, id: \.self) { i in
                Text(model.blockers[i].description)
                    .font(Type.caption)
                    .foregroundColor(Palette.lamp)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Not the lamp colour: it is reserved for refusals, and this renders.
            if let unframed = model.unframed {
                Label(unframed.description, systemImage: "crop")
                    .font(Type.caption)
                    .foregroundColor(Palette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // Only when a rate has been chosen. Shown always, it read as a warning about a setting nobody
    // had touched.
    @ViewBuilder private var fpsNote: some View {
        if model.project.delivery.fps != nil {
            Text(
                "A frame rate that does not divide the source evenly would have to be "
                    + "retimed, which judders. Those are refused before the render starts."
            )
            .font(Type.caption)
            .foregroundColor(Palette.inkTertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Named for the shape being placed rather than for "4:5", which stopped being the only
    /// croppable aspect the moment the set opened up.
    private var cropLabel: String {
        model.project.delivery.clipFramedTargets(model.selectedFrameSize).first
            .map { "\($0.aspectWidth):\($0.aspectHeight) crop" } ?? "crop"
    }

    private var cropRow: some View {
        HStack(spacing: 10) {
            Text(cropLabel).font(Type.label).foregroundColor(Palette.inkSecondary)
            if let geometry = model.cropGeometry {
                if model.cropOffset != nil {
                    // TYPED AS WELL AS DRAGGED. A drag finds a framing; only a number repeats one,
                    // and repeating one is how a shoot gets a consistent crop. Arrow keys nudge by
                    // a pixel from here too.
                    TextField(
                        "",
                        value: Binding(
                            get: { model.cropOffset ?? 0 },
                            set: { model.cropOffset = geometry.clamp($0) }),
                        formatter: Self.pixels
                    )
                    .font(Type.value)
                    .monospacedDigit()
                    .multilineTextAlignment(.trailing)
                    .textFieldStyle(.plain)
                    .foregroundColor(Palette.ink)
                    .frame(width: 46)
                    // A String, not the Int: an interpolated Int is locale-grouped ("1.140").
                    Text(
                        "of \(String(geometry.maximumOffset)) px from the "
                            + (geometry.axis == .y ? "top" : "left")
                    )
                    .font(Type.caption).foregroundColor(Palette.inkTertiary)
                    // INVERTED ON THE Y AXIS. The offset counts down from the top, so the stepper's
                    // up arrow has to shrink it to move the window up, as the Up key does. On the
                    // x axis it counts from the left, and up reads as "more".
                    let upward =
                        geometry.axis == .y ? -Self.cropStepperPixels : Self.cropStepperPixels
                    Stepper("") {
                        model.nudgeCrop(by: upward)
                    } onDecrement: {
                        model.nudgeCrop(by: -upward)
                    }
                    .labelsHidden()
                    Button("clear") { model.cropOffset = nil }
                        .buttonStyle(.borderless).font(Type.caption)
                } else {
                    // Named as an action, because it is one and nothing else will do it: the
                    // framing is a composition call per clip and the engine will not render a
                    // feed without it.
                    Text("drag the picture to place it")
                        .font(Type.caption).foregroundColor(Palette.lamp)
                }
            } else {
                // The box waits for the engine to measure the decoded frame (`GradeModel.cropGeometry`).
                Text(model.selectedClip == nil ? "select a clip first" : "measuring the clip…")
                    .font(Type.caption).foregroundColor(Palette.inkTertiary)
            }
        }
    }

    /// Passes over the footage, which is what actually decides how long convert takes. One per
    /// clip however many shapes it delivers: the engine grades once and splits.
    private var workload: String {
        let clips = model.clipNames.count
        let passes = model.project.delivery.targets.isEmpty ? 0 : 1
        let stabilised = model.clipNames.filter { model.project.settings(for: $0).stabilise }.count
        let total = clips * passes + stabilised
        guard total > 0 else { return "Nothing selected to deliver." }
        return
            "\(clips) clip\(clips == 1 ? "" : "s"), \(total) render pass\(total == 1 ? "" : "es")"
            + (stabilised > 0 ? " including \(stabilised) for stabilisation." : ".")
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
        Binding(
            get: { model.project.delivery.fps ?? 0 },
            set: { model.project.customDelivery.fps = $0 == 0 ? nil : $0 })
    }
}

/// The crop window, in the first cropping deliverable's shape, dragged on the picture.
///
/// Drawn over the preview because that is the only way to judge a crop: the question is what is in
/// the frame, and no number answers it. The box is the engine's window — filling the master along one
/// axis and moving along the other — so what is inside it is what gets delivered.
struct CropOverlay: View {
    // Not observed: see `GradeModel.changes`.
    let model: GradeModel
    @ObservedObject private var changes: GradeModel.Changes

    init(model: GradeModel, geometry: CropGeometry, framedPerClip: Bool) {
        self.model = model
        _changes = ObservedObject(wrappedValue: model.changes)
        self.geometry = geometry
        self.framedPerClip = framedPerClip
    }
    let geometry: CropGeometry
    /// False for a shape that carries `centre`: its box is drawn where the engine will cut, and
    /// dragging it would change a per-clip offset that shape ignores.
    let framedPerClip: Bool

    /// Where the box was when this drag started.
    ///
    /// A DragGesture reports translation cumulatively from where the finger went down, so adding
    /// it to the box's CURRENT position adds it again on every event and the box runs off the
    /// frame after a few pixels of travel. It has to be added to where the box was.
    @State private var startedAt: Int?

    var body: some View {
        GeometryReader { geo in
            let vertical = geometry.axis == .y
            // The frame's length along the axis the window moves, and the window's along it.
            let span = vertical ? geo.size.height : geo.size.width
            let length = span * geometry.windowFraction
            let offset =
                geometry.fraction(
                    forOffset: framedPerClip ? model.cropOffset ?? 0 : geometry.centreOffset
                ) * span
            let boxWidth = vertical ? geo.size.width : length
            let boxHeight = vertical ? length : geo.size.height
            ZStack(alignment: .topLeading) {
                // Everything outside the window is dimmed rather than hidden: you are choosing
                // what to leave out, so you have to see it.
                Rectangle().fill(Color.black.opacity(0.55))
                    .mask(
                        ZStack(alignment: .topLeading) {
                            Rectangle()
                            Rectangle().frame(width: boxWidth, height: boxHeight)
                                .offset(x: vertical ? 0 : offset, y: vertical ? offset : 0)
                                .blendMode(.destinationOut)
                        }.compositingGroup()
                    )
                Rectangle()
                    .strokeBorder(Palette.plate, lineWidth: 1)
                    .frame(width: boxWidth, height: boxHeight)
                    .offset(x: vertical ? 0 : offset, y: vertical ? offset : 0)
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
                        let travelled =
                            geometry.axis == .y
                            ? value.translation.height / geo.size.height
                            : value.translation.width / geo.size.width
                        model.cropOffset = geometry.offset(
                            forFraction: geometry.fraction(forOffset: from) + travelled)
                    }
                    .onEnded { _ in startedAt = nil }
            )
            .allowsHitTesting(framedPerClip)
        }
    }
}
