import XCTest

@testable import GradeKit

final class EngineLocationTests: XCTestCase {
    func testFindsTheEngineItLivesIn() throws {
        let engine = try engineCheckout()
        XCTAssertTrue(
            FileManager.default.isExecutableFile(atPath: engine.gradeScript.path),
            "grade.sh should be executable at \(engine.gradeScript.path)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: engine.lookFile.path))
    }

    func testPreflightPassesOnThisCheckout() throws {
        let engine = try engineCheckout()
        // Nothing a checkout needs is absent any more: every cube a render reaches is committed.
        XCTAssertTrue(engine.preflight().isEmpty, "preflight problems: \(engine.preflight())")
    }

    /// The app offers presets/ as it finds them, so a file that fails to read as a complete look
    /// would vanish from the menu in silence.
    func testEveryShippedPresetLoadsAndItsConversionResolves() throws {
        let engine = try engineCheckout()
        let files = try FileManager.default.contentsOfDirectory(
            at: engine.presetFolder, includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "json" }
        let presets = engine.shippedPresets()
        XCTAssertEqual(presets.count, files.count, "a preset file did not load")
        XCTAssertGreaterThanOrEqual(presets.count, 4)
        for preset in presets {
            XCTAssertNotNil(
                engine.conversionCube(named: preset.look.convertCube),
                "\(preset.name) names a cube that is not there")
        }
        XCTAssertNil(engine.conversionCube(named: "../film/imax65"))
        // Every file named in the picker's order exists, or the order silently stops applying.
        let stems = files.map { $0.deletingPathExtension().lastPathComponent }
        for stem in EngineLocation.presetOrder {
            XCTAssertTrue(
                stems.contains(stem), "presetOrder names \(stem), which is not in presets/")
        }
    }

    func testPreflightNamesEveryMissingPiece() throws {
        let empty = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }

        let problems = EngineLocation(root: empty).preflight()
        XCTAssertTrue(
            problems.contains(.missingFile(EngineLocation(root: empty).gradeScript)),
            "should name the missing script, got: \(problems)")
        XCTAssertTrue(
            problems.contains(.missingFile(EngineLocation(root: empty).lookFile)),
            "should name the missing look, got: \(problems)")
    }

    func testResolvesToolsWithoutTrustingPATH() throws {
        // The point of the type: a GUI process has no useful PATH, so an explicit search has to
        // find ffmpeg where this machine actually keeps it.
        let found = EngineLocation.resolveTool("ffmpeg")
        try XCTSkipIf(found == nil, "ffmpeg not installed anywhere this searches")
        XCTAssertTrue(found!.path.hasPrefix("/"), "should be absolute, got \(found!.path)")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: found!.path))
    }

    /// An executable script at `root/name`.
    private func fakeTool(_ name: String, in root: URL, body: String) throws {
        let url = root.appendingPathComponent(name)
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    func testTheEngineFindsTheToolsItCarries() throws {
        // A bundle vendors ffmpeg beside the scripts. This machine also has one in ~/.local/bin,
        // which is what hid the defect: resolved without the engine's own directory, a fresh Mac
        // was told ffmpeg was missing while the app carried it.
        let engine = try stubEngine(script: "#!/bin/bash\n")
        defer { try? FileManager.default.removeItem(at: engine.root) }
        try fakeTool("ffmpeg", in: engine.root, body: "exit 0")
        XCTAssertEqual(
            engine.resolveTool("ffmpeg")?.standardizedFileURL.path,
            engine.root.appendingPathComponent("ffmpeg").standardizedFileURL.path)
    }

    func testAPythonThatCannotRunIsNamedAtPreflight() throws {
        // What /usr/bin/python3 does on a Mac without the developer tools: it exists, it is
        // executable, and it refuses. Placed in the engine's directory so it is the one found,
        // which also proves the preflight searches there.
        let engine = try stubEngine(script: "#!/bin/bash\n")
        defer { try? FileManager.default.removeItem(at: engine.root) }
        try fakeTool(
            "python3", in: engine.root,
            body: "echo 'xcode-select: note: No developer tools were found' >&2; exit 1")
        func namesPython(_ problems: [EngineLocation.Problem]) -> Bool {
            problems.contains {
                if case .pythonDoesNotRun = $0 { return true }
                return false
            }
        }
        let problems = engine.preflight()
        XCTAssertTrue(namesPython(problems), "a python3 that cannot run must be named: \(problems)")
        let text = problems.map(\.description).joined(separator: "\n")
        XCTAssertTrue(text.contains("xcode-select --install"), "should say how to fix it: \(text)")

        try fakeTool("python3", in: engine.root, body: "exit 0")
        XCTAssertFalse(namesPython(engine.preflight()), "a python3 that runs is not a problem")
    }

    func testFindsNothingOutsideACheckout() {
        XCTAssertNil(
            EngineLocation.discover(from: URL(fileURLWithPath: "/")),
            "the filesystem root is not an engine")
    }
}

final class EngineLocateTests: XCTestCase {
    /// A directory that passes for an engine: the two files `looksLikeAnEngine` asks for.
    private func fakeEngine() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("scripts"),
            withIntermediateDirectories: true)
        try "#!/bin/bash\n".write(
            to: root.appendingPathComponent("scripts/grade.sh"),
            atomically: true, encoding: .utf8)
        try "{}".write(
            to: root.appendingPathComponent("look.json"),
            atomically: true, encoding: .utf8)
        return root
    }

    func testTheOverrideWins() throws {
        let mine = try fakeEngine()
        defer { try? FileManager.default.removeItem(at: mine) }
        let found = EngineLocation.locate(
            environment: ["LOGGRADE_ENGINE": mine.path],
            executable: nil,
            workingDirectory: URL(fileURLWithPath: "/"))
        XCTAssertEqual(found?.root.standardizedFileURL.path, mine.standardizedFileURL.path)
    }

    func testABundleFindsTheEngineBesideItself() throws {
        // The defect this test exists for: launched from the Finder, the working directory is "/",
        // so an app that asks the working directory reports no engine while carrying one.
        let bundle = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(UUID().uuidString).app")
        let macos = bundle.appendingPathComponent("Contents/MacOS")
        let engine = bundle.appendingPathComponent("Contents/Resources/engine")
        try FileManager.default.createDirectory(at: macos, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: engine.appendingPathComponent("scripts"),
            withIntermediateDirectories: true)
        try "#!/bin/bash\n".write(
            to: engine.appendingPathComponent("scripts/grade.sh"),
            atomically: true, encoding: .utf8)
        try "{}".write(
            to: engine.appendingPathComponent("look.json"),
            atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: bundle) }

        let found = EngineLocation.locate(
            environment: [:],
            executable: macos.appendingPathComponent("LogGrade"),
            workingDirectory: URL(fileURLWithPath: "/"))
        XCTAssertEqual(
            found?.root.standardizedFileURL.path, engine.standardizedFileURL.path,
            "a bundle must find the engine it carries, whatever the working directory is")
    }

    func testNoEngineAnywhereIsNil() {
        XCTAssertNil(
            EngineLocation.locate(
                environment: [:],
                executable: nil,
                workingDirectory: URL(fileURLWithPath: "/")))
    }
}
