import Foundation

/// One graded still, rendered by the engine through the real chain.
///
/// GRADE ONLY, and the interface says so. A still cannot show grain, the sharpener, the chroma
/// denoise, the stabiliser or the dither, all of which are delivery-stage. What it does show is
/// everything a control moves, at full resolution, which is exactly what a preview is for. The
/// alternative — decoding a frame here and grading it in the app — would be a second
/// implementation of the image, and it would mispredict the render, which is the failure the
/// browser bench demonstrates at about 36 code values.
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
    }

    /// Renders a still for one clip at one timecode with one look. Synchronous: the caller decides
    /// which queue it wants to wait on, and the interface debounces rather than pipelining.
    public func render(clip: URL, seconds: Double, look: Look, height: Int = 1440) throws -> Frame {
        let lookFile = workDirectory.appendingPathComponent("preview-look.json")
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        try look.write(to: lookFile)

        let outcome = try EngineRun(engine: engine).run(
            arguments: [clip.path],
            environment: ["FRAME": String(seconds),
                          "FRAME_HEIGHT": String(height),
                          "LOOK_FILE": lookFile.path,
                          "GRADE_WORK_DIR": workDirectory.path,
                          "MATCH": "1"])
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
                     seconds: seconds)
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
