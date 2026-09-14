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
        /// The picture, in its OWN observable. A new frame must not rebuild the inspector, which is
    /// what made a drag feel slow even though grading the frame took four milliseconds.
    let preview = LivePreview()
    // ONE PLACE, not every call site. A clip becomes the selected one from a drop, a click, the
    // arrow keys and an opened project, and the live tier needs its source frame however it got
    // there. Hanging it off the property means a new path cannot forget.
    @Published var selectedClip: ClipList.Entry? { didSet { prepareLivePreview() } }
    @Published var previewSeconds: Double = 1 { didSet { prepareLivePreview() } }
    /// Held down rather than clicked. A colourist compares by holding a key and letting go, which
    /// is what the Bench does too; a long press on a label was undiscoverable and awkward.
    @Published var isComparing = false
    /// The look the last ENGINE render used. Comparing it with the current one is how the panel
    /// knows the exact frame is out of date. The live tier keeps the picture current in between,
    /// so this is about which of the two you are looking at rather than about a stale picture.
    @Published private(set) var renderedLook: Look?

    var isStale: Bool {
        guard let rendered = renderedLook, preview.image != nil else { return false }
        return rendered != look
    }

    /// The project: presets, delivery, and what is decided per clip. Held here because the crop
    /// offset has to live somewhere that survives selecting another clip, and because a shoot is
    /// the unit of work rather than a file.
    @Published var project: Project

    /// Told when something finishes that you were not watching.
    weak var toaster: Toaster?

    /// What a control goes back to when you double-click its name: the value it had in the
    /// active preset, not a neutral. "Default" in a grading tool means the look you started this
    /// clip from, so undoing one control returns it to the grade rather than switching it off.
    var defaultLook: Look {
        project.presets.first(where: { $0.name == project.activePreset })?.look ?? look
    }

    /// Which inspector stages are open. Remembered across launches, because which part of the
    /// chain you are working on outlives a window.
    @Published var openStages: Set<String> = ["Tone"]

    func setStage(_ title: String, open: Bool) {
        if open { openStages.insert(title) } else { openStages.remove(title) }
        UserDefaults.standard.set(Array(openStages), forKey: "openStages")
    }

    /// The cubes on disk, read once: the interface offers what is there.
    let availableLooks: [String]
    let availablePrints: [String]

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
    /// Set while a control is under the pointer, which is only used to decide whether a render in
    /// flight is worth cancelling. It is NOT what decides whether the live tier runs: a preset or
    /// a film look changes the picture just as much as a drag does, and used to cost a three
    /// second render to see.
    private var isDragging = false
    /// The gamma the engine will apply to this clip. The midtone slider holds the REFERENCE
    /// gamma, and the two are different numbers on every clip that was not shot at the exposure
    /// the look was tuned at — so the interface shows both rather than letting the readout claim a
    /// value nothing applies.
    @Published var appliedGamma: Double?

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
    private var convertedFor: ColourKey?

    /// Everything the colour stages depend on, so a tone drag reuses them and nothing else does.
    private struct ColourKey: Equatable {
        let correct: Look.Correct
        let halation: Look.Halation
        let lookLUT: String
        let lookStrength: Double
        let printLUT: String
        let printStrength: Double

        init(_ look: Look) {
            correct = look.correct; halation = look.halation
            lookLUT = look.lookLUT; lookStrength = look.lookStrength
            printLUT = look.printLUT; printStrength = look.printStrength
        }
    }

    private func lookCube(for stem: String) -> Cube3D? {
        if let cached = lookCubeCache[stem] { return cached }
        guard let url = engine.lookCube(named: stem), let cube = try? Cube3D(contentsOf: url) else {
            return nil
        }
        lookCubeCache[stem] = cube
        return cube
    }

    /// Prints are cached apart from looks: a stem names a file within its own folder, and nothing
    /// stops a look and a print sharing one.
    private var printCubeCache: [String: Cube3D] = [:]

    private func printCube(for stem: String) -> Cube3D? {
        if let cached = printCubeCache[stem] { return cached }
        guard let url = engine.printCube(named: stem), let cube = try? Cube3D(contentsOf: url) else {
            return nil
        }
        printCubeCache[stem] = cube
        return cube
    }

    /// Called when the selection or the preview timecode changes. Fetches the frame the live tier
    /// grades, so the controls work before anything has been rendered.
    func prepareLivePreview() {
        guard let clip = selectedClip, clip.isUsable else { return }
        guard sourceClip != clip.url || sourceSeconds != previewSeconds else { return }
        guard !isFetchingSource else { return }
        isFetchingSource = true
        let seconds = previewSeconds
        let look = self.look
        queue.async { [weak self] in
            self?.refreshSource(for: clip, seconds: seconds, look: look)
        }
    }

    /// A control went under the pointer.
    ///
    /// The render in flight is for a look nobody wants any more — the person is already moving
    /// away from it — so it is stopped here rather than left to finish and be discarded. Without
    /// this, letting go and immediately grabbing again gives three dead seconds.
    func beginDrag() {
        isDragging = true
        // Unless nothing is live yet for THIS clip at THIS timecode. `sourceImage` alone is not
        // that question: right after a clip switch it still holds the previous clip's frame, so
        // checking it cancelled the very render that would have fetched the new one, and grabbing
        // a control every couple of seconds kept live from ever starting.
        let liveHere = sourceImage != nil && sourceClip == selectedClip?.url
            && sourceSeconds == previewSeconds
        if preview.isRendering && liveHere {
            previewGeneration += 1
            if let running = previewProcess, running.isRunning { EngineRun.stop(running) }
            preview.isRendering = false
        }
    }

    func endDrag() { isDragging = false }

    /// What the live tier is currently grading, and what it should be grading.
    ///
    /// COALESCED, not queued. A drag emits control changes faster than a frame can be graded, and
    /// queueing them means every frame after the first answers a question the pointer has already
    /// moved past — the picture falls behind and keeps falling. So there is at most one grade in
    /// flight; anything that arrives while it runs replaces the pending look, and when the grade
    /// finishes it starts again on the latest. The picture is then always at most one frame behind
    /// the pointer, whatever the frame costs.
    private var gradeInFlight = false
    private var pendingLook: Look?

    /// Follows the controls.
    ///
    /// EVERY CHANGE, not only a drag. This used to require the pointer to be down, which meant
    /// picking a film look or a preset skipped the live tier entirely and cost a three-second
    /// engine render to see — the slowest thing in the app, for the control with the biggest
    /// effect on the picture.
    func liveUpdate() {
        guard let clip = selectedClip else { return }
        guard sourceImage != nil, sourceClip == clip.url, sourceSeconds == previewSeconds else {
            if isFetchingSource { preview.say("Preparing preview…") }
            return
        }
        refreshCurve()
        pendingLook = look
        startGradeIfIdle()
    }

    private func startGradeIfIdle() {
        guard !gradeInFlight, let wanted = pendingLook, let source = sourceImage,
              let conversion = conversionCube, let curve = preview.curve else { return }
        pendingLook = nil
        gradeInFlight = true

        // Built here, on the main thread, because they read the caches this class owns.
        if correctionFor != wanted.correct {
            correctionCube = wanted.correct.isNeutral ? nil
                : CorrectionCube.cube(for: wanted.correct, size: 33)
            correctionFor = wanted.correct
        }
        // A correction the engine would refuse gets no live picture, rather than a picture of
        // something it will not render.
        if !wanted.correct.isNeutral && correctionCube == nil {
            gradeInFlight = false
            preview.isLive = false
            preview.say("That correction isn’t a value the engine accepts.", failure: true)
            return
        }
        // Built against the SOURCE frame's height, because the look stores the glow's radius as a
        // fraction of the frame and the frame this grades is the preview-sized one.
        let halation = LiveHalation(wanted.halation, frameHeight: source.height)
        if !wanted.halation.isNeutral && halation == nil {
            gradeInFlight = false
            preview.isLive = false
            preview.say("That halation tint isn’t a value the engine accepts.", failure: true)
            return
        }
        let stages = LiveChain.colourStages(correction: correctionCube, halation: halation,
                                            conversion: conversion,
                                            look: lookCube(for: wanted.lookLUT),
                                            lookStrength: wanted.lookStrength,
                                            print: printCube(for: wanted.printLUT),
                                            printStrength: wanted.printStrength)
        let reuse = convertedFor == ColourKey(wanted) ? convertedFrame : nil
        let grade = LiveGrade(curve: curve, saturation: wanted.colour.saturation,
                              warmth: wanted.colour.warmth)

        // OFF THE MAIN THREAD. The main thread's job during a drag is to keep the window
        // responding; grading a frame on it makes the slider itself stutter, which reads as the
        // app being slow rather than the picture being late.
        liveQueue.async { [weak self] in
            guard let self else { return }
            let converted = reuse ?? LiveChain.converted(source, through: stages)
            let graded = converted.flatMap { LiveChain.graded($0, with: grade) }
            let measured = graded.map { Scopes.measure($0) }
            DispatchQueue.main.async {
                self.gradeInFlight = false
                if let converted {
                    self.convertedFrame = converted
                    self.convertedFor = ColourKey(wanted)
                }
                if let graded {
                    self.preview.image = NSImage(cgImage: graded,
                                                 size: NSSize(width: graded.width,
                                                              height: graded.height))
                    self.preview.scopes = measured
                    self.preview.isLive = true
                    self.preview.say("Live preview. Release to render the exact frame.")
                }
                // Whatever arrived while that ran.
                self.startGradeIfIdle()
            }
        }
    }

    /// Fetches the source frame for a clip, and the clip's exposure with it.
    ///
    /// ON SELECTION, not after the first exact render. The whole claim of this tier is that you
    /// pick a clip, grab a control and see the picture move; waiting for a three-second render
    /// before any of that works is the lag it exists to remove. The frame has no chain on it, so
    /// it is quick, and `match: true` costs one probe — which is what the solved gamma needs, so
    /// the curve is right on the first drag rather than after the first render.
    ///
    /// On the same serial queue as every other render, deliberately. Both write `preview-look.json`
    /// and the per-clip tone cube into one work directory, and two ffmpeg processes racing over
    /// those is the class of bug this repo keeps finding.
    ///
    /// `look` is passed in rather than read here: this runs off the main thread, and reading a
    /// published property from one is the mistake CLAUDE.md names.
    private func refreshSource(for clip: ClipList.Entry, seconds: Double, look: Look) {
        guard let frame = try? renderer.render(clip: clip.url, seconds: seconds, look: look,
                                               height: 480, stage: .source),
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
            self.toaster?.show("photo", "\(clip.stem) ready", "Controls are live for this clip.")
            // The probe this render paid for. It is what the gamma solve needs, and recording it
            // here means the curve is the rendered one from the first drag rather than from the
            // first render.
            if let yavg = frame.yavg {
                self.measuredYAVG[clip.url] = yavg
                self.refreshCurve()
            }
        }
    }

    /// Which preview request is current. A render that finishes after a newer one was asked for
    /// is answering a question nobody is still asking.
    private var previewGeneration = 0
    private var previewProcess: Process?

    let workDirectory: URL

    private let engine: EngineLocation
    private let renderer: PreviewRenderer
    /// Engine renders, which take seconds and must not overlap: they share a work directory and a
    /// per-clip tone cube.
    private let queue = DispatchQueue(label: "loggrade.engine")
    /// The live grade, on its OWN queue. Sharing the engine's serial queue meant every live frame
    /// waited behind the three-second render that the last control change had started — so letting
    /// go of one slider froze the next one, which is the exact stutter this tier exists to remove.
    private let liveQueue = DispatchQueue(label: "loggrade.live", qos: .userInteractive)

    init(engine: EngineLocation, look: Look) {
        self.engine = engine
        self.look = look
        self.availableLooks = engine.availableLooks()
        self.availablePrints = engine.availablePrints()
        self.project = Project(presets: [.init(name: "shipped", look: look)],
                               activePreset: "shipped")
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("loggrade-preview", isDirectory: true)
        self.workDirectory = work
        self.renderer = PreviewRenderer(engine: engine, workDirectory: work)
        // Read once, here: it is 65 points and parsing it costs more than a frame does. A missing
        // cube is not fatal — preflight reports it, and the live tier simply does not start.
        self.conversionCube = try? Cube3D(contentsOf: engine.appleCube)
        if let remembered = UserDefaults.standard.stringArray(forKey: "openStages") {
            self.openStages = Set(remembered)
        }
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
        // WRITTEN ONLY WHEN IT CHANGES. Both of these are @Published, and a redundant write to a
        // published property is a full rebuild of every view observing this object — which during
        // a drag is the inspector, sixty times a second, for a value that did not move.
        if appliedGamma != tone.gamma { appliedGamma = tone.gamma }
        preview.curve = ToneCurve.generated(tone: tone)
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
        // Live FIRST. A preset is the biggest change the interface can make, and waiting three
        // seconds to see it was the slowest thing in the app.
        liveUpdate()
        renderPreview()
    }

    /// Keeps the current grade under a name. The rule is `Project.savePreset`, where it is tested.
    func savePreset(named name: String) {
        project.savePreset(named: name, look: look)
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
    /// THE CLIP LIST ITSELF, not a copy of it.
    ///
    /// These were two stored properties that every import path had to remember to refresh, and
    /// there were four such paths. One forgot, so the list showed three clips while the model
    /// believed it had none — which disabled Convert with no explanation, because "no clips" was
    /// never a state the interface expected to be in while clips were visibly on screen. A derived
    /// value cannot fall out of step with what it is derived from.
    weak var clips: ClipList?
    var clipEntries: [ClipList.Entry]? { clips.map { $0.usable } }
    var clipNames: [String] { clips?.usable.map(\.stem) ?? [] }

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

    /// Whether this clip gets stabilised. Per clip, not per project: a locked-off shot does not
    /// want a warp, and a handheld one does.
    var stabilise: Bool {
        get { selectedClip.flatMap { project.clips[$0.stem]?.stabilise } ?? true }
        set {
            guard let stem = selectedClip?.stem else { return }
            var settings = project.clips[stem] ?? Project.ClipSettings()
            settings.stabilise = newValue
            project.clips[stem] = settings
        }
    }

    /// Moves the crop by a number of pixels, clamped. The keyboard exists here because a drag
    /// finds a framing and only a number repeats one — the same reason every readout in the
    /// inspector can be typed into.
    func nudgeCrop(by pixels: Int) {
        guard let geometry = cropGeometry else { return }
        cropOffset = geometry.clamp((cropOffset ?? geometry.maximumOffset / 2) + pixels)
    }

    /// The window's geometry for the selected clip, from what was measured about it rather than
    /// from this camera's numbers assumed — and in the shape of the deliverable that will actually
    /// be cropped, rather than in 4:5 whatever was ticked.
    ///
    /// THE FIRST CROPPING TARGET DECIDES when several crop. They share one per-clip offset, so one
    /// box is all there is to draw; drawing it in the first one's shape is at least a window the
    /// render produces. Two cropping deliverables wanting different framing is the case this does
    /// not cover, and it needs a second offset before it needs a second box.
    var cropGeometry: CropGeometry? {
        guard let f = selectedClip?.fields,
              let target = project.delivery.croppingTargets.first else { return nil }
        // The container reports these clips landscape, because rotation is a display-matrix flag.
        // The master the engine crops is the DECODED frame, so the two are swapped here.
        let w = min(f.width, f.height), h = max(f.width, f.height)
        return CropGeometry(sourceWidth: w, sourceHeight: h,
                            aspectWidth: target.aspectWidth, aspectHeight: target.aspectHeight)
    }

    /// What would stop a render, named before one starts.
    var blockers: [Project.Blocker] {
        project.blockers(for: clipNames)
    }


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

        preview.isRendering = true
        preview.say("Rendering…")
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
                    // `preview.image` would sometimes take a live approximation instead, which
                    // answers a question about the model rather than about the grade.
                    self.preview.previous = self.preview.lastExact
                    self.preview.lastExact = image
                    self.preview.image = image
                    self.preview.scopes = measured
                    self.renderedLook = look
                    self.preview.isRendering = false
                    self.preview.isLive = false
                    self.preview.say("This is the grade. Grain, sharpening, denoise, the stabiliser and dither are added when you convert.")
                    // The FIRST render of a clip is the one that measures its mean, so until it
                    // lands there is no solved gamma and the graph beside the sliders is drawing
                    // the reference curve. Record it and regenerate.
                    if let yavg = frame.yavg { self.measuredYAVG[clip.url] = yavg }
                    self.refreshCurve()
                }
                // AFTER the exact frame is on screen. The source is only needed for the next drag,
                // so fetching it first would add its second to the wait for a picture somebody is
                // already looking at.
                // A fallback only: the source is normally fetched when the clip is selected. This
                // covers a fetch that failed, so a preview still eventually restores live mode.
                if needsSource { self.refreshSource(for: clip, seconds: seconds, look: look) }
            } catch {
                guard generation == self.previewGeneration else { return }
                DispatchQueue.main.async {
                    guard generation == self.previewGeneration else { return }
                    self.preview.isRendering = false
                    self.preview.say(String(describing: error), failure: true)
                }
            }
        }
    }
}
