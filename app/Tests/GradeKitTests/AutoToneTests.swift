import XCTest

@testable import GradeKit

final class AutoToneTests: XCTestCase {
    /// A histogram with a single spike at `level` (0...255), the rest empty.
    private func spike(at level: Int, count: Int = 1000) -> Scopes {
        var luma = [Int](repeating: 0, count: 256)
        luma[level] = count
        return Scopes(
            luma: luma, red: luma, green: luma, blue: luma, vector: [], sampleCount: count)
    }

    /// An even ramp across the whole range, one pixel per level.
    private func ramp() -> Scopes {
        let luma = [Int](repeating: 1, count: 256)
        return Scopes(luma: luma, red: luma, green: luma, blue: luma, vector: [], sampleCount: 256)
    }

    func testAWellExposedRampIsNearNoOp() throws {
        let solved = try XCTUnwrap(AutoTone.solve(histogram: ramp()))
        // The ramp's 0.5th/99.5th percentiles sit near the ends already, so there's little to do.
        XCTAssertEqual(solved.exposure, 0, accuracy: 0.3)
        XCTAssertEqual(solved.contrast, 1, accuracy: 0.15)
    }

    func testCrushedShadowsGetLifted() throws {
        // Everything sits at pure black: nothing to read detail from without a lift.
        let solved = try XCTUnwrap(AutoTone.solve(histogram: spike(at: 0)))
        XCTAssertGreaterThan(solved.black, 0)
    }

    func testShadowsAlreadyAboveTheFloorAreNotLiftedFurther() throws {
        // A flat, hazy frame: nothing near true black, so no extra lift is warranted.
        let solved = try XCTUnwrap(AutoTone.solve(histogram: spike(at: 128)))
        XCTAssertEqual(solved.black, 0)
    }

    func testBlownHighlightsLowerExposure() throws {
        // Almost everything pinned to white: bring it down toward the target white level.
        var luma = [Int](repeating: 0, count: 256)
        luma[20] = 10
        luma[255] = 990
        let histogram = Scopes(
            luma: luma, red: luma, green: luma, blue: luma, vector: [], sampleCount: 1000)
        let solved = try XCTUnwrap(AutoTone.solve(histogram: histogram))
        XCTAssertLessThan(solved.exposure, 0)
    }

    func testAnEmptyHistogramSolvesToNothing() {
        let empty = Scopes(luma: [], red: [], green: [], blue: [], vector: [], sampleCount: 0)
        XCTAssertNil(AutoTone.solve(histogram: empty))
    }

    func testSolvedValuesStayWithinRange() throws {
        let solved = try XCTUnwrap(AutoTone.solve(histogram: spike(at: 0)))
        XCTAssertTrue(AutoTone.exposureRange.contains(solved.exposure))
        XCTAssertTrue(AutoTone.blackRange.contains(solved.black))
        XCTAssertTrue(AutoTone.contrastRange.contains(solved.contrast))
    }
}
