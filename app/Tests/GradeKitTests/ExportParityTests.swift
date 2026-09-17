import Foundation
import XCTest

@testable import GradeKit

/// Renders one clip's deliverables: what the native export has to be, spelled as the app holds it.
/// `look` is the effective look (Adjust and bypasses applied), `delivery` the normalised one, and
/// the result is one file per deliverable, named `<clip>_<suffix>.<container>` as grade.sh names it.
typealias Exporter = (
    _ source: URL, _ look: Look, _ delivery: Project.Delivery, _ clip: Project.ClipSettings,
    _ proofSeconds: Double?, _ outputDirectory: URL
) throws -> [URL]

/// The native export against grade.sh, stage by stage, on real footage.
///
/// `candidate` is grade.sh itself until the native export exists, so this passes trivially today;
/// what it holds is the bounds. Each was set between two measurements, recorded beside it: an
/// EQUIVALENT export (grade.sh through x265 instead of x264, standing in for a different encoder)
/// and a MUTATION the check exists to catch. `PARITY_CALIBRATE=1` re-measures both.
///
/// Each stage is isolated by switching the others off in the look, so a sharpening difference
/// cannot pass as a grain one: `plain` has no grain and no sharpening, `grain` adds grain, `sharp`
/// adds sharpening.
///
/// NOT COVERED, because it could not be measured: banding and the grain's weighting by luma. On
/// this footage the sensor noise hides both, and neither a 6-bit posterise nor highlight weight 1.0
/// for 0.6 moved a measure outside what an equivalent encode did. A check that cannot fail was
/// removed rather than kept; banding needs a smooth synthetic source to test.
final class ExportParityTests: XCTestCase {
    /// The native export, in a release build. A debug build renders it at a small fraction of the
    /// speed (233 s for this test against 37 s in release), which the full check cannot carry, so
    /// there it is nil: grade.sh, whose renders are the reference's, compared with itself. Hold the
    /// native export with `swift test -c release --filter ExportParityTests` after changing it.
    #if DEBUG
        static var candidate: ((EngineLocation) -> Exporter)? = nil
    #else
        static var candidate: ((EngineLocation) -> Exporter)? = { engine in
            { source, look, delivery, clip, proof, out in
                try NativeExport.export(
                    source: source, look: look, delivery: delivery, clip: clip,
                    proofSeconds: proof, outputDirectory: out, engine: engine)
            }
        }
    #endif

    static let proofSeconds = 0.5
    static let delivery = Project.Delivery(targets: [.feed], shortSide: 720)
    /// Frames compared, inside a 0.5 s proof at 24 or 30 fps.
    static let frames = [2, 6, 10]

    // MARK: the test

    func testTheExportMatchesTheEngineStageByStage() throws {
        let rig = try Rig()
        let reference = try rig.renders(engineExporter(rig.engine))
        let candidate = try Self.candidate.map { try rig.renders($0(rig.engine)) } ?? reference
        let m = try Measurement(reference: reference, candidate: candidate)

        XCTAssertEqual(
            candidate.plain.map(\.lastPathComponent), reference.plain.map(\.lastPathComponent),
            "outputs are not named as grade.sh names them")
        XCTAssertTrue(m.size == m.referenceSize, "a different frame size: \(m.size)")
        // Equivalent 0 px; the crop moved 6 source px (2 px here) reads 2.
        XCTAssertLessThanOrEqual(m.shift, 1, "the crop window moved by \(m.shift) px")
        // Block p95 Oklab distance. Equivalent (x265) 0.0026, re-encoded 0.0010; exposure +0.1
        // stop 0.0142, the crop shift 0.0149, posterised to 6 bits 0.0070.
        XCTAssertLessThan(m.gradeP95, 0.006, "the grade differs: block p95 ΔE \(m.gradeP95)")
        // Fine-detail gain of the sharpener over the plain render. Equivalent 0.999, re-encoded
        // 0.996; sharpen 0.45 instead of 0.6 reads 0.955.
        XCTAssertEqual(m.sharpenRatio, 1, accuracy: 0.025, "sharpening strength \(m.sharpenRatio)")
        // The grain as DELIVERED, after the encoder: x265 kept 0.26 of what x264 keeps and a
        // re-encode 0.66, so an encoder alone moves this a lot and an equivalent encoder is not
        // equivalent here. Grain strength x0.75 reads 0.50. The native export has to deliver the
        // grain the engine delivers, whatever its encoder does to it.
        XCTAssertEqual(m.grainRatio, 1, accuracy: 0.2, "delivered grain \(m.grainRatio)")
        XCTAssertEqual(m.tags, m.referenceTags, "colour tags")
        XCTAssertEqual(m.frameCount, m.referenceFrameCount, "frame count")
        XCTAssertEqual(m.frameRate, m.referenceFrameRate, "frame rate")
        XCTAssertEqual(m.audioCodec, m.referenceAudioCodec, "audio codec")
        // Apple's AAC encoder ran 6 ms longer (priming); one frame at 24 fps is 42 ms.
        XCTAssertEqual(m.audioDuration, m.referenceAudioDuration, accuracy: 0.042, "audio length")
        // Energy below 30 Hz against the engine's. Apple AAC 1.02; a 20 Hz high-pass for 60 2.39.
        XCTAssertLessThan(m.lowBassRatio, 1.5, "the high-pass is missing: \(m.lowBassRatio)x")
    }

    /// Re-measures every bound's two numbers. Prints them; asserts nothing.
    func testCalibrate() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["PARITY_CALIBRATE"] == "1",
            "PARITY_CALIBRATE=1 to re-measure the bounds")
        let rig = try Rig()
        let engine = rig.engine
        let reference = try rig.renders(engineExporter(engine))
        func measure(_ name: String, _ exporter: Exporter) throws {
            let m = try Measurement(reference: reference, candidate: try rig.renders(exporter))
            print(
                "PARITY \(name): shift \(m.shift) grade p95 \(m.gradeP95) "
                    + "sharpen \(m.sharpenRatio) grain \(m.grainRatio) "
                    + "frames \(m.frameCount)/\(m.referenceFrameCount) "
                    + "audio \(m.audioDuration)/\(m.referenceAudioDuration) bass \(m.lowBassRatio)")
        }
        try measure("equivalent (x265)", engineExporter(engine, env: ["DELIVERY_CODEC": "hevc"]))
        try measure("re-encoded", reencoding(engineExporter(engine), filter: "null"))
        try measure(
            "posterised", reencoding(engineExporter(engine), filter: "lutyuv=y='bitand(val,252)'"))
        try measure("crop +6 source px", engineExporter(engine, cropShift: 6))
        try measure(
            "exposure +0.1",
            lookChanged(engineExporter(engine)) { l in l.correct.exposure += 0.1 })
        try measure(
            "sharpen 0.45", lookChanged(engineExporter(engine)) { l in l.finish.sharpen *= 0.75 })
        try measure(
            "grain x0.75", lookChanged(engineExporter(engine)) { l in l.grainStrength *= 0.75 })
        try measure("audio through Apple AAC", audioReencoded(engineExporter(engine)))
        try measure("high-pass 20 Hz", engineExporter(engine, env: ["AUDIO_HIGHPASS_HZ": "20"]))
    }

    // MARK: renders

    struct Renders {
        let plain: [URL]
        let grain: [URL]
        let sharp: [URL]
    }

    struct Rig {
        let engine: EngineLocation
        let source: URL
        let look: Look
        let work: URL

        init() throws {
            engine = try engineCheckout()
            try XCTSkipIf(!engine.preflight().isEmpty, "engine preflight not clean")
            let clips =
                (try? FileManager.default.contentsOfDirectory(
                    at: engine.root.appendingPathComponent("src"),
                    includingPropertiesForKeys: nil)) ?? []
            guard
                let clip = clips.sorted(by: { $0.path < $1.path })
                    .first(where: { $0.pathExtension.lowercased() == "mov" })
            else { throw XCTSkip("no footage in src/") }
            source = clip
            look = try Look(data: Data(contentsOf: engine.lookFile))
            work = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("parity-\(UUID().uuidString)", isDirectory: true)
        }

        func renders(_ exporter: Exporter) throws -> Renders {
            var plain = look
            plain.finish.sharpen = 0
            plain.grainStrength = 0
            var grain = plain
            grain.grainStrength = look.grainStrength
            var sharp = plain
            sharp.finish.sharpen = look.finish.sharpen
            func one(_ l: Look, _ name: String) throws -> [URL] {
                let out = work.appendingPathComponent("\(name)-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
                return try exporter(
                    source, l, ExportParityTests.delivery, Project.ClipSettings(),
                    ExportParityTests.proofSeconds, out)
            }
            return Renders(
                plain: try one(plain, "plain"), grain: try one(grain, "grain"),
                sharp: try one(sharp, "sharp"))
        }
    }

    // MARK: measurement

    struct Measurement {
        var size = (0, 0), referenceSize = (0, 0)
        var shift = 0
        var gradeP95 = 0.0
        var sharpenRatio = 0.0
        var grainRatio = 0.0
        var tags: [String] = [], referenceTags: [String] = []
        var frameCount = 0, referenceFrameCount = 0
        var frameRate = "", referenceFrameRate = ""
        var audioCodec = "", referenceAudioCodec = ""
        var audioDuration = 0.0, referenceAudioDuration = 0.0
        var lowBassRatio = 0.0

        init(reference r: Renders, candidate c: Renders) throws {
            let rp = try XCTUnwrap(r.plain.first)
            let cp = try XCTUnwrap(c.plain.first)
            let rg = try XCTUnwrap(r.grain.first)
            let cg = try XCTUnwrap(c.grain.first)
            let rs = try XCTUnwrap(r.sharp.first)
            let cs = try XCTUnwrap(c.sharp.first)
            referenceSize = try Media.size(rp)
            size = try Media.size(cp)
            guard size == referenceSize else { return }

            var shifts: [Int] = []
            var blocks: [Double] = []
            var sharpGain = (0.0, 0.0)
            var grainVar = (0.0, 0.0)
            for n in ExportParityTests.frames {
                let a = try Frame(rp, n, colour: true)
                // The same file twice when the candidate is the engine: decoded once.
                let b = cp == rp ? a : try Frame(cp, n, colour: true)
                shifts.append(Frame.registration(a, b))
                blocks += Frame.blockDeltaE(a, b)
                let sr = try Frame(rs, n)
                let sc = cs == rs ? sr : try Frame(cs, n)
                sharpGain.0 += sr.fineDetail / a.fineDetail
                sharpGain.1 += sc.fineDetail / b.fineDetail
                let gr = try Frame(rg, n)
                let gc = cg == rg ? gr : try Frame(cg, n)
                grainVar.0 += Frame.grainVariance(on: gr, off: a)
                grainVar.1 += Frame.grainVariance(on: gc, off: b)
            }
            shift = shifts.max() ?? 0
            blocks.sort()
            gradeP95 = blocks.isEmpty ? 0 : blocks[Int(Double(blocks.count - 1) * 0.95)]
            sharpenRatio = sharpGain.1 / sharpGain.0
            grainRatio = (max(0, grainVar.1) / max(1e-12, grainVar.0)).squareRoot()

            referenceTags = try Media.colourTags(rp)
            tags = try Media.colourTags(cp)
            referenceFrameCount = try Media.frameCount(rp)
            frameCount = try Media.frameCount(cp)
            referenceFrameRate = try Media.field(rp, "v:0", "stream=r_frame_rate")
            frameRate = try Media.field(cp, "v:0", "stream=r_frame_rate")
            referenceAudioCodec = try Media.field(rp, "a:0", "stream=codec_name")
            audioCodec = try Media.field(cp, "a:0", "stream=codec_name")
            referenceAudioDuration = Double(try Media.field(rp, "a:0", "stream=duration")) ?? 0
            audioDuration = Double(try Media.field(cp, "a:0", "stream=duration")) ?? 0
            lowBassRatio = try Media.lowBass(cp) / max(1e-12, try Media.lowBass(rp))
        }
    }
}

// MARK: - exporters

/// grade.sh through the app's own environment, as the app runs it. `env` overrides a variable and
/// `cropShift` moves the crop window by source pixels from centre, both for calibration only.
func engineExporter(_ engine: EngineLocation, env extra: [String: String] = [:], cropShift: Int = 0)
    -> Exporter
{
    return { source, look, delivery, clip, proof, outputDirectory in
        let work = outputDirectory.appendingPathComponent(".engine", isDirectory: true)
        let src = work.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        let linked = src.appendingPathComponent(source.lastPathComponent)
        try? FileManager.default.createSymbolicLink(at: linked, withDestinationURL: source)
        let lookFile = work.appendingPathComponent("look.json")
        try look.write(to: lookFile)
        let stem = source.deletingPathExtension().lastPathComponent
        var clipSettings = clip
        if cropShift != 0 {
            let size = try Media.size(source)
            let (w, h) = (max(size.0, size.1), min(size.0, size.1))
            // A 4:5 window on a portrait frame moves vertically: centre is half the spare rows.
            let window = h * 5 / 4
            clipSettings.cropOffset = (w - window) / 2 + cropShift
        }
        let project = Project(
            presets: [.init(name: "p", look: look)], activePreset: "p", delivery: delivery,
            exportPreset: .custom, clips: [stem: clipSettings])
        var env = project.environment(for: stem, lookFile: lookFile)
        env["GRADE_WORK_DIR"] = work.path
        env["EXPORT_DIR"] = outputDirectory.path
        if let proof { env["PROOF"] = String(proof) }
        for (k, v) in extra { env[k] = v }
        let outcome = try EngineRun(engine: engine).run(
            arguments: [linked.path], environment: env)
        guard outcome.exitCode == 0 else {
            throw NSError(
                domain: "parity", code: Int(outcome.exitCode),
                userInfo: [NSLocalizedDescriptionKey: "grade.sh failed: \(outcome.stderrText)"])
        }
        // A proof lands under .loggrade/proofs with its length in the name; the export's name is
        // the deliverable's without it.
        return try outcome.events.filter { $0.name == "output" }.compactMap(\.path).map { path in
            let from = URL(fileURLWithPath: path)
            let name = from.lastPathComponent.replacingOccurrences(
                of: #"_proof-[0-9.]+s(?=\.)"#, with: "", options: .regularExpression)
            let to = outputDirectory.appendingPathComponent(name)
            if from != to { try FileManager.default.moveItem(at: from, to: to) }
            return to
        }
    }
}

/// An exporter whose look is changed before it renders.
func lookChanged(_ exporter: @escaping Exporter, _ change: @escaping (inout Look) -> Void)
    -> Exporter
{
    return { source, look, delivery, clip, proof, out in
        var changed = look
        change(&changed)
        return try exporter(source, changed, delivery, clip, proof, out)
    }
}

/// An exporter whose video is decoded, filtered and encoded again, audio copied.
func reencoding(_ exporter: @escaping Exporter, filter: String) -> Exporter {
    return { source, look, delivery, clip, proof, out in
        try exporter(source, look, delivery, clip, proof, out).map { file in
            let tmp = file.deletingLastPathComponent().appendingPathComponent(
                "re-" + file.lastPathComponent)
            _ = try Media.run(
                "ffmpeg",
                [
                    "-v", "error", "-y", "-i", file.path, "-vf", filter, "-c:v", "libx264", "-crf",
                    "18",
                    "-pix_fmt", "yuv420p", "-c:a", "copy", "-map_metadata", "0",
                    "-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709",
                    tmp.path,
                ])
            try FileManager.default.removeItem(at: file)
            try FileManager.default.moveItem(at: tmp, to: file)
            return file
        }
    }
}

/// An exporter whose audio is encoded again with Apple's AAC encoder, the one AVAssetWriter uses.
func audioReencoded(_ exporter: @escaping Exporter) -> Exporter {
    return { source, look, delivery, clip, proof, out in
        try exporter(source, look, delivery, clip, proof, out).map { file in
            let tmp = file.deletingLastPathComponent().appendingPathComponent(
                "re-" + file.lastPathComponent)
            _ = try Media.run(
                "ffmpeg",
                [
                    "-v", "error", "-y", "-i", file.path, "-c:v", "copy", "-c:a", "aac_at", "-b:a",
                    "192k",
                    tmp.path,
                ])
            try FileManager.default.removeItem(at: file)
            try FileManager.default.moveItem(at: tmp, to: file)
            return file
        }
    }
}

// MARK: - media

enum Media {
    static func run(_ tool: String, _ arguments: [String]) throws -> Data {
        guard let url = EngineLocation.resolveTool(tool) else { throw XCTSkip("no \(tool)") }
        let process = Process()
        process.executableURL = url
        process.arguments = arguments
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        var stderr = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            stderr = err.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "parity", code: Int(process.terminationStatus),
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "\(tool) failed: \(String(decoding: stderr, as: UTF8.self))"
                ])
        }
        return data
    }

    /// One ffprobe field, one at a time, as the camera's files require.
    static func field(_ file: URL, _ stream: String, _ entry: String) throws -> String {
        let out = try run(
            "ffprobe",
            [
                "-v", "error", "-select_streams", stream, "-show_entries", entry,
                "-of", "default=nw=1:nk=1", file.path,
            ])
        return String(decoding: out, as: UTF8.self)
            .split(separator: "\n").first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
    }

    static func size(_ file: URL) throws -> (Int, Int) {
        let w = Int(try field(file, "v:0", "stream=width")) ?? 0
        let h = Int(try field(file, "v:0", "stream=height")) ?? 0
        return (w, h)
    }

    static func colourTags(_ file: URL) throws -> [String] {
        try ["color_primaries", "color_transfer", "color_space", "color_range"].map {
            try field(file, "v:0", "stream=\($0)")
        }
    }

    static func frameCount(_ file: URL) throws -> Int {
        let out = try run(
            "ffprobe",
            [
                "-v", "error", "-count_frames", "-select_streams", "v:0",
                "-show_entries", "stream=nb_read_frames", "-of", "default=nw=1:nk=1", file.path,
            ])
        return Int(String(decoding: out, as: UTF8.self).split(separator: "\n").first ?? "") ?? 0
    }

    /// Share of audio energy below 30 Hz, through four one-pole low-passes: what a 60 Hz high-pass
    /// removes and a missing one leaves.
    static func lowBass(_ file: URL) throws -> Double {
        let data = try run(
            "ffmpeg",
            ["-v", "error", "-i", file.path, "-ac", "1", "-ar", "48000", "-f", "f32le", "-"])
        let samples = data.withUnsafeBytes { Array($0.bindMemory(to: Float32.self)) }
        let a = 1 - exp(-2 * Double.pi * 30 / 48000)
        var p = [0.0, 0.0, 0.0, 0.0]
        var low = 0.0
        var total = 0.0
        for s in samples {
            let x = Double(s)
            p[0] += a * (x - p[0])
            p[1] += a * (p[0] - p[1])
            p[2] += a * (p[1] - p[2])
            p[3] += a * (p[2] - p[3])
            low += p[3] * p[3]
            total += x * x
        }
        return total > 0 ? low / total : 0
    }
}

// MARK: - frames

struct Frame {
    let width: Int, height: Int
    /// Displayed light per channel, decoded as Apple playback decodes (the BT.709 inverse OETF).
    /// Empty unless asked for: only the grade check reads colour.
    let r: [Double], g: [Double], b: [Double]
    /// Luma as the file stores it, in 8-bit code values: banding, grain and sharpening are
    /// properties of the encoded codes, and an RGB decode would round them again.
    let y: [Double]

    /// The decode, tabulated over every 16-bit code: a `pow` per pixel dominated a debug build.
    static let displayLight: [Double] = (0...65535).map { code in
        let v = Double(code) / 65535
        return v < 0.081 ? v / 4.5 : pow((v + 0.099) / 1.099, 1 / 0.45)
    }

    init(_ file: URL, _ n: Int, colour: Bool = false) throws {
        (width, height) = try Media.size(file)
        if !colour {
            (r, g, b) = ([], [], [])
        } else {
            let data = try Media.run(
                "ffmpeg",
                [
                    "-v", "error", "-i", file.path, "-vf", "select='eq(n\\,\(n))',format=rgb48le",
                    "-frames:v", "1", "-f", "rawvideo", "-",
                ])
            guard data.count == width * height * 6 else {
                throw XCTSkip("frame \(n) of \(file.lastPathComponent) did not decode")
            }
            let raw = data.withUnsafeBytes { Array($0.bindMemory(to: UInt16.self)) }
            let light = Frame.displayLight
            var r = [Double](repeating: 0, count: width * height)
            var g = r
            var b = r
            for i in 0..<(width * height) {
                r[i] = light[Int(raw[3 * i])]
                g[i] = light[Int(raw[3 * i + 1])]
                b[i] = light[Int(raw[3 * i + 2])]
            }
            (self.r, self.g, self.b) = (r, g, b)
        }
        // The first plane of the stored picture, whatever its chroma layout: take 8-bit 4:2:0.
        let planes = try Media.run(
            "ffmpeg",
            [
                "-v", "error", "-i", file.path, "-vf", "select='eq(n\\,\(n))',format=yuv420p",
                "-frames:v", "1", "-f", "rawvideo", "-",
            ])
        guard planes.count >= width * height else {
            throw XCTSkip("frame \(n) of \(file.lastPathComponent) has no luma plane")
        }
        y = planes.prefix(width * height).map(Double.init)
    }

    /// The shift, in whole pixels up to 3, that best aligns b to a on the frame's centre.
    static func registration(_ a: Frame, _ b: Frame) -> Int {
        let w = a.width
        let h = a.height
        let box = 160
        let x0 = w / 2 - box / 2
        let y0 = h / 2 - box / 2
        var best = (Double.infinity, 0)
        for dy in -3...3 {
            for dx in -3...3 {
                var sum = 0.0
                for y in y0..<(y0 + box) {
                    for x in x0..<(x0 + box) {
                        sum += abs(a.y[y * w + x] - b.y[(y + dy) * w + x + dx])
                    }
                }
                if sum < best.0 { best = (sum, max(abs(dx), abs(dy))) }
            }
        }
        return best.1
    }

    /// Oklab distance between the mean colours of 32 px blocks.
    static func blockDeltaE(_ a: Frame, _ b: Frame) -> [Double] {
        let n = 32
        var out: [Double] = []
        for by in stride(from: 0, to: a.height - n + 1, by: n) {
            for bx in stride(from: 0, to: a.width - n + 1, by: n) {
                var ma = (0.0, 0.0, 0.0)
                var mb = (0.0, 0.0, 0.0)
                for y in by..<(by + n) {
                    for x in bx..<(bx + n) {
                        let i = y * a.width + x
                        ma = (ma.0 + a.r[i], ma.1 + a.g[i], ma.2 + a.b[i])
                        mb = (mb.0 + b.r[i], mb.1 + b.g[i], mb.2 + b.b[i])
                    }
                }
                let k = Double(n * n)
                let la = oklab(ma.0 / k, ma.1 / k, ma.2 / k)
                let lb = oklab(mb.0 / k, mb.1 / k, mb.2 / k)
                out.append(
                    ((la.0 - lb.0) * (la.0 - lb.0) + (la.1 - lb.1) * (la.1 - lb.1) + (la.2 - lb.2)
                        * (la.2 - lb.2))
                        .squareRoot())
            }
        }
        return out
    }

    /// Fine detail, where the sharpener works: mean absolute luma minus its 3 px box.
    var fineDetail: Double {
        zip(y, Frame.box(y, width, height, 1)).map { abs($0 - $1) }.reduce(0, +) / Double(y.count)
    }

    /// The grain's variance: high-passed luma variance with grain, minus without. Encoder noise is
    /// in both and cancels, which a difference of the two frames would double instead.
    static func grainVariance(on: Frame, off: Frame) -> Double {
        func highPassEnergy(_ f: Frame) -> Double {
            zip(f.y, box(f.y, f.width, f.height, 2)).map { ($0 - $1) * ($0 - $1) }.reduce(0, +)
        }
        return (highPassEnergy(on) - highPassEnergy(off)) / Double(on.y.count)
    }

    static func box(_ v: [Double], _ w: Int, _ h: Int, _ r: Int) -> [Double] {
        var tmp = [Double](repeating: 0, count: v.count)
        var out = tmp
        for y in 0..<h {
            var acc = 0.0
            for x in 0..<(w + r) {
                if x < w { acc += v[y * w + x] }
                if x - 2 * r - 1 >= 0 { acc -= v[y * w + x - 2 * r - 1] }
                let c = x - r
                if c >= 0 && c < w {
                    tmp[y * w + c] = acc / Double(min(w - 1, c + r) - max(0, c - r) + 1)
                }
            }
        }
        for x in 0..<w {
            var acc = 0.0
            for y in 0..<(h + r) {
                if y < h { acc += tmp[y * w + x] }
                if y - 2 * r - 1 >= 0 { acc -= tmp[(y - 2 * r - 1) * w + x] }
                let c = y - r
                if c >= 0 && c < h {
                    out[c * w + x] = acc / Double(min(h - 1, c + r) - max(0, c - r) + 1)
                }
            }
        }
        return out
    }

    static func oklab(_ r: Double, _ g: Double, _ b: Double) -> (Double, Double, Double) {
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        return (
            0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
            1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
            0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
        )
    }
}
