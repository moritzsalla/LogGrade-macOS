import CoreGraphics
import CoreVideo
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
/// WHAT IS IMPLEMENTED TWICE, AND WHAT HOLDS EACH COPY. The conversion is the same `.cube` file
/// the render hands to `lut3d`. Everything else is a second implementation, each licensed by its
/// own test: the sampling in `Cube3D` (`Cube3DTests`), the correction cube in `CorrectionCube`
/// (`CorrectionCubeTests`) and halation's arithmetic in `LiveHalation` (`LiveHalationTests`).
/// `LiveChainTests` then holds the assembled chain to the engine's own render of real footage.
/// This type only wires them together in the engine's order.
public struct LiveChain {
    /// The colour stages in the order the chain applies them: the correction, halation, then the
    /// conversion. Absent stages are simply absent, which is the same thing the engine does — it
    /// leaves a neutral correction or halation out of the filter graph rather than passing an
    /// identity.
    ///
    /// SAMPLED IN SEQUENCE, NOT COMPOSED INTO ONE. Flattening them into a single lookup was tried
    /// and it cost accuracy: the composite has to be resampled on one grid, and a steep region of
    /// the conversion landed further out on the worst pixel than the sequence does.
    public let stages: ColourStages

    public init(stages: ColourStages) {
        self.stages = stages
    }

    /// HALATION SPLITS THE CUBES IN TWO. It is spatial — it needs the whole frame, not one pixel —
    /// so the frame is taken through the correction, then halation, then the rest, rather than
    /// through every cube in one pass per pixel.
    public struct ColourStages {
        public let correction: Cube3D?
        public let halation: LiveHalation?
        public let conversion: Cube3D

        var cubes: [Cube3D] { (correction.map { [$0] } ?? []) + [conversion] }
    }

    public static func colourStages(
        correction: Cube3D?, halation: LiveHalation? = nil, conversion: Cube3D
    ) -> ColourStages {
        ColourStages(correction: correction, halation: halation, conversion: conversion)
    }

    /// The source through the colour stages: correction, halation, conversion. Eight bits out,
    /// truncated. Sixteen bits IN because the source is log — its shadows carry most of the
    /// information, and quantising them before the conversion stretches them is where a preview
    /// would visibly band.
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
        return converted(rgba16: source, width: width, height: height, through: stages)
    }

    /// The same, from 16-bit RGBA pixels in host order, for a caller that already has them: the
    /// export, which would otherwise draw every frame into a CGImage only to read it back.
    ///
    /// `grain`, for an export only, is added to the log picture after halation and before the
    /// conversion (`LiveGrain`); `frame` numbers it.
    public static func converted(
        rgba16 source: [UInt16], width: Int, height: Int, through stages: ColourStages,
        grain: LiveGrain? = nil, frame: Int = 0
    ) -> Converted? {
        guard width > 0, height > 0, source.count >= width * height * 4 else { return nil }
        var rgb = [UInt8](repeating: 255, count: width * height * 4)
        let scale = Float(1.0 / 65535.0)
        if stages.halation != nil || grain != nil {
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
            stages.halation?.apply(to: &log, width: width, height: height)
            grain?.apply(to: &log, width: width, height: height, frame: frame)
            let conversion = stages.conversion
            log.withUnsafeBufferPointer { src in
                rgb.withUnsafeMutableBufferPointer { out in
                    Self.inBands(height: height) { rows in
                        for i in (rows.lowerBound * width)..<(rows.upperBound * width) {
                            var c = SIMD3(src[i * 3], src[i * 3 + 1], src[i * 3 + 2])
                            c = conversion.sample(c)
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
        // it is the difference between a preset switching in ten milliseconds and in three.
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

    /// A frame after the colour stages, 8-bit RGBA with the alpha opaque.
    public struct Converted {
        public let width: Int
        public let height: Int
        public let pixels: [UInt8]

        public var image: CGImage? {
            var out = pixels
            return out.withUnsafeMutableBytes { buffer -> CGImage? in
                guard
                    let context = CGContext(
                        data: buffer.baseAddress, width: width, height: height,
                        bitsPerComponent: 8, bytesPerRow: width * 4,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                else { return nil }
                return context.makeImage()
            }
        }
    }

    /// The picture as it is SHOWN: the same pixels, tagged with the colour space CoreVideo builds
    /// for a 1-1-1 frame, which is how QuickTime, Photos and iOS display the exported file
    /// (`scripts/cubefile.py`). Untagged, a Mac shows them as sRGB, lighter than the export in the
    /// midtones and darker in the shadows. NOT `CGColorSpace.itur_709`: that is the inverse OETF,
    /// which matches playback at mid grey but shows code 23/255 2.2 times lighter than it plays.
    ///
    /// ONLY FOR DISPLAY. Scopes and the live grade read pixel values by drawing into an untagged
    /// context, and a tagged image drawn there is colour-converted on the way in.
    public static func forDisplay(_ image: CGImage) -> CGImage {
        guard let space = playbackSpace else { return image }
        return image.copy(colorSpace: space) ?? image
    }

    /// Apple playback's display curve, as `cubefile.py` defines it and says why.
    static let appleDisplayGamma = 502.0 / 256.0

    static func displayDecode(_ v: Double) -> Double {
        pow(max(0, v), appleDisplayGamma)
    }

    static func displayEncode(_ light: Double) -> Double {
        pow(min(1, max(0, light)), 1.0 / appleDisplayGamma)
    }

    static let playbackSpace: CGColorSpace? = {
        let tags = [
            kCVImageBufferColorPrimariesKey: kCVImageBufferColorPrimaries_ITU_R_709_2,
            kCVImageBufferTransferFunctionKey: kCVImageBufferTransferFunction_ITU_R_709_2,
            kCVImageBufferYCbCrMatrixKey: kCVImageBufferYCbCrMatrix_ITU_R_709_2,
        ]
        return CVImageBufferCreateColorSpaceFromAttachments(tags as CFDictionary)?
            .takeRetainedValue()
    }()

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

    public func apply(to image: CGImage) -> CGImage? {
        Self.converted(image, through: stages)?.image
    }
}
