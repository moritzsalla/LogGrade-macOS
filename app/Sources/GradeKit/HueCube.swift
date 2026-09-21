import Foundation

/// The hue curves, built in this process so a knot can be dragged against the picture.
///
/// A TRANSCRIPTION of `scripts/make-hue-lut.py`, which carries the reasoning for every decision
/// below; `HueCubeTests` holds the two to the eight decimal places the generator prints, the way
/// `CorrectionCubeTests` holds the correction. Change both or neither.
public struct HueCube {
    public static let knots = 12
    private static let span = 360.0 / Double(knots)
    private static let chromaFade = 0.08
    private static let fitSteps = 18
    private static let gamutEpsilon = 1e-9

    typealias Matrix = (
        (Double, Double, Double), (Double, Double, Double), (Double, Double, Double)
    )
    private static let m1: Matrix = (
        (0.4122214708, 0.5363325363, 0.0514459929),
        (0.2119034982, 0.6806995451, 0.1073969566),
        (0.0883024619, 0.2817188376, 0.6299787005)
    )
    private static let m2: Matrix = (
        (0.2104542553, 0.7936177850, -0.0040720468),
        (1.9779984951, -2.4285922050, 0.4505937099),
        (0.0259040371, 0.7827717662, -0.8086757660)
    )
    private static let m1i = inverse(m1)
    private static let m2i = inverse(m2)

    /// Written out in the generator's order of operations, so the doubles come out identical.
    static func inverse(_ m: Matrix) -> Matrix {
        let (a, b, c) = m.0
        let (d, e, f) = m.1
        let (g, h, i) = m.2
        let det = a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g)
        return (
            ((e * i - f * h) / det, (c * h - b * i) / det, (b * f - c * e) / det),
            ((f * g - d * i) / det, (a * i - c * g) / det, (c * d - a * f) / det),
            ((d * h - e * g) / det, (b * g - a * h) / det, (a * e - b * d) / det)
        )
    }

    static func mul(_ m: Matrix, _ v: (Double, Double, Double)) -> (Double, Double, Double) {
        (
            m.0.0 * v.0 + m.0.1 * v.1 + m.0.2 * v.2,
            m.1.0 * v.0 + m.1.1 * v.1 + m.1.2 * v.2,
            m.2.0 * v.0 + m.2.1 * v.1 + m.2.2 * v.2
        )
    }

    /// Apple playback's display curve, as `cubefile.py` defines it and says why.
    static let appleDisplayGamma = 502.0 / 256.0

    static func displayDecode(_ v: Double) -> Double {
        pow(max(0, v), appleDisplayGamma)
    }

    static func displayEncode(_ light: Double) -> Double {
        pow(min(1, max(0, light)), 1.0 / appleDisplayGamma)
    }

    /// Python's `%` for a positive divisor: the result takes the divisor's sign.
    private static func pythonMod(_ x: Double, _ m: Double) -> Double {
        let r = fmod(x, m)
        return r < 0 ? r + m : r
    }

    public static func spline(_ k: [Double], _ hue: Double) -> Double {
        let x = pythonMod(hue, 360) / span
        let i = Int(floor(x))
        let t = x - Double(i)
        func at(_ j: Int) -> Double { k[((j % knots) + knots) % knots] }
        let p0 = at(i - 1)
        let p1 = at(i)
        let p2 = at(i + 1)
        let p3 = at(i + 2)
        let a = 2.0 * p1 + (p2 - p0) * t
        let b = (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * t * t
        let c = (3.0 * p1 - p0 - 3.0 * p2 + p3) * t * t * t
        return 0.5 * (a + b + c)
    }

    private static func cubeRoot(_ v: Double) -> Double {
        copysign(pow(abs(v), 1.0 / 3.0), v)
    }

    private static func toLinear(_ lab: (Double, Double, Double)) -> (Double, Double, Double) {
        let lms = mul(m2i, lab)
        return mul(m1i, (pow(lms.0, 3), pow(lms.1, 3), pow(lms.2, 3)))
    }

    private static func inGamut(_ c: (Double, Double, Double)) -> Bool {
        let range = -gamutEpsilon...(1 + gamutEpsilon)
        return range.contains(c.0) && range.contains(c.1) && range.contains(c.2)
    }

    static func shape(
        _ rgb: (Double, Double, Double), rot: [Double], sat: [Double], lum: [Double]
    ) -> (Double, Double, Double) {
        let lin = (
            displayDecode(rgb.0), displayDecode(rgb.1), displayDecode(rgb.2)
        )
        let lms = mul(m1, lin)
        let lab = mul(m2, (cubeRoot(lms.0), cubeRoot(lms.1), cubeRoot(lms.2)))
        // Not hypot: Python's is its own algorithm and differs from libm in the last bit.
        let chromaIn = (lab.1 * lab.1 + lab.2 * lab.2).squareRoot()
        let f = min(1.0, chromaIn / chromaFade)
        let fade = f * f * (3.0 - 2.0 * f)
        if fade == 0 { return rgb }
        let hue = atan2(lab.2, lab.1) * 180.0 / Double.pi
        let turned = (hue + fade * spline(rot, hue)) * Double.pi / 180.0
        let chroma = chromaIn * max(0, 1.0 + fade * spline(sat, hue))
        let lightness = lab.0 * max(0, 1.0 + fade * spline(lum, hue))
        var out = toLinear((lightness, chroma * cos(turned), chroma * sin(turned)))
        if !inGamut(out) {
            var lo = 0.0
            var hi = 1.0
            for _ in 0..<fitSteps {
                let mid = (lo + hi) / 2.0
                let k = chroma * mid
                if inGamut(toLinear((lightness, k * cos(turned), k * sin(turned)))) {
                    lo = mid
                } else {
                    hi = mid
                }
            }
            let k = chroma * lo
            out = toLinear((lightness, k * cos(turned), k * sin(turned)))
        }
        return (
            displayEncode(out.0), displayEncode(out.1), displayEncode(out.2)
        )
    }

    /// A display colour for an Oklab hue, for drawing the curve editor's hue strip: mid lightness
    /// and modest chroma, pulled into gamut the way the stage pulls colours in.
    public static func swatch(hue: Double) -> (Double, Double, Double) {
        let h = hue * Double.pi / 180.0
        var chroma = 0.12
        var lin = toLinear((0.72, chroma * cos(h), chroma * sin(h)))
        while !inGamut(lin) && chroma > 0 {
            chroma -= 0.005
            lin = toLinear((0.72, chroma * cos(h), chroma * sin(h)))
        }
        return (
            pow(min(1, max(0, lin.0)), 1 / 2.2), pow(min(1, max(0, lin.1)), 1 / 2.2),
            pow(min(1, max(0, lin.2)), 1 / 2.2)
        )
    }

    /// Nil for curves the generator would refuse, so a malformed look refuses rather than rendering
    /// something arbitrary.
    public static func cube(for hue: Look.Hue, size: Int) -> Cube3D? {
        guard size > 1, let rot = hue.values(.rot), let sat = hue.values(.sat),
            let lum = hue.values(.lum)
        else { return nil }
        var samples = [SIMD3<Float>](repeating: .zero, count: size * size * size)
        let last = Double(size - 1)
        var index = 0
        for bi in 0..<size {
            let b = Double(bi) / last
            for gi in 0..<size {
                let g = Double(gi) / last
                for ri in 0..<size {
                    let o = shape((Double(ri) / last, g, b), rot: rot, sat: sat, lum: lum)
                    samples[index] = SIMD3(Float(o.0), Float(o.1), Float(o.2))
                    index += 1
                }
            }
        }
        return Cube3D(size: size, samples: samples)
    }
}
