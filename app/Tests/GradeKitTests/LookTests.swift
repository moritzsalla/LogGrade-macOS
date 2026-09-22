import XCTest

@testable import GradeKit

final class LookTests: XCTestCase {
    func testReadsTheRepoLookAndKeepsWhatItDoesNotModel() throws {
        let url = try engineCheckout().root.appendingPathComponent("look.json")
        let look = try Look(data: try Data(contentsOf: url))
        // Against the file's own values rather than the numbers it held when this was written, so
        // a re-tune of the look does not read as a broken reader.
        let raw =
            try JSONSerialization.jsonObject(with: try Data(contentsOf: url))
            as? [String: Any] ?? [:]
        func field(_ block: String, _ key: String) -> Any? {
            (raw[block] as? [String: Any])?[key]
        }
        XCTAssertEqual(look.convertCube, field("convert", "cube") as? String)
        XCTAssertEqual(
            look.grainStrength, (field("grain", "strength") as? NSNumber)?.doubleValue)
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
        edited.grainStrength = 7
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
                if let a = Range(m.range(at: 1), in: text), let b = Range(m.range(at: 2), in: text)
                {
                    asked.insert("\(text[a]).\(text[b])")
                }
            }
        }
        XCTAssertFalse(asked.isEmpty, "found no look reads, so this test proves nothing")

        let written =
            try JSONSerialization.jsonObject(with: try Data(contentsOf: out))
            as? [String: Any] ?? [:]
        for key in asked.sorted() {
            let parts = key.split(separator: ".").map(String.init)
            let block = written[parts[0]] as? [String: Any]
            XCTAssertNotNil(
                block?[parts[1]],
                "the engine asks for \(key) and a written look.json has no such key")
        }
        // And it round-trips: what was written reads back as what was meant.
        let reread = try Look(data: try Data(contentsOf: out))
        XCTAssertEqual(reread, edited)
        XCTAssertFalse(reread.correct.isNeutral, "an exposure of 0.25 is not neutral")
    }

    func testAMissingKeyIsRefusedRatherThanDefaulted() throws {
        // Inherited from the engine: a silent substitution is a different look under the same name.
        let partial = #"{"grain":{"strength":4}}"#
        XCTAssertThrowsError(try Look(data: Data(partial.utf8))) { error in
            XCTAssertTrue(
                String(describing: error).contains("correct"),
                "the error has to name what is missing, got \(error)")
        }

        // And a block that is PRESENT but incomplete. Testing only the absent-block case let a
        // mutation through: defaulting a missing number to zero stayed green, because the first
        // thing the decoder reached was an absent block rather than an absent number.
        let root = try engineCheckout().root.appendingPathComponent("look.json")
        var object =
            try JSONSerialization.jsonObject(with: try Data(contentsOf: root))
            as? [String: Any] ?? [:]
        var halation = object["halation"] as? [String: Any] ?? [:]
        halation.removeValue(forKey: "radius")
        object["halation"] = halation
        XCTAssertThrowsError(
            try Look(data: try JSONSerialization.data(withJSONObject: object))
        ) { error in
            XCTAssertTrue(
                String(describing: error).contains("halation.radius"),
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
        look.grainStrength = 7
        let out = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(UUID().uuidString).json")
        try look.write(to: out)
        defer { try? FileManager.default.removeItem(at: out) }
        let written =
            try JSONSerialization.jsonObject(with: try Data(contentsOf: out))
            as? [String: Any] ?? [:]
        XCTAssertNotNil(written["_comment"], "the file's own commentary was dropped on write")
        // Compared against the source rather than against a phrase this test remembers: asserting
        // on wording is how a test ends up failing for the wrong reason, which this one did.
        let original =
            try JSONSerialization.jsonObject(with: try Data(contentsOf: url))
            as? [String: Any] ?? [:]
        XCTAssertEqual(
            written["_comment"] as? [String], original["_comment"] as? [String],
            "the commentary came back changed")
    }

    /// A switched-off stage must be one the engine leaves out, not a small move nobody chose.
    func testABypassedStageIsOneTheEngineLeavesOut() throws {
        var look = try lookFixture()
        look.correct.exposure = 0.5
        look.halation.strength = 0.8
        look.finish.denoise = 1
        let off = look.bypassing(Set(Look.Stage.allCases))
        XCTAssertTrue(off.correct.isNeutral)
        XCTAssertEqual(off.grainStrength, 0)
        XCTAssertEqual(off.finish.denoise, 0)
        XCTAssertEqual(
            off.halation, look.halation,
            "halation belongs to the preset, so switching Adjust off must keep it")
        XCTAssertEqual(look.bypassing([]), look)
    }
}

final class ProjectTests: XCTestCase {
    private func aLook() throws -> Look { try lookFixture() }

    func testRoundTripsThroughDisk() throws {
        var project = Project(
            presets: [.init(name: "Portra", look: try aLook())],
            activePreset: "Portra",
            delivery: .init(
                targets: [.custom(aspectWidth: 4, aspectHeight: 5)], shortSide: 1440, fps: 24))
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
        var preset =
            try JSONSerialization.jsonObject(with: try aLook().serialised())
            as? [String: Any] ?? [:]
        preset.removeValue(forKey: "halation")
        preset["grain"] = ["strength": 8]
        func project(version: Int) throws -> Data {
            try JSONSerialization.data(withJSONObject: [
                "version": version, "active_preset": "old",
                "presets": [["name": "old", "look": preset]],
                "clips": ["IMG_0609": ["look_override": preset]],
            ])
        }
        let opened = try Project(data: try project(version: 1))
        XCTAssertEqual(
            opened.presets.first?.look.halation.isNeutral, true,
            "a look from before halation existed came back with some")
        XCTAssertEqual(
            opened.clips["IMG_0609"]?.adjust, Look.Adjust(),
            "an old per-clip whole look must open as no Adjust, not pin the clip")
        XCTAssertThrowsError(
            try Project(data: try project(version: 2)),
            "a current project missing a block was quietly repaired")
        // And what this writes is the current version, so it is never upgraded twice.
        let written =
            try JSONSerialization.jsonObject(with: try opened.serialised())
            as? [String: Any]
        XCTAssertEqual(written?["version"] as? Int, Project.fileVersion)
    }

    /// A project saved before the conversion and finish existed rendered through Apple's cube,
    /// which is gone: it opens on this app's own rendering, with the finish the engine hardcoded.
    func testAProjectFromBeforeTheConversionOpensOnTheAppsRendering() throws {
        var preset =
            try JSONSerialization.jsonObject(with: try aLook().serialised())
            as? [String: Any] ?? [:]
        preset.removeValue(forKey: "convert")
        preset.removeValue(forKey: "finish")
        // What such a file carried instead: the post-Apple-cube mean, and no metering reference.
        preset["match"] = ["reference_yavg": 609]
        func project(version: Int) throws -> Data {
            try JSONSerialization.data(withJSONObject: [
                "version": version, "active_preset": "old",
                "presets": [["name": "old", "look": preset]],
            ])
        }
        let look = try XCTUnwrap(try Project(data: try project(version: 2)).presets.first?.look)
        XCTAssertEqual(look.convertCube, Look.neutralConversion)
        XCTAssertEqual(look.matchReferenceStops, Look.defaultReferenceStops)
        XCTAssertEqual(look.finish, Look.Finish(denoise: 0, sharpen: 0.6, gauge: "none"))
        XCTAssertThrowsError(
            try Project(data: try project(version: 3)),
            "a current project missing the conversion was quietly repaired")
    }

    /// A project saved while the film look and print stages existed opens without them, and does
    /// not carry the dead blocks forward: `Look` keeps unknown keys verbatim, so only the upgrade
    /// can drop them.
    func testAProjectFromBeforeTheFilmLookWasRemovedDropsIt() throws {
        var preset =
            try JSONSerialization.jsonObject(with: try aLook().serialised())
            as? [String: Any] ?? [:]
        preset["look"] = ["lut": "kodak_portra_400_nc", "strength": 0.4]
        preset["print"] = ["lut": "kodak_2383_constlmap", "strength": 0.1]
        let data = try JSONSerialization.data(withJSONObject: [
            "version": 4, "active_preset": "old", "presets": [["name": "old", "look": preset]],
        ])
        let look = try XCTUnwrap(try Project(data: data).presets.first?.look)
        XCTAssertNil(look.preserved["look"], "the film look block was carried forward")
        XCTAssertNil(look.preserved["print"], "the print block was carried forward")
        XCTAssertEqual(look, try aLook(), "the rest of the look changed on the way")
    }

    /// A look saved while grain carried brightness weights opens without them, and does not write
    /// them back.
    func testAProjectFromBeforeGrainInTheNegativeDropsTheWeights() throws {
        var preset =
            try JSONSerialization.jsonObject(with: try aLook().serialised())
            as? [String: Any] ?? [:]
        var grain = preset["grain"] as? [String: Any] ?? [:]
        grain["shadows"] = 0.35
        grain["highlights"] = 0.5
        preset["grain"] = grain
        let data = try JSONSerialization.data(withJSONObject: [
            "version": 6, "active_preset": "old", "presets": [["name": "old", "look": preset]],
        ])
        let look = try XCTUnwrap(try Project(data: data).presets.first?.look)
        XCTAssertEqual(look, try aLook())
        let written =
            try JSONSerialization.jsonObject(with: try look.serialised()) as? [String: Any]
        let writtenGrain = try XCTUnwrap(written?["grain"] as? [String: Any])
        XCTAssertEqual(Set(writtenGrain.keys), ["strength"], "the weights were written back")
    }

    /// A correction saved before it carried contrast and saturation opens with both neutral,
    /// which is what it rendered; a current file missing them is damaged and refused.
    func testAProjectFromBeforeTheSceneTrimsOpensNeutral() throws {
        var preset =
            try JSONSerialization.jsonObject(with: try aLook().serialised())
            as? [String: Any] ?? [:]
        var correct = preset["correct"] as? [String: Any] ?? [:]
        correct.removeValue(forKey: "contrast")
        correct.removeValue(forKey: "saturation")
        preset["correct"] = correct
        func project(version: Int) throws -> Data {
            try JSONSerialization.data(withJSONObject: [
                "version": version, "active_preset": "old",
                "presets": [["name": "old", "look": preset]],
            ])
        }
        let look = try XCTUnwrap(try Project(data: try project(version: 5)).presets.first?.look)
        XCTAssertEqual(look, try aLook())
        XCTAssertThrowsError(try Project(data: try project(version: 6)))
    }

    /// An opened project takes the app's presets: a saved look whose cube is gone must not come
    /// back, and the active choice survives only where it still exists.
    func testAnOpenedProjectTakesTheAppsPresets() throws {
        let current: [Project.Preset] = [
            .init(name: "Neutral", look: try aLook()), .init(name: "Portra 800", look: try aLook()),
        ]
        var deleted = try aLook()
        deleted.convertCube = "rz67_portra400"
        func opened(active: String) -> Project {
            var project = Project(
                presets: [
                    .init(name: "Mamiya RZ67 Portra 400", look: deleted),
                    .init(name: "Portra 800", look: try! lookFixture(grain: 5)),
                ], activePreset: active)
            project.adopt(presets: current, fallback: "Neutral")
            return project
        }
        let gone = opened(active: "Mamiya RZ67 Portra 400")
        XCTAssertEqual(gone.presets, current, "a saved preset list came back")
        XCTAssertEqual(gone.activePreset, "Neutral")
        XCTAssertEqual(opened(active: "Portra 800").activePreset, "Portra 800")
        XCTAssertEqual(
            opened(active: "Portra 800").active?.look, try aLook(),
            "the saved copy of a preset replaced the app's")
        XCTAssertEqual(opened(active: "shipped").activePreset, "Neutral")
    }

    /// One folder per Convert, dated, beside nothing else a person has to recognise.
    func testAnExportFolderIsNamedForWhenItStarted() throws {
        var parts = DateComponents()
        parts.year = 2026
        parts.month = 9
        parts.day = 16
        parts.hour = 14
        parts.minute = 5
        let date = try XCTUnwrap(Calendar.current.date(from: parts))
        let folder = Project.exportFolder(in: URL(fileURLWithPath: "/shoot"), at: date)
        XCTAssertEqual(folder.path, "/shoot/LogGrade export 2026-09-16 14.05")
    }

    func testAnUnplacedCropRendersCentredAndIsNamed() throws {
        var project = Project(
            presets: [.init(name: "Portra", look: try aLook())],
            activePreset: "Portra",
            delivery: .init(targets: [.reels, .feed]))
        project.clips["A"] = .init(cropOffset: 750)
        project.clips["B"] = .init(cropOffset: nil)
        // Named, but not blocking: an unplaced clip renders centred, and says so to the engine.
        XCTAssertTrue(project.blockers.isEmpty)
        let unframed = try XCTUnwrap(project.unframed(for: ["A", "B"]))
        XCTAssertEqual(unframed, .init(deliverables: [.feed], clips: ["B"]))
        XCTAssertTrue(
            unframed.description.contains("centre"),
            "the warning must say what the render will do: \(unframed.description)")
        let look = URL(fileURLWithPath: "/tmp/look.json")
        XCTAssertEqual(project.environment(for: "B", lookFile: look)["CROP_OFFSET"], "centre")
        XCTAssertEqual(project.environment(for: "A", lookFile: look)["CROP_OFFSET"], "750")
        // The shape that does not crop needs no offset at all.
        project.customDelivery.targets = [.reels]
        XCTAssertNil(project.unframed(for: ["A", "B"]))
    }

    func testTheEnvironmentCarriesOnlyVariables() throws {
        var project = Project(
            presets: [.init(name: "P", look: try aLook())], activePreset: "P",
            delivery: .init(
                targets: [.custom(aspectWidth: 16, aspectHeight: 9)], shortSide: 720, fps: 12))
        project.clips["IMG_0609"] = .init(cropOffset: 600, stabilise: false)
        let env = project.environment(
            for: "IMG_0609",
            lookFile: URL(fileURLWithPath: "/tmp/look.json"))
        XCTAssertEqual(env["CROP_OFFSET"], "600")
        XCTAssertEqual(env["WIDTH"], "1280", "720p at 16:9 is 1280 wide")
        XCTAssertEqual(env["FPS_OUT"], "12")
        XCTAssertEqual(env["DELIVERY_CODEC"], "h264")
        XCTAssertEqual(env["STAB"], "0")
        XCTAssertEqual(env["LOOK_FILE"], "/tmp/look.json")
        // The app sets variables the engine documents; it does not describe the image.
        XCTAssertFalse(
            env.values.contains { $0.contains("lut3d") || $0.contains("=") && $0.contains(",") },
            "no filter fragments belong in here: \(env)")
    }

    /// Adjust layers on the look rather than replacing it, so a clip still follows a change of
    /// preset, and a neutral Adjust is the look exactly.
    func testAdjustLayersOnTheLookItIsGiven() throws {
        let look = try aLook()
        XCTAssertEqual(Look.Adjust().applied(to: look), look)
        let moved = Look.Adjust(
            exposure: 0.5, warmth: 0.1, tint: -0.1, contrast: 1.2, saturation: 0.8
        ).applied(to: look)
        XCTAssertEqual(moved.correct.exposure, look.correct.exposure + 0.5, accuracy: 1e-12)
        XCTAssertEqual(moved.correct.temp, look.correct.temp + 0.1, accuracy: 1e-12)
        XCTAssertEqual(moved.correct.tint, look.correct.tint - 0.1, accuracy: 1e-12)
        XCTAssertEqual(moved.correct.contrast, look.correct.contrast * 1.2, accuracy: 1e-12)
        XCTAssertEqual(moved.correct.saturation, look.correct.saturation * 0.8, accuracy: 1e-12)
        XCTAssertEqual(moved.convertCube, look.convertCube)
        XCTAssertEqual(moved.halation, look.halation)
    }

    /// One clip's Adjust survives a save, the others stay neutral, and match off reaches the
    /// engine for that clip alone.
    func testAdjustIsPerClipOnDiskAndInTheEnvironment() throws {
        var project = Project(presets: [.init(name: "P", look: try aLook())], activePreset: "P")
        let dark = Look.Adjust(exposure: -1, contrast: 1.3, match: false)
        project.clips["A"] = .init(adjust: dark)
        project.clips["B"] = .init()
        let reread = try Project(data: try project.serialised())
        XCTAssertEqual(reread.clips["A"]?.adjust, dark)
        XCTAssertEqual(reread.clips["B"]?.adjust, Look.Adjust())
        let look = URL(fileURLWithPath: "/tmp/look.json")
        XCTAssertEqual(reread.environment(for: "A", lookFile: look)["MATCH"], "0")
        XCTAssertNil(reread.environment(for: "B", lookFile: look)["MATCH"])
        XCTAssertEqual(
            reread.ignoringAdjustments.clips["A"]?.adjust, Look.Adjust(),
            "the panels that ignore Adjust would rebuild on every drag tick")
    }

    /// Two clips of one project render different looks with different switches, and survive a
    /// save. A clip given no look follows the one last picked.
    func testEachClipRendersItsOwnLook() throws {
        var neutral = try aLook()
        neutral.convertCube = Look.neutralConversion
        var film = try aLook()
        film.convertCube = "portra160"
        var project = Project(
            presets: [.init(name: "Neutral", look: neutral), .init(name: "Film", look: film)],
            activePreset: "Neutral")
        project.clips["A"] = .init(look: "Film", adjustOff: true, denoise: 1.5, grain: false)
        project.clips["B"] = .init(stabilisationStrength: 12)
        let reread = try Project(data: try project.serialised())
        XCTAssertEqual(reread.clips, project.clips)

        let a = try XCTUnwrap(reread.look(for: "A"))
        XCTAssertEqual(a.convertCube, "portra160")
        XCTAssertEqual(a.finish.denoise, 1.5)
        XCTAssertEqual(a.grainStrength, 0, "grain switched off on a film look")
        XCTAssertEqual(reread.bypassed(for: "A"), [.adjust, .grain])
        let look = URL(fileURLWithPath: "/tmp/look.json")
        XCTAssertEqual(
            reread.environment(for: "A", lookFile: look)["MATCH"], "0",
            "Adjust off takes metering with it")

        let b = try XCTUnwrap(reread.look(for: "B"))
        XCTAssertEqual(b.convertCube, Look.neutralConversion)
        XCTAssertEqual(b.finish.denoise, 0, "denoise is off unless the clip turned it on")
        XCTAssertEqual(b.stabilisationSmoothing, 12)
        XCTAssertEqual(reread.bypassed(for: "B"), [.denoise, .grain])

        var followed = reread
        followed.activePreset = "Film"
        XCTAssertEqual(followed.look(for: "B")?.convertCube, "portra160")
        XCTAssertFalse(followed.bypassed(for: "B").contains(.grain), "grain follows a film look")
        XCTAssertEqual(followed.look(for: "A")?.finish.denoise, 1.5)
    }

    /// A clip whose saved look the app no longer ships falls back, rather than blocking export.
    func testAClipsDeletedLookFallsBackWhenOpened() throws {
        var project = Project(presets: [], activePreset: "Neutral")
        project.clips["A"] = .init(look: "Mamiya RZ67 Portra 400")
        project.clips["B"] = .init(look: "Film")
        project.adopt(
            presets: [
                .init(name: "Neutral", look: try aLook()), .init(name: "Film", look: try aLook()),
            ],
            fallback: "Neutral")
        XCTAssertEqual(project.clips["A"]?.look, "Neutral")
        XCTAssertEqual(project.clips["B"]?.look, "Film")
    }
}

/// The loop the unit tests cannot close: a look written by the app, handed to the real engine,
/// and read back out of its event stream. Skipped without footage, since the engine needs a clip.
final class LookEngineIntegrationTests: XCTestCase {
    func testTheEngineRendersWithALookTheAppWrote() throws {
        let engine = try engineCheckout()
        let src = engine.root.appendingPathComponent("src")
        let clips =
            (try? FileManager.default.contentsOfDirectory(
                at: src,
                includingPropertiesForKeys: nil))
            ?? []
        guard let clip = clips.first(where: { $0.pathExtension.lowercased() == "mov" }) else {
            throw XCTSkip("no footage in src/")
        }
        try XCTSkipIf(!engine.preflight().isEmpty, "engine preflight not clean")

        // A grain nothing in the repo contains, so a pass can only come from the engine reading
        // the file this test wrote and reporting it back.
        var look = try Look(data: try Data(contentsOf: engine.lookFile))
        look.grainStrength = 17
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
            environment: [
                "LOOK_FILE": lookFile.path, "GRADE_WORK_DIR": work.path,
                "DRY": "1", "MATCH": "0", "STAB": "0",
            ])
        XCTAssertTrue(outcome.succeeded, "engine said: \(outcome.stderrText)")
        let start = try XCTUnwrap(
            outcome.events.first { $0.name == "run_start" },
            "no run in: \(outcome.events.map(\.name))")
        XCTAssertEqual(
            start.double("grain"), 17,
            "the engine did not read the look the app wrote")
        XCTAssertTrue(
            outcome.malformed.isEmpty,
            "the real engine put prose on stdout: \(outcome.malformed)")
    }
}

/// Presets and the project file, exercised through the model's own operations rather than the UI.
final class PresetTests: XCTestCase {
    private func aLook(grain: Double = 8) throws -> Look { try lookFixture(grain: grain) }

    func testAProjectSurvivesBeingSavedAndReopened() throws {
        var project = Project(
            presets: [.init(name: "shipped", look: try aLook())],
            activePreset: "shipped",
            delivery: .init(
                targets: [.reels], shortSide: 1440, fps: 24, codec: .hevc10,
                quality: .max, container: .mov, audio: false))
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
        XCTAssertEqual(reopened.delivery.shortSide, 1440)
        XCTAssertEqual(reopened.delivery.fps, 24)
        XCTAssertEqual(reopened.exportPreset, .custom)
        XCTAssertEqual(reopened.delivery.codec, .hevc10)
        XCTAssertEqual(reopened.delivery.quality, .max)
        XCTAssertEqual(reopened.delivery.container, .mov)
        XCTAssertFalse(reopened.delivery.audio)
        XCTAssertEqual(reopened.presets.map(\.name), ["shipped"])
        XCTAssertEqual(reopened.active?.look.grainStrength, 8)
    }

    /// A preset renders its own fixed settings and keeps Custom's for later; ProRes is forced to
    /// mov and auto without overwriting what Custom holds.
    func testExportPresetsRenderFixedSettingsAndKeepCustom() throws {
        var project = Project(
            presets: [.init(name: "p", look: try aLook())], activePreset: "p",
            delivery: .init(
                targets: [.feed], shortSide: 2160, codec: .prores422hq, quality: .max,
                container: .mp4))
        let look = URL(fileURLWithPath: "/tmp/look.json")
        var env = project.environment(for: "A", lookFile: look)
        XCTAssertEqual(env["DELIVERY_CODEC"], "prores422hq")
        XCTAssertEqual(env["DELIVERY_CONTAINER"], "mov", "the engine refuses ProRes in mp4")
        XCTAssertEqual(env["DELIVERY_QUALITY"], "auto", "the engine refuses ProRes above auto")
        XCTAssertEqual(project.customDelivery.container, .mp4, "Custom's own choice was lost")

        project.exportPreset = .instagramStory
        env = project.environment(for: "A", lookFile: look)
        XCTAssertEqual(env["DELIVERABLES"], Deliverable.reels.spec)
        XCTAssertEqual(env["WIDTH"], "1080")
        XCTAssertNil(env["HEIGHT"])
        XCTAssertEqual(env["DELIVERY_CODEC"], "h264")
        XCTAssertEqual(env["DELIVERY_CONTAINER"], "mp4")
        XCTAssertEqual(env["DELIVERY_AUDIO"], "1")
        XCTAssertNil(env["DELIVERY_BITS"], "BITS must not be sent: it has to agree with CODEC")

        let reread = try Project(data: try project.serialised())
        XCTAssertEqual(reread.exportPreset, .instagramStory)
        XCTAssertEqual(
            reread.customDelivery.shortSide, 2160, "Custom was not kept behind the preset")
        XCTAssertEqual(Project(presets: [], activePreset: "").exportPreset, .instagramStory)
    }

    /// A project from before the codec choice: `ten_bit` meant HEVC 10-bit, and hand-picked
    /// shapes are Custom.
    func testAnOlderDeliveryBlockOpensAsCustomWithItsCodec() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "version": 5, "active_preset": "p", "presets": [],
            "delivery": [
                "targets": [["name": "feed", "aspect_width": 4, "aspect_height": 5]],
                "height": 1920, "ten_bit": true,
            ],
        ])
        let opened = try Project(data: data)
        XCTAssertEqual(opened.exportPreset, .custom)
        XCTAssertEqual(opened.delivery.codec, .hevc10)
        XCTAssertEqual(opened.delivery.container, .mp4)
        XCTAssertTrue(opened.delivery.audio)
    }

}

final class OutputDestinationTests: XCTestCase {
    /// The rule, stated as a test because the app shipped for a day without it: a preview is
    /// scratch and belongs in a temp directory, a deliverable is the thing the app exists to
    /// produce and must not. This half holds the chosen destination across the project file;
    /// `DeliveryTests` holds where a render actually lands.
    func testAProjectRemembersWhereToDeliver() throws {
        var project = Project(
            presets: [.init(name: "p", look: try lookFixture())],
            activePreset: "p")
        project.outputDirectory = URL(fileURLWithPath: "/Users/someone/Footage/shoot")
        let reread = try Project(data: try project.serialised())
        XCTAssertEqual(
            reread.outputDirectory?.path, "/Users/someone/Footage/shoot",
            "a chosen destination has to survive the project file")
    }
}
