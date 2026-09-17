import Foundation

/// The delivery finish on an 8-bit luma plane, as `delivery_image_chain` applies it in
/// scripts/lib.sh: the edge-limited sharpener. Chroma is untouched, as it is in the engine. Grain is
/// not here: it is added in the negative, before the conversion (`LiveGrain`).
///
/// A SECOND IMPLEMENTATION, held to the engine by `ExportParityTests` on the delivered file.
///
/// INTEGER AND ACROSS CORES. Written per pixel in Doubles the finish was 237 ms of a 1080x1920
/// frame, more than decode and grade together; every loop here runs rows in bands.
public struct DeliveryFinish {
    public let sharpen: Double

    public init(look: Look) {
        sharpen = look.finish.sharpen
    }

    /// Sharpens `luma` in place.
    public func apply(to luma: inout [UInt8], width: Int, height: Int) {
        if sharpen > 0 { sharpened(&luma, width: width, height: height) }
    }

    // MARK: sharpener

    /// The sharpener's integers at a size, shared with the GPU finish: binomial passes, the shift
    /// that normalises them (weights sum to 4^steps per axis), the amount in 1/65536ths as ffmpeg's
    /// `unsharp` holds it, and the clamp's allowance past the local range.
    func sharpenGeometry(width: Int, height: Int) -> (
        steps: Int, shift: Int, amount: Int, limit: Int
    ) {
        let short = min(width, height)
        var r = 5 * short / 1080
        if r < 3 { r = 3 }
        if r % 2 == 0 { r += 1 }
        return (
            r / 2, 4 * (r / 2), Int((sharpen * 65536).rounded()), max(1, Int(sharpen * 2 + 0.5))
        )
    }

    /// `unsharp` on luma at the engine's radius, clamped to within `limit` code values of the
    /// unsharpened picture's 3x3 minimum and maximum (`erosion`, `dilation`, `maskedclamp`).
    func sharpened(_ y: inout [UInt8], width: Int, height: Int) {
        let (steps, shiftBy, amount, limit) = sharpenGeometry(width: width, height: height)
        let original = y
        let blur = Self.binomial(original, width, height, steps)
        let shift = UInt32(shiftBy)
        let lo = Self.extreme(original, width, height, max: false)
        let hi = Self.extreme(original, width, height, max: true)
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
}

/// A small, seedable generator, for pictures a test needs to be the same every run.
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
}
