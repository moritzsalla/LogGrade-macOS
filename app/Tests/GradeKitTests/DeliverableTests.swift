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
            XCTAssertEqual(resolved.status, 0,
                           "the engine refused \(deliverable.spec): \(resolved.stderr)")
            let fields = resolved.stdout.split(separator: " ").map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            XCTAssertEqual(fields.count, 5, "unexpected spec output: \(resolved.stdout)")
            guard fields.count == 5 else { continue }
            XCTAssertEqual(fields[0], deliverable.name)
            XCTAssertEqual(fields[1...2], [String(deliverable.aspectWidth),
                                           String(deliverable.aspectHeight)],
                           "\(deliverable.name): the engine renders a different aspect")
        }
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

    // What blocks a render is `ProjectTests.testACroppedRenderIsBlockedUntilEveryClipHasAnOffset`,
    // which covers both the shape that crops and the one that does not. Two tests here repeated it.

    // MARK: - Custom deliverable validation

    func testEmptyNameIsRefused() throws {
        XCTAssertEqual(Deliverable.validateName("", against: []), .emptyName)
    }

    func testNamesWithFilterSyntaxAreRefused() throws {
        let badChars = ["a/b", "a'b", "a\"b", "a,b", "a;b", "a[b", "a]b", "a\\b", "a:b"]
        for name in badChars {
            XCTAssertNotNil(Deliverable.validateName(name, against: []),
                           "\(name) should be refused")
        }
    }

    func testValidNameIsPassed() throws {
        XCTAssertNil(Deliverable.validateName("square", against: []))
        XCTAssertNil(Deliverable.validateName("tall_portrait", against: []))
        XCTAssertNil(Deliverable.validateName("test-name", against: []))
    }

    func testDuplicateNameIsRefused() throws {
        let existing = [Deliverable(name: "square", aspectWidth: 1, aspectHeight: 1)]
        XCTAssertEqual(Deliverable.validateName("square", against: existing), .duplicateName)
    }

    func testZeroOrNegativeAspectsAreRefused() throws {
        XCTAssertEqual(Deliverable.validateAspect(width: 0, height: 1), .zeroAspect)
        XCTAssertEqual(Deliverable.validateAspect(width: 1, height: 0), .zeroAspect)
        XCTAssertEqual(Deliverable.validateAspect(width: -1, height: 1), .zeroAspect)
        XCTAssertEqual(Deliverable.validateAspect(width: 1, height: -1), .zeroAspect)
    }

    func testValidAspectsArePassed() throws {
        XCTAssertNil(Deliverable.validateAspect(width: 1, height: 1))
        XCTAssertNil(Deliverable.validateAspect(width: 9, height: 16))
        XCTAssertNil(Deliverable.validateAspect(width: 100, height: 200))
    }

    // MARK: - Custom deliverable centre offset

    func testACentreOffsetEmitsInTheSpec() throws {
        let square = Deliverable(name: "square", aspectWidth: 1, aspectHeight: 1,
                                cropOffset: .centre)
        XCTAssertEqual(square.spec, "square:1:1:centre")
    }

    func testNoOffsetEmitsOnlyTheNameAndAspect() throws {
        let square = Deliverable(name: "square", aspectWidth: 1, aspectHeight: 1)
        XCTAssertEqual(square.spec, "square:1:1")
    }

    func testACentreDeliverableDoesNotNeedPerClipOffset() throws {
        let centred = Deliverable(name: "feed_centred", aspectWidth: 4, aspectHeight: 5,
                                 cropOffset: .centre)
        XCTAssertFalse(centred.needsClipOffset,
                      "centre offset is explicit, so per-clip is not needed")
    }

    func testANonCentreClippingDeliverableNeedsPerClipOffset() throws {
        let clipping = Deliverable(name: "feed", aspectWidth: 4, aspectHeight: 5)
        XCTAssertTrue(clipping.needsClipOffset,
                     "no offset means it follows CROP_Y")
    }

    func testAPresetEmitsBareNameAndHasNilOffset() throws {
        // Presets are created with nil offset and should not allow setting it.
        XCTAssertEqual(Deliverable.reels.cropOffset, nil)
        XCTAssertEqual(Deliverable.reels.spec, "reels")
        XCTAssertFalse(Deliverable.reels.needsClipOffset)
    }

    // MARK: - Centre offset survives the project file

    func testACentreOffsetRoundTripsTheProjectFile() throws {
        let centred = Deliverable(name: "square_centre", aspectWidth: 1, aspectHeight: 1,
                                 cropOffset: .centre)
        let project = Project(presets: [], activePreset: "",
                             delivery: .init(targets: [.reels, centred]))
        let reread = try Project(data: try project.serialised())
        XCTAssertEqual(reread.delivery.targets.count, 2)
        guard let restored = reread.delivery.targets.first(where: { $0.name == "square_centre" })
        else {
            XCTFail("square_centre not found in round-trip")
            return
        }
        XCTAssertEqual(restored.cropOffset, .centre, "centre offset was lost in round-trip")
    }

    func testANoOffsetCustomDeliverableRoundTripsWithNilOffset() throws {
        let noOffset = Deliverable(name: "square", aspectWidth: 1, aspectHeight: 1)
        let project = Project(presets: [], activePreset: "",
                             delivery: .init(targets: [noOffset]))
        let reread = try Project(data: try project.serialised())
        guard let restored = reread.delivery.targets.first(where: { $0.name == "square" })
        else {
            XCTFail("square not found in round-trip")
            return
        }
        XCTAssertNil(restored.cropOffset, "no offset should round-trip as nil")
    }

    // MARK: - Centre offset and blockers

    func testACentreOffsetDeliverableThatCropsIsNotInBlockers() throws {
        let centred = Deliverable(name: "feed_centred", aspectWidth: 4, aspectHeight: 5,
                                 cropOffset: .centre)
        let delivery = Project.Delivery(targets: [centred])
        XCTAssertFalse(delivery.anyTargetCrops,
                      "centre offset is explicit, so there is no blocker")
        XCTAssertTrue(delivery.croppingTargets.isEmpty)
    }

    func testAPerClipOffsetDeliverableThatCropsIsInBlockers() throws {
        let cropping = Deliverable(name: "feed", aspectWidth: 4, aspectHeight: 5)
        let delivery = Project.Delivery(targets: [cropping])
        XCTAssertTrue(delivery.anyTargetCrops,
                     "no explicit offset means per-clip offset is needed")
        XCTAssertEqual(delivery.croppingTargets, [cropping])
    }

    // MARK: - Engine tie-in for custom deliverables

    func testTheEngineReadsCustomShapesWithoutOffset() throws {
        let engine = try engineCheckout()
        let square = Deliverable(name: "square", aspectWidth: 1, aspectHeight: 1)
        let resolved = try libSh(engine, "deliverable_spec", [square.spec])
        XCTAssertEqual(resolved.status, 0,
                       "the engine refused \(square.spec): \(resolved.stderr)")
        let fields = resolved.stdout.split(separator: " ").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        XCTAssertEqual(fields.count, 5)
        guard fields.count == 5 else { return }
        XCTAssertEqual(fields[0], "square")
        XCTAssertEqual(fields[1...2], ["1", "1"])
    }

    func testTheEngineReadsCustomShapesWithCentreOffset() throws {
        let engine = try engineCheckout()
        let square = Deliverable(name: "square_centred", aspectWidth: 1, aspectHeight: 1,
                                cropOffset: .centre)
        let resolved = try libSh(engine, "deliverable_spec", [square.spec])
        XCTAssertEqual(resolved.status, 0,
                       "the engine refused \(square.spec): \(resolved.stderr)")
        let fields = resolved.stdout.split(separator: " ").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        XCTAssertEqual(fields.count, 5)
        guard fields.count == 5 else { return }
        XCTAssertEqual(fields[0], "square_centred")
        XCTAssertEqual(fields[1...2], ["1", "1"])
        XCTAssertEqual(String(fields[3]), "centre")
    }

    func testTheEngineRefusesZeroAspects() throws {
        let engine = try engineCheckout()
        let bad = Deliverable(name: "bad", aspectWidth: 0, aspectHeight: 1)
        let resolved = try libSh(engine, "deliverable_spec", [bad.spec])
        XCTAssertNotEqual(resolved.status, 0, "zero aspect should be refused")
        XCTAssertTrue(resolved.stderr.contains("zero aspect"),
                     "error should mention zero aspect")
    }

    func testTheEngineRefusesNamesWithSlash() throws {
        let engine = try engineCheckout()
        let bad = Deliverable(name: "bad/name", aspectWidth: 1, aspectHeight: 1)
        let resolved = try libSh(engine, "deliverable_spec", [bad.spec])
        XCTAssertNotEqual(resolved.status, 0, "slash in name should be refused")
        // The error mentions the rejection reason — either directly or as unknown format
        XCTAssertTrue(resolved.stderr.contains("REFUSING"),
                     "should contain a refusal message")
    }
}
