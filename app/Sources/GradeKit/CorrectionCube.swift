import Foundation

/// The input-correction stage, built in this process so a slider can be dragged against it.
///
/// A SECOND IMPLEMENTATION, AND THE ONLY ONE IN THE APP THAT DECIDES ANYTHING ABOUT THE IMAGE. It
/// exists because the engine's `scripts/make-correct-lut.py` costs 419ms a call — almost all of it
/// Python starting up rather than the 36,000 samples — and a control that redraws twice a second
/// is not a control you can find a value with. Every other stage the live preview applies is read
/// from a file the render also reads.
///
/// WHAT MAKES IT SAFE. `CorrectionCubeTests` builds a cube here and the same cube with the
/// generator and compares every one of the 107,811 numbers. It is not a tolerance test: the two
/// must agree to eight decimal places, which is the precision the generator prints. Change either
/// and the test says so by name. The maths below is therefore a transcription, and it is commented
/// as one — the reasoning for every decision in it lives in the generator's own header, which is
/// where it belongs and where it is not duplicated.
public struct CorrectionCube {
    // Apple's published Log Profile transfer function. Constants copied from the generator, which
    // took them from the white paper; luts/apple/SOURCE.txt carries the provenance.
    static let r0 = -0.05641088
    private static let rt = 0.01
    private static let c = 47.28711236
    private static let beta = 0.00964052
    private static let gamma = 0.08550479
    private static let delta = 0.69336945
    private static var pt: Double { c * (rt - r0) * (rt - r0) }
    private static let lumaWeights = (0.2126, 0.7152, 0.0722)

    /// Apple Log code value to linear scene reflectance.
    static func decode(_ p: Double) -> Double {
        if p < 0 { return r0 }
        if p < pt { return (p / c).squareRoot() + r0 }
        return pow(2, (p - delta) / gamma) - beta
    }

    /// Linear scene reflectance to Apple Log code value.
    static func encode(_ r: Double) -> Double {
        if r < r0 { return 0 }
        if r < rt { return c * (r - r0) * (r - r0) }
        return gamma * log2(r + beta) + delta
    }

    private static func triple(_ text: String) -> (Double, Double, Double)? {
        let parts = text.split(separator: ",").map { Double($0.trimmingCharacters(in: .whitespaces)) }
        if parts.count == 1, let only = parts[0] { return (only, only, only) }
        guard parts.count == 3, let r = parts[0], let g = parts[1], let b = parts[2] else {
            return nil
        }
        return (r, g, b)
    }

    /// One triple of Apple Log code values in, one out. Nil when a value the generator would
    /// reject reaches it, so a malformed CDL refuses rather than rendering something arbitrary.
    public static func cube(for correct: Look.Correct, size: Int) -> Cube3D? {
        guard size > 1,
              let slope = triple(correct.slope), let offset = triple(correct.offset),
              let power = triple(correct.power),
              power.0 > 0, power.1 > 0, power.2 > 0 else { return nil }

        // Temperature and tint as per-channel linear gains, on the generator's scale.
        let wb = (max(0.05, 1 + 0.30 * correct.temp),
                  max(0.05, 1 + 0.30 * correct.tint),
                  max(0.05, 1 - 0.30 * correct.temp - 0.15 * correct.tint))
        let exposureGain = correct.exposure == 0 ? 1 : pow(2, correct.exposure)
        let hasCDL = slope != (1, 1, 1) || offset != (0, 0, 0) || power != (1, 1, 1)

        var samples = [SIMD3<Float>](repeating: .zero, count: size * size * size)
        let last = Double(size - 1)
        var index = 0
        for bi in 0..<size {
            let b = Double(bi) / last
            for gi in 0..<size {
                let g = Double(gi) / last
                for ri in 0..<size {
                    let r = Double(ri) / last
                    var out = (decode(r) * exposureGain * wb.0,
                               decode(g) * exposureGain * wb.1,
                               decode(b) * exposureGain * wb.2)
                    out = (encode(out.0), encode(out.1), encode(out.2))

                    if hasCDL {
                        func cdl(_ v: Double, _ s: Double, _ o: Double, _ p: Double) -> Double {
                            let lifted = max(0, v * s + o)
                            return p == 1 ? lifted : pow(lifted, 1 / p)
                        }
                        out = (cdl(out.0, slope.0, offset.0, power.0),
                               cdl(out.1, slope.1, offset.1, power.1),
                               cdl(out.2, slope.2, offset.2, power.2))
                    }

                    if correct.lumMix != 1 {
                        let yIn = lumaWeights.0 * r + lumaWeights.1 * g + lumaWeights.2 * b
                        let yOut = lumaWeights.0 * out.0 + lumaWeights.1 * out.1
                            + lumaWeights.2 * out.2
                        if yOut > 1e-6 {
                            let k = (1 - correct.lumMix) * (yIn / yOut) + correct.lumMix
                            out = (out.0 * k, out.1 * k, out.2 * k)
                        }
                    }

                    samples[index] = SIMD3(Float(min(1, max(0, out.0))),
                                           Float(min(1, max(0, out.1))),
                                           Float(min(1, max(0, out.2))))
                    index += 1
                }
            }
        }
        return Cube3D(size: size, samples: samples)
    }
}
