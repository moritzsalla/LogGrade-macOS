import AppKit
import XCTest
@testable import GradeKit

/// `Cube3D.sample` against ffmpeg's `lut3d`, on a cube chosen to make them disagree.
///
/// WHY THIS TEST EXISTS AS ITS OWN THING. Tetrahedral interpolation is the one piece of the live
/// preview that is implemented here rather than read from a file the render also reads, and the
/// end-to-end comparison cannot see it: on Apple's conversion, which is smooth, picking the wrong
/// one of the six tetrahedra moves a pixel by a fraction of a code value. Deleting a whole branch
/// left every other test green. So the cube here is deliberately NOT smooth — pseudo-random
/// corners, where the six tetrahedra disagree sharply — and the probe lands inside cells rather
/// than on grid points, which is the only place interpolation is observable at all.
final class Cube3DTests: XCTestCase {
    private func engine() throws -> EngineLocation {
        let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        guard let e = EngineLocation.discover(from: here) else { throw XCTSkip("no engine") }
        return e
    }

    /// A fixed sequence, so a failure is reproducible and a rerun asks the same question.
    private struct Random {
        var state: UInt64 = 0x2545F4914F6CDD1D
        mutating func next() -> Double {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            return Double(state % 1_000_000) / 1_000_000
        }
    }

    func testItInterpolatesTheWayFfmpegDoes() throws {
        let engine = try engine()
        guard let ffmpeg = EngineLocation.resolveTool("ffmpeg") else { throw XCTSkip("no ffmpeg") }
        _ = engine

        let size = 5
        var random = Random()
        var cubeText = "LUT_3D_SIZE \(size)\n"
        var samples: [SIMD3<Float>] = []
        for _ in 0..<(size * size * size) {
            let v = SIMD3(Float(random.next()), Float(random.next()), Float(random.next()))
            samples.append(v)
            cubeText += String(format: "%.8f %.8f %.8f\n", v.x, v.y, v.z)
        }
        let cube = Cube3D(size: size, samples: samples)

        let work = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cube-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let cubeFile = work.appendingPathComponent("probe.cube")
        try cubeText.write(to: cubeFile, atomically: true, encoding: .utf8)

        // The probe: 4096 colours at fractional positions inside the cells, so every tetrahedron
        // is entered many times. Sixteen bits, because eight would quantise the answer to the same
        // size as the difference being measured.
        let side = 64
        var input = [UInt16](repeating: 65535, count: side * side * 4)
        var expected = [SIMD3<Float>](repeating: .zero, count: side * side)
        for i in 0..<(side * side) {
            let rgb = SIMD3(Float(random.next()), Float(random.next()), Float(random.next()))
            input[i * 4] = UInt16(rgb.x * 65535)
            input[i * 4 + 1] = UInt16(rgb.y * 65535)
            input[i * 4 + 2] = UInt16(rgb.z * 65535)
            // Sampled at the QUANTISED value, so this measures interpolation and not rounding.
            expected[i] = cube.sample(SIMD3(Float(UInt16(rgb.x * 65535)) / 65535,
                                            Float(UInt16(rgb.y * 65535)) / 65535,
                                            Float(UInt16(rgb.z * 65535)) / 65535))
        }
        let wide = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
            | CGBitmapInfo.byteOrder16Little.rawValue)
        let context = CGContext(data: &input, width: side, height: side, bitsPerComponent: 16,
                                bytesPerRow: side * 8, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: wide.rawValue)
        guard let probe = context?.makeImage(),
              let png = NSBitmapImageRep(cgImage: probe).representation(using: .png,
                                                                       properties: [:]) else {
            return XCTFail("could not build the probe")
        }
        let probeFile = work.appendingPathComponent("probe.png")
        let outFile = work.appendingPathComponent("out.png")
        try png.write(to: probeFile)

        let run = Process()
        run.executableURL = ffmpeg
        run.arguments = ["-v", "error", "-y", "-i", probeFile.path,
                         "-vf", "lut3d=file='\(cubeFile.path)':interp=tetrahedral",
                         "-pix_fmt", "rgb48be", outFile.path]
        run.standardError = Pipe()
        try run.run(); run.waitUntilExit()
        try XCTSkipIf(run.terminationStatus != 0, "this ffmpeg would not apply the cube")

        guard let rendered = NSImage(contentsOf: outFile)?
            .cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return XCTFail("could not read ffmpeg's output")
        }
        var out = [UInt16](repeating: 0, count: side * side * 4)
        let readBack = CGContext(data: &out, width: side, height: side, bitsPerComponent: 16,
                                 bytesPerRow: side * 8, space: CGColorSpaceCreateDeviceRGB(),
                                 bitmapInfo: wide.rawValue)
        readBack?.draw(rendered, in: CGRect(x: 0, y: 0, width: side, height: side))

        var worst = 0.0
        for i in 0..<(side * side) {
            for (c, want) in [(0, expected[i].x), (1, expected[i].y), (2, expected[i].z)] {
                worst = max(worst, abs(Double(out[i * 4 + c]) / 65535 - Double(want)))
            }
        }
        // 1/512 of full scale. ffmpeg's lut3d works in the pixel format it negotiates rather than
        // in floats, so the two cannot agree exactly; a wrong tetrahedron on this cube moves a
        // sample by tens of times this.
        XCTAssertLessThan(worst, 0.002, "worst disagreement with ffmpeg: \(worst)")
    }

    func testItReadsTheCubesTheRenderApplies() throws {
        let engine = try engine()
        let conversion = try Cube3D(contentsOf: engine.appleCube)
        XCTAssertEqual(conversion.size, 65)
        XCTAssertEqual(conversion.samples.count, 65 * 65 * 65)
        // Black stays near black and white lands near white, which is the cheapest possible check
        // that the file was read in the right axis order. Read red-slowest instead and these two
        // still pass, but the end-to-end comparison would be wildly out, so this is only here to
        // fail fast and legibly on a truncated or wrong file.
        XCTAssertLessThan(conversion.sample(SIMD3(0, 0, 0)).max(), 0.1)
        XCTAssertGreaterThan(conversion.sample(SIMD3(1, 1, 1)).min(), 0.9)
    }

    func testAMalformedCubeIsRefusedRatherThanTruncated() throws {
        let work = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(UUID().uuidString).cube")
        defer { try? FileManager.default.removeItem(at: work) }
        // A size line that promises more entries than the file carries. Silently accepting it
        // would index past the table on every lookup near white.
        try "LUT_3D_SIZE 4\n0 0 0\n1 1 1\n".write(to: work, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try Cube3D(contentsOf: work))
        try "# no size here\n0 0 0\n".write(to: work, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try Cube3D(contentsOf: work))
    }
}
