import XCTest
@testable import GradeKit

/// The Swift correction against the generator's, number for number.
///
/// THIS IS WHAT LICENSES THE PORT. `CorrectionCube` is the only place in the app that computes the
/// image rather than reading it from a file the render also reads, and the repo's rule is that a
/// second implementation is allowed only where a test can hold it to the first. So this is not a
/// tolerance test on a few patches: it builds the whole cube both ways and compares all 107,811
/// numbers, to the eight decimal places the generator prints. Either side drifting fails by name.
final class CorrectionCubeTests: XCTestCase {
    /// Corrections chosen to reach every branch: exposure alone, white balance alone, a CDL with
    /// all three of slope, offset and power, and the luminance mix, which is the one case the
    /// generator's own header calls hard.
    private var cases: [(String, Look.Correct)] {
        [
            ("exposure", .init(exposure: 0.8)),
            ("cool and green", .init(temp: -0.4, tint: 0.3)),
            ("a full CDL", .init(slope: "1.1,0.95,1.02", offset: "0.01,-0.02,0.005",
                                 power: "0.9,1.0,1.15")),
            ("luminance mix at zero", .init(exposure: 0.5, temp: 0.4, lumMix: 0)),
            ("everything at once", .init(exposure: -0.6, temp: 0.5, tint: -0.2,
                                         slope: "0.9,1.05,1.1", offset: "-0.01,0.02,0",
                                         power: "1.2,0.95,1", lumMix: 0.4)),
        ]
    }

    func testItIsTheSameCubeTheEngineGenerates() throws {
        let engine = try engineCheckout()
        for (name, correct) in cases {
            let mine = try XCTUnwrap(CorrectionCube.cube(for: correct, size: 33),
                                     "\(name): the port refused a correction the engine accepts")
            let theirs = try Cube3D.fromGenerator(engine.correctGenerator,
                                                  arguments: correct.generatorArguments(size: 33))
            XCTAssertEqual(mine.size, theirs.size, "\(name): different grids")
            XCTAssertEqual(mine.samples.count, theirs.samples.count, "\(name): different counts")
            var worst = 0.0
            var worstAt = 0
            for i in 0..<min(mine.samples.count, theirs.samples.count) {
                let d = (mine.samples[i] - theirs.samples[i])
                let m = max(abs(Double(d.x)), max(abs(Double(d.y)), abs(Double(d.z))))
                if m > worst { worst = m; worstAt = i }
            }
            // 1.2e-7 rather than zero, and the figure is not arbitrary: samples are held as
            // Float, whose spacing near 1.0 is 2^-24, or 5.96e-8. The measured worst difference
            // across every case here is exactly that — one unit in the last place — so the bound
            // is two of them. Anything a person could change about the maths moves a sample by
            // far more than that.
            XCTAssertLessThan(worst, 1.2e-7,
                              "\(name): sample \(worstAt) differs by \(worst)")
        }
    }

    /// The engine's generator refuses a non-positive power and a malformed triple. So does this,
    /// rather than rendering something arbitrary from a value the render would reject.
    func testItRefusesWhatTheGeneratorRefuses() {
        XCTAssertNil(CorrectionCube.cube(for: .init(power: "0,1,1"), size: 33),
                     "a zero power is refused by the generator")
        XCTAssertNil(CorrectionCube.cube(for: .init(slope: "1,1"), size: 33),
                     "a two-value triple is refused by the generator")
        XCTAssertNil(CorrectionCube.cube(for: .init(offset: "nope"), size: 33))
    }

    /// The published transfer function's two measured properties, which are what make the port
    /// exact rather than fitted. Both are stated in the generator's header.
    func testTheTransferFunctionRoundTripsAndPeaksAtTwelve() {
        XCTAssertEqual(CorrectionCube.decode(1.0), 12.0, accuracy: 0.0001,
                       "decode(1.0) is 12x diffuse white, about 3.6 stops of headroom")
        for i in 0...100 {
            let p = Double(i) / 100
            XCTAssertEqual(CorrectionCube.encode(CorrectionCube.decode(p)), p, accuracy: 1e-12,
                           "the transfer function does not round-trip at \(p)")
        }
    }
}

/// The Swift tone curve and gamma solve against the engine's, entry for entry.
///
/// Same licence as `CorrectionCubeTests`: these are the other two places the app computes the
/// image instead of reading it, and they exist because a subprocess per slider tick is a control
/// you cannot drag. Neither is a tolerance test on a sample of points.
final class ToneCurvePortTests: XCTestCase {
    /// The shipped curve, a neutral one, and one at each end of every slider's range, because the
    /// toe and shoulder branches only separate away from the defaults.
    private var cases: [(String, Look.Tone)] {
        [
            ("shipped", .init(gamma: 2.02, pivot: 0.39, contrast: 1.09, toe: 0, shoulder: 0.1,
                              black: 0.025)),
            ("neutral", .init(gamma: 1, pivot: 0.39, contrast: 1, toe: 0, shoulder: 0, black: 0)),
            ("deep toe", .init(gamma: 1.4, pivot: 0.25, contrast: 1.6, toe: 0.8, shoulder: 0,
                               black: -0.08)),
            ("hard shoulder", .init(gamma: 2.6, pivot: 0.65, contrast: 0.8, toe: 0, shoulder: 0.8,
                                    black: 0.08)),
            ("both", .init(gamma: 1.8, pivot: 0.5, contrast: 1.3, toe: 0.5, shoulder: 0.5,
                           black: 0.02)),
        ]
    }

    func testItIsTheSameCurveTheEngineGenerates() throws {
        let engine = try engineCheckout()
        for (name, tone) in cases {
            let theirs = try ToneCurve.generate(using: engine.toneGenerator, tone: tone)
            let mine = ToneCurve.generated(tone: tone)
            XCTAssertEqual(mine.samples.count, theirs.samples.count, "\(name): different lengths")
            var worst = 0.0, worstAt = 0
            for i in 0..<min(mine.samples.count, theirs.samples.count) {
                let d = abs(mine.samples[i] - theirs.samples[i])
                if d > worst { worst = d; worstAt = i }
            }
            // The generator prints eight decimals, so half of the last place is the floor.
            XCTAssertLessThan(worst, 5e-9, "\(name): entry \(worstAt) differs by \(worst)")
        }
    }

    func testItSolvesTheSameGammaTheEngineSolves() throws {
        let engine = try engineCheckout()
        // Both clamps, both domain guards, and ordinary values in between.
        let probes: [(Double, Double, Double)] = [
            (479, 609, 2.02), (609, 609, 2.02), (100, 609, 2.02), (1000, 609, 2.02),
            (0, 609, 2.02), (1023, 609, 2.02), (479, 0, 2.02), (300, 900, 1.5),
        ]
        for (clip, reference, gamma) in probes {
            let theirs = ToneCurve.solvedGamma(using: engine.gammaSolver, clipYAVG: clip,
                                               referenceYAVG: reference, referenceGamma: gamma)
            let mine = ToneCurve.solvedGamma(clipYAVG: clip, referenceYAVG: reference,
                                             referenceGamma: gamma)
            // The solver prints three decimals, which is the comparison's floor.
            XCTAssertEqual(mine, theirs, accuracy: 5e-4,
                           "clip \(clip) against \(reference) at gamma \(gamma)")
        }
    }
}
