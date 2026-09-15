import XCTest
@testable import GradeKit

/// The live halation's arithmetic against the generator's cubes, and its shape against the rule.
///
/// THE ARITHMETIC IS A TRANSCRIPTION, so it is held exactly: every entry of the three cubes the
/// render reads, to the eight decimal places the generator prints. The blur is not a
/// transcription — the render and the preview blur differently sized frames with different kernels
/// — so it is held to the render by `LiveChainTests` instead.
final class LiveHalationTests: XCTestCase {
    /// The first column of a 1D cube, and the domain it declares.
    private func column(_ url: URL) throws -> (values: [Double], domainMax: Double) {
        var values: [Double] = []
        var domainMax = 1.0
        for line in try String(contentsOf: url, encoding: .utf8).split(separator: "\n") {
            if line.hasPrefix("DOMAIN_MAX") {
                domainMax = Double(line.split(separator: " ")[1]) ?? 1
                continue
            }
            guard let first = line.split(separator: " ").first, let v = Double(first) else { continue }
            values.append(v)
        }
        return (values, domainMax)
    }

    func testTheArithmeticIsTheGeneratorsOwn() throws {
        let engine = try engineCheckout()
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("halation-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let threshold = 1.3
        let process = Process()
        process.executableURL = engine.halationGenerator
        process.arguments = [dir.path, "--threshold", String(threshold)]
        process.standardOutput = Pipe()
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "the generator failed")

        // Offset by -R0 in the engine, which only exists to keep ffmpeg's lut1d inside a domain
        // starting at zero; the preview works in plain linear, so the offset is added back here to
        // compare like with like.
        let r0 = CorrectionCube.r0
        let checks: [(String, (Double) -> Double)] = [
            ("applelog-to-linear.cube", { CorrectionCube.decode($0) - r0 }),
            ("linear-to-applelog.cube", { min(1, CorrectionCube.encode($0 + r0)) }),
            ("halation-threshold.cube", { LiveHalation.thresholded($0, threshold: threshold) }),
        ]
        for (name, mine) in checks {
            let (values, domainMax) = try column(dir.appendingPathComponent(name))
            XCTAssertGreaterThan(values.count, 1000, "\(name): read almost nothing")
            var worst = 0.0
            var worstAt = 0
            for (i, theirs) in values.enumerated() {
                let x = domainMax * Double(i) / Double(values.count - 1)
                let d = abs(mine(x) - theirs)
                if d > worst { worst = d; worstAt = i }
            }
            // The generator prints eight decimal places, so rounding alone is 5e-9.
            XCTAssertLessThan(worst, 1e-8, "\(name): entry \(worstAt) differs by \(worst)")
        }
    }

    /// The same rule the engine's bats test pins: the glow spills past an edge and a bright field
    /// does not glow onto itself.
    func testTheGlowIsEdgeOnly() throws {
        let width = 256, height = 16
        var log = [Float](repeating: 0, count: width * height * 3)
        for y in 0..<height {
            for x in 0..<width {
                for c in 0..<3 { log[(y * width + x) * 3 + c] = x < width / 2 ? 0.9 : 0.3 }
            }
        }
        // Sigma 4 pixels on a 16-line frame.
        let halation = try XCTUnwrap(LiveHalation(
            Look.Halation(strength: 1, threshold: 1, radius: 0.25, tint: "1,0,0"),
            frameLongEdge: height))
        halation.apply(to: &log, width: width, height: height)
        func at(_ x: Int, _ c: Int) -> Float { log[((height / 2) * width + x) * 3 + c] }

        XCTAssertGreaterThan(at(130, 0) - 0.3, 0.01, "no red glow just past the edge")
        XCTAssertEqual(at(8, 0), 0.9, accuracy: 0.0005, "the bright field glowed onto itself")
        XCTAssertEqual(at(126, 0), 0.9, accuracy: 0.0005, "the bright side glowed at its own edge")
        XCTAssertEqual(at(250, 0), 0.3, accuracy: 0.002, "the glow reached the far side")
        for x in 0..<width {
            for c in 1...2 {
                XCTAssertEqual(at(x, c), x < width / 2 ? 0.9 : 0.3, accuracy: 0.0005,
                               "a red-only tint moved channel \(c) at \(x)")
            }
        }
    }

    func testANeutralOrMalformedHalationHasNoLiveStage() {
        XCTAssertNil(LiveHalation(Look.Halation(strength: 0), frameLongEdge: 480))
        XCTAssertNil(LiveHalation(Look.Halation(strength: 0.5, tint: "1,0.3"), frameLongEdge: 480),
                     "a tint the engine refuses got a live picture")
    }
}
