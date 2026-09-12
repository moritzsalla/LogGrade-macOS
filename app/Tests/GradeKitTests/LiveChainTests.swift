import AppKit
import XCTest
@testable import GradeKit

/// The whole live chain against the whole render, on real footage.
///
/// This is the only test that can catch the live tier being wrong in the way that matters: the
/// picture on screen while a control is moving disagreeing with the file that comes out. The
/// golden holds the tone and trim arithmetic, `Cube3DTests` holds the sampling, and neither would
/// notice the two being wired together in the wrong order or the source frame arriving in a
/// different colour space than the chain's first filter sees.
final class LiveChainTests: XCTestCase {
    private struct Rig {
        let engine: EngineLocation
        let renderer: PreviewRenderer
        let clip: URL
        let look: Look
        let conversion: Cube3D
        let lookCube: Cube3D?
    }

    private func rig() throws -> Rig {
        let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        guard let engine = EngineLocation.discover(from: here) else {
            throw XCTSkip("no engine checkout")
        }
        try XCTSkipIf(!engine.preflight().isEmpty, "engine preflight not clean")
        let clips = (try? FileManager.default.contentsOfDirectory(
            at: engine.root.appendingPathComponent("src"), includingPropertiesForKeys: nil)) ?? []
        guard let clip = clips.first(where: { $0.pathExtension.lowercased() == "mov" }) else {
            throw XCTSkip("no footage in src/")
        }
        let work = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("chain-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: work) }
        let look = try Look(data: Data(contentsOf: engine.lookFile))
        let conversion = try Cube3D(contentsOf: engine.appleCube)
        let lookCube = engine.lookCube(named: look.lookLUT).map { try? Cube3D(contentsOf: $0) } ?? nil
        return Rig(engine: engine,
                   renderer: PreviewRenderer(engine: engine, workDirectory: work),
                   clip: clip, look: look, conversion: conversion, lookCube: lookCube)
    }

    private func image(_ frame: PreviewRenderer.Frame) throws -> CGImage {
        guard let image = NSImage(contentsOf: frame.url)?
            .cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw XCTSkip("cannot read \(frame.url.path)")
        }
        return image
    }

    /// Mean, 99.9th percentile and worst absolute difference per channel, in 8-bit code values.
    ///
    /// THE PERCENTILE IS THE REAL MEASURE, not the worst pixel. The live tier resamples to preview
    /// size and then grades; the render grades at full resolution and then resamples. Those two
    /// orders agree everywhere except on a hard edge, where one pixel is a blend of two colours
    /// that the tone curve moves in different directions. The disagreement is therefore bounded to
    /// edges and is invisible, but a single worst-pixel assertion would read it as a defect.
    private func difference(_ a: CGImage, _ b: CGImage) throws -> (mean: Double, p999: Double,
                                                                  worst: Double) {
        try XCTSkipIf(a.width != b.width || a.height != b.height, "different sizes")
        func pixels(_ image: CGImage) -> [UInt8] {
            var buffer = [UInt8](repeating: 0, count: image.width * image.height * 4)
            let ctx = CGContext(data: &buffer, width: image.width, height: image.height,
                                bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            ctx?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return buffer
        }
        let left = pixels(a), right = pixels(b)
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

    private func source(_ rig: Rig) throws -> CGImage {
        if let cached = Self.cachedSource { return cached }
        let image = try image(rig.renderer.render(clip: rig.clip, seconds: 4, look: rig.look,
                                                  height: 480, match: false, stage: .source))
        Self.cachedSource = image
        return image
    }

    /// Grades the source frame in-process and measures it against the engine's own render.
    private func compare(_ rig: Rig, look: Look) throws -> (mean: Double, p999: Double,
                                                            worst: Double) {
        let exact = try rig.renderer.render(clip: rig.clip, seconds: 4, look: look, height: 480)
        let exactImage = try image(exact)
        var tone = look.tone
        // The engine reports the gamma it solved; the app's own path solves the same one, which
        // `ToneCurvePortTests` checks separately. Taking it from the event keeps this a test of
        // the picture rather than of the solve.
        if let gamma = exact.gamma { tone.gamma = gamma }
        let correction = look.correct.isNeutral ? nil
            : CorrectionCube.cube(for: look.correct, size: 33)
        let chain = LiveChain(
            stages: LiveChain.colourStages(correction: correction, conversion: rig.conversion,
                                           look: rig.lookCube),
            grade: LiveGrade(curve: ToneCurve.generated(tone: tone),
                             saturation: look.colour.saturation, warmth: look.colour.warmth))
        guard let live = chain.apply(to: try source(rig)) else {
            throw XCTSkip("the live chain produced no image")
        }
        return try difference(live, exactImage)
    }

    /// Every case in one test, because each one costs an engine render and they share a rig.
    ///
    /// Measured on IMG_0607: mean 1.28, 99.9th percentile 13, worst 56 at the shipped look. The
    /// bounds carry headroom over those, because they are one clip's numbers.
    func testTheLivePictureMatchesTheRender() throws {
        let rig = try rig()
        var withCorrection = rig.look
        withCorrection.correct.exposure = 0.6
        withCorrection.correct.temp = 0.25
        var withoutLook = rig.look
        withoutLook.lookLUT = "none"

        let cases: [(String, Look, Rig)] = [
            ("the shipped look", rig.look, rig),
            // THE ONE THE OLD TIER COULD NOT DO AT ALL. A correction runs before Apple's
            // conversion, so a live preview built on a converted frame showed nothing while this
            // slider moved.
            ("a live correction", withCorrection, rig),
            ("no film look", withoutLook, Rig(engine: rig.engine, renderer: rig.renderer,
                                              clip: rig.clip, look: withoutLook,
                                              conversion: rig.conversion, lookCube: nil)),
        ]
        for (name, look, useRig) in cases {
            let (mean, p999, worst) = try compare(useRig, look: look)
            XCTAssertLessThan(mean, 3, "\(name): \(mean) code values from the render on average")
            XCTAssertLessThan(p999, 24, "\(name): a thousandth of it is more than \(p999) out")
            XCTAssertLessThan(worst, 90, "\(name): the worst pixel is \(worst), beyond the edge "
                              + "effect the percentile allows for")
        }
    }
}
