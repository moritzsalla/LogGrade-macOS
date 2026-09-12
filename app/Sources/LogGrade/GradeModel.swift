import AppKit
import CoreGraphics
import Combine
import GradeKit
import SwiftUI

/// What the interface is editing, and the preview that follows it.
///
/// ObservableObject, not @Observable: the latter is macOS 14 and this builds against 13.
final class GradeModel: ObservableObject {
    @Published var look: Look
    @Published var curve: ToneCurve?
    @Published var previewImage: NSImage?
    /// Measured on the rendered frame, so the scopes read the render rather than a guess at it.
    @Published var scopes: Scopes?
    /// The previous render, kept for hold-to-compare. Comparing against the last committed frame
    /// is what a colourist actually wants while adjusting: "is this better than what I had".
    @Published var previousImage: NSImage?
    @Published var status: String = ""
    @Published var isRendering = false
    @Published var selectedClip: ClipList.Entry?
    @Published var previewSeconds: Double = 1
    /// Held down rather than clicked. A colourist compares by holding a key and letting go, which
    /// is what the Bench does too; a long press on a label was undiscoverable and awkward.
    @Published var isComparing = false
    /// The look the last ENGINE render used. Comparing it with the current one is how the panel
    /// knows the exact frame is out of date. The live tier keeps the picture current in between,
    /// so this is about which of the two you are looking at rather than about a stale picture.
    @Published private(set) var renderedLook: Look?

    var isStale: Bool {
        guard let rendered = renderedLook, previewImage != nil else { return false }
        return rendered != look
    }

    /// The project: presets, delivery, and what is decided per clip. Held here because the crop
    /// offset has to live somewhere that survives selecting another clip, and because a shoot is
    /// the unit of work rather than a file.
    @Published var project: Project

    /// The cubes on disk, read once: the interface offers what is there.
    let availableLooks: [String]

    // MARK: - the live tier

    /// The clip as the camera recorded it, decoded and resampled and nothing else. Every stage of
    /// the grade is applied to this in-process while a control moves, so the picture follows the
    /// pointer and the render on release confirms it.
    ///
    /// IT DOES NOT DEPEND ON THE LOOK, which is the point. The earlier tier graded a frame the
    /// engine had already converted, so the correction stage — which runs BEFORE that conversion —
    /// could not be shown at all, and any change to it meant rendering a new base. This one is the
    /// clip, so it is fetched once per clip and per timecode and nothing else invalidates it.
    private var sourceImage: CGImage?
    private var sourceClip: URL?
    private var sourceSeconds: Double?
    private var isFetchingSource = false
    @Published var isLive = false
    /// The last frame the ENGINE produced, kept apart from `previewImage` because that one holds
    /// live approximations too. Compare reaches for this, so that holding C answers a question
    /// about the grade rather than about the model.
    @Published private var lastExactImage: NSImage?

    /// What holding C shows: the picture as it was before the adjustment in progress.
    ///
    /// Which frame that is depends on where you are. Mid-drag it is the render this drag started
    /// from, because the question is what the move has done. Once the render lands, that frame IS
    /// the picture, so the comparison moves back one to the render before it.
    var comparisonImage: NSImage? { isLive ? lastExactImage : previousImage }
    /// Set while a control is actually under the pointer. Only a real drag goes live: a preset
    /// switch or an opened project moves the same values and wants the render, not a model of it.
    private var isDragging = false
    /// The gamma the engine will apply to this clip. The midtone slider holds the REFERENCE
    /// gamma, and the two are different numbers on every clip that was not shot at the exposure
    /// the look was tuned at — so the interface shows both rather than letting the readout claim a
    /// value nothing applies.
    @Published var appliedGamma: Double?
    /// Whether `status` is a failure. It used to be inferred from the message's first word, which
    /// meant rewording a message silently changed its colour.
    @Published var statusIsFailure = false

    /// Apple's conversion, read once. It is 65 points and parsing it takes long enough to be worth
    /// not doing on a drag.
    private let conversionCube: Cube3D?
    /// Film looks, read on first use and kept. There are two on disk and they are small.
    private var lookCubeCache: [String: Cube3D] = [:]
    /// The correction cube and what it was built from, so an unchanged correction is not rebuilt
    /// 60 times a second.
    private var correctionCube: Cube3D?
    private var correctionFor: Look.Correct?
    /// The source through the colour stages, kept so a tone or trim drag costs only the curve.
    /// Dragging midtone does not move the correction, the conversion or the look, and those three
    /// are most of the work.
    private var convertedFrame: LiveChain.Converted?
    private var convertedFor: (Look.Correct, String)?

    private func lookCube(for stem: String) -> Cube3D? {
        if let cached = lookCubeCache[stem] { return cached }
        guard let url = engine.lookCube(named: stem), let cube = try? Cube3D(contentsOf: url) else {
            return nil
        }
        lookCubeCache[stem] = cube
        return cube
    }

    /// A control went under the pointer.
    ///
    /// The render in flight is for a look nobody wants any more — the person is already moving
    /// away from it — so it is stopped here rather than left to finish and be discarded. Without
    /// this, letting go and immediately grabbing again gives three dead seconds.
    func beginDrag() {
        isDragging = true
        // Unless it is the render that has not produced a source frame yet: cancelling that one
        // leaves nothing to be live from.
        if isRendering && sourceImage != nil {
            previewGeneration += 1
            if let running = previewProcess, running.isRunning { EngineRun.stop(running) }
            isRendering = false
        }
    }

    func endDrag() { isDragging = false }

    /// Follows the controls. Every stage runs here, in this process, with no subprocess on the
    /// path: the correction cube is 1.4ms, the tone curve a tenth of that, and the frame itself
    /// about 12ms at preview size. That is why there is no throttle and no debounce — there is
    /// nothing to defer.
    func liveUpdate() {
        guard isDragging, let clip = selectedClip else { return }
        guard let source = sourceImage, sourceClip == clip.url, sourceSeconds == previewSeconds,
              let conversion = conversionCube else {
            if isFetchingSource { status = "Setting up the live preview…" }
            return
        }
        refreshCurve()
        guard let curve = curve else { return }

        if correctionFor != look.correct {
            correctionCube = look.correct.isNeutral ? nil
                : CorrectionCube.cube(for: look.correct, size: 33)
            correctionFor = look.correct
        }
        // A correction the engine would refuse gets no live picture, rather than a picture of
        // something it will not render.
        if !look.correct.isNeutral && correctionCube == nil {
            isLive = false
            status = "that correction is not a value the engine accepts"
            statusIsFailure = true
            return
        }

        if convertedFrame == nil || convertedFor?.0 != look.correct
            || convertedFor?.1 != look.lookLUT {
            convertedFrame = LiveChain.converted(
                source, through: LiveChain.colourStages(correction: correctionCube,
                                                        conversion: conversion,
                                                        look: lookCube(for: look.lookLUT)))
            convertedFor = (look.correct, look.lookLUT)
        }
        guard let converted = convertedFrame,
              let graded = LiveChain.graded(converted,
                                            with: LiveGrade(curve: curve,
                                                            saturation: look.colour.saturation,
                                                            warmth: look.colour.warmth))
        else { return }
        previewImage = NSImage(cgImage: graded, size: NSSize(width: graded.width,
                                                             height: graded.height))
        scopes = Scopes.measure(graded)
        isLive = true
        status = "Live preview. Letting go renders the exact frame."
        statusIsFailure = false
    }

    /// Fetches the source frame for a clip. Once per clip and timecode, off the main thread.
    private func refreshSource(for clip: ClipList.Entry, seconds: Double) {
        guard let frame = try? renderer.render(clip: clip.url, seconds: seconds, look: look,
                                               height: 480, match: false, stage: .source),
              let image = NSImage(contentsOf: frame.url)?
                .cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            DispatchQueue.main.async { self.isFetchingSource = false }
            return
        }
        DispatchQueue.main.async {
            self.sourceImage = image
            self.sourceClip = clip.url
            self.sourceSeconds = seconds
            self.isFetchingSource = false
            // A new clip's pixels, so whatever was converted belongs to the old one.
            self.convertedFrame = nil
            self.convertedFor = nil
        }
    }

    /// Which preview request is current. A render that finishes after a newer one was asked for
    /// is answering a question nobody is still asking.
    private var previewGeneration = 0
    private var previewProcess: Process?

    let workDirectory: URL

    private let engine: EngineLocation
    private let renderer: PreviewRenderer
    private let queue = DispatchQueue(label: "loggrade.preview")

    init(engine: EngineLocation, look: Look) {
        self.engine = engine
        self.look = look
        self.availableLooks = engine.availableLooks()
        self.project = Project(presets: [.init(name: "shipped", look: look)],
                               activePreset: "shipped")
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("loggrade-preview", isDirectory: true)
        self.workDirectory = work
        self.renderer = PreviewRenderer(engine: engine, workDirectory: work)
        // Read once, here: it is 65 points and parsing it costs more than a frame does. A missing
        // cube is not fatal — preflight reports it, and the live tier simply does not start.
        self.conversionCube = try? Cube3D(contentsOf: engine.appleCube)
        refreshCurve()
    }

    /// The curve the render will apply to this clip, built here.
    ///
    /// Synchronous, and cheap enough to call on every control change: the curve is 4096 entries of
    /// arithmetic and the solve is ten lines. Both were subprocesses, which put the graph and the
    /// live picture a tenth of a second behind the pointer; `ToneCurvePortTests` holds each to the
    /// generator it replaced, entry for entry.
    ///
    /// THE SLIDER IS NOT THE CURVE. With exposure matching on, which is every render this app
    /// performs, `tone.gamma` is the REFERENCE gamma and the engine solves a per-clip gamma from
    /// it so that every clip lands where the look was tuned. Drawing the slider value gives a
    /// graph of a curve nothing applies.
    func refreshCurve() {
        var tone = look.tone
        if let clip = selectedClip?.url, let measured = measuredYAVG[clip] {
            tone.gamma = ToneCurve.solvedGamma(clipYAVG: measured,
                                               referenceYAVG: look.matchReferenceYAVG,
                                               referenceGamma: tone.gamma)
        }
        appliedGamma = tone.gamma
        curve = ToneCurve.generated(tone: tone)
    }

    /// What the engine measured for each clip, mirrored here so the solve above needs no render
    /// and no cross-thread read of the renderer's own cache.
    private var measuredYAVG: [URL: Double] = [:]

    // MARK: - presets and the project file

    /// Switches to a preset, which replaces the whole grade: a look cube together with its tone
    /// and trims. They are switched as a pair because the shipped curve was tuned with its cube in
    /// the chain, so swapping one alone is a different grade rather than another film stock.
    func apply(preset name: String) {
        guard let preset = project.presets.first(where: { $0.name == name }) else { return }
        project.activePreset = name
        look = preset.look
        refreshCurve()
        renderPreview()
    }

    /// Keeps the current grade under a name. A new name adds one; an existing name replaces it,
    /// which is how you save over a preset you have been adjusting.
    func savePreset(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        if let index = project.presets.firstIndex(where: { $0.name == trimmed }) {
            project.presets[index] = .init(name: trimmed, look: look)
        } else {
            project.presets.append(.init(name: trimmed, look: look))
        }
        project.activePreset = trimmed
    }

    /// The grade differs from the preset it came from. Worth showing: an unsaved adjustment that
    /// looks like a preset is how a shoot ends up rendered with something nobody chose.
    var hasUnsavedChanges: Bool {
        guard let active = project.active else { return true }
        return active.look != look
    }

    func saveProject(to url: URL) throws {
        var copy = project
        copy.outputDirectory = project.outputDirectory
        try copy.serialised().write(to: url, options: .atomic)
        projectURL = url
        UserDefaults.standard.set(url, forKey: "lastProject")
    }

    func openProject(at url: URL) throws {
        project = try Project(data: try Data(contentsOf: url))
        projectURL = url
        UserDefaults.standard.set(url, forKey: "lastProject")
        if let active = project.active {
            look = active.look
            refreshCurve()
            renderPreview()
        }
    }

    /// WHERE DELIVERABLES GO, which is not the same place previews go.
    ///
    /// A preview is scratch and belongs in a temp directory. A deliverable is the thing the whole
    /// app exists to produce, and rendering it into a temp directory — which is what this did —
    /// means macOS is free to delete your shoot. The engine writes `dist/` inside whatever work
    /// directory it is given, so choosing an output folder is choosing that.
    ///
    /// The default is the folder the clips came from, so a shoot's output lands beside it rather
    /// than somewhere nobody chose. ADR 0006 in the engine's own docs makes the same argument
    /// about defaults that work with no configuration.
    var outputDirectory: URL? {
        if let chosen = project.outputDirectory { return chosen }
        return clipEntries?.first?.url.deletingLastPathComponent()
    }

    func chooseOutputDirectory(_ url: URL) {
        project.outputDirectory = url
    }

    /// Renders every clip in the list, through the engine, with the project's own settings. The
    /// look is written to a file per run and handed over with LOOK_FILE, so a render never edits
    /// the checkout's own look.json.
    func convert(queue: RenderQueue) {
        guard let clips = clipEntries else { return }
        queue.clearFinished()
        queue.enqueue(clips.map { (url: $0.url, stem: $0.stem, frames: $0.fields?.frameCount) })
        let project = self.project
        let look = self.look
        // The look file is scratch and stays in the scratch directory; the RENDER goes where the
        // person said, or beside their footage.
        let work = self.workDirectory
        guard let destination = outputDirectory else { return }
        queue.enqueue([])
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let lookFile = work.appendingPathComponent("render-look.json")
            try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            try? look.write(to: lookFile)
            try? FileManager.default.createDirectory(at: destination,
                                                      withIntermediateDirectories: true)
            queue.start(environment: { stem in
                var env = project.environment(for: stem, lookFile: lookFile)
                env["GRADE_WORK_DIR"] = destination.path
                return env
            })
            _ = self
        }
    }

    /// Steps through the clips in the list, which is what a shoot is worked through as.
    func step(_ direction: Int, in clips: [ClipList.Entry]) {
        guard !clips.isEmpty else { return }
        let current = clips.firstIndex(where: { $0.stem == selectedClip?.stem }) ?? -1
        let next = max(0, min(clips.count - 1, current + direction))
        guard next != current else { return }
        selectedClip = clips[next]
        renderPreview()
    }

    func cancel(queue: RenderQueue) {
        queue.cancel()
        RenderQueue.sweepStagingFiles(in: workDirectory)
    }

    /// The clips the interface is holding, set by the window when the list changes.
    var clipEntries: [ClipList.Entry]?

    /// Where the project was opened from or last saved to.
    @Published var projectURL: URL?

    /// The crop offset for the selected clip, in master pixels. Nil means undecided, which is not
    /// zero: the engine refuses a Feed render across clips without one, because one clip's framing
    /// applied to eighteen others produces files that all look done.
    var cropOffset: Int? {
        get { selectedClip.flatMap { project.clips[$0.stem]?.cropOffset } }
        set {
            guard let stem = selectedClip?.stem else { return }
            var settings = project.clips[stem] ?? Project.ClipSettings()
            settings.cropOffset = newValue
            project.clips[stem] = settings
        }
    }

    /// The window's geometry for the selected clip, from what was measured about it rather than
    /// from this camera's numbers assumed.
    var cropGeometry: CropGeometry? {
        guard let f = selectedClip?.fields else { return nil }
        // The container reports these clips landscape, because rotation is a display-matrix flag.
        // The master the engine crops is the DECODED frame, so the two are swapped here.
        let w = min(f.width, f.height), h = max(f.width, f.height)
        return CropGeometry(sourceWidth: w, sourceHeight: h)
    }

    /// What would stop a render, named before one starts.
    var blockers: [Project.Blocker] {
        project.blockers(for: clipNames)
    }

    var clipNames: [String] = []

    func renderPreview() {
        guard let clip = selectedClip, clip.isUsable else { return }
        let look = self.look
        let seconds = previewSeconds

        // A NEWER REQUEST CANCELS THE ONE IN FLIGHT. Moving three controls in a row used to mean
        // waiting for three renders in sequence, the first two answering questions nobody was
        // still asking. The generation counter discards their results; stopping the process stops
        // the work rather than merely ignoring it.
        previewGeneration += 1
        let generation = previewGeneration
        if let running = previewProcess, running.isRunning {
            EngineRun.stop(running)
        }

        // Decided on the main thread, where these are the only ones touched.
        let needsSource = sourceClip != clip.url || sourceSeconds != seconds
        if needsSource { isFetchingSource = true }

        isRendering = true
        status = "Rendering…"
        statusIsFailure = false
        queue.async { [weak self] in
            guard let self else { return }
            do {
                let frame = try self.renderer.render(
                    clip: clip.url, seconds: seconds, look: look,
                    onStart: { [weak self] process in self?.previewProcess = process })
                guard generation == self.previewGeneration else { return }
                let image = NSImage(contentsOf: frame.url)
                let measured = image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
                    .map { Scopes.measure($0) }
                DispatchQueue.main.async {
                    guard generation == self.previewGeneration else { return }
                    // Compare holds the last EXACT frame, from its own slot. Taking it from
                    // `previewImage` would sometimes take a live approximation instead, which
                    // answers a question about the model rather than about the grade.
                    self.previousImage = self.lastExactImage
                    self.lastExactImage = image
                    self.previewImage = image
                    self.scopes = measured
                    self.renderedLook = look
                    self.isRendering = false
                    self.isLive = false
                    self.status = "This is the grade. Grain, sharpening, denoise, the stabiliser and dither are added when you convert."
                    self.statusIsFailure = false
                    // The FIRST render of a clip is the one that measures its mean, so until it
                    // lands there is no solved gamma and the graph beside the sliders is drawing
                    // the reference curve. Record it and regenerate.
                    if let yavg = frame.yavg { self.measuredYAVG[clip.url] = yavg }
                    self.refreshCurve()
                }
                // AFTER the exact frame is on screen. The source is only needed for the next drag,
                // so fetching it first would add its second to the wait for a picture somebody is
                // already looking at.
                if needsSource { self.refreshSource(for: clip, seconds: seconds) }
            } catch {
                guard generation == self.previewGeneration else { return }
                DispatchQueue.main.async {
                    guard generation == self.previewGeneration else { return }
                    self.isRendering = false
                    self.status = String(describing: error)
                    self.statusIsFailure = true
                }
            }
        }
    }
}
