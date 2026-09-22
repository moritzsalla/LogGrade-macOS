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
    /// Corrections chosen to reach every branch.
    private var cases: [(String, Look.Correct)] {
        [
            ("exposure", .init(exposure: 0.8)),
            ("cool and green", .init(temp: -0.4, tint: 0.3)),
            ("contrast and saturation", .init(contrast: 1.6, saturation: 0.7)),
            (
                "everything at once",
                .init(exposure: -0.6, temp: 0.5, tint: -0.2, contrast: 0.85, saturation: 1.4)
            ),
        ]
    }

    func testItIsTheSameCubeTheEngineGenerates() throws {
        let engine = try engineCheckout()
        for (name, correct) in cases {
            let mine = try XCTUnwrap(
                CorrectionCube.cube(for: correct, size: 33),
                "\(name): the port refused a correction the engine accepts")
            let theirs = try Cube3D.fromGenerator(
                engine.correctGenerator,
                arguments: correct.generatorArguments(size: 33))
            XCTAssertEqual(mine.size, theirs.size, "\(name): different grids")
            XCTAssertEqual(mine.samples.count, theirs.samples.count, "\(name): different counts")
            var worst = 0.0
            var worstAt = 0
            for i in 0..<min(mine.samples.count, theirs.samples.count) {
                let d = (mine.samples[i] - theirs.samples[i])
                let m = max(abs(Double(d.x)), max(abs(Double(d.y)), abs(Double(d.z))))
                if m > worst {
                    worst = m
                    worstAt = i
                }
            }
            // 1.2e-7 rather than zero, and the figure is not arbitrary: samples are held as
            // Float, whose spacing near 1.0 is 2^-24, or 5.96e-8. The measured worst difference
            // across every case here is exactly that — one unit in the last place — so the bound
            // is two of them. Anything a person could change about the maths moves a sample by
            // far more than that.
            XCTAssertLessThan(
                worst, 1.2e-7,
                "\(name): sample \(worstAt) differs by \(worst)")
        }
    }

    /// The published transfer function's two measured properties, which are what make the port
    /// exact rather than fitted. Both are stated in the generator's header.
    func testTheTransferFunctionRoundTripsAndPeaksAtTwelve() {
        XCTAssertEqual(
            CorrectionCube.decode(1.0), 12.0, accuracy: 0.0001,
            "decode(1.0) is 12x diffuse white, about 3.6 stops of headroom")
        for i in 0...100 {
            let p = Double(i) / 100
            XCTAssertEqual(
                CorrectionCube.encode(CorrectionCube.decode(p)), p, accuracy: 1e-12,
                "the transfer function does not round-trip at \(p)")
        }
    }
}
