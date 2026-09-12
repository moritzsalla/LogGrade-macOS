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

    // NO TIMING TEST HERE, deliberately. One used to assert a frame took under 0.1s, and it
    // passed — in a debug build, where the real cost of the live chain is 1.5 SECONDS against
    // 12.7ms optimised. A timing assertion that only holds in the configuration nobody grades in
    // reads as coverage and provides none. The measurements live in docs/adr/0009 and the build
    // that matters is pinned by app/make-app.sh defaulting to release.
}

/// The whole-frame path against the per-pixel one, which is the path the golden holds.
///
/// The app grades frames through `LiveChain.graded`; the golden tests `LiveGrade.apply(r:g:b:)`.
/// They share a body, but "share" is a property of today's code: this is what fails the day
/// somebody optimises one and not the other, which is how the two drifted the first time — a copy
/// of the arithmetic with the chroma clamp missing passed every test there was.
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
        let converted = LiveChain.Converted(width: corners.count, height: 1, pixels: buffer)
        guard let graded = LiveChain.graded(converted, with: live) else {
            return XCTFail("the whole-frame path produced no image")
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
