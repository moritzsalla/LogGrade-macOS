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
    // Not observed: see `GradeModel.changes`.
    let model: GradeModel
    @ObservedObject private var changes: GradeModel.Changes

    init(model: GradeModel) {
        self.model = model
        _changes = ObservedObject(wrappedValue: model.changes)
    }
    @State private var shapeEditor: ShapeEditorMode?

    private static let cropStepperPixels = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("deliver")
                .font(Type.heading)
                .foregroundColor(Palette.ink)
            shapeRow
            customTargetsSection
            sizeRow
            sizeCostNote
            depthRow
            cropSection
            workloadNote
            saveRow
            blockerList
            fpsNote
        }
        .padding(Space.l)
        .background(Palette.panel)
        .sheet(item: $shapeEditor) { mode in
            DeliverableEditor(mode: mode) { model.saveShape($0, replacing: mode.original) }
        }
    }

    // GENERATED FROM THE PRESET LIST, not written out one per line. Two hardcoded toggles is what
    // made the set of shapes closed at two in the first place; a preset added to
    // Deliverable.presets now appears here without a UI edit.
    private var shapeRow: some View {
        HStack(spacing: 14) {
            ForEach(Deliverable.presets, id: \.self) { deliverable in
                Toggle(label(for: deliverable), isOn: binding(for: deliverable))
            }
        }
        .toggleStyle(.checkbox)
        .font(Type.label)
        .foregroundColor(Palette.inkSecondary)
    }

    // Shapes that are not presets have no checkbox: they exist only while selected, so removing
    // one is unticking it. They were listed read-only before an editor existed, and are still
    // listed rather than hidden, because a deliverable rendering with no visible reason reads as a
    // bug in the renderer.
    private var customTargetsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(customTargets, id: \.self) { deliverable in
                HStack(spacing: 8) {
                    Text(deliverable.spec)
                        .font(Type.value)
                        .foregroundColor(Palette.ink)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    Button("edit") { shapeEditor = .editing(deliverable) }
                    Button("remove") {
                        model.project.delivery.targets.removeAll { $0 == deliverable }
                    }
                }
                .buttonStyle(.borderless)
                .font(Type.caption)
            }
            Button {
                shapeEditor = .adding
            } label: {
                Label("Add shape", systemImage: "plus")
                    .font(Type.label)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    // Labels get room rather than wrapping mid-word, which is what "heig / ht" was.
    private var sizeRow: some View {
        HStack(spacing: 8) {
            Text("size").font(Type.label).foregroundColor(Palette.inkSecondary)
                .fixedSize()
            // Spelled as the WIDTH every deliverable shares, not as "1080p" or a portrait size: each
            // shape's height follows its own aspect, so "1080 × 1920" was only true of reels. The
            // tag stays the 9:16 reference height the engine's HEIGHT takes.
            Picker(
                "",
                selection: Binding(
                    get: { model.project.delivery.height },
                    set: { model.project.delivery.height = $0 })
            ) {
                Text("1080 wide").tag(1920)
                Text("1440 wide").tag(2560)
                Text("2160 wide").tag(3840)
            }
            .labelsHidden().frame(width: 108)
            Spacer(minLength: 4)
            Text("fps").font(Type.label).foregroundColor(Palette.inkSecondary)
                .fixedSize()
            Picker("", selection: fpsBinding) {
                Text("source").tag(0)
                Text("24").tag(24)
                Text("12").tag(12)
            }
            .labelsHidden().frame(width: 84)
        }
    }

    // WHAT THIS COSTS, BEFORE IT COSTS IT. A 2160-tall delivery is four times the pixels of a
    // 1080 one and takes proportionally longer, and Instagram re-encodes everything to 1080 wide
    // anyway — so the larger sizes buy nothing downstream while multiplying the render. The look
    // was also tuned at 1080: grain and the sharpener have radii in pixels, and scaling them with
    // height is an assumption rather than a measurement.
    @ViewBuilder private var sizeCostNote: some View {
        if model.project.delivery.height > 1920 {
            Label(
                "Instagram re-encodes to 1080 wide. This renders \(pixelRatio)× longer for no "
                    + "gain, and the grain was tuned at 1080.",
                systemImage: "info.circle"
            )
            .font(Type.caption)
            .foregroundColor(Palette.inkTertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The chosen size's pixels over 1080 × 1920's, as the note prints it. In Double: integer
    /// division made 2560 "1×". A String, because an interpolated number in a SwiftUI Text is
    /// localised and a German locale would print "1,8".
    private var pixelRatio: String {
        let linear = Double(model.project.delivery.height) / 1920
        let ratio = linear * linear
        return String(format: ratio == ratio.rounded() ? "%.0f" : "%.1f", ratio)
    }

    // Says where it helps and where it does not, because "10-bit" alone reads as simply better, and a
    // file re-encoded by a platform gains nothing from it.
    private var depthRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(
                "10-bit file (HEVC)",
                isOn: Binding(
                    get: { model.project.delivery.tenBit },
                    set: { model.project.delivery.tenBit = $0 })
            )
            .toggleStyle(.checkbox)
            .font(Type.label)
            .foregroundColor(Palette.inkSecondary)
            if model.project.delivery.tenBit {
                Text(
                    "Smoother skies and gradients on a Mac, an iPhone or in an editor. Social "
                        + "platforms convert uploads to 8-bit, so it gains nothing there."
                )
                .font(Type.caption)
                .foregroundColor(Palette.inkTertiary)
                .fixedSize(horizontal: false, vertical: true)
            }
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
        } else {
            Text(
                "Nothing selected crops this clip, so there is no crop to place. Tick a "
                    + "shape that is not the clip's own and it appears here."
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
        ForEach(model.blockers.indices, id: \.self) { i in
            Text(model.blockers[i].description)
                .font(Type.caption)
                .foregroundColor(Palette.lamp)
                .fixedSize(horizontal: false, vertical: true)
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

    /// The shapes carried by the project that have no checkbox, because they are not presets.
    private var customTargets: [Deliverable] {
        model.project.delivery.targets.filter { !Deliverable.presets.contains($0) }
    }

    private func label(for deliverable: Deliverable) -> String {
        deliverable.crops(model.selectedFrameSize)
            ? "\(deliverable.name), cropped to \(deliverable.aspectWidth):\(deliverable.aspectHeight)"
            : "\(deliverable.name), full frame"
    }

    private func binding(for deliverable: Deliverable) -> Binding<Bool> {
        Binding(
            get: { model.project.delivery.isSelected(deliverable) },
            set: { model.project.delivery.setTarget(deliverable, selected: $0) })
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
            set: { model.project.delivery.fps = $0 == 0 ? nil : $0 })
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
