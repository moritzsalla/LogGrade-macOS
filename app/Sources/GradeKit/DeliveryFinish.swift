import Foundation

/// The delivery finish on an 8-bit luma plane, as `delivery_image_chain` and `render_deliverables`
/// apply it in scripts/lib.sh: the edge-limited sharpener, then the clustered grain, weighted by
/// the picture's own brightness. Chroma is untouched by both, as it is in the engine.
///
/// A SECOND IMPLEMENTATION, held to the engine by `ExportParityTests` on the delivered file, not
/// by equal bytes: the grain is random in both, so only its size can agree.
///
/// INTEGER AND ACROSS CORES. Written per pixel in Doubles it was 237 ms of a 1080x1920 frame, more
/// than decode and grade together; every loop here runs rows in bands (`LiveChain.inBands`).
public struct DeliveryFinish {
    public let sharpen: Double
    public let grainStrength: Double
    public let grainShadows: Double
    public let grainHighlights: Double

    public init(look: Look) {
        sharpen = look.finish.sharpen
        grainStrength = look.grainStrength
        grainShadows = look.grainShadows
        grainHighlights = look.grainHighlights
    }

    /// Sharpens, then grains, `luma` in place. `frame` numbers the grain, which is temporal.
    public func apply(to luma: inout [UInt8], width: Int, height: Int, frame: Int) {
        if sharpen > 0 { sharpened(&luma, width: width, height: height) }
        if grainStrength > 0 { grained(&luma, width: width, height: height, frame: frame) }
    }

    // MARK: sharpener

    /// `unsharp` on luma at the engine's radius, clamped to within `limit` code values of the
    /// unsharpened picture's 3x3 minimum and maximum (`erosion`, `dilation`, `maskedclamp`).
    func sharpened(_ y: inout [UInt8], width: Int, height: Int) {
        let short = min(width, height)
        var r = 5 * short / 1080
        if r < 3 { r = 3 }
        if r % 2 == 0 { r += 1 }
        let limit = max(1, Int(sharpen * 2 + 0.5))
        let steps = r / 2
        let original = y
        // Binomial weights sum to 4^steps per axis, so the blur is `blur / 16^steps`.
        let blur = Self.binomial(original, width, height, steps)
        let shift = UInt32(4 * steps)
        let lo = Self.extreme(original, width, height, max: false)
        let hi = Self.extreme(original, width, height, max: true)
        // Amount in 1/65536ths, as ffmpeg's `unsharp` holds it.
        let amount = Int((sharpen * 65536).rounded())
        let half = 1 << (Int(shift) - 1)
        original.withUnsafeBufferPointer { o in
            blur.withUnsafeBufferPointer { b in
                lo.withUnsafeBufferPointer { l in
                    hi.withUnsafeBufferPointer { h in
                        y.withUnsafeMutableBufferPointer { out in
                            LiveChain.inBands(height: height) { rows in
                                for i in (rows.lowerBound * width)..<(rows.upperBound * width) {
                                    let v = Int(o[i])
                                    let blurred = (Int(b[i]) + half) >> Int(shift)
                                    let sharp = v + ((v - blurred) * amount + 32768) >> 16
                                    let clamped = min(
                                        Int(h[i]) + limit, max(Int(l[i]) - limit, sharp))
                                    out[i] = UInt8(min(255, max(0, clamped)))
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// `unsharp`'s blur, unnormalised: `steps` passes of [1 2 1] each way, a binomial kernel of
    /// 2·steps+1 taps (1 4 6 4 1 for its 5x5), not a box. A box blurs more and sharpened 3% too
    /// hard, measured against the engine's file. Edge pixels are repeated.
    static func binomial(_ v: [UInt8], _ w: Int, _ h: Int, _ steps: Int) -> [UInt32] {
        var cur = v.map(UInt32.init)
        var tmp = cur
        for _ in 0..<steps {
            cur.withUnsafeBufferPointer { c in
                tmp.withUnsafeMutableBufferPointer { t in
                    LiveChain.inBands(height: h) { rows in
                        for y in rows {
                            let b = y * w
                            for x in 0..<w {
                                t[b + x] =
                                    c[b + max(0, x - 1)] + 2 * c[b + x] + c[b + min(w - 1, x + 1)]
                            }
                        }
                    }
                }
            }
            tmp.withUnsafeBufferPointer { t in
                cur.withUnsafeMutableBufferPointer { c in
                    LiveChain.inBands(height: h) { rows in
                        for y in rows {
                            let up = max(0, y - 1) * w
                            let down = min(h - 1, y + 1) * w
                            let b = y * w
                            for x in 0..<w { c[b + x] = t[up + x] + 2 * t[b + x] + t[down + x] }
                        }
                    }
                }
            }
        }
        return cur
    }

    /// The 3x3 minimum or maximum, as `erosion` and `dilation` give it.
    static func extreme(_ v: [UInt8], _ w: Int, _ h: Int, max isMax: Bool) -> [UInt8] {
        var rows = v
        var out = v
        @inline(__always) func pick(_ a: UInt8, _ b: UInt8) -> UInt8 {
            isMax ? (a > b ? a : b) : (a < b ? a : b)
        }
        v.withUnsafeBufferPointer { s in
            rows.withUnsafeMutableBufferPointer { r in
                LiveChain.inBands(height: h) { band in
                    for y in band {
                        let b = y * w
                        for x in 0..<w {
                            r[b + x] = pick(
                                pick(s[b + max(0, x - 1)], s[b + x]), s[b + min(w - 1, x + 1)])
                        }
                    }
                }
            }
        }
        rows.withUnsafeBufferPointer { r in
            out.withUnsafeMutableBufferPointer { o in
                LiveChain.inBands(height: h) { band in
                    for y in band {
                        let up = max(0, y - 1) * w
                        let down = min(h - 1, y + 1) * w
                        let b = y * w
                        for x in 0..<w { o[b + x] = pick(pick(r[up + x], r[b + x]), r[down + x]) }
                    }
                }
            }
        }
        return out
    }

    // MARK: grain

    /// Gaussian noise on a plate half the picture's size at a 1080 short edge (`grain_plate`), sd
    /// strength/√3 rounded to whole code values as ffmpeg's `noise` makes it, scaled up bilinearly,
    /// faded toward zero by the brightness weight, and added (`grainmerge` about 128).
    func grained(_ y: inout [UInt8], width: Int, height: Int, frame: Int) {
        let short = min(width, height)
        var pw = width * 540 / short
        var ph = height * 540 / short
        if pw > width {
            pw = width
            ph = height
        }
        var rng = SplitMix64(seed: 0x9E37_79B9_7F4A_7C15 &+ UInt64(frame))
        let sd = grainStrength / 3.0.squareRoot()
        var plate = [Int32](repeating: 0, count: pw * ph)
        for i in 0..<plate.count {
            plate[i] = Int32(min(127, max(-128, (rng.gaussian() * sd).rounded())))
        }
        // The mask per code value, in 1/255ths, as `lutyuv` tabulates it.
        let weighted = !(grainShadows == 1 && grainHighlights == 1)
        let mask = (0..<256).map { Int32((255 * weight(Double($0))).rounded()) }
        // Bilinear sample positions in 1/256ths, per column and per row.
        func positions(_ out: Int, _ plateSize: Int) -> [(Int, Int, Int32)] {
            let s = Double(plateSize) / Double(out)
            return (0..<out).map { i in
                let f = max(0, min(Double(plateSize - 1), (Double(i) + 0.5) * s - 0.5))
                let i0 = Int(f)
                return (i0, min(plateSize - 1, i0 + 1), Int32(((f - Double(i0)) * 256).rounded()))
            }
        }
        let cols = positions(width, pw)
        let rowsAt = positions(height, ph)
        plate.withUnsafeBufferPointer { p in
            mask.withUnsafeBufferPointer { m in
                y.withUnsafeMutableBufferPointer { out in
                    LiveChain.inBands(height: height) { band in
                        for row in band {
                            let (y0, y1, ty) = rowsAt[row]
                            let a = y0 * pw
                            let b = y1 * pw
                            for col in 0..<width {
                                let (x0, x1, tx) = cols[col]
                                let top = p[a + x0] * (256 - tx) + p[a + x1] * tx
                                let bottom = p[b + x0] * (256 - tx) + p[b + x1] * tx
                                // Round the 16.16 bilinear value to a whole code value.
                                var g = (top * (256 - ty) + bottom * ty + 32768) >> 16
                                let i = row * width + col
                                let v = Int32(out[i])
                                if weighted { g = (g * m[Int(v)] + (g >= 0 ? 127 : -127)) / 255 }
                                out[i] = UInt8(min(255, max(0, v + g)))
                            }
                        }
                    }
                }
            }
        }
    }

    /// `delivery_grain_merge`'s mask: 1 across the midtones, easing to `grainShadows` at black and
    /// `grainHighlights` at white.
    func weight(_ code: Double) -> Double {
        func ease(_ t: Double) -> Double { t * t * (3 - 2 * t) }
        let level = min(1, max(0, (code - 16) / 219))
        let shadow = min(1, max(0, level / 0.45))
        let highlight = min(1, max(0, (level - 0.55) / 0.45))
        return min(
            1,
            max(
                0,
                (grainShadows + (1 - grainShadows) * ease(shadow))
                    + (grainHighlights - 1) * ease(highlight)))
    }
}

/// A small, seedable generator, so a frame's grain is the same every time it is rendered.
struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func uniform() -> Double { Double(next() >> 11) / Double(1 << 53) }

    /// The polar method, as ffmpeg's `noise` draws it.
    mutating func gaussian() -> Double {
        while true {
            let x1 = 2 * uniform() - 1
            let x2 = 2 * uniform() - 1
            let w = x1 * x1 + x2 * x2
            if w < 1 && w > 0 { return x1 * (-2 * log(w) / w).squareRoot() }
        }
    }
}
