import XCTest
@testable import GradeKit

final class LookTests: XCTestCase {
    private func repoRoot() throws -> URL {
        let here = URL(fileURLWithPath: #filePath)
        guard let engine = EngineLocation.discover(from: here.deletingLastPathComponent()) else {
            throw XCTSkip("no engine checkout above \(here.path)")
        }
        return engine.root
    }

    func testReadsTheRepoLookAndKeepsWhatItDoesNotModel() throws {
        let url = try repoRoot().appendingPathComponent("look.json")
        let look = try Look(data: try Data(contentsOf: url))
        XCTAssertEqual(look.lookLUT, "kodak_portra_400_nc")
        XCTAssertEqual(look.tone.gamma, 2.02)
        XCTAssertEqual(look.colour.saturation, 1.27)
        XCTAssertTrue(look.correct.isNeutral, "the shipped correction does nothing, by design")
        // The file's own commentary is not modelled and must survive a round trip, or a look sent
        // from the app strips the reasoning out of the file every time.
        XCTAssertNotNil(look.preserved["_comment"], "_comment was dropped")
    }

    /// The contract, from the engine's side: every key the scripts ask for has to be in a file
    /// this writes, because `look()` stops the run on a missing one rather than substituting.
    func testAWrittenLookAnswersEveryKeyTheScriptsAskFor() throws {
        let root = try repoRoot()
        let look = try Look(data: try Data(contentsOf: root.appendingPathComponent("look.json")))
        // Change something, so this is not accidentally testing the file it read.
        var edited = look
        edited.tone.gamma = 1.77
        edited.correct.exposure = 0.25
        let out = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(UUID().uuidString).json")
        try edited.write(to: out)
        defer { try? FileManager.default.removeItem(at: out) }

        // Every `look .a.b` in the scripts, read out of the scripts themselves.
        var asked = Set<String>()
        let scripts = try FileManager.default.contentsOfDirectory(
            at: root.appendingPathComponent("scripts"), includingPropertiesForKeys: nil)
        let pattern = try NSRegularExpression(pattern: #"look \.([a-z_]+)\.([a-z_]+)"#)
        for script in scripts where script.pathExtension == "sh" {
            let text = try String(contentsOf: script, encoding: .utf8)
            for m in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                if let a = Range(m.range(at: 1), in: text), let b = Range(m.range(at: 2), in: text) {
                    asked.insert("\(text[a]).\(text[b])")
                }
            }
        }
        XCTAssertFalse(asked.isEmpty, "found no look reads, so this test proves nothing")

        let written = try JSONSerialization.jsonObject(with: try Data(contentsOf: out))
            as? [String: Any] ?? [:]
        for key in asked.sorted() {
            let parts = key.split(separator: ".").map(String.init)
            let block = written[parts[0]] as? [String: Any]
            XCTAssertNotNil(block?[parts[1]],
                            "the engine asks for \(key) and a written look.json has no such key")
        }
        // And it round-trips: what was written reads back as what was meant.
        let reread = try Look(data: try Data(contentsOf: out))
        XCTAssertEqual(reread, edited)
        XCTAssertFalse(reread.correct.isNeutral, "an exposure of 0.25 is not neutral")
    }

    func testAMissingKeyIsRefusedRatherThanDefaulted() throws {
        // Inherited from the engine: a silent substitution is a different look under the same name.
        let partial = #"{"tone":{"gamma":2.0,"pivot":0.4,"contrast":1.1,"toe":0,"shoulder":0.1,"black":0}}"#
        XCTAssertThrowsError(try Look(data: Data(partial.utf8))) { error in
            XCTAssertTrue(String(describing: error).contains("correct"),
                          "the error has to name what is missing, got \(error)")
        }

        // And a block that is PRESENT but incomplete. Testing only the absent-block case let a
        // mutation through: defaulting a missing number to zero stayed green, because the first
        // thing the decoder reached was an absent block rather than an absent number.
        let root = try repoRoot().appendingPathComponent("look.json")
        var object = try JSONSerialization.jsonObject(with: try Data(contentsOf: root))
            as? [String: Any] ?? [:]
        var tone = object["tone"] as? [String: Any] ?? [:]
        tone.removeValue(forKey: "shoulder")
        object["tone"] = tone
        XCTAssertThrowsError(
            try Look(data: try JSONSerialization.data(withJSONObject: object))
        ) { error in
            XCTAssertTrue(String(describing: error).contains("tone.shoulder"),
                          "should name the exact key, got \(error)")
        }
    }

    func testAWrittenFileKeepsTheCommentaryItWasGiven() throws {
        // The Bench carries every block it does not edit through to its output verbatim, for the
        // same reason: a look sent from a tool should not strip the reasoning out of the file. A
        // mutation that dropped `preserved` on write went unnoticed, because equality here
        // deliberately compares the GRADE and not the commentary — so this asserts on the bytes.
        let url = try repoRoot().appendingPathComponent("look.json")
        var look = try Look(data: try Data(contentsOf: url))
        look.tone.gamma = 1.33
        let out = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(UUID().uuidString).json")
        try look.write(to: out)
        defer { try? FileManager.default.removeItem(at: out) }
        let written = try JSONSerialization.jsonObject(with: try Data(contentsOf: out))
            as? [String: Any] ?? [:]
        XCTAssertNotNil(written["_comment"], "the file's own commentary was dropped on write")
        // Compared against the source rather than against a phrase this test remembers: asserting
        // on wording is how a test ends up failing for the wrong reason, which this one did.
        let original = try JSONSerialization.jsonObject(with: try Data(contentsOf: url))
            as? [String: Any] ?? [:]
        XCTAssertEqual(written["_comment"] as? [String], original["_comment"] as? [String],
                       "the commentary came back changed")
    }
}

final class ProjectTests: XCTestCase {
    private func aLook() throws -> Look {
        let json = #"""
        {"correct":{"exposure":0,"temp":0,"tint":0,"slope":"1,1,1","offset":"0,0,0",
         "power":"1,1,1","lum_mix":1},"look":{"lut":"kodak_portra_400_nc"},
         "tone":{"gamma":2.02,"pivot":0.39,"contrast":1.09,"toe":0,"shoulder":0.1,"black":0.025},
         "colour":{"saturation":1.27,"warmth":0.005},"grain":{"strength":8},
         "stabilisation":{"smoothing":30},"match":{"reference_yavg":609}}
        """#
        return try Look(data: Data(json.utf8))
    }

    func testRoundTripsThroughDisk() throws {
        var project = Project(presets: [.init(name: "Portra", look: try aLook())],
                              activePreset: "Portra",
                              delivery: .init(targets: [.reels, .feed], height: 1440, fps: 24))
        project.clips["IMG_0609"] = .init(cropOffset: 750, previewSeconds: 4, stabilise: true)
        project.clips["IMG_0610"] = .init(cropOffset: nil, previewSeconds: 1, stabilise: false)

        let reread = try Project(data: try project.serialised())
        XCTAssertEqual(reread.presets.map(\.name), ["Portra"])
        XCTAssertEqual(reread.delivery, project.delivery)
        XCTAssertEqual(reread.clips["IMG_0609"]?.cropOffset, 750)
        // Undecided is not zero, and it has to survive as undecided.
        XCTAssertNil(reread.clips["IMG_0610"]?.cropOffset)
        XCTAssertEqual(reread.clips["IMG_0610"]?.stabilise, false)
    }

    func testACroppedRenderIsBlockedUntilEveryClipHasAnOffset() throws {
        var project = Project(presets: [.init(name: "Portra", look: try aLook())],
                              activePreset: "Portra",
                              delivery: .init(targets: [.reels, .feed]))
        project.clips["A"] = .init(cropOffset: 750)
        project.clips["B"] = .init(cropOffset: nil)
        let blockers = project.blockers(for: ["A", "B"])
        XCTAssertEqual(blockers, [.cropWithoutOffset(deliverables: [.feed], clips: ["B"])])
        XCTAssertTrue(blockers[0].description.contains("per-clip"),
                      "the reason matters more than the fact: \(blockers[0].description)")
        // The shape that does not crop needs no offset at all.
        project.delivery.setTarget(.feed, selected: false)
        XCTAssertTrue(project.blockers(for: ["A", "B"]).isEmpty)
    }

    func testTheEnvironmentCarriesOnlyVariables() throws {
        var project = Project(presets: [.init(name: "P", look: try aLook())], activePreset: "P",
                              delivery: .init(targets: [.reels, .feed], height: 1080, fps: 12))
        project.clips["IMG_0609"] = .init(cropOffset: 600, stabilise: false)
        let env = project.environment(for: "IMG_0609",
                                      lookFile: URL(fileURLWithPath: "/tmp/look.json"))
        XCTAssertEqual(env["CROP_Y"], "600")
        XCTAssertEqual(env["HEIGHT"], "1080")
        XCTAssertEqual(env["FPS_OUT"], "12")
        XCTAssertEqual(env["STAB"], "0")
        XCTAssertEqual(env["LOOK_FILE"], "/tmp/look.json")
        // The app sets variables the engine documents; it does not describe the image.
        XCTAssertFalse(env.values.contains { $0.contains("lut3d") || $0.contains("=") && $0.contains(",") },
                       "no filter fragments belong in here: \(env)")
    }

    func testAClipFollowsThePresetUnlessItDeparts() throws {
        var project = Project(presets: [.init(name: "P", look: try aLook())], activePreset: "P")
        project.clips["A"] = .init()
        XCTAssertEqual(project.look(for: "A")?.tone.gamma, 2.02)
        var departed = try aLook()
        departed.tone.gamma = 1.5
        project.clips["A"]?.lookOverride = departed
        XCTAssertEqual(project.look(for: "A")?.tone.gamma, 1.5)
        XCTAssertEqual(project.look(for: "B")?.tone.gamma, 2.02, "an unknown clip follows the preset")
    }
}

/// The loop the unit tests cannot close: a look written by the app, handed to the real engine,
/// and read back out of its event stream. Skipped without footage, since the engine needs a clip.
final class LookEngineIntegrationTests: XCTestCase {
    func testTheEngineRendersWithALookTheAppWrote() throws {
        let here = URL(fileURLWithPath: #filePath)
        guard let engine = EngineLocation.discover(from: here.deletingLastPathComponent()) else {
            throw XCTSkip("no engine checkout")
        }
        let src = engine.root.appendingPathComponent("src")
        let clips = (try? FileManager.default.contentsOfDirectory(at: src,
                                                                  includingPropertiesForKeys: nil))
            ?? []
        guard let clip = clips.first(where: { $0.pathExtension.lowercased() == "mov" }) else {
            throw XCTSkip("no footage in src/")
        }
        try XCTSkipIf(!engine.preflight().isEmpty, "engine preflight not clean")

        // A gamma nothing in the repo contains, so a pass can only come from the engine reading
        // the file this test wrote.
        var look = try Look(data: try Data(contentsOf: engine.lookFile))
        look.tone.gamma = 1.61
        let lookFile = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(UUID().uuidString)-look.json")
        try look.write(to: lookFile)
        let work = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: lookFile)
            try? FileManager.default.removeItem(at: work)
        }

        let outcome = try EngineRun(engine: engine).run(
            arguments: [clip.path],
            environment: ["LOOK_FILE": lookFile.path, "GRADE_WORK_DIR": work.path,
                          "DRY": "1", "MATCH": "0", "STAB": "0"])
        XCTAssertTrue(outcome.succeeded, "engine said: \(outcome.stderrText)")
        let planned = try XCTUnwrap(outcome.events.first { $0.name == "clip_planned" },
                                    "no plan in: \(outcome.events.map(\.name))")
        XCTAssertEqual(planned.double("gamma"), 1.61,
                       "the engine did not read the look the app wrote")
        XCTAssertTrue(outcome.malformed.isEmpty,
                      "the real engine put prose on stdout: \(outcome.malformed)")
    }
}

/// Presets and the project file, exercised through the model's own operations rather than the UI.
final class PresetTests: XCTestCase {
    private func aLook(gamma: Double = 2.02) throws -> Look {
        let json = #"""
        {"correct":{"exposure":0,"temp":0,"tint":0,"slope":"1,1,1","offset":"0,0,0",
         "power":"1,1,1","lum_mix":1},"look":{"lut":"kodak_portra_400_nc"},
         "tone":{"gamma":GAMMA,"pivot":0.39,"contrast":1.09,"toe":0,"shoulder":0.1,"black":0.025},
         "colour":{"saturation":1.27,"warmth":0.005},"grain":{"strength":8},
         "stabilisation":{"smoothing":30},"match":{"reference_yavg":609}}
        """#.replacingOccurrences(of: "GAMMA", with: String(gamma))
        return try Look(data: Data(json.utf8))
    }

    func testAPresetCarriesTheLookAndTheTrimsTogether() throws {
        var project = Project(presets: [.init(name: "shipped", look: try aLook())],
                              activePreset: "shipped")
        var neutral = try aLook(gamma: 1.4)
        neutral.lookLUT = "none"
        neutral.colour.saturation = 1.0
        project.presets.append(.init(name: "neutral", look: neutral))

        // Switching replaces the whole grade, not just the cube: the curve was tuned with its cube
        // in the chain, so half a switch is a grade nobody chose.
        let chosen = try XCTUnwrap(project.presets.first { $0.name == "neutral" })
        XCTAssertEqual(chosen.look.lookLUT, "none")
        XCTAssertEqual(chosen.look.tone.gamma, 1.4)
        XCTAssertEqual(chosen.look.colour.saturation, 1.0)
        // And the other preset is untouched by that.
        XCTAssertEqual(project.presets[0].look.tone.gamma, 2.02)
    }

    func testAProjectSurvivesBeingSavedAndReopened() throws {
        var project = Project(presets: [.init(name: "shipped", look: try aLook())],
                              activePreset: "shipped",
                              delivery: .init(targets: [.reels, .feed], height: 2560, fps: 24))
        project.clips["IMG_0609"] = .init(cropOffset: 812, previewSeconds: 4, stabilise: false)
        project.clips["IMG_0610"] = .init(cropOffset: nil)

        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try project.serialised().write(to: url)

        // The crop offsets are the point: they are the one thing in this pipeline that cannot be
        // guessed, and without a project file they live only as long as a window is open.
        let reopened = try Project(data: try Data(contentsOf: url))
        XCTAssertEqual(reopened.clips["IMG_0609"]?.cropOffset, 812)
        XCTAssertNil(reopened.clips["IMG_0610"]?.cropOffset, "undecided must stay undecided")
        XCTAssertEqual(reopened.clips["IMG_0609"]?.previewSeconds, 4)
        XCTAssertEqual(reopened.delivery.height, 2560)
        XCTAssertEqual(reopened.delivery.fps, 24)
        XCTAssertEqual(reopened.presets.map(\.name), ["shipped"])
        XCTAssertEqual(reopened.active?.look.tone.gamma, 2.02)
    }

    func testSavingUnderAnExistingNameReplacesIt() throws {
        var project = Project(presets: [.init(name: "shipped", look: try aLook())],
                              activePreset: "shipped")
        let adjusted = try aLook(gamma: 1.77)
        if let i = project.presets.firstIndex(where: { $0.name == "shipped" }) {
            project.presets[i] = .init(name: "shipped", look: adjusted)
        }
        XCTAssertEqual(project.presets.count, 1, "saving over a name should not add a second")
        XCTAssertEqual(project.active?.look.tone.gamma, 1.77)
    }
}


final class OutputDestinationTests: XCTestCase {
    /// The rule, stated as a test because the app shipped for a day without it: a preview is
    /// scratch and belongs in a temp directory, a deliverable is the thing the app exists to
    /// produce and must not.
    func testAProjectRemembersWhereToDeliver() throws {
        let json = #"""
        {"correct":{"exposure":0,"temp":0,"tint":0,"slope":"1,1,1","offset":"0,0,0",
         "power":"1,1,1","lum_mix":1},"look":{"lut":"none"},
         "tone":{"gamma":1,"pivot":0.5,"contrast":1,"toe":0,"shoulder":0,"black":0},
         "colour":{"saturation":1,"warmth":0},"grain":{"strength":8},
         "stabilisation":{"smoothing":30},"match":{"reference_yavg":609}}
        """#
        var project = Project(presets: [.init(name: "p", look: try Look(data: Data(json.utf8)))],
                              activePreset: "p")
        project.outputDirectory = URL(fileURLWithPath: "/Users/someone/Footage/shoot")
        let reread = try Project(data: try project.serialised())
        XCTAssertEqual(reread.outputDirectory?.path, "/Users/someone/Footage/shoot",
                       "a chosen destination has to survive the project file")
        XCTAssertFalse(reread.outputDirectory?.path.contains("/var/folders") ?? true,
                       "nothing should default into a scratch directory")
    }
}

/// The wheels, and the one way they can quietly break a default render.
final class WheelTests: XCTestCase {
    /// THE TRAP THIS EXISTS FOR. The wire format is a string and the engine decides whether a
    /// correction is neutral by parsing it. Joining three doubles the obvious way writes
    /// "1.0,1.0,1.0" — the same correction, a different string — so a wheel dragged and returned
    /// to centre would put the correction cube back in the filter graph and stop a default render
    /// being byte-identical to the precursor's.
    func testAWheelMovedAndReturnedIsNeutralAgain() {
        var correct = Look.Correct()
        XCTAssertTrue(correct.isNeutral, "the default correction is not neutral")
        for wheel in Look.Correct.Wheel.allCases {
            for channel in 0..<3 {
                correct.setValue(wheel, channel, wheel.neutral + 0.25)
                XCTAssertFalse(correct.isNeutral, "\(wheel) \(channel) moved and still reads neutral")
                correct.setValue(wheel, channel, wheel.neutral)
                XCTAssertTrue(correct.isNeutral,
                              "\(wheel) \(channel) returned to centre and reads as a correction — "
                              + "the engine would put the cube back in the graph")
            }
        }
        // And the text is spelled the way the generator spells it, which is what the engine's own
        // neutrality check and its cube fingerprint both compare.
        XCTAssertEqual(correct.slope, "1,1,1")
        XCTAssertEqual(correct.offset, "0,0,0")
        XCTAssertEqual(correct.power, "1,1,1")
    }

    /// look.json is documented as hand-editable, so a neutral correction reaches this code spelled
    /// however a person felt like spelling it. The engine's own check parses before comparing;
    /// this one has to as well, or a hand-written "1.0,1.0,1.0" puts a lookup that returns its own
    /// input into the filter graph for every pixel of every render.
    func testNeutralityIsDecidedByValueNotBySpelling() {
        XCTAssertTrue(Look.Correct(slope: "1.0,1.0,1.0", offset: "0.0,0.0,0.0",
                                   power: "1.00,1.00,1.00").isNeutral)
        XCTAssertTrue(Look.Correct(slope: "1", offset: "0", power: "1").isNeutral,
                      "the generator accepts one value for three; so must this")
        XCTAssertFalse(Look.Correct(slope: "1,1,1.0001").isNeutral)
        XCTAssertFalse(Look.Correct(slope: "nonsense").isNeutral,
                       "an unparseable triple is not a neutral one — the engine would refuse it")
    }

    func testEachWheelAndChannelIsItsOwnValue() {
        var correct = Look.Correct()
        correct.setValue(.slope, 0, 1.1)
        correct.setValue(.offset, 1, -0.02)
        correct.setValue(.power, 2, 1.15)
        XCTAssertEqual(correct.slope, "1.1,1,1")
        XCTAssertEqual(correct.offset, "0,-0.02,0")
        XCTAssertEqual(correct.power, "1,1,1.15")
        XCTAssertEqual(correct.value(.slope, 0), 1.1)
        XCTAssertEqual(correct.value(.offset, 1), -0.02)
        XCTAssertEqual(correct.value(.power, 2), 1.15)
        XCTAssertEqual(correct.value(.slope, 1), 1, "a channel nobody moved changed anyway")
    }

    /// A file written by hand can carry a single value meaning all three, which the generator
    /// accepts. Reading it must not silently lose the other two.
    func testAOneValueTripleReadsAsThreeChannels() {
        var correct = Look.Correct(slope: "1.2")
        XCTAssertEqual(correct.value(.slope, 2), 1.2)
        correct.setValue(.slope, 0, 1.3)
        XCTAssertEqual(correct.slope, "1.3,1.2,1.2")
    }
}
