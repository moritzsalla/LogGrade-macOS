import CoreGraphics
import Foundation

/// The grade, applied in the app, so a control can be dragged and seen.
///
/// THIS IS A SECOND IMPLEMENTATION OF THE IMAGE, which this repo allows only when a test can hold
/// it to the first. Two do: `LiveGradeTests` measures this model against ffmpeg's own output over
/// a probe, recorded in the golden that `tests/grade-parity.py` keeps fresh, while
/// `LiveChainTests` measures the whole live preview against the engine's own render of real
/// footage. On the shipped look the finished picture is 1.3 code values from the render on
/// average.
///
/// WHAT IT MODELS, and why it is not the obvious thing. `lut1d` cannot process a YUV plane, so
/// ffmpeg converts to planar RGB around it: the tone curve is applied to R, G and B INDEPENDENTLY,
/// and `mergeplanes` then takes the luma of that and merges the ORIGINAL chroma back. Modelling
/// the description — curve the luma — is wrong by about 30 code values, which is what the browser
/// bench did for months.
///
/// WHERE IT SITS. This is the second half of the live preview: `LiveChain` puts the source frame
/// through the correction, the conversion and the hue curves, and hands the result here. So
/// this models exactly the part of the chain that follows those — the tone LUT and the two trims —
/// and nothing else.
public struct LiveGrade {
    public let curve: ToneCurve
    public let saturation: Double
    public let warmth: Double

    public init(curve: ToneCurve, saturation: Double, warmth: Double) {
        self.curve = curve
        self.saturation = saturation
        self.warmth = warmth
    }

    /// colorbalance's midtone window, measured rather than taken from its constants: on a ramp it
    /// is zero below level 27, peaks at 0.70 near 63, and is gone by 100.
    static func midtoneWeight(_ level: Double) -> Double {
        if level <= 0.1059 || level >= 0.3922 { return 0 }
        if level < 0.2314 { return (level - 0.1059) / (0.2314 - 0.1059) * 0.6999 }
        if level <= 0.2510 { return 0.6999 }
        return (0.3922 - level) / (0.3922 - 0.2510) * 0.6999
    }

    /// One pixel, in 0...255, from a frame that has been through the colour stages, given the
    /// curve already applied to each channel.
    ///
    /// ONE BODY, TWO CALLERS, and that is not tidiness either. This arithmetic was written twice —
    /// once here and once inside the whole-frame loop — and the two copies already disagreed on
    /// how they spelled the green coefficient. Only the per-pixel copy is held to the golden, so
    /// the copy the app actually runs was the untested one: removing the chroma clamp from it left
    /// every test green. The curve values come in as arguments because the two callers get them
    /// differently — one evaluates the curve, one reads a table — and that is the only difference
    /// between them that is allowed to exist.
    @inline(__always)
    func merge(
        r: Double, g: Double, b: Double,
        lr: Double, lg: Double, lb: Double
    ) -> (Double, Double, Double) {
        let y = Rec709.luma(r, g, b)
        var cb = (b - y) / Rec709.cbScale
        var cr = (r - y) / Rec709.crScale

        // Per channel, then take the luma of that: what lut1d does once ffmpeg has converted the
        // plane to RGB for it.
        var ny = Rec709.luma(lr, lg, lb)

        if saturation != 1 {
            cb *= saturation
            cr *= saturation
        }

        // Clamped in the PLANE, which is where the renderer clamps, not in RGB afterwards.
        ny = min(255, max(0, ny))
        cb = min(127, max(-128, cb))
        cr = min(127, max(-128, cr))

        var outR = ny + Rec709.crScale * cr
        let outG =
            ny - (Rec709.kr * Rec709.crScale / Rec709.kg) * cr
            - (Rec709.kb * Rec709.cbScale / Rec709.kg) * cb
        var outB = ny + Rec709.cbScale * cb

        if warmth != 0 {
            let w = warmth * 255 * Self.midtoneWeight(ny / 255)
            outR += w
            outB -= w
        }
        return (min(255, max(0, outR)), min(255, max(0, outG)), min(255, max(0, outB)))
    }

    public func apply(r: Double, g: Double, b: Double) -> (Double, Double, Double) {
        func curved(_ v: Double) -> Double { curve.value(at: min(1, max(0, v / 255))) * 255 }
        return merge(r: r, g: g, b: b, lr: curved(r), lg: curved(g), lb: curved(b))
    }
}
