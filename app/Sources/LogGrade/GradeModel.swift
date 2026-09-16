import AppKit
import Combine
import CoreGraphics
import GradeKit
import SwiftUI

/// What the interface is editing, and the preview that follows it.
///
/// ObservableObject, not @Observable: the latter is macOS 14 and this builds against 13.
final class GradeModel: ObservableObject {
    // A new @Published property goes into the `changes` relay in init too, unless it follows from
    // the look; otherwise the panels that observe the relay never see it change.
    @Published var look: Look
    /// The picture, in its OWN observable. A new frame must not rebuild the inspector, which is
    /// what made a drag feel slow even though grading the frame took four milliseconds.
    let preview = LivePreview()
    // ONE PLACE, not every call site. A clip becomes the selected one from a drop, a click, the
    // arrow keys and an opened project, and each needs its picture however it got there. Hanging
    // it off the property means a new path cannot forget.
    @Published var selectedClip: ClipList.Entry? {
        didSet {
            renderPreview()
            if isComparing {
                preview.baseline = nil
                prepareBaseline()
            }
        }
    }
    let previewSeconds: Double = 1
    /// Held down rather than clicked. A colourist compares by holding a key and letting go, which
    /// is what the Bench did too; a long press on a label was undiscoverable and awkward.
    @Published var isComparing = false

    /// Stages switched off in the inspector. Everything that renders — the preview and the export —
    /// reads `effectiveLook`, so what you see with a stage off is what the shoot renders.
    ///
    /// NOT SAVED, deliberately: not in the preset, the project or the defaults. A bypass left on
    /// from yesterday's comparison silently renders a whole shoot without a stage.
    ///
    /// Denoise and grain start off: denoise because daylight footage is clean once scaled down,
    /// grain because Neutral is what opens. `apply(preset:)` turns grain on for a film preset.
    @Published var bypassed: Set<Look.Stage> = [.denoise, .grain]

    /// The selected clip's Adjust, stored in the project under the clip. With no clip selected
    /// there is nothing to adjust, and a write goes nowhere.
    var adjust: Look.Adjust {
        get { selectedClip.map { project.settings(for: $0.stem).adjust } ?? Look.Adjust() }
        set {
            guard let stem = selectedClip?.stem else { return }
            var settings = project.settings(for: stem)
            settings.adjust = newValue
            project.clips[stem] = settings
        }
    }

    /// Adjust switched off takes metering out too: off is the preset as shipped.
    var matches: Bool { adjust.match && !bypassed.contains(.adjust) }

    func setMatch(_ on: Bool) {
        adjust.match = on
        renderPreview()
    }

    var effectiveLook: Look { adjust.applied(to: look).bypassing(bypassed) }

    func setEnabled(_ stage: Look.Stage, _ enabled: Bool) {
        if enabled { bypassed.remove(stage) } else { bypassed.insert(stage) }
        refreshCurve()
        renderPreview()
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
    /// All closed at first: a preset is meant to be finished, so the panel opens on nothing to do.
    @Published var openStages: Set<String> = []

    func setStage(_ title: String, open: Bool) {
        if open { openStages.insert(title) } else { openStages.remove(title) }
        UserDefaults.standard.set(Array(openStages), forKey: DefaultsKey.openStages)
    }

    // MARK: - the preview

    /// The clip as the camera recorded it, decoded and resampled and nothing else. Every stage of
    /// the grade is applied to this in-process, for a drag and for the picture after it alike.
    ///
    /// IT DOES NOT DEPEND ON THE LOOK, which is the point. The correction stage runs before Apple's
    /// conversion, so a preview built on a converted frame could not show it. This is the clip, so
    /// it is fetched once per clip and per timecode and nothing else invalidates it.
    ///
    /// NO ENGINE RENDER BEHIND IT. Release, selection and a preset used to wait 2–4 s for
    /// `grade.sh FRAME` at 1440 lines. `LiveChainTests` holds this grade to that render (ADR 0009),
    /// so the preview is this grade and nothing replaces it.
    private var sourceImage: CGImage?
    private var sourceClip: URL?
    private var sourceSeconds: Double?
    /// The frame being decoded. One at a time: its landing re-checks the selection.
    private var fetchingSource: (clip: URL, seconds: Double)?
    /// 1080 lines: a landscape 4K clip grades in ~55 ms, ~125 ms with halation, on the Intel Mac
    /// in release. At 1440 the same was ~100 ms and up to 0.35 s. Decoding costs 0.35–0.9 s at
    /// any height, which is why decoded frames are kept.
    private static let sourceFrameHeight = 1080
    /// Recently viewed clips' frames, newest last, so switching back does not decode again.
    /// ~16 MB each at 1920x1080 (16-bit RGBA).
    private var recentSources: [DecodedSource] = []
    private static let recentSourceLimit = 8
    private struct DecodedSource {
        let clip: URL
        let seconds: Double
        let image: CGImage
    }
    /// Each clip's decoded frame, by stem. What decides which shapes crop a clip and along which
    /// axis; see `cropGeometry`.
    @Published private(set) var frameSizes: [String: FrameSize] = [:]
    // TOUCHED ONLY ON `liveQueue`, from here to `convertedFrom`. They were built on the main
    // thread, and the correction cube alone costs 10 ms on the Intel Mac — every tick of an
    // Exposure drag, which spent the frame the slider's thumb needed to redraw. `liveQueue` is
    // serial, so no two grades touch them at once.

    /// Conversion cubes, read on first use and kept. There are a handful.
    private var filmCubeCache: [URL: Cube3D] = [:]
    /// The correction cube and what it was built from, so an unchanged correction is not rebuilt
    /// 60 times a second.
    private var correctionCube: Cube3D?
    private var correctionFor: Look.Correct?
    /// The hue curves' cube and the curves it was built from, rebuilt only when a knot moves.
    private var hueCube: Cube3D?
    private var hueFor: Look.Hue?
    private var gradeCurve: ToneCurve?
    private var gradeCurveFor: Look.Tone?
    /// The engine's own default (`CORRECT_SIZE` in grade.sh), because the preview has to be
    /// built from the cube the render builds. The error at 17, 33 and 65 is measured in
    /// `make-correct-lut.py`.
    private static let correctionCubeSize = 33
    /// The source through the colour stages, kept so a tone or trim drag costs only the curve.
    /// Dragging midtone does not move the correction, the conversion or the hue curves, and those
    /// are most of the work.
    private var convertedFrame: LiveChain.Converted?
    private var convertedFor: ColourKey?
    /// Which source pixels `convertedFrame` came from, compared by identity. A new clip replaces
    /// `sourceImage` on the main thread, and this lets the live queue notice that without the main
    /// thread reaching into its cache.
    private var convertedFrom: CGImage?

    /// Everything the colour stages depend on, so a tone drag reuses them and nothing else does.
    private struct ColourKey: Equatable {
        let convertCube: String
        let correct: Look.Correct
        let halation: Look.Halation
        let hue: Look.Hue

        /// `look`'s correction is the one the frame was converted with, metering included.
        init(_ look: Look) {
            convertCube = look.convertCube
            correct = look.correct
            halation = look.halation
            hue = look.hue
        }
    }

    /// Everything a graded picture depends on. Two requests with the same key are the same pixels.
    private struct FrameKey: Equatable {
        let clip: URL
        let seconds: Double
        let look: Look
        /// Nil when the grade is unmetered: matching off, or a meter that failed.
        let metered: PreviewRenderer.Metered?
    }

    /// The rendering or a film stock, cached: each is 65 points, and parsing one costs more than a
    /// frame does, so it is read once rather than on a drag. Keyed by the resolved file, which is
    /// unique across `luts/rendering/` and `luts/film/` where a stem need not be.
    private func conversionCube(for stem: String) -> Cube3D? {
        filmCube(at: engine.conversionCube(named: stem))
    }

    private func filmCube(at url: URL?) -> Cube3D? {
        guard let url else { return nil }
        if let cached = filmCubeCache[url] { return cached }
        guard let cube = try? Cube3D(contentsOf: url) else { return nil }
        filmCubeCache[url] = cube
        return cube
    }

    /// Makes the selected clip's source frame the one graded: from `recentSources` at once, or
    /// decoded. The meter reading is started beside the decode, not after it.
    private func prepareSource() {
        guard let clip = selectedClip, clip.isUsable else { return }
        let seconds = previewSeconds
        _ = metering(for: effectiveLook, clip: clip.url, match: matches)
        guard !isLiveHere else { return }
        if let index = recentSources.firstIndex(where: {
            $0.clip == clip.url && $0.seconds == seconds
        }) {
            let recent = recentSources.remove(at: index)
            recentSources.append(recent)
            useSource(recent)
            return
        }
        guard fetchingSource == nil else { return }
        fetchingSource = (clip.url, seconds)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let decoded = Result {
                try NativeSource.frame(of: clip.url, at: seconds, height: Self.sourceFrameHeight)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.fetchingSource = nil
                let selected = self.selectedClip?.url == clip.url
                switch decoded {
                case .success(let frame):
                    self.frameSizes[clip.stem] = frame.sourceSize
                    let recent = DecodedSource(clip: clip.url, seconds: seconds, image: frame.image)
                    self.recentSources.append(recent)
                    if self.recentSources.count > Self.recentSourceLimit {
                        self.recentSources.removeFirst()
                    }
                    if selected { self.useSource(recent) }
                case .failure(let error):
                    // SAID, not only reset: controls that answer nothing with no reason given
                    // read as the app being slow rather than as a clip it cannot read.
                    if selected {
                        self.preview.isRendering = false
                        self.preview.isOutOfDate = self.preview.image != nil
                        self.preview.say(
                            "The preview couldn’t read this clip: \(error)", failure: true)
                    }
                }
                // The selection moved on while this decoded.
                if !selected { self.prepareSource() }
            }
        }
    }

    private func useSource(_ source: DecodedSource) {
        sourceImage = source.image
        sourceClip = source.clip
        sourceSeconds = source.seconds
        startGradeIfIdle()
        if isComparing { prepareBaseline() }
    }

    private var isLiveHere: Bool {
        sourceImage != nil && sourceClip == selectedClip?.url && sourceSeconds == previewSeconds
    }

    /// What is graded, and what should be.
    ///
    /// COALESCED, not queued. A drag emits control changes faster than a frame can be graded, and
    /// queueing them means every frame after the first answers a question the pointer has already
    /// moved past — the picture falls behind and keeps falling. So there is at most one grade in
    /// flight; anything that arrives while it runs replaces the pending look, and when the grade
    /// finishes it starts again on the latest. The picture is then always at most one frame behind
    /// the pointer, whatever the frame costs.
    private var gradeInFlight = false
    private var pendingLook: Look?
    /// Which request is current. A grade that lands after a cached picture was shown is answering
    /// a question nobody is still asking.
    private var previewGeneration = 0
    /// The look a release, a selection or a preset asked for. The picture of it is kept in
    /// `finishedFrames`; the frames of a drag are not, or they would push out every clip's.
    private var settleLook: Look?
    private var displayed: FinishedFrame?

    /// Follows the controls.
    ///
    /// EVERY CHANGE, not only a drag. This used to require the pointer to be down, which meant
    /// picking a preset showed nothing until a render finished.
    func liveUpdate() {
        guard selectedClip != nil else { return }
        pendingLook = effectiveLook
        startGradeIfIdle()
    }

    private func startGradeIfIdle() {
        guard !gradeInFlight, let wanted = pendingLook, let clip = selectedClip?.url else { return }
        guard isLiveHere, let source = sourceImage, let seconds = sourceSeconds else {
            if fetchingSource != nil { waiting() }
            return
        }
        let metered: PreviewRenderer.Metered?
        let unmetered: Bool
        switch metering(for: wanted, clip: clip, match: matches) {
        case .off:
            (metered, unmetered) = (nil, false)
        case .reading(let reading):
            (metered, unmetered) = (reading, false)
        case .failed:
            (metered, unmetered) = (nil, true)
        case .pending:
            // NOT GRADED UNMETERED IN THE MEANTIME: that picture is not the one the export makes.
            return waiting()
        }
        pendingLook = nil
        let key = FrameKey(clip: clip, seconds: seconds, look: wanted, metered: metered)
        // A release after a drag, or every slider's onChange after a preset: already on screen.
        if key == displayed?.key {
            keepIfSettled()
            return
        }
        gradeInFlight = true
        let generation = previewGeneration
        // Read now, on the main thread: the selection can move on while this grade is queued.
        let sourceLongEdge = frameSizes[clip.deletingPathExtension().lastPathComponent]
            .map { max($0.width, $0.height) }

        // OFF THE MAIN THREAD, all of it. The main thread's job during a drag is to redraw the
        // slider; any work here is a frame the thumb doesn't get, which reads as the control being
        // slow rather than the picture being late.
        liveQueue.async { [weak self] in
            guard let self else { return }
            let outcome = self.grade(
                wanted, source: source, metered: metered, sourceLongEdge: sourceLongEdge)
            let finished = outcome.frame.map { image in
                FinishedFrame(
                    key: key,
                    image: NSImage(
                        cgImage: LiveChain.forDisplay(image),
                        size: NSSize(width: image.width, height: image.height)),
                    scopes: Scopes.measure(image))
            }
            DispatchQueue.main.async {
                self.gradeInFlight = false
                if generation == self.previewGeneration, self.selectedClip?.url == clip {
                    switch outcome {
                    case .refused(let reason):
                        self.preview.isRendering = false
                        self.preview.isOutOfDate = self.preview.image != nil
                        self.preview.say(reason, failure: true)
                    case .graded(_, let tone, let curve):
                        if tone != self.publishedTone {
                            self.preview.curve = curve
                            self.publishedTone = tone
                        }
                        if let finished { self.show(finished) }
                        if unmetered {
                            self.preview.say(
                                "This clip couldn’t be metered, so the preview shows it unmetered.",
                                failure: true)
                        }
                        self.keepIfSettled()
                    case .failed:
                        self.preview.isRendering = false
                    }
                }
                // Whatever arrived while that ran.
                self.startGradeIfIdle()
            }
        }
    }

    /// The picture is not yet the one asked for, and the reason is not a failure.
    private func waiting() {
        preview.isRendering = true
        preview.isOutOfDate = preview.image != nil
        preview.say("Preparing preview…")
    }

    private func show(_ frame: FinishedFrame) {
        displayed = frame
        preview.image = frame.image
        preview.scopes = frame.scopes
        preview.isRendering = false
        preview.isOutOfDate = false
        preview.say("")
    }

    private func keepIfSettled() {
        guard let settle = settleLook, let frame = displayed, frame.key.look == settle,
            frame.key.clip == selectedClip?.url
        else { return }
        settleLook = nil
        guard !finishedFrames.contains(where: { $0.key == frame.key }) else { return }
        finishedFrames.append(frame)
        if finishedFrames.count > Self.finishedFrameLimit { finishedFrames.removeFirst() }
    }

    private enum LiveOutcome {
        case graded(CGImage, Look.Tone, ToneCurve)
        case refused(String)
        case failed

        var frame: CGImage? {
            if case .graded(let image, _, _) = self { return image }
            return nil
        }
    }

    /// One graded frame. Runs on `liveQueue`, where the caches it reads live.
    private func grade(
        _ requested: Look, source: CGImage, metered: PreviewRenderer.Metered?,
        sourceLongEdge: Int?
    ) -> LiveOutcome {
        // The engine adds what it metered to the look's correction before building the cube, so
        // the preview does the same.
        var wanted = requested
        if let metered { wanted.correct = metered.applied(to: wanted.correct) }
        guard let conversion = conversionCube(for: wanted.convertCube) else {
            return .refused("The conversion “\(wanted.convertCube)” couldn’t be read.")
        }
        if correctionFor != wanted.correct {
            correctionCube =
                wanted.correct.isNeutral
                ? nil
                : CorrectionCube.cube(for: wanted.correct, size: Self.correctionCubeSize)
            correctionFor = wanted.correct
        }
        // A correction the engine would refuse gets no picture, rather than a picture of
        // something it will not render.
        if !wanted.correct.isNeutral && correctionCube == nil {
            return .refused("That correction isn’t a value the engine accepts.")
        }
        // Built against the SOURCE frame's height, because the look stores the glow's radius as a
        // fraction of the frame and the frame this grades is the preview-sized one.
        let halation = LiveHalation(
            wanted.halation, frameLongEdge: max(source.width, source.height),
            sourceLongEdge: sourceLongEdge)
        if !wanted.halation.isNeutral && halation == nil {
            return .refused("That halation tint isn’t a value the engine accepts.")
        }
        if hueFor != wanted.hue {
            hueCube =
                wanted.hue.isNeutral
                ? nil : HueCube.cube(for: wanted.hue, size: Self.correctionCubeSize)
            hueFor = wanted.hue
        }
        if !wanted.hue.isNeutral && hueCube == nil {
            return .refused("Those hue curves aren’t values the engine accepts.")
        }

        let tone = wanted.tone
        if gradeCurveFor != tone {
            gradeCurve = ToneCurve.generated(tone: tone)
            gradeCurveFor = tone
        }
        guard let curve = gradeCurve else { return .failed }

        let key = ColourKey(wanted)
        let converted: LiveChain.Converted?
        if convertedFor == key, convertedFrom === source, let reused = convertedFrame {
            converted = reused
        } else {
            let stages = LiveChain.colourStages(
                correction: correctionCube, halation: halation,
                conversion: conversion, hue: hueCube)
            converted = LiveChain.converted(source, through: stages)
            if let converted {
                convertedFrame = converted
                convertedFor = key
                convertedFrom = source
            }
        }
        let grade = LiveGrade(
            curve: curve, saturation: wanted.colour.saturation,
            warmth: wanted.colour.warmth)
        guard let graded = converted.flatMap({ LiveChain.graded($0, with: grade) }) else {
            return .failed
        }
        return .graded(graded, tone, curve)
    }

    // MARK: - metering

    /// A reading counts only against the reference it was solved for: `match.reference_stops`
    /// differs between Neutral and the film looks, so a preset change can need a new one.
    private struct MeterKey: Hashable {
        let clip: URL
        let referenceStops: Double
    }
    /// Three numbers each, so not bounded.
    private var measuredMetering: [MeterKey: PreviewRenderer.Metered] = [:]
    /// Not retried on every control change; a new session tries again.
    private var failedMetering: Set<MeterKey> = []
    private var meteringInFlight: Set<MeterKey> = []

    private enum Metering {
        case off
        case reading(PreviewRenderer.Metered)
        case failed
        case pending
    }

    /// What the grade of `look` on `clip` adds for exposure and white balance, starting a reading
    /// when there is none. Off when matching is, which is what switches metering off in the export.
    private func metering(for look: Look, clip: URL, match: Bool) -> Metering {
        guard match else { return .off }
        let key = MeterKey(clip: clip, referenceStops: look.matchReferenceStops)
        if let reading = measuredMetering[key] { return .reading(reading) }
        if failedMetering.contains(key) { return .failed }
        guard meteringInFlight.insert(key).inserted else { return .pending }
        let meter = self.meter
        // The engine's own function (`ExposureMeter`), ~0.5 s on ProRes; in parallel with a decode.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let reading = try? meter.measure(key.clip, referenceStops: key.referenceStops)
            DispatchQueue.main.async {
                guard let self else { return }
                self.meteringInFlight.remove(key)
                // NIL, NOT ZERO, when the meter fails: a zero passed on as a reading would show
                // the clip unmetered while calling it metered.
                if let reading {
                    self.measuredMetering[key] = reading
                } else {
                    self.failedMetering.insert(key)
                }
                self.startGradeIfIdle()
                if self.isComparing { self.prepareBaseline() }
            }
        }
        return .pending
    }

    let workDirectory: URL

    private let engine: EngineLocation
    private let meter: ExposureMeter
    /// The grade, on its OWN serial queue, so the caches above are touched by one job at a time
    /// and never by the main thread.
    private let liveQueue = DispatchQueue(label: "loggrade.live", qos: .userInteractive)

    init(engine: EngineLocation, look: Look) {
        self.engine = engine
        self.look = look
        // Neutral and the engine's `presets/`. Every opened project is given this same list
        // (`Project.adopt`), so `project.presets` is always the app's own.
        self.project = Project(
            presets: [.init(name: Self.neutralPresetName, look: look)] + engine.shippedPresets(),
            activePreset: Self.neutralPresetName)
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("loggrade-preview", isDirectory: true)
        self.workDirectory = work
        self.meter = ExposureMeter(engine: engine)
        if let remembered = UserDefaults.standard.stringArray(forKey: DefaultsKey.openStages) {
            self.openStages = Set(remembered)
        }
        refreshCurve()

        for changed in [
            $selectedClip.map { _ in () }.eraseToAnyPublisher(),
            $isComparing.map { _ in () }.eraseToAnyPublisher(),
            // Adjust lives in the project, and a drag writes it every tick; the panels watching
            // `changes` never show it, so they see the project without it.
            $project.map(\.ignoringAdjustments).removeDuplicates().map { _ in () }
                .eraseToAnyPublisher(),
            $openStages.map { _ in () }.eraseToAnyPublisher(),
            $bypassed.map { _ in () }.eraseToAnyPublisher(),
            $frameSizes.map { _ in () }.eraseToAnyPublisher(),
            $projectURL.map { _ in () }.eraseToAnyPublisher(),
        ] {
            changed.dropFirst()
                .sink { [changes] in changes.objectWillChange.send() }
                .store(in: &relayed)
        }
    }

    /// Everything this model publishes EXCEPT the look and what follows from it (`appliedGamma`),
    /// for the views that never read the look.
    ///
    /// A look write is sixty a second during a drag, and with ObservableObject every observer of
    /// the model rebuilds on each one. The delivery and queue panels alone cost the Intel Mac
    /// about 30 ms of SwiftUI and AppKit layout per tick, measured, so the slider's thumb ran at
    /// 20 fps while grading was already off the main thread. A new view that does not read
    /// `look` observes this; a new @Published property that such a view reads is added above.
    final class Changes: ObservableObject {}
    let changes = Changes()
    private var relayed: Set<AnyCancellable> = []

    /// The curve the render will apply, built here.
    ///
    /// Synchronous, and cheap enough to call on every control change: 4096 entries of arithmetic.
    /// It was a subprocess, which put the graph and the live picture a tenth of a second behind the
    /// pointer; `ToneCurvePortTests` holds it to the generator it replaced, entry for entry.
    func refreshCurve() {
        let tone = effectiveLook.tone
        guard tone != publishedTone else { return }
        preview.curve = ToneCurve.generated(tone: tone)
        publishedTone = tone
    }

    private var publishedTone: Look.Tone?

    // MARK: - presets and the project file

    /// Switches to a preset, which replaces the whole grade: a look cube together with its tone
    /// and trims. They are switched as a pair because the shipped curve was tuned with its cube in
    /// the chain, so swapping one alone is a different grade rather than another film stock.
    func apply(preset name: String) {
        guard let preset = project.presets.first(where: { $0.name == name }) else { return }
        project.activePreset = name
        look = preset.look
        // Grain follows the preset: a film stock has one, Neutral does not.
        if preset.look.convertCube == Look.neutralConversion {
            bypassed.insert(.grain)
        } else {
            bypassed.remove(.grain)
        }
        refreshCurve()
        renderPreview()
    }

    /// The selected clip's Adjust and the switches back to where a preset starts. Other clips keep
    /// their Adjust: a reset while looking at one clip must not undo work on eighteen others.
    func resetAdjustments() {
        bypassed = [.denoise]
        adjust = Look.Adjust()
        apply(preset: project.activePreset)
    }

    var hasAdjustments: Bool {
        hasUnsavedChanges || adjust != Look.Adjust() || bypassed.contains(.adjust)
            || !bypassed.contains(.denoise)
            || bypassed.contains(.grain) != (look.convertCube == Look.neutralConversion)
    }

    /// The grade differs from the preset it came from. Worth showing: an unsaved adjustment that
    /// looks like a preset is how a shoot ends up rendered with something nobody chose.
    var hasUnsavedChanges: Bool {
        guard let active = project.active else { return true }
        return active.look != look
    }

    func saveProject(to url: URL) throws {
        try project.serialised().write(to: url, options: .atomic)
        projectURL = url
        UserDefaults.standard.set(url, forKey: DefaultsKey.lastProject)
    }

    /// The app's own rendering with nothing on top: the preset a new project starts on.
    static let neutralPresetName = "Neutral"

    func openProject(at url: URL) throws {
        var opened = try Project(data: try Data(contentsOf: url))
        opened.adopt(presets: project.presets, fallback: Self.neutralPresetName)
        project = opened
        projectURL = url
        UserDefaults.standard.set(url, forKey: DefaultsKey.lastProject)
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
    /// means macOS is free to delete your shoot. Each Convert lands in its own dated folder inside
    /// this one (`Project.exportFolder(in:)`), and the engine's working files in a hidden `.loggrade` beside it.
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
    /// The folder the last Convert wrote to, so a cancel sweeps its staging files.
    private(set) var lastExportFolder: URL?

    func convert(queue: RenderQueue) {
        guard let clips = clipEntries, let destination = outputDirectory else { return }
        let export = Project.exportFolder(in: destination)
        lastExportFolder = export
        let project = self.project
        let adjustOff = bypassed.contains(.adjust)
        let missingLook = workDirectory
        // One look file per clip, because each carries its own Adjust. Scratch, in the scratch
        // directory; the RENDER goes where the person said, or beside their footage.
        //
        // THE QUEUE'S WAITING JOBS TOO, not only the list. A retried job from an earlier export
        // runs with this one, and its clip may have left the list since.
        let stems = Set(
            clips.map(\.stem) + queue.jobs.filter { $0.state == .waiting }.map(\.stem))
        let lookFiles = Dictionary(
            uniqueKeysWithValues: stems.map {
                ($0, workDirectory.appendingPathComponent("render-look-\($0).json"))
            })
        // BEFORE ANYTHING IS QUEUED, and refused outright on failure. A look file that could not
        // be written is the PREVIOUS run's look still on disk, so carrying on renders a whole
        // shoot with a grade nobody is looking at.
        do {
            try FileManager.default.createDirectory(
                at: workDirectory,
                withIntermediateDirectories: true)
            for (stem, file) in lookFiles {
                try project.settings(for: stem).adjust.applied(to: look)
                    .bypassing(bypassed).write(to: file)
            }
            try FileManager.default.createDirectory(
                at: destination,
                withIntermediateDirectories: true)
        } catch {
            toaster?.show(
                "exclamationmark.triangle.fill", "Export not started",
                String(describing: error))
            return
        }
        queue.clearFinished()
        queue.enqueue(clips.map { (url: $0.url, stem: $0.stem, frames: $0.fields?.frameCount) })
        // Off the main thread: `start` returns only when the whole queue has run.
        DispatchQueue.global(qos: .userInitiated).async {
            queue.start(environment: { stem in
                // A stem with no file here can only be one queued after this export started.
                // It gets a path that does not exist, which the engine refuses by name, rather
                // than another clip's grade or a crash.
                let file =
                    lookFiles[stem]
                    ?? missingLook.appendingPathComponent("no-look-for-\(stem).json")
                var env = project.environment(for: stem, lookFile: file)
                env["GRADE_WORK_DIR"] = destination.path
                env["EXPORT_DIR"] = export.path
                if adjustOff { env["MATCH"] = "0" }
                return env
            })
        }
    }

    /// Steps through the clips in the list, which is what a shoot is worked through as.
    func step(_ direction: Int, in clips: [ClipList.Entry]) {
        guard !clips.isEmpty else { return }
        let current = clips.firstIndex(where: { $0.stem == selectedClip?.stem }) ?? -1
        let next = max(0, min(clips.count - 1, current + direction))
        guard next != current else { return }
        selectedClip = clips[next]
    }

    func cancel(queue: RenderQueue) {
        queue.cancel()
        if let export = lastExportFolder { RenderQueue.sweepStagingFiles(in: export) }
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
            var settings = project.settings(for: stem)
            settings.cropOffset = newValue
            project.clips[stem] = settings
        }
    }

    /// Whether this clip gets stabilised. Per clip, not per project: a locked-off shot does not
    /// want a warp, and a handheld one does.
    var stabilise: Bool {
        get {
            selectedClip.map { project.settings(for: $0.stem).stabilise }
                ?? Project.ClipSettings.stabilisesByDefault
        }
        set {
            guard let stem = selectedClip?.stem else { return }
            var settings = project.settings(for: stem)
            settings.stabilise = newValue
            project.clips[stem] = settings
        }
    }

    /// Moves the crop by a number of pixels, clamped. The keyboard exists here because a drag
    /// finds a framing and only a number repeats one — the same reason every readout in the
    /// inspector can be typed into.
    func nudgeCrop(by pixels: Int) {
        guard cropIsPerClip, let geometry = cropGeometry else { return }
        cropOffset = geometry.clamp((cropOffset ?? geometry.maximumOffset / 2) + pixels)
    }

    /// The window's geometry for the selected clip, from what was measured about it rather than
    /// from this camera's numbers assumed — and in the shape of the deliverable that will actually
    /// be cropped, rather than in 4:5 whatever was ticked.
    ///
    /// THE FIRST CROPPING TARGET DECIDES when several crop, preferring one the clip frames over one
    /// fixed at `centre` (`Delivery.cropBoxTarget`). They share one per-clip offset, so one box is
    /// all there is to draw; drawing it in the first one's shape is at least a window the render
    /// produces. Two cropping deliverables wanting different framing is the case this does
    /// not cover, and it needs a second offset before it needs a second box.
    ///
    /// NIL UNTIL THE ENGINE HAS MEASURED THE CLIP. The container's dimensions are unrotated on this
    /// camera, so no box is better than one guessed from them: a portrait clip and a landscape one
    /// report the same 3840x2160.
    var cropGeometry: CropGeometry? {
        guard let size = selectedFrameSize,
            let target = project.delivery.cropBoxTarget(size)
        else { return nil }
        return CropGeometry(source: size, deliverable: target)
    }

    /// The selected clip's decoded frame, once a preview has measured it.
    var selectedFrameSize: FrameSize? {
        selectedClip.flatMap { frameSizes[$0.stem] }
    }

    /// Whether the box on the picture is this clip's to place. False when the only cropping shapes
    /// carry `centre`, whose box is drawn fixed.
    var cropIsPerClip: Bool {
        project.delivery.cropBoxTarget(selectedFrameSize)?.needsClipOffset(selectedFrameSize)
            ?? false
    }

    /// What would stop a render, named before one starts.
    var blockers: [Project.Blocker] {
        project.blockers
    }

    var unframed: Project.Unframed? {
        project.unframed(for: clipNames, sizes: frameSizes)
    }

    /// Pictures already graded after a release, a selection or a preset, so switching back to a
    /// clip shows it at once. Keyed by everything the grade depends on.
    private struct FinishedFrame {
        let key: FrameKey
        let image: NSImage
        let scopes: Scopes?
    }
    private var finishedFrames: [FinishedFrame] = []
    /// ~8 MB each at 1920x1080, a third of that for a portrait clip.
    private static let finishedFrameLimit = 24

    // MARK: - compare

    /// The look as it ships for this clip: the active preset with no Adjust, metered as by
    /// default. What holding C compares against.
    private var baselineLook: Look { defaultLook }
    /// The baseline being graded, so a second press does not grade it again.
    private var baselineInFlight: FrameKey?

    func beginCompare() {
        guard selectedClip != nil, preview.image != nil else { return }
        isComparing = true
        preview.baseline = nil
        prepareBaseline()
    }

    /// The baseline graded as the picture is, from the same source frame. Called again when a
    /// source frame or a meter reading lands, whichever it was waiting for.
    private func prepareBaseline() {
        guard isComparing, preview.baseline == nil, let clip = selectedClip?.url else { return }
        let look = baselineLook
        let metered: PreviewRenderer.Metered?
        switch metering(for: look, clip: clip, match: true) {
        case .reading(let reading): metered = reading
        case .off, .failed: metered = nil
        case .pending: return
        }
        let key = FrameKey(clip: clip, seconds: previewSeconds, look: look, metered: metered)
        if let cached = finishedFrames.last(where: { $0.key == key }) {
            preview.baseline = cached.image
            return
        }
        guard isLiveHere, let source = sourceImage, baselineInFlight != key else { return }
        baselineInFlight = key
        let sourceLongEdge = frameSizes[clip.deletingPathExtension().lastPathComponent]
            .map { max($0.width, $0.height) }
        liveQueue.async { [weak self] in
            guard let self else { return }
            let outcome = self.grade(
                look, source: source, metered: metered, sourceLongEdge: sourceLongEdge)
            let finished = outcome.frame.map { image in
                FinishedFrame(
                    key: key,
                    image: NSImage(
                        cgImage: LiveChain.forDisplay(image),
                        size: NSSize(width: image.width, height: image.height)),
                    scopes: Scopes.measure(image))
            }
            DispatchQueue.main.async {
                if self.baselineInFlight == key { self.baselineInFlight = nil }
                guard let finished else {
                    if case .refused(let reason) = outcome, self.isComparing {
                        self.preview.say(
                            "The look as it ships couldn’t be graded: \(reason)", failure: true)
                    }
                    return
                }
                if !self.finishedFrames.contains(where: { $0.key == key }) {
                    self.finishedFrames.append(finished)
                    if self.finishedFrames.count > Self.finishedFrameLimit {
                        self.finishedFrames.removeFirst()
                    }
                }
                if self.isComparing, self.selectedClip?.url == clip, self.preview.baseline == nil {
                    self.preview.baseline = finished.image
                }
            }
        }
    }

    func endCompare() {
        isComparing = false
    }

    /// The picture a release, a selection, a preset or a reset settles on: the grade of
    /// `effectiveLook`, the same as a drag's, kept so it comes back at once.
    func renderPreview() {
        guard let clip = selectedClip, clip.isUsable else { return }
        let look = effectiveLook
        let known: PreviewRenderer.Metered?? = {
            guard matches else { return .some(nil) }
            let key = MeterKey(clip: clip.url, referenceStops: look.matchReferenceStops)
            if let reading = measuredMetering[key] { return .some(reading) }
            return failedMetering.contains(key) ? .some(nil) : nil
        }()
        if let metered = known,
            let cached = finishedFrames.last(where: {
                $0.key
                    == FrameKey(
                        clip: clip.url, seconds: previewSeconds, look: look, metered: metered)
            })
        {
            // An older grade still in flight must not land on top of this.
            previewGeneration += 1
            pendingLook = nil
            settleLook = nil
            show(cached)
            refreshCurve()
            // For the drag that may follow.
            prepareSource()
            return
        }
        settleLook = look
        pendingLook = look
        prepareSource()
        startGradeIfIdle()
    }
}

/// Every preference the app remembers, named once. A key is spelled in two places — where it is
/// written and where it is read — and a typo in either is a setting that silently never comes back.
enum DefaultsKey {
    static let lastProject = "lastProject"
    static let openStages = "openStages"
    static let concurrency = "concurrency"
}
