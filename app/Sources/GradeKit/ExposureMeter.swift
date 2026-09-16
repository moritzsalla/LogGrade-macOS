import Foundation

/// The engine's exposure meter, and nothing else of the engine.
///
/// THE ENGINE'S OWN FUNCTION, not a port. `probe_scene_exposure` in scripts/lib.sh is sourced and
/// called, so the numbers are the ones every render uses, and the preview no longer has to start
/// grade.sh — preflight, generators, a decode for the picture — just to learn three numbers.
/// Measured on the Intel Mac: ~0.5 s ProRes, ~1.3 s HEVC, run beside the native decode.
public struct ExposureMeter {
    public enum Failure: Error {
        case noReading(status: Int32)
    }

    public let engine: EngineLocation
    public init(engine: EngineLocation) { self.engine = engine }

    /// Metered at 1 s, the timecode the export meters at, against the look's reference. "0 0 0",
    /// the engine's answer for a frame it cannot read, is a real neutral reading. A process that
    /// fails or prints something unreadable THROWS: a failure passed on as zero would be used as
    /// the reading and the preview would silently disagree with the export.
    public func measure(_ clip: URL, referenceStops: Double) throws -> PreviewRenderer.Metered {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [
            "-c", #"source "$0/scripts/lib.sh" && probe_scene_exposure "$1" "$2""#,
            engine.root.path, clip.path, String(referenceStops),
        ]
        process.currentDirectoryURL = engine.root
        process.environment = EngineRun(engine: engine).childEnvironment()
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let numbers = String(decoding: data, as: UTF8.self)
            .split(whereSeparator: { $0 == " " || $0 == "\n" }).compactMap { Double($0) }
        guard process.terminationStatus == 0, numbers.count == 3 else {
            throw Failure.noReading(status: process.terminationStatus)
        }
        return PreviewRenderer.Metered(exposure: numbers[0], temp: numbers[1], tint: numbers[2])
    }
}
