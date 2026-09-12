import Foundation

/// One graded still, rendered by the engine through the real chain.
///
/// GRADE ONLY, and the interface says so. A still cannot show grain, the sharpener, the chroma
/// denoise, the stabiliser or the dither, all of which are delivery-stage. What it does show is
/// everything a control moves, at full resolution, which is exactly what a preview is for. The
/// alternative — decoding a frame here and grading it in the app — is a second implementation of
/// the image, which this repo permits only where a test can hold it to this one. `LiveGrade` is
/// that second implementation and it exists for dragging against, not for judging: this stays the
/// picture every decision is made on.
public final class PreviewRenderer {
    private let engine: EngineLocation
    private let workDirectory: URL

    public init(engine: EngineLocation, workDirectory: URL) {
        self.engine = engine
        self.workDirectory = workDirectory
    }

    public struct Frame: Equatable {
        public let url: URL
        public let clip: String
        public let seconds: Double
        /// The clip's post-CST luma mean, as the engine measured it, and the gamma it solved from
        /// that. The app needs both: the curve it draws and the curve it previews live have to be
        /// the SOLVED one, or they describe a render that never happens.
        public let yavg: Double?
        public let gamma: Double?
    }

    /// Renders a still for one clip at one timecode with one look. Synchronous: the caller decides
    /// which queue it wants to wait on, and the interface debounces rather than pipelining.
    /// The clip's post-CST mean, measured once by the engine and remembered here. It does not
    /// change when a look does, and re-measuring it costs about a second of every preview.
    private var measuredExposure: [String: Double] = [:]

    /// What the engine last measured for a clip, so the interface can solve the same gamma the
    /// next render will without paying for a render to find out.
    public func measuredYAVG(for clip: URL) -> Double? {
        measuredExposure[clip.deletingPathExtension().lastPathComponent]
    }

    /// `match` is the engine's exposure matching. It defaults on, because every render this app
    /// performs has it on. It is turned OFF for exactly one caller: the base frame the live tier
    /// grades from, which wants the tone stage to do nothing. With matching on, a gamma of 1 is
    /// not passed through — it is solved, and `solve-gamma.py` clamps the result to at least 1.2,
    /// so the "neutral" base would come back with a curve already baked into it.
    /// Which frame the engine should produce.
    public enum Stage: String {
        /// Everything a control moves, through the real chain. What gets judged.
        case graded
        /// The decoded Apple Log picture with no chain at all, which is what `LiveChain` grades in
        /// this process while a control is moving.
        case source
    }

    public func render(clip: URL, seconds: Double, look: Look, height: Int = 1440,
                       match: Bool = true, stage: Stage = .graded,
                       onStart: ((Process) -> Void)? = nil) throws -> Frame {
        let lookFile = workDirectory.appendingPathComponent("preview-look.json")
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        try look.write(to: lookFile)

        let stem = clip.deletingPathExtension().lastPathComponent
        var environment = ["FRAME": String(seconds),
                           "FRAME_HEIGHT": String(height),
                           "LOOK_FILE": lookFile.path,
                           "GRADE_WORK_DIR": workDirectory.path,
                           "FRAME_STAGE": stage.rawValue,
                           "MATCH": match ? "1" : "0"]
        if let known = measuredExposure[stem] {
            environment["YAVG_IN"] = String(known)
        }
        let outcome = try EngineRun(engine: engine).run(
            arguments: [clip.path],
            environment: environment,
            onStart: onStart)
        let planned = outcome.events.first(where: { $0.name == "clip_planned" })
        // Remember what the engine measured, so the next preview of this clip skips the probe.
        if let yavg = planned?.double("yavg") {
            measuredExposure[stem] = yavg
        }
        guard outcome.succeeded else {
            throw Failure.engineRefused(outcome.codes, outcome.stderrText)
        }
        // The engine names the file it wrote, so the app does not reconstruct the path and does
        // not have to agree with the engine about how stills are named.
        guard let event = outcome.events.first(where: { $0.name == "frame" }),
              let path = event.path else {
            throw Failure.noFrameEvent(outcome.events.map(\.name))
        }
        return Frame(url: URL(fileURLWithPath: path),
                     clip: event.clip ?? clip.deletingPathExtension().lastPathComponent,
                     seconds: seconds,
                     yavg: planned?.double("yavg"),
                     gamma: planned?.double("gamma"))
    }

    public enum Failure: Error, CustomStringConvertible {
        case engineRefused([EngineCode], String)
        case noFrameEvent([String])

        public var description: String {
            switch self {
            case .engineRefused(let codes, let text):
                if let first = codes.first { return first.message }
                return text.isEmpty ? "the engine refused without saying why" : text
            case .noFrameEvent(let names):
                return "the engine rendered but announced no frame: \(names.joined(separator: ", "))"
            }
        }
    }
}
