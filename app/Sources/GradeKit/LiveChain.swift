import CoreGraphics
import Foundation

/// The whole grade, applied in this process to the decoded source frame.
///
/// WHY IT TAKES THE SOURCE AND NOT A GRADED FRAME. The correction stage — exposure, white balance,
/// the CDL — runs BEFORE Apple's conversion, deliberately, because that is where the log highlight
/// headroom still exists: code 1.0 decodes to 12 times diffuse white, about 3.6 stops above it.
/// Nothing downstream of the conversion can show it, so a live tier that starts from a converted
/// frame leaves the first control anybody reaches for dead until release. Starting from the source
/// makes every control live, and it also means the base frame never needs re-rendering: it is the
/// clip, not a stage of the grade.
///
/// WHAT IS IMPLEMENTED TWICE, AND WHAT HOLDS EACH COPY. Apple's conversion, the film look and the
/// print are the same `.cube` files the render hands to `lut3d`. Everything else is a second
/// implementation, each licensed by its own test: the sampling in `Cube3D` (`Cube3DTests`), the
/// correction cube in `CorrectionCube` (`CorrectionCubeTests`), the tone curve in
/// `ToneCurve.generated` (`ToneCurvePortTests`), halation's arithmetic in `LiveHalation`
/// (`LiveHalationTests`), and the tone and trim arithmetic in `LiveGrade` (`LiveGradeTests`,
/// against the parity golden). `LiveChainTests` then holds the assembled chain to the engine's own
/// render of real footage. This type only wires them together in the engine's order.
public struct LiveChain {
    /// The colour stages in the order the chain applies them: the correction, halation, Apple's
    /// conversion, the film look, then the print. Absent stages are simply absent, which is the
    /// same thing the engine does — it leaves a neutral correction, a neutral halation and a look
    /// or print of "none" out of the filter graph rather than passing an identity.
    ///
    /// SAMPLED IN SEQUENCE, NOT COMPOSED INTO ONE. Flattening them into a single lookup was tried
    /// and it cost accuracy: the composite has to be resampled on one grid, and the film look's is
    /// only 13 points, so a steep region of Apple's conversion landed 55 code values out on the
    /// worst pixel against 48 for the sequence. Three lookups per pixel is 6ms on a preview frame,
    /// which is not worth an approximation the render does not make.
    public let stages: ColourStages
    public let grade: LiveGrade

    public init(stages: ColourStages, grade: LiveGrade) {
        self.stages = stages
        self.grade = grade
    }

    /// HALATION SPLITS THE CUBES IN TWO. It is spatial — it needs the whole frame, not one pixel —
    /// so the frame is taken through the correction, then halation, then the rest, rather than
    /// through every cube in one pass per pixel.
    public struct ColourStages {
        public let correction: Cube3D?
        public let halation: LiveHalation?
        public let conversion: Cube3D
        public let look: Cube3D?
        public let lookStrength: Float
        /// The print follows the look, as it does in the engine's `grade_chain`.
        public let print: Cube3D?
        public let printStrength: Float

        var cubes: [StageCube] { (correction.map { [StageCube($0)] } ?? []) + afterHalation }
        var afterHalation: [StageCube] {
            [StageCube(conversion), StageCube(look, lookStrength), StageCube(print, printStrength)]
                .compactMap { $0 }
        }
    }

    /// A cube at a strength. The engine blends a film cube back toward its input with `mix`; this
    /// is the same weighted sum, and at full strength it is the cube alone, as the engine's graph is.
    struct StageCube {
        let cube: Cube3D
        let strength: Float

        init(_ cube: Cube3D) {
            self.cube = cube
            strength = 1
        }

        /// Nil for an absent cube or a strength of zero, which the engine leaves out of the graph.
        init?(_ cube: Cube3D?, _ strength: Float) {
            guard let cube, strength > 0 else { return nil }
            self.cube = cube
            self.strength = strength
        }

        @inline(__always)
        func sample(_ c: SIMD3<Float>) -> SIMD3<Float> {
            let full = cube.sample(c)
            return strength == 1 ? full : c + (full - c) * strength
        }
    }

    public static func colourStages(
        correction: Cube3D?, halation: LiveHalation? = nil,
        conversion: Cube3D, look: Cube3D?, lookStrength: Double = 1,
        print: Cube3D? = nil, printStrength: Double = 1
    ) -> ColourStages {
        ColourStages(
            correction: correction, halation: halation, conversion: conversion, look: look,
            lookStrength: Float(lookStrength), print: print,
            printStrength: Float(printStrength))
    }

    /// The source through the colour stages only: correction, halation, conversion, look, print.
    /// The result is what the tone curve and the trims act on.
    ///
    /// SEPARATE FROM THE GRADE BECAUSE OF WHAT CHANGES. Dragging midtone or saturation does not
    /// move any of the colour stages, and they are the expensive part — up to four cube samples
    /// per pixel, and a blur, against a handful of multiplies. Converting once and keeping the result makes a tone
    /// drag about 3ms instead of 13.
    ///
    /// Eight bits out because that is what the tone stage is defined on: `LiveGrade` models the
    /// renderer applying its 1D LUT per RGB channel, and the model's own table is 256 entries.
    /// Sixteen bits IN because the source is log — its shadows carry most of the information, and
    /// quantising them before the conversion stretches them is where a preview would visibly band.
    public static func converted(_ image: CGImage, through stages: ColourStages) -> Converted? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }

        var source = [UInt16](repeating: 0, count: width * height * 4)
        let wide = CGBitmapInfo(
            rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
                | CGBitmapInfo.byteOrder16Little.rawValue)
        guard
            let readContext = CGContext(
                data: &source, width: width, height: height,
                bitsPerComponent: 16, bytesPerRow: width * 8,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: wide.rawValue)
        else { return nil }
        readContext.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var rgb = [UInt8](repeating: 255, count: width * height * 4)
        let scale = Float(1.0 / 65535.0)
        if let halation = stages.halation {
            var log = [Float](repeating: 0, count: width * height * 3)
            let correction = stages.correction
            source.withUnsafeBufferPointer { src in
                log.withUnsafeMutableBufferPointer { out in
                    Self.inBands(height: height) { rows in
                        for i in (rows.lowerBound * width)..<(rows.upperBound * width) {
                            var c = SIMD3(
                                Float(src[i * 4]) * scale, Float(src[i * 4 + 1]) * scale,
                                Float(src[i * 4 + 2]) * scale)
                            if let correction { c = correction.sample(c) }
                            out[i * 3] = c.x
                            out[i * 3 + 1] = c.y
                            out[i * 3 + 2] = c.z
                        }
                    }
                }
            }
            halation.apply(to: &log, width: width, height: height)
            let after = stages.afterHalation
            log.withUnsafeBufferPointer { src in
                rgb.withUnsafeMutableBufferPointer { out in
                    Self.inBands(height: height) { rows in
                        for i in (rows.lowerBound * width)..<(rows.upperBound * width) {
                            var c = SIMD3(src[i * 3], src[i * 3 + 1], src[i * 3 + 2])
                            for stage in after { c = stage.sample(c) }
                            Self.store(c, in: out, at: i * 4)
                        }
                    }
                }
            }
            return Converted(width: width, height: height, pixels: rgb)
        }
        let cubes = stages.cubes
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
                            var c = SIMD3(
                                Float(src[s]) * scale, Float(src[s + 1]) * scale,
                                Float(src[s + 2]) * scale)
                            for stage in cubes { c = stage.sample(c) }
                            Self.store(c, in: out, at: s)
                        }
                    }
                }
            }
        }
        return Converted(width: width, height: height, pixels: rgb)
    }

    @inline(__always)
    private static func store(
        _ c: SIMD3<Float>, in out: UnsafeMutableBufferPointer<UInt8>,
        at offset: Int
    ) {
        out[offset] = UInt8(min(255, max(0, c.x * 255)))
        out[offset + 1] = UInt8(min(255, max(0, c.y * 255)))
        out[offset + 2] = UInt8(min(255, max(0, c.z * 255)))
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
                            let r = buffer[i]
                            let g = buffer[i + 1]
                            let b = buffer[i + 2]
                            let pixel = grade.merge(
                                r: Double(r), g: Double(g), b: Double(b),
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
            guard
                let context = CGContext(
                    data: buffer.baseAddress, width: converted.width,
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
