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
    /// In pixels of the frame being graded. The look stores a fraction of the frame's long edge,
    /// as `halation_sigma` in scripts/lib.sh reads it, so a 480-line preview and a 3840-line render
    /// blur the same part of the picture in either orientation.
    let sigma: Float
    /// How many times smaller the glow is computed than the frame being graded.
    let reduction: Int

    /// BT.2020, because Apple Log's primaries are BT.2020. The same weights the engine writes into
    /// its channel mixer.
    static let lumaWeights = SIMD3<Float>(0.2627, 0.6780, 0.0593)

    /// Nil when the stage would do nothing, or when the tint is not a value the engine accepts —
    /// a live picture of something the render refuses is worse than none.
    ///
    /// `sourceLongEdge` is the clip's decoded frame. The engine computes the glow on a quarter of
    /// THAT (`HALATION_SCALE` in scripts/lib.sh), so a preview larger than a quarter of the source
    /// reduces by the difference and one smaller does not reduce at all. Without it, no reduction.
    public init?(_ halation: Look.Halation, frameLongEdge: Int, sourceLongEdge: Int? = nil) {
        guard !halation.isNeutral, let t = halation.tintValues else { return nil }
        strength = Float(halation.strength)
        threshold = halation.threshold
        tint = SIMD3(Float(t.0), Float(t.1), Float(t.2))
        sigma = Float(halation.radius) * Float(frameLongEdge)
        reduction =
            sourceLongEdge.map { max(1, frameLongEdge * Self.engineReduction / max(1, $0)) } ?? 1
    }

    /// `halation-threshold.cube`, one entry.
    static func thresholded(_ logValue: Double, threshold: Double) -> Double {
        thresholded(linear: CorrectionCube.decode(logValue), threshold: threshold)
    }

    /// The same entry for a value already decoded. `apply` calls this one, because it keeps the
    /// decoded value for the glow as well, and decoding twice per channel is the hot loop's cost.
    /// Split rather than inlined so the exact test on the cube reaches the arithmetic that runs,
    /// not a copy of it beside the loop.
    @inline(__always)
    static func thresholded(linear: Double, threshold: Double) -> Double {
        max(0, linear - threshold)
    }

    /// `HALATION_SCALE` in scripts/lib.sh: the engine computes the glow on the source this many
    /// times smaller.
    static let engineReduction = 4

    /// Adds the glow to a frame of Apple Log values, interleaved RGB, in place.
    ///
    /// AT THE ENGINE'S RESOLUTION, AS THE ENGINE DOES IT: the log frame area-averaged down to about a
    /// quarter of the source, thresholded, blurred with the radius scaled to match, the sharp
    /// highlight subtracted and clamped at zero, and only that glow scaled back up bilinearly. It
    /// blurred the full preview, a ~180-tap kernel over every pixel at 2560x1440: 1.1 s on the Intel
    /// Mac, 0.12–0.15 s now. Reducing by a quarter of the PREVIEW instead broke parity at 480 lines
    /// (99.9th percentile 45 against a bound of 24), because that is far coarser than the engine.
    func apply(to log: inout [Float], width: Int, height: Int) {
        let f = reduction
        let sw = max(1, width / f)
        let sh = max(1, height / f)
        let t = threshold

        var highlight = [Float](repeating: 0, count: sw * sh)
        log.withUnsafeBufferPointer { src in
            highlight.withUnsafeMutableBufferPointer { hi in
                LiveChain.inBands(height: sh) { rows in
                    for sy in rows {
                        for sx in 0..<sw {
                            // The block's mean in log, as `scale=...:flags=area` gives.
                            var mean = SIMD3<Float>()
                            let x0 = sx * width / sw
                            let x1 = max(x0 + 1, (sx + 1) * width / sw)
                            let y0 = sy * height / sh
                            let y1 = max(y0 + 1, (sy + 1) * height / sh)
                            for y in y0..<y1 {
                                for x in x0..<x1 {
                                    let i = (y * width + x) * 3
                                    mean += SIMD3(src[i], src[i + 1], src[i + 2])
                                }
                            }
                            mean /= Float((x1 - x0) * (y1 - y0))
                            var h = SIMD3<Float>()
                            for c in 0..<3 {
                                let decoded = CorrectionCube.decode(Double(mean[c]))
                                h[c] = Float(Self.thresholded(linear: decoded, threshold: t))
                            }
                            hi[sy * sw + sx] = (h * Self.lumaWeights).sum()
                        }
                    }
                }
            }
        }

        let blurred = Self.gaussian(highlight, width: sw, height: sh, sigma: sigma / Float(f))
        // Edge-only: what the blur spreads past the highlight, never the highlight glowing onto
        // itself; clamped at zero as `nonnegative.cube` clamps it.
        var glowSmall = [Float](repeating: 0, count: sw * sh)
        for i in 0..<(sw * sh) { glowSmall[i] = max(0, blurred[i] - highlight[i]) }

        let gain = tint * strength
        log.withUnsafeMutableBufferPointer { out in
            glowSmall.withUnsafeBufferPointer { small in
                LiveChain.inBands(height: height) { rows in
                    for y in rows {
                        // Bilinear, pixel centres aligned, edges clamped.
                        let fy = max(
                            0,
                            min(Float(sh - 1), (Float(y) + 0.5) * Float(sh) / Float(height) - 0.5))
                        let y0 = Int(fy)
                        let y1 = min(sh - 1, y0 + 1)
                        let wy = fy - Float(y0)
                        for x in 0..<width {
                            let fx = max(
                                0,
                                min(
                                    Float(sw - 1), (Float(x) + 0.5) * Float(sw) / Float(width) - 0.5
                                ))
                            let x0 = Int(fx)
                            let x1 = min(sw - 1, x0 + 1)
                            let wx = fx - Float(x0)
                            let top = small[y0 * sw + x0] * (1 - wx) + small[y0 * sw + x1] * wx
                            let bottom = small[y1 * sw + x0] * (1 - wx) + small[y1 * sw + x1] * wx
                            let glow = top * (1 - wy) + bottom * wy
                            guard glow > 0 else { continue }
                            let i = (y * width + x) * 3
                            for c in 0..<3 {
                                let linear = CorrectionCube.decode(Double(out[i + c]))
                                let lit = linear + Double(gain[c] * glow)
                                out[i + c] = Float(min(1, CorrectionCube.encode(lit)))
                            }
                        }
                    }
                }
            }
        }
    }

    /// A separable Gaussian with edges clamped, out to three sigma.
    static func gaussian(_ plane: [Float], width: Int, height: Int, sigma: Float) -> [Float] {
        // At a twentieth of a pixel the neighbours' weights are below e^-200: the kernel is one tap
        // and the blur is the identity, so it is skipped rather than computed.
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
                                sum +=
                                    src[min(height - 1, max(0, y + k)) * width + x]
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
