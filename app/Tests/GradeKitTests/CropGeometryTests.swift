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

    func testALandscapeClipMovesTheWindowSideways() {
        let wide = CropGeometry(sourceWidth: 3840, sourceHeight: 2160, aspectWidth: 9, aspectHeight: 16)
        XCTAssertEqual(wide.axis, .x)
        XCTAssertEqual(wide.windowWidth, 1214)
        XCTAssertEqual(wide.windowHeight, 2160)
        XCTAssertEqual(wide.maximumOffset, 2626)
        XCTAssertEqual(wide.windowFraction, 1214.0 / 3840.0, accuracy: 1e-9)
        XCTAssertEqual(wide.offset(forFraction: 0.25), 960, "a quarter of 3840 across")
        XCTAssertFalse(CropGeometry(sourceWidth: 3840, sourceHeight: 2160,
                                    aspectWidth: 16, aspectHeight: 9).crops)
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
        for (width, height) in [(2160, 3840), (1081, 3840), (3840, 2160), (3840, 2161)] {
            for deliverable in shapes {
                let label = "\(deliverable.name) on \(width)x\(height)"
                let geometry = CropGeometry(sourceWidth: width, sourceHeight: height,
                                            aspectWidth: deliverable.aspectWidth,
                                            aspectHeight: deliverable.aspectHeight)
                let aspect = [String(deliverable.aspectWidth), String(deliverable.aspectHeight)]

                let window = try libSh(engine, "crop_window",
                                       [String(width), String(height)] + aspect)
                XCTAssertEqual(window.status, 0, "\(label): \(window.stderr)")
                XCTAssertEqual(window.stdout,
                               "\(geometry.windowWidth) \(geometry.windowHeight) "
                               + (geometry.axis == .y ? "y" : "x") + "\n",
                               "\(label): the box is not the window the engine gives this shape")

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
                    XCTAssertFalse(geometry.crops,
                                   "\(label): the engine crops nothing, so the box must be the frame")
                } else {
                    XCTAssertEqual(last.stdout, geometry.filter(at: geometry.maximumOffset),
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
        let portrait = FrameSize(width: 2160, height: 3840)
        var delivery = Project.Delivery(targets: [.reels, .feed, square])
        XCTAssertEqual(delivery.cropBoxTarget(portrait), .feed,
                       "reels does not crop a 9:16 master, so it must not claim the box")
        XCTAssertEqual(delivery.cropBoxTarget(FrameSize(width: 3840, height: 2160)), .reels,
                       "reels crops a landscape clip, so it is the first box")
        delivery = Project.Delivery(targets: [.reels])
        XCTAssertNil(delivery.cropBoxTarget(portrait), "nothing crops, so there is no box to draw")
    }

    /// A `centre` shape is out of the blocker and still in the picture. The first version of the
    /// editor took it out of both with one predicate, so a centred square cropped the render with
    /// no box to show where, and the panel said nothing selected crops.
    func testACentreShapeStillHasABoxButTheClipFramedOneOwnsIt() {
        let centred = Deliverable(name: "square", aspectWidth: 1, aspectHeight: 1,
                                  cropOffset: .centre)
        var delivery = Project.Delivery(targets: [.reels, centred])
        let portrait = FrameSize(width: 2160, height: 3840)
        XCTAssertTrue(delivery.anyTargetCrops(portrait))
        XCTAssertFalse(delivery.anyTargetNeedsClipOffset(portrait))
        XCTAssertEqual(delivery.cropBoxTarget(portrait), centred, "a centred crop lost its box")
        delivery = Project.Delivery(targets: [centred, .feed])
        XCTAssertEqual(delivery.cropBoxTarget(portrait), .feed,
                       "the box that has to be dragged gave way to one that cannot be")
    }

    /// The fixed box for a `centre` shape is drawn where the engine puts it, so this asks the
    /// engine. The slacks are chosen so that half of one is odd and one is itself odd, because the
    /// round-down-to-even step is the part a copy gets wrong.
    func testTheCentreBoxIsWhereTheEngineCentres() throws {
        let engine = try engineCheckout()
        let cases = [(2160, 3840, 4, 5), (2160, 3842, 4, 5), (2160, 3841, 4, 5),
                     (1081, 3840, 4, 5), (2160, 3840, 1, 1),
                     (3840, 2160, 9, 16), (3841, 2160, 9, 16), (3840, 2160, 4, 5)]
        for (width, height, aw, ah) in cases {
            let label = "\(aw):\(ah) on \(width)x\(height)"
            let geometry = CropGeometry(sourceWidth: width, sourceHeight: height,
                                        aspectWidth: aw, aspectHeight: ah)
            let ran = try libSh(engine, "crop_prefix",
                                [width, height, aw, ah].map(String.init) + ["centre"])
            XCTAssertEqual(ran.status, 0, "\(label): \(ran.stderr)")
            XCTAssertEqual(ran.stdout, geometry.filter(at: geometry.centreOffset),
                           "\(label): the centred box is not where the engine crops")
        }
    }
}
