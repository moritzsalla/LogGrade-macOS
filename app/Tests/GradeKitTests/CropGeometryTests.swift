import XCTest
@testable import GradeKit

final class CropGeometryTests: XCTestCase {
    /// This camera's master, and the numbers the engine uses.
    private let master = CropGeometry(sourceWidth: 2160, sourceHeight: 3840)

    func testTheWindowMatchesWhatTheEngineCrops() {
        // The engine builds crop=<src_w>:<src_w * 5/4>:0:<offset>, which is 2160x2700 here.
        XCTAssertEqual(master.windowHeight, 2700)
        XCTAssertEqual(master.maximumOffset, 1140)
        XCTAssertTrue(master.isValid(0))
        XCTAssertTrue(master.isValid(1140))
        XCTAssertFalse(master.isValid(1141), "one pixel past the edge fails inside ffmpeg")
        XCTAssertFalse(master.isValid(-1))
    }

    func testTheWindowIsAlwaysEven() {
        // libx264 rejects an odd dimension, and it rejects it at encode time — after the graph is
        // built and the first frames decoded.
        for width in [1079, 1081, 2159, 3841] {
            let g = CropGeometry(sourceWidth: width, sourceHeight: 4000)
            XCTAssertEqual(g.windowHeight % 2, 0, "odd window for width \(width)")
        }
    }

    func testADragMapsToMasterPixelsAndClamps() {
        // A quarter of the way down a 3840-tall master is 960.
        XCTAssertEqual(master.offset(forFraction: 0.25), 960)
        XCTAssertEqual(master.offset(forFraction: 0), 0)
        // Past the bottom clamps to the last legal offset rather than producing one the engine
        // would refuse seconds into a render.
        XCTAssertEqual(master.offset(forFraction: 0.9), 1140)
        XCTAssertEqual(master.offset(forFraction: -1), 0)
    }

    func testTheBoxIsDrawnAsAFractionOfTheFrame() {
        XCTAssertEqual(master.windowFraction, 2700.0 / 3840.0, accuracy: 1e-9)
        XCTAssertEqual(master.fraction(forOffset: 1140), 1140.0 / 3840.0, accuracy: 1e-9)
        // Drawing and reading back agree, or the box sits somewhere the render does not.
        for offset in [0, 375, 750, 1140] {
            XCTAssertEqual(master.offset(forFraction: master.fraction(forOffset: offset)), offset)
        }
    }

    func testAnotherAspectMovesTheWindow() {
        let square = CropGeometry(sourceWidth: 2160, sourceHeight: 3840,
                                  aspectWidth: 1, aspectHeight: 1)
        XCTAssertEqual(square.windowHeight, 2160)
        XCTAssertEqual(square.maximumOffset, 1680)
    }
}
