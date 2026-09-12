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
    /// The look the visible frame was rendered from. Comparing it with the live one is how the
    /// panel knows the reading is out of date — which matters because this renders on release,
    /// not continuously, so the gap is real.
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

    /// The clip through the conversion and the look, with the tone stage neutral: the input the
    /// live model expects. Rendered once per clip by the engine, then graded in the app on every
    /// control change so a drag is followed rather than waited for.
    private var baseImage: CGImage?
    /// What the base was rendered from, all three parts. The look's correction stage runs BEFORE
    /// the conversion so changing it invalidates the base and needs the engine again — a live tier
    /// cannot fake that. The clip and the timecode invalidate it for a blunter reason: a base kept
    /// across a clip change would grade the picture you are no longer looking at, live, and say it
    /// was live.
    private var baseSignature: String?
    private var baseClip: URL?
    private var baseSeconds: Double?
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
    /// True while the base is being rendered. Without it, a tone drag in that window reports the
    /// correction message, which is not what is happening.
    @Published private var isPreparingLive = false
    /// The gamma the engine will apply to this clip, once it has measured the clip. The midtone
    /// slider holds the REFERENCE gamma, and the two are different numbers on every clip that was
    /// not shot at the exposure the look was tuned at — so the interface shows both rather than
    /// letting the readout claim a value nothing applies.
    @Published var appliedGamma: Double?
    /// Whether `status` is a failure. It used to be inferred from the message's first word, which
    /// meant rewording a message silently changed its colour.
    @Published var statusIsFailure = false

    /// The tone curve is the engine's own table, so it is regenerated rather than evaluated here.
    /// Throttled: generating costs about a tenth of a second and a drag does not need a new one
    /// every frame, only a recent one.
    private var lastCurveAt = Date.distantPast

    private func signature(of look: Look) -> String {
        "\(look.lookLUT)|\(look.correct.exposure)|\(look.correct.temp)|\(look.correct.tint)|"
            + "\(look.correct.slope)|\(look.correct.offset)|\(look.correct.power)|"
            + "\(look.correct.lumMix)"
    }

    /// A control went under the pointer.
    ///
    /// The render in flight is for a look nobody wants any more — the person is already moving
    /// away from it — so it is stopped here rather than left to finish and be discarded. Without
    /// this, letting go and immediately grabbing again gives three dead seconds, which is the
    /// stutter the whole tier exists to remove.
    func beginDrag() {
        isDragging = true
        // Unless it is the render that builds the base. Cancelling that one leaves nothing to be
        // live from, so grabbing a control every couple of seconds would keep the live tier from
        // ever starting — the render would be killed each time by the gesture that needs it.
        let haveBase = baseImage != nil && baseClip == selectedClip?.url
            && baseSeconds == previewSeconds && baseSignature == signature(of: look)
        if isRendering && haveBase {
            previewGeneration += 1
            if let running = previewProcess, running.isRunning { EngineRun.stop(running) }
            isRendering = false
        }
    }

    func endDrag() { isDragging = false }

    /// Follows the controls. Applies the verified model to the base frame and shows the result;
    /// falls back to marking the preview stale when the change is one the model cannot apply.
    func liveUpdate() {
        guard isDragging, let clip = selectedClip else { return }
        // Nothing to be live from yet, and nothing to say about it: the first preview has not
        // happened, so the controls have nothing to move against.
        guard baseImage != nil, baseClip == clip.url, baseSeconds == previewSeconds else { return }
        if isPreparingLive {
            status = "Setting up the live preview…"
            statusIsFailure = false
            return
        }
        if signature(of: look) != baseSignature {
            // The correction stage runs BEFORE Apple's conversion, so nothing downstream of the
            // conversion can show it. The render on release is what shows it, and it is already
            // scheduled, so this says what is true rather than asking for a button press.
            isLive = false
            status = "Exposure and white balance run before the conversion. They appear when you let go."
            statusIsFailure = false
            return
        }
        if Date().timeIntervalSince(lastCurveAt) > 0.12 {
            lastCurveAt = Date()
            refreshCurve()
        }
        applyLive()
    }

    /// Grades the base with whatever curve has arrived. Called again when a newer curve lands, so
    /// the last frame of a drag is not left showing a curve one generation behind.
    private func applyLive() {
        guard let base = baseImage, let curve = curve else { return }
        let live = LiveGrade(curve: curve, saturation: look.colour.saturation,
                             warmth: look.colour.warmth)
        guard let graded = live.apply(to: base) else { return }
        previewImage = NSImage(cgImage: graded, size: NSSize(width: graded.width,
                                                             height: graded.height))
        scopes = Scopes.measure(graded)
        isLive = true
        status = "Live preview. Letting go renders the exact frame."
        statusIsFailure = false
    }

    /// Renders the base the live tier grades from: the same chain with the tone stage neutral.
    /// Small, because it is dragged against rather than judged, and a drag needs frames.
    private func refreshBase(for clip: ClipList.Entry, seconds: Double, signature: String) {
        let neutral = LiveGrade.base(for: look)
        // MATCH OFF, which is the whole reason this parameter exists. With it on, gamma 1 is not
        // passed through: the engine solves a per-clip gamma from it and clamps the answer to at
        // least 1.2, so the base would arrive with a curve already in it and every live frame
        // would be that curve twice.
        if let frame = try? renderer.render(clip: clip.url, seconds: seconds, look: neutral,
                                            height: 480, match: false),
           let image = NSImage(contentsOf: frame.url)?
            .cgImage(forProposedRect: nil, context: nil, hints: nil) {
            DispatchQueue.main.async {
                self.baseImage = image
                self.baseSignature = signature
                self.baseClip = clip.url
                self.baseSeconds = seconds
                self.isPreparingLive = false
            }
        } else {
            // A base that will not render is not worth a message of its own: the exact preview
            // still works, and the controls fall back to rendering on release.
            DispatchQueue.main.async { self.isPreparingLive = false }
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
        refreshCurve()
    }

    /// The curve is regenerated by the engine's own generator, so the graph beside the sliders is
    /// the table the render applies. It costs about a tenth of a second, which is why it can be
    /// done on every change rather than only on release.
    func refreshCurve() {
        var tone = look.tone
        let generator = engine.toneGenerator
        let solver = engine.gammaSolver
        // The reference gamma is what the slider holds; the engine renders the SOLVED one. Drawing
        // the slider value was a graph of a curve nothing applies, and previewing it would be a
        // picture nothing renders.
        let clip = selectedClip?.url
        let reference = look.matchReferenceYAVG
        // Read on `queue`, not here. `measuredExposure` is written on that same serial queue by
        // every render, and a Swift dictionary read from another thread while one writes is not
        // merely stale — it is undefined.
        queue.async { [weak self] in
            guard let self else { return }
            if let measured = clip.flatMap({ self.renderer.measuredYAVG(for: $0) }) {
                tone.gamma = ToneCurve.solvedGamma(using: solver, clipYAVG: measured,
                                                   referenceYAVG: reference,
                                                   referenceGamma: tone.gamma)
            }
            let applied = tone.gamma
            let curve = try? ToneCurve.generate(using: generator, tone: tone)
            DispatchQueue.main.async {
                self.curve = curve
                self.appliedGamma = applied
                if self.isLive { self.applyLive() }
            }
        }
    }

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

        // Decided here, on the main thread, because `baseSignature` is only ever touched here.
        let baseSig = signature(of: look)
        let needsBase = baseSignature != baseSig || baseClip != clip.url || baseSeconds != seconds

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
                    // the reference curve. Regenerate now that the answer exists.
                    self.refreshCurve()
                }
                // AFTER the exact frame is on screen, not before it. The base is only needed for
                // the next drag, so rendering it first would add its second to the wait for a
                // picture somebody is already looking at.
                if needsBase {
                    DispatchQueue.main.async { self.isPreparingLive = true }
                    self.refreshBase(for: clip, seconds: seconds, signature: baseSig)
                }
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
