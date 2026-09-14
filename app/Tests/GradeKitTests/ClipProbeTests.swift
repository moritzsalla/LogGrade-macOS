import XCTest
@testable import GradeKit

final class ClipProbeTests: XCTestCase {
    private func probe() throws -> ClipProbe {
        guard let ffprobe = EngineLocation.resolveTool("ffprobe") else {
            throw XCTSkip("no ffprobe")
        }
        return ClipProbe(ffprobe: ffprobe)
    }

    /// Real footage only. A synthetic file prints one clean ffprobe line; this camera's originals
    /// print the video stream twice, which is exactly what the reader has to survive.
    func testRecognisesRealAppleLogFootage() throws {
        let src = try engineCheckout().root.appendingPathComponent("src")
        let clips = (try? FileManager.default.contentsOfDirectory(at: src,
                                                                  includingPropertiesForKeys: nil))
            ?? []
        guard let clip = clips.first(where: { $0.pathExtension.lowercased() == "mov" }) else {
            throw XCTSkip("no footage in src/")
        }
        let p = try probe()
        let fields = try XCTUnwrap(p.fields(of: clip))
        XCTAssertEqual(fields.codec, "prores")
        XCTAssertEqual(fields.primaries, "bt2020")
        XCTAssertTrue(fields.pixelFormat.contains("10"), "got \(fields.pixelFormat)")
        // The quirk this reader exists for: a naive read gets two values and a blank line.
        XCTAssertFalse(fields.codec.contains("\n"), "two lines were read as one value")
        XCTAssertEqual(p.verdict(for: clip), .appleLog)
        // And the container says LANDSCAPE for a clip that plays vertically, because the rotation
        // is a display-matrix flag. Asserted here so nobody adds an orientation answer to this
        // type: the engine decides that by decoding a frame.
        XCTAssertGreaterThan(fields.width, fields.height,
                             "the container's dimensions are not the graph's; that is ADR 0005")
    }

    func testRefusesFootageThatHasAlreadyBeenConverted() throws {
        // The case that matters. Converting twice is the *bleached* failure with a new cause, and
        // it produces a file that looks finished.
        guard let ffmpeg = EngineLocation.resolveTool("ffmpeg") else { throw XCTSkip("no ffmpeg") }
        let out = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: out) }
        // BUILT THE WAY THE PIPELINE BUILDS OUTPUT: encode, then tag in a separate -c copy remux.
        // Passing the colour flags to prores_ks does not produce a tagged file — that is the very
        // bug the engine's retag pass exists for, and the first version of this test tripped over
        // it and measured "unknown".
        let raw = out.deletingPathExtension().appendingPathExtension("raw.mov")
        defer { try? FileManager.default.removeItem(at: raw) }
        let encode = Process()
        encode.executableURL = ffmpeg
        encode.arguments = ["-v", "error", "-y", "-f", "lavfi",
                            "-i", "color=c=gray:s=64x128:d=0.1:r=24", "-frames:v", "1",
                            "-c:v", "prores_ks", "-profile:v", "3", "-pix_fmt", "yuv422p10le",
                            raw.path]
        try encode.run(); encode.waitUntilExit()
        let tag = Process()
        tag.executableURL = ffmpeg
        tag.arguments = ["-v", "error", "-y", "-i", raw.path, "-map", "0:v:0", "-c", "copy",
                         "-color_primaries", "bt709", "-color_trc", "bt709",
                         "-colorspace", "bt709", out.path]
        try tag.run(); tag.waitUntilExit()

        let verdict = try probe().verdict(for: out)
        guard case .alreadyConverted(let why) = verdict else {
            return XCTFail("a Rec.709 file should be refused, got \(verdict)")
        }
        XCTAssertTrue(why.contains("bt709"), "the reason should name what it measured: \(why)")
        XCTAssertTrue(verdict.description.contains("bleached"),
                      "the message should point at the failure class, got \(verdict.description)")
    }

    func testRefusesBT2020FootageThatCarriesARec709Transfer() throws {
        // The case the primaries check cannot see: BT.2020 primaries with a Rec.709 transfer, which
        // is what already-graded footage from this pipeline looks like if it kept its wide
        // primaries. Without a fixture like this, removing the transfer check entirely left every
        // test green — found by mutation.
        guard let ffmpeg = EngineLocation.resolveTool("ffmpeg") else { throw XCTSkip("no ffmpeg") }
        let out = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(UUID().uuidString).mov")
        let raw = out.deletingPathExtension().appendingPathExtension("raw.mov")
        defer {
            try? FileManager.default.removeItem(at: out)
            try? FileManager.default.removeItem(at: raw)
        }
        let encode = Process()
        encode.executableURL = ffmpeg
        encode.arguments = ["-v", "error", "-y", "-f", "lavfi",
                            "-i", "color=c=gray:s=64x128:d=0.1:r=24", "-frames:v", "1",
                            "-c:v", "prores_ks", "-profile:v", "3", "-pix_fmt", "yuv422p10le",
                            raw.path]
        try encode.run(); encode.waitUntilExit()
        let tag = Process()
        tag.executableURL = ffmpeg
        tag.arguments = ["-v", "error", "-y", "-i", raw.path, "-map", "0:v:0", "-c", "copy",
                         "-color_primaries", "bt2020", "-color_trc", "bt709",
                         "-colorspace", "bt2020nc", out.path]
        try tag.run(); tag.waitUntilExit()

        let verdict = try probe().verdict(for: out)
        guard case .alreadyConverted(let why) = verdict else {
            return XCTFail("BT.2020 primaries with a 709 transfer is converted, got \(verdict)")
        }
        XCTAssertTrue(why.contains("transfer"), "the reason should name the transfer: \(why)")
    }

    func testSaysSoWhenItCannotMeasure() throws {
        let missing = URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).mov")
        guard case .unreadable = try probe().verdict(for: missing) else {
            return XCTFail("a file that is not there is not a verdict about colour")
        }
    }
}

final class ClipFieldsSummaryTests: XCTestCase {
    func testDimensionsAreNotFormattedWithSeparators() {
        // SwiftUI formats an interpolated Int with the locale's separators, so 3840 rendered as
        // "3.840" on this machine and read as a decimal. Built as a string here, and tested.
        let f = ClipProbe.Fields(codec: "prores", pixelFormat: "yuv422p10le", primaries: "bt2020",
                                 transfer: "unknown", width: 3840, height: 2160)
        XCTAssertEqual(f.summary, "prores yuv422p10le bt2020 3840x2160")
        XCTAssertFalse(f.summary.contains("3.840"))
        XCTAssertTrue(f.containerLooksLandscape,
                      "and the container really does say landscape for a vertical clip")
    }
}

final class ClipDurationTests: XCTestCase {
    func testRealFootageReportsItsLengthAndRate() throws {
        let engine = try engineCheckout()
        let clips = (try? FileManager.default.contentsOfDirectory(
            at: engine.root.appendingPathComponent("src"), includingPropertiesForKeys: nil)) ?? []
        guard let clip = clips.first(where: { $0.pathExtension.lowercased() == "mov" }),
              let ffprobe = EngineLocation.resolveTool("ffprobe") else {
            throw XCTSkip("no footage or no ffprobe")
        }
        let fields = try XCTUnwrap(ClipProbe(ffprobe: ffprobe).fields(of: clip))
        XCTAssertNotNil(fields.duration, "a queue cannot show progress without a length")
        XCTAssertEqual(fields.frameRate ?? 0, 24, accuracy: 0.01, "this shoot is 4K24")
        XCTAssertGreaterThan(fields.frameCount ?? 0, 24, "less than a second of footage?")
    }
}
