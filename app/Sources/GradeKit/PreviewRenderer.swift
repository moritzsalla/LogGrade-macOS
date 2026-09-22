import Foundation

/// One graded still, rendered by the engine through the real chain.
///
/// GRADE ONLY, and the interface says so. A still cannot show grain, the sharpener, the chroma
/// denoise, the stabiliser or the dither, all of which are delivery-stage. What it does show is
/// everything a control moves, at full resolution, which is exactly what a preview is for. The
/// alternative — decoding a frame here and grading it in the app — is a second implementation of
/// the image, which this repo permits only where a test can hold it to this one. `LiveChain` is
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
        /// The exposure and white balance the engine metered for this clip and added to the
        /// look's correction. Zero when metering was off.
        public let metered: Metered
        /// The decoded frame, which is how the app learns a clip's orientation.
        public let sourceSize: FrameSize?
    }

    public struct Metered: Equatable {
        public var exposure: Double
        public var temp: Double
        public var tint: Double

        public init(exposure: Double = 0, temp: Double = 0, tint: Double = 0) {
            self.exposure = exposure
            self.temp = temp
            self.tint = tint
        }

        /// A correction with this added, as `correction_args` adds it in the engine.
        public func applied(to correct: Look.Correct) -> Look.Correct {
            var out = correct
            out.exposure += exposure
            out.temp += temp
            out.tint += tint
            return out
        }
    }

    /// Which frame the engine should produce.
    public enum Stage: String {
        /// Everything a control moves, through the real chain. What gets judged.
        case graded
        /// The decoded Apple Log picture with no chain at all, which is what `LiveChain` grades in
        /// this process while a control is moving.
        case source
    }

    /// Renders a still for one clip at one timecode with one look. Synchronous: the caller decides
    /// which queue it wants to wait on, and the interface cancels a superseded render rather than
    /// pipelining.
    ///
    /// `match` is the engine's exposure metering. It defaults on, because every render this app
    /// performs has it on; it is off for the base frame the live tier grades, which must be the
    /// clip as shot.
    public func render(
        clip: URL, seconds: Double, look: Look, height: Int = 1440,
        match: Bool = true, stage: Stage = .graded,
        knownSize: FrameSize? = nil, knownMetering: Metered? = nil,
        onStart: ((Process) -> Void)? = nil
    ) throws -> Frame {
        let lookFile = workDirectory.appendingPathComponent("preview-look.json")
        try FileManager.default.createDirectory(
            at: workDirectory, withIntermediateDirectories: true)
        try look.write(to: lookFile)

        var environment = [
            "FRAME": String(seconds),
            "FRAME_HEIGHT": String(height),
            "LOOK_FILE": lookFile.path,
            "GRADE_WORK_DIR": workDirectory.path,
            "FRAME_STAGE": stage.rawValue,
            "MATCH": match ? "1" : "0",
        ]
        // WHAT AN EARLIER PREVIEW OF THIS CLIP ALREADY MEASURED, so the engine does not decode the
        // same frame twice more to learn it again (~2 s on 4K HEVC). Both come from that render's
        // own clip_planned, at the same timecode.
        if let knownSize {
            environment["FRAME_SOURCE_SIZE"] = "\(knownSize.width) \(knownSize.height)"
        }
        if match, let m = knownMetering {
            environment["FRAME_METERED"] = "\(m.exposure) \(m.temp) \(m.tint)"
        }
        let outcome = try EngineRun(engine: engine).run(
            arguments: [clip.path],
            environment: environment,
            onStart: onStart)
        let planned = outcome.events.first(where: { $0.name == "clip_planned" })
        guard outcome.succeeded else {
            throw Failure.engineRefused(outcome.codes, outcome.stderrText)
        }
        // The engine names the file it wrote, so the app does not reconstruct the path and does
        // not have to agree with the engine about how stills are named.
        guard let event = outcome.events.first(where: { $0.name == "frame" }),
            let path = event.path
        else {
            throw Failure.noFrameEvent(outcome.events.map(\.name))
        }
        return Frame(
            url: URL(fileURLWithPath: path),
            clip: event.clip ?? clip.deletingPathExtension().lastPathComponent,
            seconds: seconds,
            metered: Metered(
                exposure: planned?.double("metered_exposure") ?? 0,
                temp: planned?.double("metered_temp") ?? 0,
                tint: planned?.double("metered_tint") ?? 0),
            sourceSize: planned.flatMap { p in
                p.int("width").flatMap { w in
                    p.int("height").map { FrameSize(width: w, height: $0) }
                }
            })
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
                return
                    "the engine rendered but announced no frame: \(names.joined(separator: ", "))"
            }
        }
    }
}
