import CoreVideo
import XCTest

@testable import GradeKit

/// The GPU finish against `DeliveryFinish` on the same picture and the same grain plate.
final class MetalFrameTests: XCTestCase {
    func testTheGPUFinishIsTheCPUFinish() throws {
        let frame: MetalFrame
        do { frame = try MetalFrame(chain: try MetalChain()) } catch { throw XCTSkip("\(error)") }
        // Detail that is not smooth, so the sharpener and its clamp both have work: a ramp with
        // hard-edged blocks and a pseudo-random texture over it.
        // A 1080 short edge, so the grain plate is half the picture and its bilinear rounding runs:
        // below 1080 the plate is the picture's own size and every weight is zero.
        let w = 1280
        let h = 1080
        var rgba = [UInt8](repeating: 255, count: w * h * 4)
        var rng = SplitMix64(seed: 7)
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 4
                let block = ((x / 37) + (y / 23)) % 2 == 0 ? 60 : 0
                let noise = Int(rng.next() % 24)
                rgba[i] = UInt8(min(255, x * 200 / w + block + noise))
                rgba[i + 1] = UInt8(min(255, y * 200 / h + noise))
                rgba[i + 2] = UInt8(min(255, 40 + block + noise / 2))
            }
        }
        var look = try lookFixture()
        look.finish.sharpen = 0.6
        look.grainStrength = 4
        look.grainShadows = 0.8
        look.grainHighlights = 0.6
        let finish = DeliveryFinish(look: look)

        var made: CVPixelBuffer?
        CVPixelBufferCreate(
            nil, w, h, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            [
                kCVPixelBufferMetalCompatibilityKey: true,
                kCVPixelBufferIOSurfacePropertiesKey: [String: Any](),
            ] as CFDictionary, &made)
        let output = try XCTUnwrap(made)
        let plate = finish.plate(width: w, height: h, frame: 3)
        try frame.finish(
            rgba: rgba, width: w, height: h,
            targets: [.init(crop: (0, 0), finish: finish, output: output, plate: plate)])

        // The CPU side from the same luma the GPU starts from: 709 video range, rounded.
        var luma = [UInt8](repeating: 0, count: w * h)
        for i in 0..<(w * h) {
            let r = Float(rgba[i * 4])
            let g = Float(rgba[i * 4 + 1])
            let b = Float(rgba[i * 4 + 2])
            let yl = 0.2126 * r + 0.7152 * g + 0.0722 * b
            luma[i] = UInt8((16 + yl * 219 / 255 + 0.5).rounded(.down))
        }
        finish.apply(to: &luma, width: w, height: h, frame: 3)

        CVPixelBufferLockBaseAddress(output, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(output, .readOnly) }
        let row = CVPixelBufferGetBytesPerRowOfPlane(output, 0)
        let plane = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(output, 0))
            .assumingMemoryBound(to: UInt8.self)
        var worst = 0
        var differing = 0
        for y in 0..<h {
            for x in 0..<w {
                let d = abs(Int(plane[y * row + x]) - Int(luma[y * w + x]))
                worst = max(worst, d)
                if d > 0 { differing += 1 }
            }
        }
        // The finish is integer arithmetic on both sides and agrees exactly; what differs starts at
        // the RGB-to-luma rounding, which is Float on both but not the same instructions, and the
        // sharpener can carry that one code to two. Measured at 640x360: 7 of 230,400 pixels, worst 2. A
        // wrong kernel moves thousands.
        XCTAssertLessThanOrEqual(worst, 2, "a pixel is \(worst) codes off")
        XCTAssertLessThan(differing, 100, "\(differing) pixels differ")
    }
}
