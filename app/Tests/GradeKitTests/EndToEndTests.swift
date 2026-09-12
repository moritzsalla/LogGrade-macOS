import XCTest
@testable import GradeKit

/// The test that holds the whole architecture up.
///
/// The app drives the engine and never rebuilds its filter graph, which is ADR 0008's decision.
/// The way that is enforced is not a convention or a review: it is this. One clip, rendered through
/// the engine from the shell and through the engine from the app, asserted byte-identical.
///
/// They MUST match, because it is the same binary with the same arguments — so a difference means
/// the app changed something about the render, which is the one failure this arrangement exists to
/// prevent. Byte-identity rather than a tolerance, because a tolerance would admit exactly that.
///
/// It is not free: the app sets JSON=1, and under JSON=1 the engine adds `-progress pipe:1
/// -nostats` to its ffmpeg command so a queue can show a bar. Those are reporting flags and should
/// not touch the bitstream — "should" being the word this test exists to replace.
final class EndToEndTests: XCTestCase {
    func testTheAppRendersTheSameBytesAsTheShell() throws {
        let here = URL(fileURLWithPath: #filePath)
        guard let engine = EngineLocation.discover(from: here.deletingLastPathComponent()) else {
            throw XCTSkip("no engine checkout")
        }
        try XCTSkipIf(!engine.preflight().isEmpty, "engine preflight not clean")
        let clips = (try? FileManager.default.contentsOfDirectory(
            at: engine.root.appendingPathComponent("src"), includingPropertiesForKeys: nil)) ?? []
        guard let clip = clips.first(where: { $0.pathExtension.lowercased() == "mov" }) else {
            throw XCTSkip("no footage in src/")
        }

        let shellWork = try temporaryDirectory()
        let appWork = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: shellWork)
            try? FileManager.default.removeItem(at: appWork)
        }

        // The same short render both ways. STAB=0 because a stabilised render would compute a
        // transform per work dir, and this is a test about the app, not about vid.stab.
        let settings = ["PROOF": "0.1", "STAB": "0", "MATCH": "1",
                        "LOOK_FILE": engine.lookFile.path]

        // The shell's own path: no JSON, no progress, nothing from the app.
        var shellEnvironment = ProcessInfo.processInfo.environment
        for (key, value) in settings { shellEnvironment[key] = value }
        shellEnvironment["GRADE_WORK_DIR"] = shellWork.path
        let shell = Process()
        shell.executableURL = engine.gradeScript
        shell.arguments = [clip.path]
        shell.environment = shellEnvironment
        shell.standardOutput = Pipe()
        shell.standardError = Pipe()
        try shell.run()
        shell.waitUntilExit()
        XCTAssertEqual(shell.terminationStatus, 0, "the shell render failed")

        // The app's path, through the adapter, which sets JSON=1 and its own PATH.
        var appSettings = settings
        appSettings["GRADE_WORK_DIR"] = appWork.path
        let outcome = try EngineRun(engine: engine).run(arguments: [clip.path],
                                                        environment: appSettings)
        XCTAssertTrue(outcome.succeeded, "the app render failed: \(outcome.stderrText)")

        let shellFile = try onlyProof(in: shellWork)
        let appFile = try onlyProof(in: appWork)
        let a = try Data(contentsOf: shellFile)
        let b = try Data(contentsOf: appFile)
        XCTAssertEqual(a.count, b.count, "different sizes: \(shellFile.path) vs \(appFile.path)")
        XCTAssertEqual(a, b, "the app's render is not the shell's render")

        // And the app learned what it rendered from the events rather than by guessing a path.
        let output = outcome.events.first { $0.name == "output" }
        XCTAssertEqual(output?.path.map { URL(fileURLWithPath: $0).lastPathComponent },
                       appFile.lastPathComponent)
    }

    private func temporaryDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func onlyProof(in work: URL) throws -> URL {
        let proofs = work.appendingPathComponent("dist/proofs")
        let files = try FileManager.default.contentsOfDirectory(at: proofs,
                                                                includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "mp4" }
        guard let first = files.first, files.count == 1 else {
            throw XCTSkip("expected one proof in \(proofs.path), found \(files.count)")
        }
        return first
    }
}
