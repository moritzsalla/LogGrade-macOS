import CoreGraphics
import Foundation

/// The whole grade, applied in this process to the decoded source frame.
///
/// WHY IT TAKES THE SOURCE AND NOT A GRADED FRAME. The correction stage — exposure, white balance,
/// the CDL — runs BEFORE Apple's conversion, deliberately, because that is where twelve stops of
/// log headroom still exist. Nothing downstream of the conversion can show it, so a live tier that
/// starts from a converted frame leaves the first control anybody reaches for dead until release.
/// Starting from the source makes every control live, and it also means the base frame never needs
/// re-rendering: it is the clip, not a stage of the grade.
///
/// THE STAGES STAY WHERE THEY LIVE. The correction cube comes from the engine's own generator, and
/// Apple's conversion and the film look are the same `.cube` files the render hands to `lut3d`.
/// The only thing implemented twice is the sampling, in `Cube3D`, and the tone and trim arithmetic
/// in `LiveGrade` — both of which the parity golden and `LiveAgainstTheRenderTests` hold to the
/// render. Nothing here decides anything about the image.
public struct LiveChain {
    /// The colour stages in the order the chain applies them: the correction, then Apple's
    /// conversion, then the film look. Absent stages are simply not in the list, which is the same
    /// thing the engine does — it leaves a neutral correction and a look of "none" out of the
    /// filter graph rather than passing an identity cube.
    ///
    /// SAMPLED IN SEQUENCE, NOT COMPOSED INTO ONE. Flattening them into a single lookup was tried
    /// and it cost accuracy: the composite has to be resampled on one grid, and the film look's is
    /// only 13 points, so a steep region of Apple's conversion landed 55 code values out on the
    /// worst pixel against 48 for the sequence. Three lookups per pixel is 6ms on a preview frame,
    /// which is not worth an approximation the render does not make.
    public let stages: [Cube3D]
    public let grade: LiveGrade

    public init(stages: [Cube3D], grade: LiveGrade) {
        self.stages = stages
        self.grade = grade
    }

    public static func colourStages(correction: Cube3D?, conversion: Cube3D,
                                    look: Cube3D?) -> [Cube3D] {
        [correction, conversion, look].compactMap { $0 }
    }

    /// The source through the colour stages only: correction, conversion, look. The result is
    /// what the tone curve and the trims act on.
    ///
    /// SEPARATE FROM THE GRADE BECAUSE OF WHAT CHANGES. Dragging midtone or saturation does not
    /// move any of the colour stages, and they are the expensive part — three cube samples per
    /// pixel against a handful of multiplies. Converting once and keeping the result makes a tone
    /// drag about 3ms instead of 13.
    ///
    /// Eight bits out because that is what the tone stage is defined on: `LiveGrade` models the
    /// renderer applying its 1D LUT per RGB channel, and the model's own table is 256 entries.
    /// Sixteen bits IN because the source is log — its shadows carry most of the information, and
    /// quantising them before the conversion stretches them is where a preview would visibly band.
    public static func converted(_ image: CGImage, through stages: [Cube3D]) -> Converted? {
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { return nil }

        var source = [UInt16](repeating: 0, count: width * height * 4)
        let wide = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
            | CGBitmapInfo.byteOrder16Little.rawValue)
        guard let readContext = CGContext(data: &source, width: width, height: height,
                                          bitsPerComponent: 16, bytesPerRow: width * 8,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: wide.rawValue) else { return nil }
        readContext.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var rgb = [UInt8](repeating: 255, count: width * height * 4)
        let scale = Float(1.0 / 65535.0)
        // ACROSS CORES. Each pixel is independent of every other, so this is the one place in the
        // app where the machine's other cores are free money: rows are handed out in bands and no
        // two bands touch the same bytes. Measured at about four times faster on this machine, and
        // it is the difference between a film look switching in ten milliseconds and in three.
        source.withUnsafeBufferPointer { src in
            rgb.withUnsafeMutableBufferPointer { out in
                Self.inBands(height: height) { rows in
                    for y in rows {
                        for x in 0..<width {
                            let s = (y * width + x) * 4
                            var c = SIMD3(Float(src[s]) * scale, Float(src[s + 1]) * scale,
                                          Float(src[s + 2]) * scale)
                            for stage in stages { c = stage.sample(c) }
                            out[s] = UInt8(min(255, max(0, c.x * 255)))
                            out[s + 1] = UInt8(min(255, max(0, c.y * 255)))
                            out[s + 2] = UInt8(min(255, max(0, c.z * 255)))
                        }
                    }
                }
            }
        }
        return Converted(width: width, height: height, pixels: rgb)
    }

    /// A frame after the colour stages, kept so the tone and trim controls can be dragged without
    /// redoing them.
    public struct Converted {
        public let width: Int
        public let height: Int
        public let pixels: [UInt8]
    }

    /// The tone curve and the trims over an already-converted frame.
    public static func graded(_ converted: Converted, with grade: LiveGrade) -> CGImage? {
        var out = converted.pixels
        // One table, because the curve is the same for every pixel and the input is 8-bit, so its
        // 256 entries are every value the curve can be asked for.
        var table = [Double](repeating: 0, count: 256)
        for i in 0..<256 { table[i] = grade.curve.value(at: Double(i) / 255) * 255 }

        let width = converted.width
        table.withUnsafeBufferPointer { curve in
            out.withUnsafeMutableBufferPointer { buffer in
                Self.inBands(height: converted.height) { rows in
                    for y in rows {
                        for x in 0..<width {
                            let i = (y * width + x) * 4
                            let r = buffer[i], g = buffer[i + 1], b = buffer[i + 2]
                            let pixel = grade.merge(r: Double(r), g: Double(g), b: Double(b),
                                                    lr: curve[Int(r)], lg: curve[Int(g)],
                                                    lb: curve[Int(b)])
                            buffer[i] = UInt8(pixel.0)
                            buffer[i + 1] = UInt8(pixel.1)
                            buffer[i + 2] = UInt8(pixel.2)
                        }
                    }
                }
            }
        }
        return out.withUnsafeMutableBytes { buffer -> CGImage? in
            guard let context = CGContext(data: buffer.baseAddress, width: converted.width,
                                          height: converted.height, bitsPerComponent: 8,
                                          bytesPerRow: converted.width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return nil }
            return context.makeImage()
        }
    }

    /// Splits the rows into one band per core and runs them at once.
    ///
    /// Bands rather than individual rows because the per-chunk overhead of `concurrentPerform` is
    /// real at this size: a 480-row frame is 480 dispatches against 8. Every band is a disjoint
    /// range of rows, so nothing needs a lock.
    @inline(__always)
    static func inBands(height: Int, _ body: (Range<Int>) -> Void) {
        let cores = max(1, min(ProcessInfo.processInfo.activeProcessorCount, height))
        if cores == 1 { return body(0..<height) }
        let band = (height + cores - 1) / cores
        // withoutActuallyEscaping, because `concurrentPerform` runs every iteration before it
        // returns — the closure never outlives this call, which is exactly the guarantee the
        // compiler cannot infer from an `inout` buffer captured inside it.
        withoutActuallyEscaping(body) { escapable in
            DispatchQueue.concurrentPerform(iterations: cores) { i in
                let lower = i * band
                guard lower < height else { return }
                escapable(lower..<min(height, lower + band))
            }
        }
    }

    /// Both halves, for a caller that is not keeping the middle.
    public func apply(to image: CGImage) -> CGImage? {
        guard let converted = Self.converted(image, through: stages) else { return nil }
        return Self.graded(converted, with: grade)
    }
}
