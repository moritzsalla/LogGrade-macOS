import AppKit
import XCTest
@testable import GradeKit

/// The live grade against the same oracle the browser bench is measured against: ffmpeg's own
/// output over the committed probe. This is the gate that makes a second implementation of the
/// image allowable at all, so it reads the golden rather than restating tolerances of its own.
final class LiveGradeTests: XCTestCase {
    private struct Golden {
        let cases: [[String: Any]]
        let tolerances: [String: Any]
    }

    private func golden() throws -> Golden {
        let here = URL(fileURLWithPath: #filePath)
        guard let engine = EngineLocation.discover(from: here.deletingLastPathComponent()) else {
            throw XCTSkip("no engine checkout")
        }
        let url = engine.root.appendingPathComponent("tests/fixtures/grade-golden.json")
        guard let root = try JSONSerialization.jsonObject(with: try Data(contentsOf: url))
                as? [String: Any],
              let cases = root["cases"] as? [[String: Any]],
              let tolerances = root["tolerances"] as? [String: Any] else {
            throw XCTSkip("no golden")
        }
        return Golden(cases: cases, tolerances: tolerances)
    }

    private func engineRoot() throws -> EngineLocation {
        let here = URL(fileURLWithPath: #filePath)
        guard let engine = EngineLocation.discover(from: here.deletingLastPathComponent()) else {
            throw XCTSkip("no engine checkout")
        }
        return engine
    }

    func testItMatchesFfmpegWithinTheMeasuredTolerance() throws {
        let g = try golden()
        let engine = try engineRoot()
        guard let base = g.cases.first(where: { $0["name"] as? String == "post-look" }),
              let inputs = base["output"] as? [[Int]] else {
            throw XCTSkip("the golden has no post-look case to grade from")
        }
        let perCase = g.tolerances["grade_worst_by_case"] as? [String: Double] ?? [:]
        let margin = g.tolerances["grade_margin_code_values"] as? Double ?? 0.5
        XCTAssertFalse(perCase.isEmpty, "no tolerances, so this test proves nothing")

        var checked = 0
        for c in g.cases {
            guard let name = c["name"] as? String,
                  let tolerance = perCase[name],
                  let params = c["params"] as? [String: Double],
                  let sat = c["saturation"] as? Double,
                  let warm = c["warmth"] as? Double,
                  let outputs = c["output"] as? [[Int]] else { continue }

            let tone = Look.Tone(gamma: params["gamma"] ?? 1, pivot: params["pivot"] ?? 0.5,
                                 contrast: params["contrast"] ?? 1, toe: params["toe"] ?? 0,
                                 shoulder: params["shoulder"] ?? 0, black: params["black"] ?? 0)
            let curve = try ToneCurve.generate(using: engine.toneGenerator, tone: tone)
            let live = LiveGrade(curve: curve, saturation: sat, warmth: warm)

            var worst = 0.0
            for (input, expected) in zip(inputs, outputs) {
                let inR = Double(input[0]) / 65535 * 255
                let inG = Double(input[1]) / 65535 * 255
                let inB = Double(input[2]) / 65535 * 255
                let got = live.apply(r: inR, g: inG, b: inB)
                let want = (Double(expected[0]) / 65535 * 255,
                            Double(expected[1]) / 65535 * 255,
                            Double(expected[2]) / 65535 * 255)
                worst = max(worst, abs(got.0 - want.0))
                worst = max(worst, abs(got.1 - want.1))
                worst = max(worst, abs(got.2 - want.2))
            }
            // The SAME tolerance the JavaScript is held to: both model the same renderer, so a
            // separate allowance for this one would be a way of not noticing it is worse.
            XCTAssertLessThanOrEqual(worst, tolerance + margin,
                                     "\(name): \(worst) code values against \(tolerance)")
            checked += 1
        }
        XCTAssertGreaterThan(checked, 4, "only \(checked) cases were checked")
    }

    func testTheShippedLookIsCloseEnoughToDragAgainst() throws {
        let g = try golden()
        let tolerances = g.tolerances["grade_worst_by_case"] as? [String: Double] ?? [:]
        let shipped = try XCTUnwrap(tolerances["shipped"])
        // The number that decides whether a live preview is honest at all. If the model drifts
        // from the render by more than a couple of code values on the look that ships, the picture
        // being dragged against is not the picture that comes out.
        XCTAssertLessThan(shipped, 4.0,
                          "the shipped look diverges by \(shipped) code values; a live preview "
                          + "would be showing something the render does not produce")
    }

    func testAWholeFrameGoesThroughFastEnoughToDrag() throws {
        let engine = try engineRoot()
        let curve = try ToneCurve.generate(
            using: engine.toneGenerator,
            tone: .init(gamma: 2.02, pivot: 0.39, contrast: 1.09, toe: 0, shoulder: 0.1,
                        black: 0.025))
        let live = LiveGrade(curve: curve, saturation: 1.27, warmth: 0.005)

        // A preview-sized frame: 480 tall at this camera's aspect.
        let width = 270, height = 480
        let space = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: 0, space: space,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(red: 0.6, green: 0.4, blue: 0.3, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let base = context.makeImage()!

        let started = Date()
        let out = live.apply(to: base)
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertNotNil(out)
        XCTAssertEqual(out?.width, width)
        // A drag needs frames, not a slideshow. This is the whole reason the curve is tabulated
        // once per frame rather than evaluated per pixel.
        XCTAssertLessThan(elapsed, 0.1, "a frame took \(elapsed)s, which will not follow a drag")
    }
}

/// The live tier against the render it stands in for, on a real frame rather than a probe.
///
/// The golden tests hold the model to ffmpeg on a synthetic probe, which is what makes the model
/// right. This holds the whole arrangement to the render: the base frame the app asks for, the
/// curve the app generates, the model the app applies, against the frame the app would have waited
/// for. It is the test that would have caught the two mistakes this tier nearly shipped with —
/// a base rendered with exposure matching still on, and a curve generated from the slider's gamma
/// instead of the solved one.
final class LiveAgainstTheRenderTests: XCTestCase {
    private struct Setup {
        let renderer: PreviewRenderer
        let clip: URL
        let look: Look
        let engine: EngineLocation
    }

    private func setUpRender() throws -> Setup {
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
            .appendingPathComponent("live-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: work) }
        let look = try Look(data: Data(contentsOf: engine.lookFile))
        return Setup(renderer: PreviewRenderer(engine: engine, workDirectory: work),
                     clip: clip, look: look, engine: engine)
    }

    /// Mean and worst absolute difference per channel, in 8-bit code values.
    private func difference(_ a: CGImage, _ b: CGImage) throws -> (mean: Double, worst: Double) {
        try XCTSkipIf(a.width != b.width || a.height != b.height,
                      "the two renders are different sizes: \(a.width)x\(a.height) "
                      + "against \(b.width)x\(b.height)")
        func pixels(_ image: CGImage) -> [UInt8] {
            var buffer = [UInt8](repeating: 0, count: image.width * image.height * 4)
            let context = CGContext(data: &buffer, width: image.width, height: image.height,
                                    bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                    space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            context?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return buffer
        }
        let left = pixels(a), right = pixels(b)
        var total = 0.0, worst = 0.0, count = 0.0
        var i = 0
        while i + 3 < left.count {
            for channel in 0..<3 {
                let d = abs(Double(left[i + channel]) - Double(right[i + channel]))
                total += d
                worst = max(worst, d)
                count += 1
            }
            i += 4
        }
        return (total / max(1, count), worst)
    }

    /// DECODED IMMEDIATELY, and that is not tidiness. The engine names a still after its clip and
    /// its timecode, so two renders of the same clip at the same second write the same path: hold
    /// the URL and the second render silently replaces what the first one produced. A test that
    /// did exactly that compared the base frame against itself and read 16 code values of error
    /// off a model that was within one.
    private func image(_ frame: PreviewRenderer.Frame) throws -> CGImage {
        guard let image = NSImage(contentsOf: frame.url)?
            .cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw XCTSkip("the engine wrote a frame this cannot read: \(frame.url.path)")
        }
        return image
    }

    func testALiveFrameLooksLikeTheRenderItStandsIn() throws {
        let setup = try setUpRender()
        let exact = try setup.renderer.render(clip: setup.clip, seconds: 4, look: setup.look,
                                              height: 480)
        let exactImage = try image(exact)
        let base = try image(setup.renderer.render(clip: setup.clip, seconds: 4,
                                                   look: LiveGrade.base(for: setup.look), height: 480,
                                                   match: false))
        // The engine says which gamma it applied. Taking it from the event rather than solving it
        // again is what makes this a test of the render and not of the solver.
        guard let gamma = exact.gamma else {
            throw XCTSkip("the engine did not report the gamma it applied")
        }
        var tone = setup.look.tone
        tone.gamma = gamma
        let curve = try ToneCurve.generate(using: setup.engine.toneGenerator, tone: tone)
        let live = LiveGrade(curve: curve, saturation: setup.look.colour.saturation,
                             warmth: setup.look.colour.warmth)
        guard let graded = live.apply(to: base) else {
            return XCTFail("the live model produced no image")
        }
        let (mean, worst) = try difference(graded, exactImage)
        // Measured at 0.78 mean and 28 worst on IMG_0607 at the shipped look. The mean is what a
        // drag is judged on and it is under a code value; the worst pixel sits in the shadows,
        // where the base's 8-bit round trip costs the most, and the render on release is what
        // gets judged anyway.
        XCTAssertLessThan(mean, 2, "the live frame is \(mean) code values from the render on average")
        XCTAssertLessThan(worst, 40, "one pixel is \(worst) code values out")
    }

    func testTheSliderGammaIsNotTheRenderedGamma() throws {
        let setup = try setUpRender()
        let exact = try setup.renderer.render(clip: setup.clip, seconds: 4, look: setup.look,
                                              height: 480)
        let exactImage = try image(exact)
        let base = try image(setup.renderer.render(clip: setup.clip, seconds: 4,
                                                   look: LiveGrade.base(for: setup.look), height: 480,
                                                   match: false))
        guard let gamma = exact.gamma else {
            throw XCTSkip("the engine did not report the gamma it applied")
        }
        try XCTSkipIf(abs(gamma - setup.look.tone.gamma) < 0.01,
                      "this clip happens to need no exposure match, so there is nothing to catch")
        // THE MUTATION, KEPT AS A TEST. Generating from the slider's gamma rather than the solved
        // one is the mistake, and this is how far out it puts the picture. If this assertion ever
        // starts failing because the two got close, the interface can stop solving.
        let curve = try ToneCurve.generate(using: setup.engine.toneGenerator, tone: setup.look.tone)
        let live = LiveGrade(curve: curve, saturation: setup.look.colour.saturation,
                             warmth: setup.look.colour.warmth)
        guard let graded = live.apply(to: base) else {
            return XCTFail("the live model produced no image")
        }
        let (mean, _) = try difference(graded, exactImage)
        XCTAssertGreaterThan(mean, 4, "the unsolved gamma is only \(mean) code values out, so the "
                             + "solve in refreshCurve is no longer earning its subprocess")
    }
}

/// The base frame's two conditions, pinned separately from the picture they produce.
///
/// A whole-frame comparison would go red if either of these broke, but it would not say which, and
/// it needs footage. These do not.
final class LiveBaseTests: XCTestCase {
    /// The shipped look itself, not a hand-built stand-in: this is about what the base does to a
    /// real grade, and a stand-in that happened to be neutral already would prove nothing.
    private func shipped() throws -> Look {
        let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        guard let engine = EngineLocation.discover(from: here) else {
            throw XCTSkip("no engine checkout")
        }
        return try Look(data: Data(contentsOf: engine.lookFile))
    }

    func testTheBaseTurnsOffEverythingTheModelApplies() throws {
        let look = try shipped()
        XCTAssertNotEqual(look.tone.gamma, 1, "the shipped look is already neutral, so this proves "
                          + "nothing — point it at a look that grades something")
        let base = LiveGrade.base(for: look)
        XCTAssertEqual(base.tone.gamma, 1)
        XCTAssertEqual(base.tone.contrast, 1)
        XCTAssertEqual(base.tone.toe, 0)
        XCTAssertEqual(base.tone.shoulder, 0)
        XCTAssertEqual(base.tone.black, 0)
        XCTAssertEqual(base.colour.saturation, 1)
        XCTAssertEqual(base.colour.warmth, 0)
    }

    func testTheBaseKeepsTheStagesTheModelCannotApply() throws {
        var look = try shipped()
        look.lookLUT = "kodak_portra_400_nc"
        look.correct.exposure = 0.3
        let base = LiveGrade.base(for: look)
        // The look cube and the correction stage are IN the base, because the model does not model
        // them. Neutralising those instead would leave the live picture missing half the grade.
        XCTAssertEqual(base.lookLUT, "kodak_portra_400_nc")
        XCTAssertEqual(base.correct.exposure, 0.3)
    }

    /// WHY THE BASE IS RENDERED WITH MATCHING OFF, as an assertion rather than as a comment.
    func testExposureMatchingDoesNotPassAGammaOfOneThrough() throws {
        let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        guard let engine = EngineLocation.discover(from: here) else {
            throw XCTSkip("no engine checkout")
        }
        let solved = ToneCurve.solvedGamma(using: engine.gammaSolver, clipYAVG: 479,
                                           referenceYAVG: 609, referenceGamma: 1)
        XCTAssertGreaterThan(solved, 1.1, "a base rendered with matching on would carry this curve")
    }
}

/// The whole-frame path against the per-pixel one, which is the path the golden holds.
///
/// The app calls the whole-frame path and the golden tests the per-pixel one. They share a body
/// now, but "now" is the operative word: this is what fails the day somebody optimises one of them
/// and not the other, which is exactly how the two drifted the first time.
extension LiveGradeTests {
    func testTheWholeFramePathAgreesWithThePixelPath() throws {
        let curve = ToneCurve(samples: (0..<4096).map { pow(Double($0) / 4095, 2.02) })
        let live = LiveGrade(curve: curve, saturation: 1.6, warmth: 0.08)

        // Saturated corners, which is where the plane clamp bites and where ordinary footage does
        // not go. A frame of real pixels would not exercise it and would leave the clamp untested.
        let corners: [(UInt8, UInt8, UInt8)] = [
            (255, 0, 0), (0, 255, 0), (0, 0, 255), (255, 255, 0), (0, 255, 255), (255, 0, 255),
            (0, 0, 0), (255, 255, 255), (128, 64, 200), (243, 55, 65), (12, 200, 30),
        ]
        var buffer = [UInt8](repeating: 255, count: corners.count * 4)
        for (i, c) in corners.enumerated() {
            buffer[i * 4] = c.0; buffer[i * 4 + 1] = c.1; buffer[i * 4 + 2] = c.2
        }
        let context = CGContext(data: &buffer, width: corners.count, height: 1,
                                bitsPerComponent: 8, bytesPerRow: corners.count * 4,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let source = context?.makeImage(), let graded = live.apply(to: source) else {
            return XCTFail("could not build the probe strip")
        }
        var out = [UInt8](repeating: 0, count: corners.count * 4)
        let readBack = CGContext(data: &out, width: corners.count, height: 1, bitsPerComponent: 8,
                                 bytesPerRow: corners.count * 4,
                                 space: CGColorSpaceCreateDeviceRGB(),
                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        readBack?.draw(graded, in: CGRect(x: 0, y: 0, width: corners.count, height: 1))

        for (i, c) in corners.enumerated() {
            let expected = live.apply(r: Double(c.0), g: Double(c.1), b: Double(c.2))
            // One code value, which is the truncation the whole-frame path does writing bytes back.
            XCTAssertEqual(Double(out[i * 4]), expected.0, accuracy: 1, "red at \(c)")
            XCTAssertEqual(Double(out[i * 4 + 1]), expected.1, accuracy: 1, "green at \(c)")
            XCTAssertEqual(Double(out[i * 4 + 2]), expected.2, accuracy: 1, "blue at \(c)")
        }
    }
}
