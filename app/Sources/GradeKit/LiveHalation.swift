import Foundation

/// Halation in the live preview: the glow bright things spill into their surroundings, applied to
/// the source frame after the correction and before Apple's conversion, where the engine applies it.
///
/// TWO KINDS OF LICENCE, because the stage has two kinds of part. The per-pixel arithmetic — decode
/// to linear, subtract the threshold, add the glow, encode back — is a transcription of
/// `scripts/make-halation-luts.py` and `halation_prefix` in `scripts/lib.sh`, and
/// `LiveHalationTests` holds it to the generator's own cubes entry for entry. The blur cannot be
/// held that way: the render blurs a quarter-resolution copy of a 4K frame with ffmpeg's recursive
/// approximation and the preview blurs a 480-line frame with a true Gaussian. That part is held to
/// the render by `LiveChainTests`, with a tolerance, which is what a tolerance is for.
///
/// The reasoning for every decision in the stage lives in those two engine files and in
/// `docs/adr/0012`. It is not repeated here.
public struct LiveHalation {
    let strength: Float
    let threshold: Double
    let tint: SIMD3<Float>
    /// In pixels of the frame being graded. The look stores a fraction of the frame's height, so
    /// a 480-line preview and a 3840-line render blur the same part of the picture.
    let sigma: Float

    /// BT.2020, because Apple Log's primaries are BT.2020. The same weights the engine writes into
    /// its channel mixer.
    static let lumaWeights = SIMD3<Float>(0.2627, 0.6780, 0.0593)

    /// Nil when the stage would do nothing, or when the tint is not a value the engine accepts —
    /// a live picture of something the render refuses is worse than none.
    public init?(_ halation: Look.Halation, frameHeight: Int) {
        guard !halation.isNeutral, let t = halation.tintValues else { return nil }
        strength = Float(halation.strength)
        threshold = halation.threshold
        tint = SIMD3(Float(t.0), Float(t.1), Float(t.2))
        sigma = Float(halation.radius) * Float(frameHeight)
    }

    /// `halation-threshold.cube`, one entry.
    static func thresholded(_ logValue: Double, threshold: Double) -> Double {
        max(0, CorrectionCube.decode(logValue) - threshold)
    }

    /// Adds the glow to a frame of Apple Log values, interleaved RGB, in place.
    func apply(to log: inout [Float], width: Int, height: Int) {
        let count = width * height
        var linear = [Float](repeating: 0, count: count * 3)
        var highlight = [Float](repeating: 0, count: count)
        let t = threshold
        log.withUnsafeBufferPointer { src in
            linear.withUnsafeMutableBufferPointer { lin in
                highlight.withUnsafeMutableBufferPointer { hi in
                    LiveChain.inBands(height: height) { rows in
                        for i in (rows.lowerBound * width)..<(rows.upperBound * width) {
                            var h = SIMD3<Float>()
                            for c in 0..<3 {
                                let decoded = CorrectionCube.decode(Double(src[i * 3 + c]))
                                lin[i * 3 + c] = Float(decoded)
                                h[c] = Float(max(0, decoded - t))
                            }
                            hi[i] = (h * Self.lumaWeights).sum()
                        }
                    }
                }
            }
        }

        let blurred = Self.gaussian(highlight, width: width, height: height, sigma: sigma)
        let gain = tint * strength
        log.withUnsafeMutableBufferPointer { out in
            linear.withUnsafeBufferPointer { lin in
                highlight.withUnsafeBufferPointer { hi in
                    blurred.withUnsafeBufferPointer { blur in
                        LiveChain.inBands(height: height) { rows in
                            for i in (rows.lowerBound * width)..<(rows.upperBound * width) {
                                // Edge-only: what the blur spreads past the highlight, never the
                                // highlight glowing onto itself.
                                let glow = blur[i] - hi[i]
                                guard glow > 0 else { continue }
                                for c in 0..<3 {
                                    let lit = Double(lin[i * 3 + c] + gain[c] * glow)
                                    out[i * 3 + c] = Float(min(1, CorrectionCube.encode(lit)))
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// A separable Gaussian with edges clamped, out to three sigma.
    static func gaussian(_ plane: [Float], width: Int, height: Int, sigma: Float) -> [Float] {
        guard sigma > 0.05 else { return plane }
        let radius = Int((sigma * 3).rounded(.up))
        var kernel = (-radius...radius).map { exp(-Float($0 * $0) / (2 * sigma * sigma)) }
        let total = kernel.reduce(0, +)
        kernel = kernel.map { $0 / total }

        var across = [Float](repeating: 0, count: plane.count)
        plane.withUnsafeBufferPointer { src in
            across.withUnsafeMutableBufferPointer { dst in
                LiveChain.inBands(height: height) { rows in
                    for y in rows {
                        let row = y * width
                        for x in 0..<width {
                            var sum: Float = 0
                            for k in -radius...radius {
                                sum += src[row + min(width - 1, max(0, x + k))] * kernel[k + radius]
                            }
                            dst[row + x] = sum
                        }
                    }
                }
            }
        }
        var down = [Float](repeating: 0, count: plane.count)
        across.withUnsafeBufferPointer { src in
            down.withUnsafeMutableBufferPointer { dst in
                LiveChain.inBands(height: height) { rows in
                    for y in rows {
                        for x in 0..<width {
                            var sum: Float = 0
                            for k in -radius...radius {
                                sum += src[min(height - 1, max(0, y + k)) * width + x]
                                    * kernel[k + radius]
                            }
                            dst[y * width + x] = sum
                        }
                    }
                }
            }
        }
        return down
    }
}
