import XCTest
@testable import GradeKit

final class ToneCurveTests: XCTestCase {
    private func engine() throws -> EngineLocation {
        let here = URL(fileURLWithPath: #filePath)
        guard let e = EngineLocation.discover(from: here.deletingLastPathComponent()) else {
            throw XCTSkip("no engine checkout")
        }
        return e
    }

    private var shipped: Look.Tone {
        .init(gamma: 2.02, pivot: 0.39, contrast: 1.09, toe: 0, shoulder: 0.1, black: 0.025)
    }

    func testTheCurveComesFromTheEnginesOwnGenerator() throws {
        let e = try engine()
        let curve = try ToneCurve.generate(using: e.toneGenerator, tone: shipped)
        XCTAssertEqual(curve.samples.count, 4096, "the generator writes a 4096-entry table")
        // The shipped curve lifts the black point and darkens the midtones.
        XCTAssertEqual(curve.value(at: 0), 0.025, accuracy: 0.0005)
        XCTAssertLessThan(curve.value(at: 0.5), 0.5, "gamma 2.02 darkens")
        XCTAssertEqual(curve.value(at: 1), 1, accuracy: 0.002)
        // Monotone, or the interface would draw something the eye reads as a fold.
        for i in 1..<curve.samples.count {
            XCTAssertGreaterThanOrEqual(curve.samples[i], curve.samples[i - 1] - 1e-9,
                                        "the curve reverses at \(i)")
        }
    }

    func testItIsTheCurveAndNotAPortOfIt() throws {
        let e = try engine()
        // Byte-for-byte against a cube the generator writes to a FILE: same generator, same
        // parameters, so the interface draws what the render applies rather than a lookalike.
        let file = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(UUID().uuidString).cube")
        defer { try? FileManager.default.removeItem(at: file) }
        let write = Process()
        write.executableURL = e.toneGenerator
        write.arguments = [file.path, "--gamma", "2.02", "--pivot", "0.39", "--contrast", "1.09",
                           "--toe", "0", "--shoulder", "0.1", "--black", "0.025"]
        write.standardOutput = Pipe()
        try write.run(); write.waitUntilExit()

        let text = try String(contentsOf: file, encoding: .utf8)
        let fromFile = text.split(separator: "\n").compactMap { line -> Double? in
            let parts = line.split(separator: " ")
            guard parts.count == 3 else { return nil }
            return Double(parts[0])
        }
        let curve = try ToneCurve.generate(using: e.toneGenerator, tone: shipped)
        XCTAssertEqual(curve.samples, fromFile)
    }

    func testADifferentGammaIsADifferentCurve() throws {
        let e = try engine()
        var other = shipped
        other.gamma = 1.2
        let a = try ToneCurve.generate(using: e.toneGenerator, tone: shipped)
        let b = try ToneCurve.generate(using: e.toneGenerator, tone: other)
        XCTAssertNotEqual(a.samples, b.samples)
        XCTAssertGreaterThan(b.value(at: 0.5), a.value(at: 0.5), "less gamma is brighter")
    }
}

final class PreviewRendererTests: XCTestCase {
    func testRendersAStillThroughTheRealChainAndTheLookChangesIt() throws {
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

        let work = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: work) }
        let renderer = PreviewRenderer(engine: engine, workDirectory: work)
        var look = try Look(data: try Data(contentsOf: engine.lookFile))

        let first = try renderer.render(clip: clip, seconds: 0, look: look, height: 240)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.url.path))
        let a = try Data(contentsOf: first.url)
        XCTAssertGreaterThan(a.count, 1000, "that is not an image")

        // The property that matters: the preview reflects the look. A preview that does not move
        // when a control moves is a picture, not a preview.
        look.tone.gamma = 1.2
        let second = try renderer.render(clip: clip, seconds: 0, look: look, height: 240)
        let b = try Data(contentsOf: second.url)
        XCTAssertNotEqual(a, b, "changing gamma did not change the rendered still")
    }

    func testARefusalComesBackAsItsReason() throws {
        let here = URL(fileURLWithPath: #filePath)
        guard let engine = EngineLocation.discover(from: here.deletingLastPathComponent()) else {
            throw XCTSkip("no engine checkout")
        }
        try XCTSkipIf(!engine.preflight().isEmpty, "engine preflight not clean")
        let work = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: work) }
        let look = try Look(data: try Data(contentsOf: engine.lookFile))
        let renderer = PreviewRenderer(engine: engine, workDirectory: work)
        let missing = URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).mov")
        do {
            _ = try renderer.render(clip: missing, seconds: 0, look: look)
            XCTFail("rendering a file that is not there should fail")
        } catch let failure as PreviewRenderer.Failure {
            // Named, and the engine's own code carried through rather than a generic message.
            XCTAssertTrue(failure.description.contains("not there")
                          || failure.description.contains("not found"),
                          "got: \(failure.description)")
        }
    }
}
