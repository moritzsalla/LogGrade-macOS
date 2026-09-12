import XCTest
@testable import GradeKit

/// Driven by a stand-in engine rather than the real one: these tests are about the adapter, and a
/// real render would make them slow, footage-dependent and about something else.
final class EngineRunTests: XCTestCase {
    private func stubEngine(script: String) throws -> EngineLocation {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        let scripts = root.appendingPathComponent("scripts")
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("luts/looks"),
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("luts/apple"),
                                                withIntermediateDirectories: true)
        try "{}".write(to: root.appendingPathComponent("look.json"), atomically: true,
                       encoding: .utf8)
        try "".write(to: root.appendingPathComponent("luts/apple/AppleLogToRec709-v1.0.cube"),
                     atomically: true, encoding: .utf8)
        for name in ["grade.sh", "make-tone-lut.py", "make-correct-lut.py", "solve-gamma.py"] {
            let url = scripts.appendingPathComponent(name)
            try (name == "grade.sh" ? script : "#!/bin/bash\n").write(to: url, atomically: true,
                                                                      encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                  ofItemAtPath: url.path)
        }
        return EngineLocation(root: root)
    }

    func testReadsEventsAndCodesFromBothStreams() throws {
        let engine = try stubEngine(script: """
        #!/bin/bash
        echo '{"event":"run_start","clips":1}'
        echo 'GRADE_CODE=REFUSE_NOT_PORTRAIT' >&2
        echo '{"event":"clip_skipped","clip":"WIDE","code":"REFUSE_NOT_PORTRAIT"}'
        echo '{"event":"run_done","rendered":0,"skipped":1,"failed":0}'
        exit 0
        """)
        defer { try? FileManager.default.removeItem(at: engine.root) }

        var streamed: [String] = []
        let outcome = try EngineRun(engine: engine).run(arguments: ["src/"],
                                                        onEvent: { streamed.append($0.name) })
        XCTAssertTrue(outcome.succeeded)
        XCTAssertEqual(outcome.events.map(\.name), ["run_start", "clip_skipped", "run_done"])
        XCTAssertEqual(streamed, ["run_start", "clip_skipped", "run_done"],
                       "events must arrive as they happen, not only at the end")
        XCTAssertEqual(outcome.codes, [.notPortrait])
        XCTAssertTrue(outcome.malformed.isEmpty)
    }

    func testProseOnStdoutIsReportedRatherThanIgnored() throws {
        // Under JSON=1 stdout carries events and nothing else. A verdict written to the wrong
        // stream was a real defect in this engine, and an adapter that quietly drops the line is
        // how it would have stayed hidden.
        let engine = try stubEngine(script: """
        #!/bin/bash
        echo 'disk OK: 21GB available in /tmp'
        echo '{"event":"run_done","rendered":0,"skipped":0,"failed":0}'
        """)
        defer { try? FileManager.default.removeItem(at: engine.root) }
        let outcome = try EngineRun(engine: engine).run(arguments: [])
        XCTAssertEqual(outcome.malformed, ["disk OK: 21GB available in /tmp"])
        XCTAssertEqual(outcome.events.map(\.name), ["run_done"])
    }

    func testAFailureKeepsItsExitCodeAndItsReason() throws {
        let engine = try stubEngine(script: """
        #!/bin/bash
        echo 'REFUSING: FEED=1 across 2 clips with no CROP_Y.' >&2
        echo 'GRADE_CODE=REFUSE_FEED_NO_CROP_Y' >&2
        exit 1
        """)
        defer { try? FileManager.default.removeItem(at: engine.root) }
        let outcome = try EngineRun(engine: engine).run(arguments: ["a", "b"])
        XCTAssertFalse(outcome.succeeded)
        XCTAssertEqual(outcome.exitCode, 1)
        XCTAssertEqual(outcome.codes, [.feedWithoutCropOffset])
        XCTAssertTrue(outcome.stderrText.contains("REFUSING"),
                      "the human sentence has to survive too: it is what a person reads")
    }

    func testItRefusesToStartWhenThePreflightFails() throws {
        let empty = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }
        XCTAssertThrowsError(try EngineRun(engine: EngineLocation(root: empty)).run(arguments: []))
    }

    func testTheChildGetsAPathThatFindsTheTools() throws {
        let engine = try stubEngine(script: "#!/bin/bash\nexit 0\n")
        defer { try? FileManager.default.removeItem(at: engine.root) }
        let env = EngineRun(engine: engine).childEnvironment()
        let path = try XCTUnwrap(env["PATH"])
        // The reason this class exists: a launched app's PATH does not include where this
        // machine's ffmpeg lives, and every tool in the scripts is a bare name.
        XCTAssertTrue(path.contains(engine.root.path),
                      "the engine's own directory carries the vendored tools")
        XCTAssertTrue(EngineLocation.toolSearchPaths.allSatisfy { path.contains($0) })
        XCTAssertEqual(env["LOOK_FILE"], engine.lookFile.path)
    }

    func testALongStreamDoesNotDeadlock() throws {
        // Draining one pipe to completion before the other deadlocks as soon as the engine fills
        // the pipe nobody is reading, which a real render does within seconds. This writes more
        // than a pipe buffer holds to both streams at once.
        let engine = try stubEngine(script: """
        #!/bin/bash
        for i in $(seq 1 2000); do
          echo "{\\"event\\":\\"progress\\",\\"frame\\":$i}"
          echo "noise $i noise $i noise $i noise $i noise $i noise $i" >&2
        done
        echo '{"event":"run_done","rendered":1,"skipped":0,"failed":0}'
        """)
        defer { try? FileManager.default.removeItem(at: engine.root) }
        let outcome = try EngineRun(engine: engine).run(arguments: [])
        XCTAssertEqual(outcome.events.count, 2001)
        XCTAssertTrue(outcome.succeeded)
    }
}
