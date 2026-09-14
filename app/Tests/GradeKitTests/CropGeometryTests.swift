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

    /// The box drawn on the picture must be the window the engine crops, so this ASKS the engine.
    /// It used to recompute `crop_prefix`'s arithmetic in Swift, which proved only that two Swift
    /// expressions agreed and would have stayed green through a change to lib.sh. The two had
    /// already drifted once: the interface defaulted to 4:5 and drew a Feed box over every
    /// deliverable until a deliverable could be any shape.
    ///
    /// Odd widths are in the set because the round-down-to-even step is where a port goes wrong.
    func testTheWindowMatchesWhatTheEngineWouldCrop() throws {
        let engine = try engineCheckout()
        let shapes = [Deliverable.reels, .feed,
                      Deliverable(name: "square", aspectWidth: 1, aspectHeight: 1),
                      Deliverable(name: "tall", aspectWidth: 2, aspectHeight: 3)]
        for (width, height) in [(2160, 3840), (1081, 3840)] {
            for deliverable in shapes {
                let label = "\(deliverable.name) on \(width)x\(height)"
                let geometry = CropGeometry(sourceWidth: width, sourceHeight: height,
                                            aspectWidth: deliverable.aspectWidth,
                                            aspectHeight: deliverable.aspectHeight)
                let aspect = [String(deliverable.aspectWidth), String(deliverable.aspectHeight)]

                let tall = try libSh(engine, "deliverable_height", [String(width)] + aspect)
                XCTAssertEqual(tall.status, 0, "\(label): \(tall.stderr)")
                XCTAssertEqual(Int(tall.stdout.trimmingCharacters(in: .whitespacesAndNewlines)),
                               geometry.windowHeight,
                               "\(label): the box is not the height the engine gives this shape")

                // The last offset the picker allows must be one the engine accepts, and one past
                // it one the engine refuses — that refusal, seconds into a render, is what the
                // clamp exists to move forward.
                let size = [String(width), String(height)] + aspect
                let last = try libSh(engine, "crop_prefix", size + [String(geometry.maximumOffset)])
                guard last.status == 0 else {
                    XCTFail("\(label): the last legal offset was refused: \(last.stderr)")
                    continue
                }
                if last.stdout.isEmpty {
                    XCTAssertEqual(geometry.windowHeight, height,
                                   "\(label): the engine crops nothing, so the box must be the frame")
                } else {
                    XCTAssertEqual(last.stdout,
                                   "crop=\(width):\(geometry.windowHeight):0:\(geometry.maximumOffset),\n",
                                   "\(label): the box is not the window the engine crops")
                    let past = try libSh(engine, "crop_prefix",
                                         size + [String(geometry.maximumOffset + 1)])
                    XCTAssertNotEqual(past.status, 0,
                                      "\(label): the engine took an offset the picker forbids")
                    XCTAssertTrue(past.stderr.contains("outside 0..\(geometry.maximumOffset)"),
                                  "\(label): refused for another reason: \(past.stderr)")
                }
            }
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
