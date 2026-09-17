import Metal
import XCTest

@testable import GradeKit

/// The GPU chain against the CPU chain it transcribes, on a real source frame, look by look.
final class MetalChainTests: XCTestCase {
    func testTheGPUChainIsTheCPUChain() throws {
        let engine = try engineCheckout()
        let clips =
            (try? FileManager.default.contentsOfDirectory(
                at: engine.root.appendingPathComponent("src"), includingPropertiesForKeys: nil))
            ?? []
        guard
            let clip = clips.sorted(by: { $0.path < $1.path })
                .first(where: { $0.pathExtension.lowercased() == "mov" })
        else { throw XCTSkip("no footage in src/") }
        let metal: MetalChain
        do { metal = try MetalChain() } catch { throw XCTSkip("\(error)") }
        let frame = try NativeSource.frame(of: clip, at: 2, height: 480)
        let image = frame.image
        var source = [UInt16](repeating: 0, count: image.width * image.height * 4)
        let context = try XCTUnwrap(
            CGContext(
                data: &source, width: image.width, height: image.height, bitsPerComponent: 16,
                bytesPerRow: image.width * 8, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                    | CGBitmapInfo.byteOrder16Little.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))

        let shipped = try Look(data: Data(contentsOf: engine.lookFile))
        var corrected = shipped
        corrected.correct.exposure = 0.6
        corrected.correct.temp = 0.25
        corrected.correct.contrast = 1.3
        var halation = shipped
        halation.halation = Look.Halation(
            strength: 0.8, threshold: 1, radius: 0.006, tint: "1,0.3,0.05")
        let film = try XCTUnwrap(
            engine.shippedPresets().first { $0.look.convertCube == "portra160" }
        ).look
        var hue = film
        hue.hue = Look.Hue(
            rot: "30,30,0,-20,-20,-20,0,0,0,0,30,30", sat: "1,1,0,-1,-1,-1,0,0,-1,-1,1,1",
            lum: "0,0,0,-0.4,-0.4,-0.4,0,0,0,0,0,0")
        var trims = shipped
        trims.tone.contrast = 1.3
        trims.colour.saturation = 1.2
        trims.colour.warmth = 0.05

        let builder = ChainBuilder(engine: engine)
        for (name, look) in [
            ("shipped", shipped), ("correction", corrected), ("halation", halation),
            ("film", film), ("hue", hue), ("trims", trims),
        ] {
            let chain = try builder.build(
                look, metered: nil, frameLongEdge: max(image.width, image.height),
                sourceLongEdge: max(frame.sourceSize.width, frame.sourceSize.height)
            ).chain
            let cpu = LiveChain.gradedPixels(
                try XCTUnwrap(
                    LiveChain.converted(
                        rgba16: source, width: image.width, height: image.height,
                        through: chain.stages)), with: chain.grade)
            let gpu = try metal.graded(
                rgba16: source, width: image.width, height: image.height, chain: chain)
            var worst = 0
            var off = 0
            var sum = 0
            for i in 0..<cpu.count where i % 4 != 3 {
                let d = abs(Int(cpu[i]) - Int(gpu[i]))
                worst = max(worst, d)
                sum += d
                if d > 0 { off += 1 }
            }
            let n = Double(cpu.count / 4 * 3)
            // Measured on IMG_0607 at 480 high: worst 1 in every case, mean 0.24-0.26, and 0.004
            // for the trims case. The one-code differences are the tone merge's truncation landing
            // on an integer boundary in Float here and Double on the CPU: an identity curve puts
            // most values exactly on one, a real curve almost none. Any stage wired wrong moves
            // the mean by tens of codes (a missing readback read 99).
            XCTAssertLessThanOrEqual(worst, 1, "\(name): a pixel is \(worst) codes off")
            XCTAssertLessThan(Double(sum) / n, 0.35, "\(name): mean \(Double(sum) / n)")
        }

        // Timed at the export's size, upload and readback included, only when asked: a debug build
        // runs the CPU chain at 1080x1920 far too slowly for the full check.
        guard ProcessInfo.processInfo.environment["METAL_TIMING"] == "1" else { return }
        let big = try NativeSource.frame(of: clip, at: 2, height: 1920).image
        var pixels = [UInt16](repeating: 0, count: big.width * big.height * 4)
        let bigContext = try XCTUnwrap(
            CGContext(
                data: &pixels, width: big.width, height: big.height, bitsPerComponent: 16,
                bytesPerRow: big.width * 8, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                    | CGBitmapInfo.byteOrder16Little.rawValue))
        bigContext.draw(big, in: CGRect(x: 0, y: 0, width: big.width, height: big.height))
        for device in MTLCopyAllDevices() {
            let m = try MetalChain(device: device)
            let chain = try builder.build(
                shipped, metered: nil, frameLongEdge: max(big.width, big.height),
                sourceLongEdge: max(frame.sourceSize.width, frame.sourceSize.height)
            ).chain
            _ = try m.graded(rgba16: pixels, width: big.width, height: big.height, chain: chain)
            let t = Date()
            for _ in 0..<5 {
                _ = try m.graded(rgba16: pixels, width: big.width, height: big.height, chain: chain)
            }
            print(
                "METAL device \(device.name) lowPower \(device.isLowPower): \(Date().timeIntervalSince(t) / 5 * 1000) ms, last GPU time \(m.lastGPUTime * 1000) ms"
            )
        }
        for look in [shipped, halation] {
            let chain = try builder.build(
                look, metered: nil, frameLongEdge: max(big.width, big.height),
                sourceLongEdge: max(frame.sourceSize.width, frame.sourceSize.height)
            ).chain
            _ = try metal.graded(rgba16: pixels, width: big.width, height: big.height, chain: chain)
            var t = Date()
            for _ in 0..<5 {
                _ = try metal.graded(
                    rgba16: pixels, width: big.width, height: big.height, chain: chain)
            }
            let gpuMs = Date().timeIntervalSince(t) / 5 * 1000
            t = Date()
            for _ in 0..<5 {
                _ = LiveChain.gradedPixels(
                    try XCTUnwrap(
                        LiveChain.converted(
                            rgba16: pixels, width: big.width, height: big.height,
                            through: chain.stages)), with: chain.grade)
            }
            let cpuMs = Date().timeIntervalSince(t) / 5 * 1000
            print(
                "METAL timing \(big.width)x\(big.height) halation \(chain.stages.halation != nil): gpu \(gpuMs) ms, cpu \(cpuMs) ms"
            )
        }
    }
}
