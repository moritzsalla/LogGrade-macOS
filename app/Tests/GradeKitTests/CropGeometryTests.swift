import XCTest
@testable import GradeKit

final class CropGeometryTests: XCTestCase {
    /// This camera's master, and the numbers the engine uses.
    private let master = CropGeometry(sourceWidth: 2160, sourceHeight: 3840, aspectWidth: 4, aspectHeight: 5)

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
            let g = CropGeometry(sourceWidth: width, sourceHeight: 4000, aspectWidth: 4, aspectHeight: 5)
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

    /// The box drawn on the picture must be the window the engine crops. `crop_prefix` in lib.sh
    /// computes `ch = sw * ah / aw`, rounded down to even; this is the same arithmetic, and the
    /// test exists because the two can drift silently — the interface defaulted to 4:5 and drew a
    /// Feed box over every deliverable until a deliverable could be any shape.
    func testTheWindowMatchesWhatTheEngineWouldCrop() {
        for deliverable in [Deliverable.reels, .feed,
                            Deliverable(name: "square", aspectWidth: 1, aspectHeight: 1),
                            Deliverable(name: "wide", aspectWidth: 16, aspectHeight: 9)] {
            let geometry = CropGeometry(sourceWidth: 2160, sourceHeight: 3840,
                                        aspectWidth: deliverable.aspectWidth,
                                        aspectHeight: deliverable.aspectHeight)
            var expected = 2160 * deliverable.aspectHeight / deliverable.aspectWidth
            expected -= expected % 2
            XCTAssertEqual(geometry.windowHeight, expected,
                           "\(deliverable.name): the box is not the window the engine crops")
        }
    }

    /// Which shape the one box is drawn in when several crop. They share a single per-clip offset,
    /// so there is only one box to draw, and it follows the first cropping target.
    func testTheFirstCroppingTargetIsTheOneWithABox() {
        let square = Deliverable(name: "square", aspectWidth: 1, aspectHeight: 1)
        var delivery = Project.Delivery(targets: [.reels, .feed, square])
        XCTAssertEqual(delivery.croppingTargets.first, .feed,
                       "reels does not crop a 9:16 master, so it must not claim the box")
        delivery = Project.Delivery(targets: [.reels])
        XCTAssertNil(delivery.croppingTargets.first,
                     "nothing crops, so there is no box to draw")
    }
}
