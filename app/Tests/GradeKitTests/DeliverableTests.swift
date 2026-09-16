import XCTest

@testable import GradeKit

/// A deliverable used to be two booleans here and a two-branch `case` in the engine, so the set of
/// shapes this tool can produce was closed at two. These cover the replacement, and in particular
/// the two things that would break quietly: the filenames existing deliverables already have, and
/// the project files already on disk.
final class DeliverableTests: XCTestCase {
    // MARK: - The engine contract

    func testAPresetGoesToTheEngineAsItsBareName() throws {
        // THE FILENAME-STABILITY GUARD. The engine's presets carry output suffixes an arbitrary
        // spec cannot reproduce — `reels-stories_9x16`, `feed_4x5` — so emitting the expanded
        // `reels:9:16` would silently start writing `reels_9x16.mp4` beside somebody's existing
        // files. Nothing else in the suite would notice; the render would succeed.
        XCTAssertEqual(Deliverable.reels.spec, "reels")
        XCTAssertEqual(Deliverable.feed.spec, "feed")
    }

    /// A preset's shape is written twice, here and in `deliverable_spec`, and the engine's copy is
    /// the one that renders. Emitting the bare name (above) is what makes a drift silent: the app
    /// would draw and validate a crop for one aspect while the engine rendered another. So every
    /// spec this type produces goes through the engine and has to come back as the same shape.
    func testTheEngineReadsEverySpecAsTheShapeTheAppMeans() throws {
        let engine = try engineCheckout()
        let square = Deliverable(name: "square", aspectWidth: 1, aspectHeight: 1)
        for deliverable in Deliverable.presets + [square] {
            let resolved = try libSh(engine, "deliverable_spec", [deliverable.spec])
            XCTAssertEqual(
                resolved.status, 0,
                "the engine refused \(deliverable.spec): \(resolved.stderr)")
            let fields = resolved.stdout.split(separator: " ").map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            XCTAssertEqual(fields.count, 5, "unexpected spec output: \(resolved.stdout)")
            guard fields.count == 5 else { continue }
            XCTAssertEqual(fields[0], deliverable.name)
            XCTAssertEqual(
                fields[1...2],
                [
                    String(deliverable.aspectWidth),
                    String(deliverable.aspectHeight),
                ],
                "\(deliverable.name): the engine renders a different aspect")
        }
    }

    func testAShapeThatIsNotAPresetCarriesItsAspect() throws {
        let square = Deliverable(name: "square", aspectWidth: 1, aspectHeight: 1)
        XCTAssertEqual(square.spec, "square:1:1")
    }

    func testWhetherAShapeCropsIsDecidedByTheClipNotByName() throws {
        let portrait = FrameSize(width: 2160, height: 3840)
        let landscape = FrameSize(width: 3840, height: 2160)
        let wide = Deliverable(name: "wide", aspectWidth: 16, aspectHeight: 9)
        XCTAssertFalse(Deliverable.reels.crops(portrait))
        XCTAssertTrue(Deliverable.feed.crops(portrait))
        XCTAssertTrue(wide.crops(portrait))
        XCTAssertTrue(Deliverable.reels.crops(landscape), "9:16 is a crop of a landscape clip")
        XCTAssertFalse(wide.crops(landscape))
        // 18:32 IS 9:16. A name-based test would call this a crop and make the interface demand a
        // crop offset for a shape that takes the whole frame, which blocks Convert on a question
        // with no answer.
        let sameRatio = Deliverable(name: "tall", aspectWidth: 18, aspectHeight: 32)
        XCTAssertFalse(sameRatio.crops(portrait), "18:32 is 9:16, so it takes the whole frame")
        // Unmeasured is answered as a 9:16 master, so an unpreviewed clip does not block reels.
        XCTAssertFalse(Deliverable.reels.crops(nil))
        XCTAssertTrue(Deliverable.feed.crops(nil))
    }

    func testALandscapeClipIsNamedAsUnframedForReels() throws {
        let project = Project(
            presets: [.init(name: "p", look: try lookFixture())],
            activePreset: "p", delivery: .init(targets: [.reels]))
        let sizes = [
            "WIDE": FrameSize(width: 3840, height: 2160),
            "TALL": FrameSize(width: 2160, height: 3840),
        ]
        XCTAssertEqual(
            project.unframed(for: ["WIDE", "TALL"], sizes: sizes),
            .init(deliverables: [.reels], clips: ["WIDE"]),
            "only the landscape clip has a window to place")
    }

    func testTheEnvironmentNamesEveryDeliverableAndNoLongerNamesFEED() throws {
        var project = Project(
            presets: [], activePreset: "",
            delivery: .init(targets: [.reels, .feed]))
        project.clips["IMG_0609"] = .init(cropOffset: 600)
        let env = project.environment(
            for: "IMG_0609",
            lookFile: URL(fileURLWithPath: "/tmp/look.json"))
        XCTAssertEqual(env["DELIVERABLES"], "reels,feed")
        // FEED was removed from the engine, not aliased. An app still setting it would be asking
        // for a deliverable nothing renders, and the run would succeed while producing one file
        // where two were expected.
        XCTAssertNil(env["FEED"], "FEED no longer exists in the engine")
    }

    func testACustomShapeReachesTheEngineThroughTheSameVariable() throws {
        let project = Project(
            presets: [], activePreset: "",
            delivery: .init(targets: [
                .reels,
                .init(
                    name: "square", aspectWidth: 1,
                    aspectHeight: 1),
            ]))
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
        // A custom shape has no checkbox, so ticking a preset is not a moment anyone is watching
        // it, and losing it here would be silent.
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
        let project = Project(
            presets: [], activePreset: "",
            delivery: .init(targets: [.reels, square], height: 1920))
        let reread = try Project(data: try project.serialised())
        XCTAssertEqual(reread.delivery.targets, [.reels, square])
    }

    // What blocks a render is `ProjectTests.testACroppedRenderIsBlockedUntilEveryClipHasAnOffset`,
    // which covers both the shape that crops and the one that does not. Two tests here repeated it.

    // MARK: - A shape carrying its own offset

    func testACentreShapeSaysSoInItsSpecAndAnUnoffsetOneDoesNot() throws {
        let centred = Deliverable(
            name: "square", aspectWidth: 1, aspectHeight: 1,
            cropOffset: .centre)
        XCTAssertEqual(centred.spec, "square:1:1:centre")
        XCTAssertEqual(
            Deliverable(name: "square", aspectWidth: 1, aspectHeight: 1).spec,
            "square:1:1")
    }

    /// The engine lets a deliverable's own offset beat `CROP_OFFSET`, so a `centre` shape has nothing
    /// for a clip to decide, while one without an offset still takes the clip's.
    func testOnlyAShapeWithoutItsOwnOffsetWaitsForTheClip() throws {
        let centred = Deliverable(
            name: "square", aspectWidth: 1, aspectHeight: 1,
            cropOffset: .centre)
        var project = Project(
            presets: [.init(name: "p", look: try lookFixture())],
            activePreset: "p", delivery: .init(targets: [centred]))
        XCTAssertEqual(
            project.unframed(for: ["IMG_0609"]), nil,
            "a centred shape warned about a framing it ignores")
        project.delivery.targets.append(.feed)
        XCTAssertEqual(
            project.unframed(for: ["IMG_0609"]),
            .init(deliverables: [.feed], clips: ["IMG_0609"]),
            "the warning must name only the shape that takes the clip's offset")
    }

    func testTheEngineReadsACentreShapeAsCentred() throws {
        let engine = try engineCheckout()
        let centred = Deliverable(
            name: "square", aspectWidth: 1, aspectHeight: 1,
            cropOffset: .centre)
        XCTAssertEqual(
            engine.resolveDeliverable(name: centred.name, spec: centred.spec),
            .resolved(
                .init(
                    name: "square", aspectWidth: "1", aspectHeight: "1",
                    offset: "centre", suffix: "square_1x1")))
    }

    /// Both directions, because a serialiser that dropped the key would read every shape back as
    /// nil and still pass a test that only saves shapes without one.
    func testACentreOffsetSurvivesTheProjectFileAndItsAbsenceReadsAsNone() throws {
        let centred = Deliverable(
            name: "square", aspectWidth: 1, aspectHeight: 1,
            cropOffset: .centre)
        let plain = Deliverable(name: "tall", aspectWidth: 2, aspectHeight: 3)
        let project = Project(
            presets: [], activePreset: "",
            delivery: .init(targets: [.reels, centred, plain]))
        let reread = try Project(data: try project.serialised())
        XCTAssertEqual(reread.delivery.targets, [.reels, centred, plain])

        // Written before a shape could carry an offset: every shape then followed the clip's offset.
        let older = """
            {"version": 2, "presets": [], "active_preset": "",
             "delivery": {"targets": [{"name": "square", "aspect_width": 1, "aspect_height": 1}]},
             "clips": {}}
            """
        let opened = try Project(data: Data(older.utf8))
        XCTAssertEqual(
            opened.delivery.targets,
            [Deliverable(name: "square", aspectWidth: 1, aspectHeight: 1)])
    }
}
