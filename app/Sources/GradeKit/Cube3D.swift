import Foundation

/// A 3D lookup table, read from a `.cube` file, sampled the way ffmpeg samples one.
///
/// THIS IS THE ONE PORT THE LIVE PREVIEW NEEDS, and it is a port of an interpolation rule, not of
/// an image decision. The cubes themselves stay data: Apple's conversion and the film-emulation
/// look are read from the same files the render passes to `lut3d`, so there is no second copy of
/// either to drift. What is implemented here is tetrahedral interpolation, which is what the chain
/// asks for by name (`interp=tetrahedral`) in every place it applies a cube.
///
/// TETRAHEDRAL, NOT TRILINEAR, and the difference is not cosmetic. Trilinear blends eight corners
/// and pulls a saturated colour toward the cube's neutral diagonal; tetrahedral picks the one
/// tetrahedron the sample lies in and blends four. On a grade built around signage that is exactly
/// where the error would land.
public struct Cube3D: Equatable {
    public let size: Int
    /// Red fastest, then green, then blue, which is the `.cube` file order.
    public let samples: [SIMD3<Float>]

    public init(size: Int, samples: [SIMD3<Float>]) {
        self.size = size
        self.samples = samples
    }

    public enum Invalid: Error, CustomStringConvertible {
        case noSize(URL)
        case wrongCount(URL, expected: Int, found: Int)

        public var description: String {
            switch self {
            case .noSize(let url): return "\(url.lastPathComponent): no LUT_3D_SIZE"
            case .wrongCount(let url, let expected, let found):
                return "\(url.lastPathComponent): \(found) entries, expected \(expected)"
            }
        }
    }

    public init(contentsOf url: URL) throws {
        let text = try String(contentsOf: url, encoding: .utf8)
        var size = 0
        var samples: [SIMD3<Float>] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            if trimmed.hasPrefix("LUT_3D_SIZE") {
                size = Int(trimmed.split(separator: " ").last ?? "") ?? 0
                if size > 0 { samples.reserveCapacity(size * size * size) }
                continue
            }
            let parts = trimmed.split(separator: " ")
            guard parts.count == 3, let r = Float(parts[0]), let g = Float(parts[1]),
                  let b = Float(parts[2]) else { continue }
            samples.append(SIMD3(r, g, b))
        }
        guard size > 1 else { throw Invalid.noSize(url) }
        guard samples.count == size * size * size else {
            throw Invalid.wrongCount(url, expected: size * size * size, found: samples.count)
        }
        self.size = size
        self.samples = samples
    }

    @inline(__always)
    private func corner(_ r: Int, _ g: Int, _ b: Int) -> SIMD3<Float> {
        samples[(b * size + g) * size + r]
    }

    /// One sample. Input and output are 0...1.
    @inline(__always)
    public func sample(_ input: SIMD3<Float>) -> SIMD3<Float> {
        let last = Float(size - 1)
        let p = input.clamped(lowerBound: SIMD3(repeating: 0),
                              upperBound: SIMD3(repeating: 1)) * last
        let i0 = SIMD3<Int>(Int(p.x), Int(p.y), Int(p.z))
        let lo = SIMD3<Int>(min(i0.x, size - 2), min(i0.y, size - 2), min(i0.z, size - 2))
        let f = p - SIMD3(Float(lo.x), Float(lo.y), Float(lo.z))
        let (dr, dg, db) = (f.x, f.y, f.z)

        let c000 = corner(lo.x, lo.y, lo.z)
        let c111 = corner(lo.x + 1, lo.y + 1, lo.z + 1)
        // The six tetrahedra of the unit cube, ordered by which axis leads. This is the standard
        // decomposition and the one ffmpeg's lut3d uses; each branch names the two intermediate
        // corners on the path from the cell's black end to its white one.
        //
        // Written as three weights and three edges rather than one expression on purpose: as a
        // single SIMD sum per branch it type-checked for over two minutes and then timed out.
        let w0: Float, w1: Float, w2: Float
        let e0: SIMD3<Float>, e1: SIMD3<Float>
        if dr > dg {
            if dg > db {                                        // r > g > b
                (w0, w1, w2) = (dr, dg, db)
                e0 = corner(lo.x + 1, lo.y, lo.z)
                e1 = corner(lo.x + 1, lo.y + 1, lo.z)
            } else if dr > db {                                 // r > b > g
                (w0, w1, w2) = (dr, db, dg)
                e0 = corner(lo.x + 1, lo.y, lo.z)
                e1 = corner(lo.x + 1, lo.y, lo.z + 1)
            } else {                                            // b > r > g
                (w0, w1, w2) = (db, dr, dg)
                e0 = corner(lo.x, lo.y, lo.z + 1)
                e1 = corner(lo.x + 1, lo.y, lo.z + 1)
            }
        } else {
            if db > dg {                                        // b > g > r
                (w0, w1, w2) = (db, dg, dr)
                e0 = corner(lo.x, lo.y, lo.z + 1)
                e1 = corner(lo.x, lo.y + 1, lo.z + 1)
            } else if db > dr {                                 // g > b > r
                (w0, w1, w2) = (dg, db, dr)
                e0 = corner(lo.x, lo.y + 1, lo.z)
                e1 = corner(lo.x, lo.y + 1, lo.z + 1)
            } else {                                            // g > r > b
                (w0, w1, w2) = (dg, dr, db)
                e0 = corner(lo.x, lo.y + 1, lo.z)
                e1 = corner(lo.x + 1, lo.y + 1, lo.z)
            }
        }
        var result = c000
        var step = e0 - c000
        result += step * w0
        step = e1 - e0
        result += step * w1
        step = c111 - e1
        result += step * w2
        return result
    }

    /// Reads a cube one of the engine's generators writes to stdout. The app does not call this:
    /// it is the oracle `CorrectionCubeTests` holds `CorrectionCube` to. The output goes through a
    /// temporary file so it is parsed by the same reader as every cube on disk.
    public static func fromGenerator(_ generator: URL, arguments: [String]) throws -> Cube3D {
        let process = Process()
        process.executableURL = generator
        process.arguments = arguments
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(UUID().uuidString).cube")
        try data.write(to: scratch)
        defer { try? FileManager.default.removeItem(at: scratch) }
        return try Cube3D(contentsOf: scratch)
    }
}
