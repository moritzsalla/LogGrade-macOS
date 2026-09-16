import AppKit
import XCTest

@testable import GradeKit

/// The in-process source frame and meter against the engine's, on real footage. The live tier
/// grades these, so a colour-space, orientation or scale mistake here would put a wrong picture on
/// screen that no other test sees.
final class NativeSourceTests: XCTestCase {
    private func realClip(_ engine: EngineLocation) throws -> URL {
        try XCTSkipIf(!engine.preflight().isEmpty, "engine preflight not clean")
        let clips =
            (try? FileManager.default.contentsOfDirectory(
                at: engine.root.appendingPathComponent("src"), includingPropertiesForKeys: nil))
            ?? []
        guard let clip = clips.first(where: { $0.pathExtension.lowercased() == "mov" }) else {
            throw XCTSkip("no footage in src/")
        }
        return clip
    }

    private func pixels(_ image: CGImage) -> [UInt16] {
        var px = [UInt16](repeating: 0, count: image.width * image.height * 4)
        let context = CGContext(
            data: &px, width: image.width, height: image.height, bitsPerComponent: 16,
            bytesPerRow: image.width * 8, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                | CGBitmapInfo.byteOrder16Little.rawValue)
        context?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return px
    }

    /// Measured on IMG_0607: mean 0.24–0.32, 99.9th percentile 12.5–13.1, worst ~25 per channel. The
    /// bounds leave room for a different clip in src/ without admitting the failures seen while
    /// building it: a portrait frame rotated the wrong way read mean 39, a landscape one scaled by the
    /// vertical factor read percentile 62.
    func testTheNativeFrameMatchesTheEnginesSourceFrame() throws {
        let engine = try engineCheckout()
        let clip = try realClip(engine)
        let work = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("native-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: work) }
        let renderer = PreviewRenderer(engine: engine, workDirectory: work)
        let look = try Look(data: Data(contentsOf: engine.lookFile))
        let engineFrame = try renderer.render(
            clip: clip, seconds: 1, look: look, height: 480, match: false, stage: .source)
        let reference = try XCTUnwrap(
            NSImage(contentsOf: engineFrame.url)?
                .cgImage(forProposedRect: nil, context: nil, hints: nil))

        let native = try NativeSource.frame(of: clip, at: 1, height: 480)
        XCTAssertEqual(native.image.width, reference.width, "width differs from scale=-2:480")
        XCTAssertEqual(native.image.height, reference.height)
        XCTAssertEqual(
            native.sourceSize, engineFrame.sourceSize, "orientation differs from the engine's")

        let a = pixels(native.image)
        let b = pixels(reference)
        for channel in 0..<3 {
            var diffs: [Double] = []
            var i = channel
            while i < a.count {
                diffs.append(abs(Double(a[i]) - Double(b[i])) / 257)
                i += 4
            }
            diffs.sort()
            let mean = diffs.reduce(0, +) / Double(diffs.count)
            let p999 = diffs[Int(Double(diffs.count - 1) * 0.999)]
            XCTAssertLessThan(mean, 1.0, "channel \(channel) mean \(mean)")
            XCTAssertLessThan(p999, 20, "channel \(channel) 99.9th percentile \(p999)")
        }
    }

    /// The meter is the engine's function, so it must agree with the engine's own reading exactly.
    func testTheMeterIsTheEnginesReading() throws {
        let engine = try engineCheckout()
        let clip = try realClip(engine)
        let work = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("meter-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: work) }
        let look = try Look(data: Data(contentsOf: engine.lookFile))
        let engineFrame = try PreviewRenderer(engine: engine, workDirectory: work).render(
            clip: clip, seconds: 1, look: look, height: 120, match: true, stage: .source)
        let reading = try ExposureMeter(engine: engine).measure(
            clip, referenceStops: look.matchReferenceStops)
        XCTAssertEqual(reading, engineFrame.metered)
        XCTAssertNotEqual(reading, PreviewRenderer.Metered(), "a neutral reading proves nothing")
    }
}
