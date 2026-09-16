import XCTest

@testable import GradeKit

/// The checkout these tests live in, found by walking up from this source file. No resource
/// copying: the engine has one home and the tests read it where it is. Skips rather than fails
/// without one, because a test target copied out of the repo has nothing to measure against.
func engineCheckout() throws -> EngineLocation {
    let here = URL(fileURLWithPath: #filePath)
    guard let engine = EngineLocation.discover(from: here.deletingLastPathComponent()) else {
        throw XCTSkip("no engine checkout above \(here.path)")
    }
    return engine
}

/// A stand-in engine whose `grade.sh` is the given script, for tests about the adapter or the
/// queue rather than about the image: a real render would make them slow, footage-dependent and
/// about something else. Every file `preflight` checks exists, so a stub is never refused for a
/// reason the test is not about.
func stubEngine(script: String) throws -> EngineLocation {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString)
    let scripts = root.appendingPathComponent("scripts")
    try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
        at: root.appendingPathComponent("luts/looks"),
        withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
        at: root.appendingPathComponent("luts/rendering"),
        withIntermediateDirectories: true)
    try "{}".write(
        to: root.appendingPathComponent("look.json"), atomically: true,
        encoding: .utf8)
    try "".write(
        to: root.appendingPathComponent("luts/rendering/neutral.cube"),
        atomically: true, encoding: .utf8)
    for name in [
        "grade.sh", "make-tone-lut.py", "make-correct-lut.py", "make-halation-luts.py",
    ] {
        let url = scripts.appendingPathComponent(name)
        try (name == "grade.sh" ? script : "#!/bin/bash\n")
            .write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: url.path)
    }
    return EngineLocation(root: root)
}

/// What a command printed, and how it ended.
struct Ran {
    let status: Int32
    let stdout: String
    let stderr: String
}

/// Runs an executable to completion. Both pipes are drained before waiting, because a child that
/// fills a pipe nobody reads blocks forever and the test hangs instead of failing.
func runToCompletion(_ executable: URL, _ arguments: [String]) throws -> Ran {
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    let out = Pipe()
    let err = Pipe()
    process.standardOutput = out
    process.standardError = err
    try process.run()
    let stdout = out.fileHandleForReading.readDataToEndOfFile()
    let stderr = err.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return Ran(
        status: process.terminationStatus,
        stdout: String(decoding: stdout, as: UTF8.self),
        stderr: String(decoding: stderr, as: UTF8.self))
}

/// One call into `scripts/lib.sh`, on the interpreter production runs it under.
///
/// This is how a Swift copy of an engine fact is held to the engine: ask the function, rather than
/// restating its arithmetic in the test. A test that recomputes the expected value in Swift only
/// proves two Swift expressions agree. The arguments go through argv, never spliced into the
/// script, so a value can never be read as shell.
func libSh(_ engine: EngineLocation, _ function: String, _ arguments: [String]) throws -> Ran {
    try runToCompletion(
        URL(fileURLWithPath: "/bin/bash"),
        ["-c", #"source "$0/scripts/lib.sh"; "$@""#, engine.root.path, function]
            + arguments)
}

/// A complete look.json, so a test that needs a `Look` does not depend on the checkout's file —
/// which is re-tuned — and does not repeat the whole key set, which is a contract that grows.
/// Every key is present because `Look` refuses a missing one, as the engine does.
func lookFixture(gamma: Double = 2.02, lut: String = "kodak_portra_400_nc") throws -> Look {
    let json = """
        {"correct":{"exposure":0,"temp":0,"tint":0,"slope":"1,1,1","offset":"0,0,0",
         "power":"1,1,1","lum_mix":1},
         "halation":{"strength":0,"threshold":1,"radius":0.006,"tint":"1,0.3,0.05"},
         "look":{"lut":"\(lut)","strength":1},"print":{"lut":"none","strength":1},
         "tone":{"gamma":\(gamma),"pivot":0.39,"contrast":1.09,"toe":0,"shoulder":0.1,"black":0.025},
         "colour":{"saturation":1.27,"warmth":0.005},"grain":{"strength":8,"shadows":1,"highlights":1},
         "hue":{"rot":"0,0,0,0,0,0,0,0,0,0,0,0","sat":"0,0,0,0,0,0,0,0,0,0,0,0","lum":"0,0,0,0,0,0,0,0,0,0,0,0"},
         "stabilisation":{"smoothing":30},"match":{"reference_stops":-0.4},
         "convert":{"cube":"neutral"},"finish":{"denoise":0,"sharpen":0.6,"gauge":"none"}}
        """
    return try Look(data: Data(json.utf8))
}
