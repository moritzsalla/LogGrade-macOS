import XCTest
@testable import GradeKit

/// A deliverable used to be two booleans here and a two-branch `case` in the engine, so the set of
/// shapes this tool can produce was closed at two. These cover the replacement, and in particular
/// the two things that would break quietly: the filenames existing deliverables already have, and
/// the project files already on disk.
final class DeliverableTests: XCTestCase {
    /// A project needs a preset that resolves, or `blockers` reports the missing one and the
    /// assertions below read as failures of the thing they are actually testing.
    private func aProject(targets: [Deliverable], height: Int = 1920) throws -> Project {
        let json = #"""
        {"correct":{"exposure":0,"temp":0,"tint":0,"slope":"1,1,1","offset":"0,0,0",
         "power":"1,1,1","lum_mix":1},"look":{"lut":"kodak_portra_400_nc"},
         "tone":{"gamma":2.02,"pivot":0.39,"contrast":1.09,"toe":0,"shoulder":0.1,"black":0.025},
         "colour":{"saturation":1.27,"warmth":0.005},"grain":{"strength":8},
         "stabilisation":{"smoothing":30},"match":{"reference_yavg":609}}
        """#
        let look = try Look(data: Data(json.utf8))
        return Project(presets: [.init(name: "P", look: look)], activePreset: "P",
                       delivery: .init(targets: targets, height: height))
    }

    // MARK: - The engine contract

    func testAPresetGoesToTheEngineAsItsBareName() throws {
        // THE FILENAME-STABILITY GUARD. The engine's presets carry output suffixes an arbitrary
        // spec cannot reproduce — `reels-stories_9x16`, `feed_4x5` — so emitting the expanded
        // `reels:9:16` would silently start writing `reels_9x16.mp4` beside somebody's existing
        // files. Nothing else in the suite would notice; the render would succeed.
        XCTAssertEqual(Deliverable.reels.spec, "reels")
        XCTAssertEqual(Deliverable.feed.spec, "feed")
    }

    func testAShapeThatIsNotAPresetCarriesItsAspect() throws {
        let square = Deliverable(name: "square", aspectWidth: 1, aspectHeight: 1)
        XCTAssertEqual(square.spec, "square:1:1")
    }

    func testWhetherAShapeCropsIsDecidedByRatioNotByName() throws {
        XCTAssertFalse(Deliverable.reels.cropsPortraitMaster)
        XCTAssertTrue(Deliverable.feed.cropsPortraitMaster)
        // 18:32 IS 9:16. A name-based test would call this a crop and make the interface demand a
        // crop offset for a shape that takes the whole frame, which blocks Convert on a question
        // with no answer.
        let sameRatio = Deliverable(name: "tall", aspectWidth: 18, aspectHeight: 32)
        XCTAssertFalse(sameRatio.cropsPortraitMaster,
                       "18:32 is 9:16, so it takes the whole frame")
        let landscape = Deliverable(name: "wide", aspectWidth: 16, aspectHeight: 9)
        XCTAssertTrue(landscape.cropsPortraitMaster)
    }

    func testTheEnvironmentNamesEveryDeliverableAndNoLongerNamesFEED() throws {
        var project = Project(presets: [], activePreset: "",
                              delivery: .init(targets: [.reels, .feed]))
        project.clips["IMG_0609"] = .init(cropOffset: 600)
        let env = project.environment(for: "IMG_0609",
                                      lookFile: URL(fileURLWithPath: "/tmp/look.json"))
        XCTAssertEqual(env["DELIVERABLES"], "reels,feed")
        // FEED was removed from the engine, not aliased. An app still setting it would be asking
        // for a deliverable nothing renders, and the run would succeed while producing one file
        // where two were expected.
        XCTAssertNil(env["FEED"], "FEED no longer exists in the engine")
    }

    func testACustomShapeReachesTheEngineThroughTheSameVariable() throws {
        let project = Project(presets: [], activePreset: "",
                              delivery: .init(targets: [.reels,
                                                        .init(name: "square", aspectWidth: 1,
                                                              aspectHeight: 1)]))
        let env = project.environment(for: "X", lookFile: URL(fileURLWithPath: "/tmp/look.json"))
        XCTAssertEqual(env["DELIVERABLES"], "reels,square:1:1")
    }

    // MARK: - Selection

    func testTickingAShapeBackOnRestoresItsPlaceInTheRenderOrder() throws {
        // Appending would make the render order depend on the order the boxes were clicked, so
        // unticking reels and ticking it again would move it behind feed. The order is what the
        // queue shows and what the engine works through.
        var delivery = Project.Delivery(targets: [.reels, .feed])
        delivery.setTarget(.reels, selected: false)
        XCTAssertEqual(delivery.targets, [.feed])
        delivery.setTarget(.reels, selected: true)
        XCTAssertEqual(delivery.targets, [.reels, .feed], "preset order, not click order")
    }

    func testSelectingSomethingAlreadySelectedChangesNothing() throws {
        var delivery = Project.Delivery(targets: [.reels])
        delivery.setTarget(.reels, selected: true)
        XCTAssertEqual(delivery.targets, [.reels])
    }

    func testAShapeWithNoCheckboxSurvivesSelectingOneThatHasOne() throws {
        // The interface has no editor for arbitrary aspects, so the only thing that must not
        // happen is losing one that a project file carries.
        let square = Deliverable(name: "square", aspectWidth: 1, aspectHeight: 1)
        var delivery = Project.Delivery(targets: [square])
        delivery.setTarget(.feed, selected: true)
        XCTAssertTrue(delivery.targets.contains(square), "a custom shape was dropped")
        XCTAssertTrue(delivery.targets.contains(.feed))
    }

    // MARK: - On disk

    func testAProjectWrittenBeforeTheSetOpenedUpStillOpens() throws {
        // Every project file written by the previous build carries this pair and no `targets`.
        // A reader that ignored them would open such a project showing the default — a delivery
        // nobody chose, replacing one somebody did.
        let legacy = """
        {"version": 1, "presets": [], "active_preset": "",
         "delivery": {"reels": true, "feed": true, "height": 2560}, "clips": {}}
        """
        let project = try Project(data: Data(legacy.utf8))
        XCTAssertEqual(project.delivery.targets, [.reels, .feed])
        XCTAssertEqual(project.delivery.height, 2560)
    }

    func testALegacyProjectWithFeedOffLoadsOnlyReels() throws {
        let legacy = """
        {"version": 1, "presets": [], "active_preset": "",
         "delivery": {"reels": true, "feed": false, "height": 1920}, "clips": {}}
        """
        let project = try Project(data: Data(legacy.utf8))
        XCTAssertEqual(project.delivery.targets, [.reels])
    }

    func testAnArbitraryShapeSurvivesTheProjectFile() throws {
        let square = Deliverable(name: "square", aspectWidth: 1, aspectHeight: 1)
        let project = Project(presets: [], activePreset: "",
                              delivery: .init(targets: [.reels, square], height: 1920))
        let reread = try Project(data: try project.serialised())
        XCTAssertEqual(reread.delivery.targets, [.reels, square])
    }

    // MARK: - What blocks a render

    func testTheRefusalNamesTheShapesThatActuallyCrop() throws {
        var project = try aProject(targets: [.reels, .feed])
        project.clips["A"] = .init(cropOffset: 750)
        project.clips["B"] = .init(cropOffset: nil)
        let blockers = project.blockers(for: ["A", "B"])
        XCTAssertEqual(blockers, [.cropWithoutOffset(deliverables: [.feed], clips: ["B"])],
                       "reels does not crop, so it must not appear in the refusal")
        XCTAssertTrue(blockers[0].description.contains("per-clip"),
                      "the reason is the point of the refusal: \(blockers[0].description)")
    }

    func testNothingThatCropsMeansNothingToAsk() throws {
        var project = try aProject(targets: [.reels])
        project.clips["A"] = .init(cropOffset: nil)
        XCTAssertTrue(project.blockers(for: ["A"]).isEmpty)
        XCTAssertFalse(project.delivery.anyTargetCrops)
    }
}
