import XCTest

@testable import GradeKit

/// The Swift hue curves against the generator's, number for number, as `CorrectionCubeTests` holds
/// the correction: every sample of the whole cube, to the eight places the generator prints.
final class HueCubeTests: XCTestCase {
    private var cases: [(String, Look.Hue)] {
        [
            (
                "greens pulled down and turned",
                .init(
                    rot: "0,0,0,0,-15,-10,0,0,0,0,0,0", sat: "0,0,0,0,-0.6,-0.6,0,0,0,0,0,0")
            ),
            // A doubled chroma everywhere drives saturated colour out of gamut, so the fit runs.
            (
                "everything saturated and turned",
                .init(
                    rot: "20,-20,20,-20,20,-20,20,-20,20,-20,20,-20",
                    sat: "1,1,1,1,1,1,1,1,1,1,1,1", lum: "0.5,-0.5,0.3,0,0,0,0,0,0,0,-0.2,0.1")
            ),
            // A knot at zero hue, so the wrap between the last span and the first is exercised.
            ("reds lightened across the wrap", .init(lum: "0.4,0,0,0,0,0,0,0,0,0,0,0.2")),
        ]
    }

    func testItIsTheSameCubeTheEngineGenerates() throws {
        let generator = try engineCheckout().root.appendingPathComponent("scripts/make-hue-lut.py")
        for (name, hue) in cases {
            let mine = try XCTUnwrap(HueCube.cube(for: hue, size: 17), "\(name): refused")
            let theirs = try Cube3D.fromGenerator(
                generator, arguments: hue.generatorArguments(size: 17))
            XCTAssertEqual(mine.samples.count, theirs.samples.count, "\(name): different counts")
            var worst = 0.0
            for i in 0..<min(mine.samples.count, theirs.samples.count) {
                let d = mine.samples[i] - theirs.samples[i]
                worst = max(worst, max(abs(Double(d.x)), max(abs(Double(d.y)), abs(Double(d.z)))))
            }
            // Two units of Float's spacing near 1.0, as in CorrectionCubeTests.
            XCTAssertLessThan(worst, 1.2e-7, "\(name): worst sample differs by \(worst)")
        }
    }

    /// The generator refuses a wrong count and a knot past its bound; so does this.
    func testItRefusesWhatTheGeneratorRefuses() {
        XCTAssertNil(HueCube.cube(for: .init(sat: "0,0,0"), size: 5))
        XCTAssertNil(HueCube.cube(for: .init(rot: "61,0,0,0,0,0,0,0,0,0,0,0"), size: 5))
        XCTAssertNil(HueCube.cube(for: .init(lum: "x,0,0,0,0,0,0,0,0,0,0,0"), size: 5))
    }

    /// Setting a knot writes the text the engine reads, and a curve returned to zero is neutral
    /// again, so the stage leaves the graph.
    func testAKnotRoundTripsAndFlatIsNeutral() {
        var hue = Look.Hue()
        XCTAssertTrue(hue.isNeutral)
        hue.setValue(.sat, 4, -0.5)
        XCTAssertEqual(hue.sat, "0,0,0,0,-0.5,0,0,0,0,0,0,0")
        XCTAssertFalse(hue.isNeutral)
        hue.setValue(.sat, 4, 0)
        XCTAssertTrue(hue.isNeutral, "a knot dragged back to zero left the stage in")
        hue.setValue(.rot, 0, 500)
        XCTAssertEqual(hue.value(.rot, 0), 60, "a knot past its bound was not clamped")
    }
}
