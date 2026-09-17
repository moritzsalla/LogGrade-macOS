import Foundation

/// Grain in the negative, as `grain_prefix` in scripts/lib.sh adds it: noise in the LOG picture
/// before the conversion cube, so the stock's own toe and shoulder shape it. Exports only.
///
/// ONE NOISE FOR THE CPU AND THE GPU. The engine's comes from ffmpeg's `noise` and cannot be
/// reproduced, so the two native paths share their own: a hash of pixel, frame and channel into a
/// Gaussian (`gaussian(x:y:frame:channel:)`, and the same arithmetic in `MetalChain`'s shader), so
/// `MetalChainTests` can hold the GPU's grain to the CPU's. The engine's is held by
/// `ExportParityTests` on its size in the delivered file.
public struct LiveGrain: Equatable {
    /// Per-channel sd in log, as the engine's: strength * 0.00064.
    public let sd: Float
    /// The Gaussian softening, in pixels of the frame the grain is added to.
    public let sigma: Float

    /// The share of the grain's variance that R, G and B have in common; the rest is each channel's.
    static let shared: Float = 0.9

    public init?(strength: Double, frameWidth: Int, frameHeight: Int) {
        guard strength > 0 else { return nil }
        sd = Float(strength * 0.00064)
        let short = Float(min(frameWidth, frameHeight))
        sigma = max(0.5, 0.8 * short / 1080)
    }

    /// The normalised blur kernel, and the sum of its squared weights: a unit-variance field blurred
    /// by it has sd equal to that sum in two dimensions, which is what it is divided by.
    var kernel: (weights: [Float], sumOfSquares: Float) {
        let radius = Int((sigma * 3).rounded(.up))
        var w = (-radius...radius).map { exp(-Float($0 * $0) / (2 * sigma * sigma)) }
        let total = w.reduce(0, +)
        w = w.map { $0 / total }
        return (w, w.map { $0 * $0 }.reduce(0, +))
    }

    @inline(__always)
    static func hash(_ v: UInt32) -> UInt32 {
        let s = v &* 747_796_405 &+ 2_891_336_453
        let w = ((s >> ((s >> 28) &+ 4)) ^ s) &* 277_803_737
        return (w >> 22) ^ w
    }

    /// A unit Gaussian for one pixel of one field: channel 0 is the shared field, 1-3 red, green,
    /// blue's own.
    @inline(__always)
    static func gaussian(x: Int, y: Int, frame: Int, channel: Int) -> Float {
        let base = hash(
            UInt32(truncatingIfNeeded: frame) &* 0x9E37_79B9 ^ UInt32(channel) &* 0x85EB_CA6B)
        let a = hash(hash(base ^ UInt32(truncatingIfNeeded: x)) ^ UInt32(truncatingIfNeeded: y))
        let b = hash(a ^ 0x68E3_1DA4)
        let u1 = (Float(a >> 8) + 0.5) / 16_777_216
        let u2 = Float(b >> 8) / 16_777_216
        return (-2 * log(u1)).squareRoot() * cos(2 * Float.pi * u2)
    }

    /// Adds the grain to 3-channel float log pixels in place.
    func apply(to log: inout [Float], width: Int, height: Int, frame: Int) {
        let (weights, sumOfSquares) = kernel
        let radius = weights.count / 2
        // Four fields: the shared one and each channel's own.
        var fields = [Float](repeating: 0, count: width * height * 4)
        fields.withUnsafeMutableBufferPointer { f in
            LiveChain.inBands(height: height) { rows in
                for y in rows {
                    for x in 0..<width {
                        let i = (y * width + x) * 4
                        for c in 0..<4 {
                            f[i + c] = Self.gaussian(x: x, y: y, frame: frame, channel: c)
                        }
                    }
                }
            }
        }
        var across = fields
        fields.withUnsafeBufferPointer { src in
            across.withUnsafeMutableBufferPointer { dst in
                LiveChain.inBands(height: height) { rows in
                    for y in rows {
                        for x in 0..<width {
                            for c in 0..<4 {
                                var sum: Float = 0
                                for k in -radius...radius {
                                    let xx = min(width - 1, max(0, x + k))
                                    sum += src[(y * width + xx) * 4 + c] * weights[k + radius]
                                }
                                dst[(y * width + x) * 4 + c] = sum
                            }
                        }
                    }
                }
            }
        }
        let shared = Self.shared.squareRoot() * sd / sumOfSquares
        let own = (1 - Self.shared).squareRoot() * sd / sumOfSquares
        across.withUnsafeBufferPointer { src in
            log.withUnsafeMutableBufferPointer { out in
                LiveChain.inBands(height: height) { rows in
                    for y in rows {
                        for x in 0..<width {
                            var blurred = SIMD4<Float>(repeating: 0)
                            for k in -radius...radius {
                                let yy = min(height - 1, max(0, y + k))
                                let j = (yy * width + x) * 4
                                blurred +=
                                    SIMD4(src[j], src[j + 1], src[j + 2], src[j + 3])
                                    * weights[k + radius]
                            }
                            let i = (y * width + x) * 3
                            out[i] += shared * blurred[0] + own * blurred[1]
                            out[i + 1] += shared * blurred[0] + own * blurred[2]
                            out[i + 2] += shared * blurred[0] + own * blurred[3]
                        }
                    }
                }
            }
        }
    }
}
