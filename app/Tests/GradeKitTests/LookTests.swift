import XCTest
@testable import GradeKit

final class LookTests: XCTestCase {
    func testReadsTheRepoLookAndKeepsWhatItDoesNotModel() throws {
        let url = try engineCheckout().root.appendingPathComponent("look.json")
        let look = try Look(data: try Data(contentsOf: url))
        // Against the file's own values rather than the numbers it held when this was written, so
        // a re-tune of the look does not read as a broken reader.
        let raw = try JSONSerialization.jsonObject(with: try Data(contentsOf: url))
            as? [String: Any] ?? [:]
        func field(_ block: String, _ key: String) -> Any? {
            (raw[block] as? [String: Any])?[key]
        }
        XCTAssertEqual(look.lookLUT, field("look", "lut") as? String)
        XCTAssertEqual(look.tone.gamma, (field("tone", "gamma") as? NSNumber)?.doubleValue)
        XCTAssertEqual(look.colour.saturation,
                       (field("colour", "saturation") as? NSNumber)?.doubleValue)
        XCTAssertEqual(look.halation.tint, field("halation", "tint") as? String)
        XCTAssertTrue(look.correct.isNeutral, "the shipped correction does nothing, by design")
        // The file's own commentary is not modelled and must survive a round trip, or a look sent
        // from the app strips the reasoning out of the file every time.
        XCTAssertNotNil(look.preserved["_comment"], "_comment was dropped")
    }

    /// The contract, from the engine's side: every key the scripts ask for has to be in a file
    /// this writes, because `look()` stops the run on a missing one rather than substituting.
    func testAWrittenLookAnswersEveryKeyTheScriptsAskFor() throws {
        let root = try engineCheckout().root
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
        let root = try engineCheckout().root.appendingPathComponent("look.json")
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
        // The retired Bench carried every block it did not edit through to its output verbatim, for
        // the same reason: a look sent from a tool should not strip the reasoning out of the file. A
        // mutation that dropped `preserved` on write went unnoticed, because equality here
        // deliberately compares the GRADE and not the commentary — so this asserts on the bytes.
        let url = try engineCheckout().root.appendingPathComponent("look.json")
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

    /// A switched-off stage must be one the engine leaves out, not a small move nobody chose.
    func testABypassedStageIsOneTheEngineLeavesOut() throws {
        var look = try lookFixture()
        look.correct.exposure = 0.5
        look.halation.strength = 0.8
        look.printLUT = "kodak_2383"
        look.tone.toe = 0.3
        let off = look.bypassing(Set(Look.Stage.allCases))
        XCTAssertTrue(off.correct.isNeutral)
        XCTAssertTrue(off.halation.isNeutral)
        XCTAssertEqual(off.lookLUT, "none")
        XCTAssertEqual(off.printLUT, "none")
        XCTAssertEqual(off.colour, Look.Colour(saturation: 1, warmth: 0))
        XCTAssertEqual(off.grainStrength, 0)
        let curve = ToneCurve.generated(tone: off.tone)
        for x in stride(from: 0.0, through: 1.0, by: 0.05) {
            XCTAssertEqual(curve.value(at: x), x, accuracy: 1e-3, "tone off is not identity at \(x)")
        }
        XCTAssertFalse(Look.matchesExposure(bypassing: [.tone]),
                       "matching would re-solve the identity gamma into a curve")
        XCTAssertEqual(look.bypassing([]), look)
    }
}

final class ProjectTests: XCTestCase {
    private func aLook() throws -> Look { try lookFixture() }

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

    /// A project saved before the film stages existed still opens, and means what it meant: no
    /// halation. A current project missing the block is damaged and is refused, because that is
    /// the rule `Look` enforces everywhere else.
    func testAProjectFromBeforeTheFilmStagesOpensWithoutThem() throws {
        var preset = try JSONSerialization.jsonObject(with: try aLook().serialised())
            as? [String: Any] ?? [:]
        preset.removeValue(forKey: "halation")
        preset["grain"] = ["strength": 8]
        preset.removeValue(forKey: "print")
        preset["look"] = ["lut": "kodak_portra_400_nc"]
        func project(version: Int) throws -> Data {
            try JSONSerialization.data(withJSONObject: [
                "version": version, "active_preset": "old",
                "presets": [["name": "old", "look": preset]],
                "clips": ["IMG_0609": ["look_override": preset]],
            ])
        }
        let opened = try Project(data: try project(version: 1))
        XCTAssertEqual(opened.presets.first?.look.halation.isNeutral, true,
                       "a look from before halation existed came back with some")
        XCTAssertEqual(opened.clips["IMG_0609"]?.lookOverride?.halation.isNeutral, true,
                       "a per-clip look was not upgraded like the preset it sits beside")
        XCTAssertEqual(opened.presets.first?.look.grainShadows, 1, "old grain came back weighted")
        XCTAssertEqual(opened.presets.first?.look.printLUT, "none", "an old look came back printed")
        XCTAssertEqual(opened.presets.first?.look.lookStrength, 1, "an old look came back weakened")
        XCTAssertEqual(opened.presets.first?.look.grainHighlights, 1, "old grain came back weighted")
        XCTAssertThrowsError(try Project(data: try project(version: 2)),
                             "a current project missing a block was quietly repaired")
        // And what this writes is the current version, so it is never upgraded twice.
        let written = try JSONSerialization.jsonObject(with: try opened.serialised())
            as? [String: Any]
        XCTAssertEqual(written?["version"] as? Int, 2)
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
        XCTAssertEqual(env["CROP_OFFSET"], "600")
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
        let engine = try engineCheckout()
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
    private func aLook(gamma: Double = 2.02) throws -> Look { try lookFixture(gamma: gamma) }

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
        project.savePreset(named: " shipped ", look: try aLook(gamma: 1.77))
        XCTAssertEqual(project.presets.count, 1, "saving over a name should not add a second")
        XCTAssertEqual(project.active?.look.tone.gamma, 1.77)

        // A new name is a second preset, and becomes the one in use.
        project.savePreset(named: "warmer", look: try aLook(gamma: 1.9))
        XCTAssertEqual(project.presets.map(\.name), ["shipped", "warmer"])
        XCTAssertEqual(project.activePreset, "warmer")
        XCTAssertEqual(project.presets[0].look.tone.gamma, 1.77, "the other preset is untouched")

        // A blank name saves nothing rather than a preset nobody can pick.
        project.savePreset(named: "  ", look: try aLook(gamma: 1.5))
        XCTAssertEqual(project.presets.count, 2)
        XCTAssertEqual(project.activePreset, "warmer")
    }
}


final class OutputDestinationTests: XCTestCase {
    /// The rule, stated as a test because the app shipped for a day without it: a preview is
    /// scratch and belongs in a temp directory, a deliverable is the thing the app exists to
    /// produce and must not. This half holds the chosen destination across the project file;
    /// `DeliveryTests` holds where a render actually lands.
    func testAProjectRemembersWhereToDeliver() throws {
        var project = Project(presets: [.init(name: "p", look: try lookFixture())],
                              activePreset: "p")
        project.outputDirectory = URL(fileURLWithPath: "/Users/someone/Footage/shoot")
        let reread = try Project(data: try project.serialised())
        XCTAssertEqual(reread.outputDirectory?.path, "/Users/someone/Footage/shoot",
                       "a chosen destination has to survive the project file")
    }
}

/// The wheels, and the one way they can quietly break a default render.
final class WheelTests: XCTestCase {
    /// THE TRAP THIS EXISTS FOR. The wire format is a string and the engine decides whether a
    /// correction is neutral by parsing it. Joining three doubles the obvious way writes
    /// "1.0,1.0,1.0" — the same correction, a different string — so a wheel dragged and returned
    /// to centre would put the correction cube back in the filter graph and move a default render
    /// for a look nobody changed.
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
        // And the text is spelled the default way, so a centred wheel writes back the file it
        // read. Nothing in the engine compares this spelling: its neutrality check parses the
        // values, which is the only thing a wheel's text has to survive.
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

    /// `isNeutral` is a second copy of the generator's `is_neutral`, and the generator's is the one
    /// that decides whether the cube enters the render. So each case is put to the generator with
    /// the exact arguments the app passes it, and the two answers have to match. The cases are the
    /// ones a copy gets wrong: a spelling that differs from the default, one value for three, and
    /// `lum_mix` moved alone, which the generator deliberately ignores because it scales a
    /// correction that is not there.
    func testNeutralityAgreesWithTheGenerator() throws {
        let engine = try engineCheckout()
        let cases: [(String, Look.Correct)] = [
            ("the default", .init()),
            ("exposure", .init(exposure: 0.1)),
            ("temp", .init(temp: 0.1)),
            ("tint", .init(tint: -0.1)),
            ("slope", .init(slope: "1,1,1.1")),
            ("offset", .init(offset: "0,0.01,0")),
            ("power", .init(power: "0.9,1,1")),
            ("spelled by hand", .init(slope: "1.0,1.0,1.0", offset: "0.0,0.0,0.0",
                                      power: "1.00,1.00,1.00")),
            ("one value for three", .init(slope: "1", offset: "0", power: "1")),
            ("lum_mix alone", .init(lumMix: 0)),
            ("a trailing comma", .init(slope: "1,")),
        ]
        for (name, correct) in cases {
            let answer = try runToCompletion(engine.correctGenerator,
                                             correct.generatorArguments(size: 2) + ["--check-neutral"])
            let verdict = answer.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if answer.status != 0 {
                // A value the generator refuses cannot be a neutral one: the engine stops there.
                XCTAssertFalse(correct.isNeutral,
                               "\(name): the generator refuses it and the app calls it neutral")
                continue
            }
            XCTAssertTrue(verdict == "neutral" || verdict == "active",
                          "\(name): the generator answered '\(verdict)' \(answer.stderr)")
            XCTAssertEqual(correct.isNeutral, verdict == "neutral",
                           "\(name): the generator says \(verdict)")
        }
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
