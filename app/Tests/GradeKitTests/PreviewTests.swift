import XCTest

@testable import GradeKit

final class PreviewRendererTests: XCTestCase {
    func testRendersAStillThroughTheRealChainAndTheLookChangesIt() throws {
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
        defer { try? FileManager.default.removeItem(at: work) }
        let renderer = PreviewRenderer(engine: engine, workDirectory: work)
        var look = try Look(data: try Data(contentsOf: engine.lookFile))

        let first = try renderer.render(clip: clip, seconds: 0, look: look, height: 240)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.url.path))
        let a = try Data(contentsOf: first.url)
        XCTAssertGreaterThan(a.count, 1000, "that is not an image")

        // The property that matters: the preview reflects the look. A preview that does not move
        // when a control moves is a picture, not a preview.
        look.correct.exposure = 1
        let second = try renderer.render(clip: clip, seconds: 0, look: look, height: 240)
        let b = try Data(contentsOf: second.url)
        XCTAssertNotEqual(a, b, "changing exposure did not change the rendered still")
    }

    func testARefusalComesBackAsItsReason() throws {
        let engine = try engineCheckout()
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
            XCTAssertTrue(
                failure.description.contains("not there")
                    || failure.description.contains("not found"),
                "got: \(failure.description)")
        }
    }
}
