import CoreGraphics
import Foundation

/// Waveform, parade and vectorscope, measured on a processed frame rather than predicted.
///
/// Two frames reach them. The engine's still is the render itself — one frame through the real
/// chain — so a scope computed from it measures what was produced rather than what an app thinks
/// would be produced. While a control is moving they read the live preview's frame instead, which
/// `LiveChainTests` holds to within a few code values of that render. Every grading suite's scopes
/// read the processed image for the same reason.
///
/// The three reference targets are the colours this pipeline calibrates against: the Dutch plate
/// yellow and two traffic signs, whose values are legally standardised. They are drawn as targets
/// to measure from, not as places to arrive: the shipped grade sits deliberately off spec.
public struct Scopes: Equatable {
    /// 256 bins, each the count of pixels at that level.
    public let luma: [Int]
    public let red: [Int]
    public let green: [Int]
    public let blue: [Int]
    /// Chroma occupancy on a 128x128 grid, Cb across and Cr down, centred on neutral.
    public let vector: [Int]
    public let sampleCount: Int

    public static let vectorSize = 128

    /// RAL colours in sRGB, which is itself an approximation — RAL is defined by a physical
    /// sample, not by a triple. Close enough to aim at, and labelled so nobody reads them as
    /// ground truth.
    public struct Reference: Equatable {
        public let name: String
        public let ral: String
        public let rgb: (Double, Double, Double)

        public static func == (a: Reference, b: Reference) -> Bool {
            a.name == b.name && a.ral == b.ral && a.rgb == b.rgb
        }
    }

    /// Named on its own because it is also the interface's accent, and an accent that drifted from
    /// the target it claims to be would be a colour the tool does not know the value of.
    public static let plateYellow = Reference(
        name: "plate yellow", ral: "RAL 1021",
        rgb: (0.953, 0.765, 0.000))

    public static let references: [Reference] = [
        plateYellow,
        Reference(name: "traffic red", ral: "RAL 3020", rgb: (0.800, 0.024, 0.020)),
        Reference(name: "traffic blue", ral: "RAL 5017", rgb: (0.024, 0.224, 0.443)),
    ]

    /// Rec.709 full range, matching the space the engine's tone stage works in.
    static func chroma(_ r: Double, _ g: Double, _ b: Double) -> (cb: Double, cr: Double) {
        let y = Rec709.luma(r, g, b)
        return (cb: (b - y) / Rec709.cbScale, cr: (r - y) / Rec709.crScale)
    }

    /// Where a colour lands on the vectorscope, as a fraction of the grid in each axis.
    public static func vectorPosition(_ r: Double, _ g: Double, _ b: Double) -> (
        x: Double, y: Double
    ) {
        let c = chroma(r, g, b)
        // Chroma runs -0.5...0.5 for legal colour, so the centre is neutral and the corners are
        // the most saturated a Rec.709 signal can be.
        return (x: min(1, max(0, c.cb + 0.5)), y: min(1, max(0, 1 - (c.cr + 0.5))))
    }

    /// Reads a rendered frame. Sampled rather than exhaustive: a 1440-tall still is two million
    /// pixels and a scope needs a shape, not a census. Every nth pixel, deterministically.
    public static func measure(_ image: CGImage, stride sampleStride: Int = 4) -> Scopes {
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let space = CGColorSpaceCreateDeviceRGB()
        guard
            let context = CGContext(
                data: &pixels, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else {
            return Scopes(luma: [], red: [], green: [], blue: [], vector: [], sampleCount: 0)
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var luma = [Int](repeating: 0, count: 256)
        var red = luma
        var green = luma
        var blue = luma
        var vector = [Int](repeating: 0, count: vectorSize * vectorSize)
        var count = 0
        var index = 0
        let step = max(1, sampleStride) * 4
        while index + 3 < pixels.count {
            let r = Double(pixels[index]) / 255
            let g = Double(pixels[index + 1]) / 255
            let b = Double(pixels[index + 2]) / 255
            red[Int(r * 255)] += 1
            green[Int(g * 255)] += 1
            blue[Int(b * 255)] += 1
            let y = Rec709.luma(r, g, b)
            luma[min(255, Int(y * 255))] += 1
            let p = vectorPosition(r, g, b)
            let vx = min(vectorSize - 1, max(0, Int(p.x * Double(vectorSize - 1))))
            let vy = min(vectorSize - 1, max(0, Int(p.y * Double(vectorSize - 1))))
            vector[vy * vectorSize + vx] += 1
            count += 1
            index += step
        }
        return Scopes(
            luma: luma, red: red, green: green, blue: blue, vector: vector,
            sampleCount: count)
    }

    /// The brightest level with anything in it, which is what tells you whether an image clips.
    public var peakLuma: Int? { luma.lastIndex(where: { $0 > 0 }) }
    public var floorLuma: Int? { luma.firstIndex(where: { $0 > 0 }) }
}
