import AppKit
import XCTest

@testable import GradeKit

/// The whole live chain against the whole render, on real footage.
///
/// This is the only test that can catch the live tier being wrong in the way that matters: the
/// picture on screen while a control is moving disagreeing with the file that comes out.
/// `Cube3DTests` holds the sampling, and would not notice the stages being wired together in the
/// wrong order or the source frame arriving in a different colour space than the chain's first
/// filter sees.
final class LiveChainTests: XCTestCase {
    private struct Rig {
        let engine: EngineLocation
        let renderer: PreviewRenderer
        let clip: URL
        let look: Look
        let conversion: Cube3D
    }

    private func rig() throws -> Rig {
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
            .appendingPathComponent("chain-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: work) }
        let look = try Look(data: Data(contentsOf: engine.lookFile))
        let conversion = try Cube3D(
            contentsOf: try XCTUnwrap(engine.conversionCube(named: look.convertCube)))
        return Rig(
            engine: engine,
            renderer: PreviewRenderer(engine: engine, workDirectory: work),
            clip: clip, look: look, conversion: conversion)
    }

    private func image(_ frame: PreviewRenderer.Frame) throws -> CGImage {
        guard
            let image = NSImage(contentsOf: frame.url)?
                .cgImage(forProposedRect: nil, context: nil, hints: nil)
        else {
            throw XCTSkip("cannot read \(frame.url.path)")
        }
        return image
    }

    /// Mean, 99.9th percentile and worst absolute difference per channel, in 8-bit code values.
    ///
    /// THE PERCENTILE IS THE REAL MEASURE, not the worst pixel. The live tier resamples to preview
    /// size and then grades; the render grades at full resolution and then resamples. Those two
    /// orders agree everywhere except on a hard edge, where one pixel is a blend of two colours
    /// that the grade moves in different directions. The disagreement is therefore bounded to
    /// edges and is invisible, but a single worst-pixel assertion would read it as a defect.
    private func difference(_ a: CGImage, _ b: CGImage) throws -> (
        mean: Double, p999: Double,
        worst: Double
    ) {
        try XCTSkipIf(a.width != b.width || a.height != b.height, "different sizes")
        func pixels(_ image: CGImage) -> [UInt8] {
            var buffer = [UInt8](repeating: 0, count: image.width * image.height * 4)
            let ctx = CGContext(
                data: &buffer, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            ctx?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return buffer
        }
        let left = pixels(a)
        let right = pixels(b)
        var deltas: [Double] = []
        deltas.reserveCapacity(left.count / 4 * 3)
        var i = 0
        while i + 3 < left.count {
            for c in 0..<3 { deltas.append(abs(Double(left[i + c]) - Double(right[i + c]))) }
            i += 4
        }
        deltas.sort()
        let mean = deltas.reduce(0, +) / Double(max(1, deltas.count))
        return (mean, deltas[Int(Double(deltas.count - 1) * 0.999)], deltas.last ?? 0)
    }

    /// One source frame for the whole suite.
    ///
    /// IT DOES NOT DEPEND ON THE LOOK — that is the property the live tier is built on, so the
    /// test may as well rely on it too. Rendering it once instead of once per case takes three
    /// engine renders out of this file, which is about fifteen seconds of every run.
    private static var cachedSource: CGImage?

    private func source(_ rig: Rig, height: Int = 480) throws -> CGImage {
        if height == 480, let cached = Self.cachedSource { return cached }
        let image = try image(
            rig.renderer.render(
                clip: rig.clip, seconds: 4, look: rig.look,
                height: height, match: false, stage: .source))
        if height == 480 { Self.cachedSource = image }
        return image
    }

    /// Grades the source frame in-process and measures it against the engine's own render.
    private func compare(_ rig: Rig, look: Look, height: Int = 480) throws -> (
        mean: Double, p999: Double,
        worst: Double
    ) {
        let exact = try rig.renderer.render(clip: rig.clip, seconds: 4, look: look, height: height)
        let exactImage = try image(exact)
        let sourceImage = try source(rig, height: height)
        // Assembled by the builder the app and the export use, so this holds that assembly too.
        let chain = try ChainBuilder(engine: rig.engine).build(
            look, metered: exact.metered, frameLongEdge: max(sourceImage.width, sourceImage.height),
            sourceLongEdge: exact.sourceSize.map { max($0.width, $0.height) }
        ).chain
        guard let live = chain.apply(to: sourceImage) else {
            throw XCTSkip("the live chain produced no image")
        }
        return try difference(live, exactImage)
    }

    /// Every case in one test, because each one costs an engine render and they share a rig.
    ///
    /// Measured on IMG_0607: mean 1.29, 99.9th percentile 18, worst 56 at the shipped look. The
    /// bounds carry headroom over those, because they are one clip's numbers.
    ///
    /// Halation at strength 0.8 measured mean 1.52, 99.9th percentile 19, worst 83 — the worst
    /// pixel nearest its bound, on the rim of a glow, where the two blurs differ most. With the
    /// live glow removed entirely the same case reads 46 at the percentile and 179 at the worst,
    /// so the percentile bound is what catches a preview that has lost the stage.
    func testTheLivePictureMatchesTheRender() throws {
        let rig = try rig()
        var withCorrection = rig.look
        withCorrection.correct.exposure = 0.6
        withCorrection.correct.temp = 0.25
        // Strong enough to see, so the tolerance below is spent on the glow rather than on nothing.
        var withHalation = rig.look
        withHalation.halation = Look.Halation(
            strength: 0.8, threshold: 1, radius: 0.006,
            tint: "1,0.3,0.05")
        let filmPreset = try XCTUnwrap(
            rig.engine.shippedPresets().first { $0.look.convertCube == "portra160" }
        ).look

        // The percentile each case is held to.
        let edgeBound = 24.0
        let cases: [(String, Look, Double)] = [
            ("the shipped look", rig.look, edgeBound),
            // THE ONE THE OLD TIER COULD NOT DO AT ALL. A correction runs before Apple's
            // conversion, so a live preview built on a converted frame showed nothing while this
            // slider moved.
            ("a live correction", withCorrection, edgeBound),
            // SPATIAL, so the one stage that cannot be a transcription. The render blurs a quarter-
            // resolution copy of the 4K frame with ffmpeg's recursive approximation; this blurs the
            // 480-line frame with a true Gaussian.
            ("halation", withHalation, edgeBound),
            // The conversion swapped for a film cube, with the engine's metered exposure and white
            // balance in the correction.
            ("a film preset", filmPreset, edgeBound),
        ]
        for (name, look, percentileBound) in cases {
            let (mean, p999, worst) = try compare(rig, look: look)
            XCTAssertLessThan(mean, 3, "\(name): \(mean) code values from the render on average")
            XCTAssertLessThan(
                p999, percentileBound,
                "\(name): a thousandth of it is more than \(p999) out")
            XCTAssertLessThan(
                worst, 90,
                "\(name): the worst pixel is \(worst), beyond the edge "
                    + "effect the percentile allows for")
        }
    }

    /// Halation where the preview is big enough to compute the glow reduced, as the app's 1080-line
    /// preview of a landscape 4K clip does. The 480-line cases above never reduce, so without this
    /// the path the app runs had no parity test.
    ///
    /// 1920 HIGH: the smallest frame of this portrait 2160x3840 clip that reduces by 2
    /// (`frameLongEdge * 4 / sourceLongEdge`). Measured on IMG_0607, Super 8 at strength 0.8: mean
    /// 0.97, 99.9th percentile 8, worst 48. With the sigma not divided by the reduction: mean 2.05,
    /// percentile 64, worst 106, so the percentile is the bound that catches it. About 13 s in
    /// release and 64 s in debug, the two 1920-line engine renders and the debug pixel loop.
    func testReducedHalationMatchesTheRender() throws {
        let rig = try rig()
        var look = try XCTUnwrap(
            rig.engine.shippedPresets().first { $0.look.convertCube == "super8_kodachrome64" }
        ).look
        look.halation.strength = 0.8
        let (mean, p999, worst) = try compare(rig, look: look, height: 1920)
        XCTAssertLessThan(mean, 3, "reduced halation: \(mean) code values off on average")
        XCTAssertLessThan(p999, 16, "reduced halation: a thousandth is more than \(p999) out")
        XCTAssertLessThan(worst, 90, "reduced halation: the worst pixel is \(worst) out")
    }
}
