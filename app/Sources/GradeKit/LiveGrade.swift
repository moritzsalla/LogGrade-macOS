import CoreGraphics
import Foundation

/// The grade, applied in the app, so a control can be dragged and seen.
///
/// THIS IS A SECOND IMPLEMENTATION OF THE IMAGE, which this repo allows only when a test can hold
/// it to the first. That test exists: `tests/grade-parity.py` measures this model against ffmpeg's
/// own output over a probe, and `LiveGradeTests` runs the same comparison against the same golden
/// in Swift. On the shipped look it is within about 2 code values of the render.
///
/// WHAT IT MODELS, and why it is not the obvious thing. `lut1d` cannot process a YUV plane, so
/// ffmpeg converts to planar RGB around it: the tone curve is applied to R, G and B INDEPENDENTLY,
/// and `mergeplanes` then takes the luma of that and merges the ORIGINAL chroma back. Modelling
/// the description — curve the luma — is wrong by about 30 code values, which is what the browser
/// bench did for months.
///
/// WHAT IT DOES NOT MODEL. The input correction runs BEFORE Apple's conversion, so it cannot be
/// applied to an already-converted frame: changing exposure or white balance needs the engine.
/// The interface says so rather than showing a picture that ignores a control.
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

    /// One pixel, in 0...255, from a frame that has been through the conversion and the look.
    /// One pixel, given the curve already applied to each channel.
    ///
    /// ONE BODY, TWO CALLERS, and that is not tidiness either. This arithmetic was written twice —
    /// once here and once inside the whole-frame loop — and the two copies already disagreed on
    /// how they spelled the green coefficient. Only the per-pixel copy is held to the golden, so
    /// the copy the app actually runs was the untested one: removing the chroma clamp from it left
    /// every test green. The curve values come in as arguments because the two callers get them
    /// differently — one evaluates the curve, one reads a table — and that is the only difference
    /// between them that is allowed to exist.
    @inline(__always)
    func merge(r: Double, g: Double, b: Double,
               lr: Double, lg: Double, lb: Double) -> (Double, Double, Double) {
        let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
        var cb = (b - y) / 1.8556
        var cr = (r - y) / 1.5748

        // Per channel, then take the luma of that: what lut1d does once ffmpeg has converted the
        // plane to RGB for it.
        var ny = 0.2126 * lr + 0.7152 * lg + 0.0722 * lb

        if saturation != 1 { cb *= saturation; cr *= saturation }

        // Clamped in the PLANE, which is where the renderer clamps, not in RGB afterwards.
        ny = min(255, max(0, ny))
        cb = min(127, max(-128, cb))
        cr = min(127, max(-128, cr))

        var outR = ny + 1.5748 * cr
        var outG = ny - (0.2126 * 1.5748 / 0.7152) * cr - (0.0722 * 1.8556 / 0.7152) * cb
        var outB = ny + 1.8556 * cb

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

    /// The look to render the base frame with: everything this model applies, turned off.
    ///
    /// IT LIVES HERE, next to the model that consumes it, because the two are one contract. Held
    /// separately they drift silently: a control added to the model and not neutralised here gets
    /// applied twice, and nothing would say so — the picture would simply be wrong in a way that
    /// looks like a grade. The test uses this same function, so it tests the arrangement the app
    /// runs rather than a second copy of it that happens to agree today.
    ///
    /// Render it with exposure matching OFF. Matching does not pass a gamma of 1 through: it
    /// solves a per-clip gamma from it and `solve-gamma.py` clamps the answer to at least 1.2.
    public static func base(for look: Look) -> Look {
        var base = look
        base.tone.gamma = 1
        base.tone.contrast = 1
        base.tone.toe = 0
        base.tone.shoulder = 0
        base.tone.black = 0
        base.colour.saturation = 1
        base.colour.warmth = 0
        return base
    }

    /// A whole frame. The base image is the clip through the conversion and the look with the tone
    /// stage neutral — which is the input this model expects, and what the engine renders when it
    /// is handed an identity curve.
    public func apply(to image: CGImage) -> CGImage? {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let space = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: &pixels, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        // A 256-entry table, because the curve is the same for every pixel and evaluating it four
        // million times is the difference between a drag that follows and one that stutters.
        var table = [Double](repeating: 0, count: 256)
        for i in 0..<256 { table[i] = curve.value(at: Double(i) / 255) * 255 }

        var index = 0
        while index + 3 < pixels.count {
            let r = pixels[index], g = pixels[index + 1], b = pixels[index + 2]
            // The table is exact rather than an approximation: the input is 8-bit, so its 256
            // entries are every value the curve can be asked for.
            let out = merge(r: Double(r), g: Double(g), b: Double(b),
                            lr: table[Int(r)], lg: table[Int(g)], lb: table[Int(b)])
            pixels[index] = UInt8(out.0)
            pixels[index + 1] = UInt8(out.1)
            pixels[index + 2] = UInt8(out.2)
            index += 4
        }
        return context.makeImage()
    }
}
