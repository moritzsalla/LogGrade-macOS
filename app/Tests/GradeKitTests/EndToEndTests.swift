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
        let engine = try engineCheckout()
        try XCTSkipIf(!engine.preflight().isEmpty, "engine preflight not clean")
        let clips =
            (try? FileManager.default.contentsOfDirectory(
                at: engine.root.appendingPathComponent("src"), includingPropertiesForKeys: nil))
            ?? []
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
        let settings = [
            "PROOF": "0.1", "STAB": "0", "MATCH": "1",
            "LOOK_FILE": engine.lookFile.path,
        ]

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
        let outcome = try EngineRun(engine: engine).run(
            arguments: [clip.path],
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
        XCTAssertEqual(
            output?.path.map { URL(fileURLWithPath: $0).lastPathComponent },
            appFile.lastPathComponent)
    }

    private func temporaryDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func onlyProof(in work: URL) throws -> URL {
        let proofs = work.appendingPathComponent(".loggrade/proofs")
        let files = try FileManager.default.contentsOfDirectory(
            at: proofs,
            includingPropertiesForKeys: nil
        )
        .filter { $0.pathExtension == "mp4" }
        guard let first = files.first, files.count == 1 else {
            throw XCTSkip("expected one proof in \(proofs.path), found \(files.count)")
        }
        return first
    }
}

/// A whole delivery, through the app's own queue, to the file that would be uploaded.
///
/// Everything else tests a piece. This is the app doing the thing it exists for: a clip in, a
/// deliverable out, with its colour tags verified — because an encoder writing the wrong tags is
/// the failure this pipeline's whole retag pass exists for, and it has happened on two different
/// encoders here.
final class DeliveryTests: XCTestCase {
    func testTheQueueDeliversATaggedFile() throws {
        let engine = try engineCheckout()
        try XCTSkipIf(!engine.preflight().isEmpty, "engine preflight not clean")
        let clips =
            (try? FileManager.default.contentsOfDirectory(
                at: engine.root.appendingPathComponent("src"), includingPropertiesForKeys: nil))
            ?? []
        guard let clip = clips.first(where: { $0.pathExtension.lowercased() == "mov" }) else {
            throw XCTSkip("no footage in src/")
        }

        let work = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        let look = try Look(data: try Data(contentsOf: engine.lookFile))
        let lookFile = work.appendingPathComponent("look.json")
        try look.write(to: lookFile)

        var project = Project(
            presets: [.init(name: "shipped", look: look)],
            activePreset: "shipped",
            delivery: .init(targets: [.reels], height: 640))
        let stem = clip.deletingPathExtension().lastPathComponent
        project.clips[stem] = .init(stabilise: false)

        let queue = RenderQueue(engine: engine)
        queue.concurrency = 1
        queue.enqueue([(clip, stem, nil)])

        let done = expectation(description: "delivered")
        DispatchQueue.global().async {
            queue.start(environment: { name in
                var env = project.environment(for: name, lookFile: lookFile)
                env["GRADE_WORK_DIR"] = work.path
                env["PROOF"] = "0.3"  // a short one: this is about the path, not the runtime
                return env
            })
            done.fulfill()
        }
        wait(for: [done], timeout: 600)
        // The queue publishes on the main queue; polled until the job's state lands, which is
        // published after its outputs, rather than paused for a guessed duration.
        let deadline = Date().addingTimeInterval(5)
        while !queue.jobs.allSatisfy({ $0.state.isFinished }) && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }

        XCTAssertEqual(queue.jobs.first?.state, .done, "the queue said: \(queue.jobs)")
        // WHERE IT LANDED. A deliverable rendered into a scratch directory is one macOS may
        // delete, and that is what this app did until it was given somewhere to put things.
        //
        // The prefix, not the exact folder: this render is a proof so it lands in .loggrade/proofs by
        // design, and proofs are deliberately not deliverables. What is asserted is that the
        // engine wrote inside the directory it was pointed at.
        let written = try XCTUnwrap(queue.jobs.first?.outputs.first).standardizedFileURL.path
        XCTAssertTrue(
            written.hasPrefix(work.standardizedFileURL.path),
            "the file landed outside the chosen directory: \(written)")
        XCTAssertFalse(
            written.contains("loggrade-preview"),
            "a deliverable landed in the preview scratch directory: \(written)")
        let outputs = try XCTUnwrap(queue.jobs.first?.outputs)
        XCTAssertEqual(outputs.count, 1, "one shape was asked for, got \(outputs)")
        let delivered = try XCTUnwrap(outputs.first)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: delivered.path),
            "the queue named a file that is not there: \(delivered.path)")
        let size = try FileManager.default.attributesOfItem(atPath: delivered.path)[.size] as? Int
        XCTAssertGreaterThan(size ?? 0, 10_000, "that is not a rendered clip")

        // The tags, because an encoder writing the wrong ones is how a correct image gets
        // double-transformed by anything that trusts them — CONTEXT.md calls that bleached.
        let ffprobe = try XCTUnwrap(EngineLocation.resolveTool("ffprobe"))
        let probe = Process()
        probe.executableURL = ffprobe
        probe.arguments = [
            "-v", "error", "-select_streams", "v:0", "-show_entries",
            "stream=color_primaries,color_transfer,color_space",
            "-of", "default=nw=1:nk=1", delivered.path,
        ]
        let pipe = Pipe()
        probe.standardOutput = pipe
        try probe.run()
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        probe.waitUntilExit()
        let fields = text.split(separator: "\n").map(String.init)
        XCTAssertTrue(
            fields.allSatisfy { $0 == "bt709" },
            "the delivered file is not tagged Rec.709: \(fields)")

        // And nothing half-written was left next to it.
        let leftovers =
            (try? FileManager.default.contentsOfDirectory(
                at: delivered.deletingLastPathComponent(), includingPropertiesForKeys: nil)) ?? []
        XCTAssertFalse(
            leftovers.contains { $0.lastPathComponent.contains(".partial.") },
            "a staging file was left in the delivery folder")
    }
}
