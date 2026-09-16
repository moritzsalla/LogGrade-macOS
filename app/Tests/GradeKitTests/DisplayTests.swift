import AVFoundation
import CoreGraphics
import XCTest

@testable import GradeKit

/// The preview shows a pixel as the exported file shows it on Apple playback, which is the display
/// every cube is encoded for (`scripts/cubefile.py`). Measured the way it failed: a Rec.709-tagged
/// H.264 of flat grey decoded through AVFoundation, against the same code value in the preview.
final class DisplayTests: XCTestCase {
    private func light(_ image: CGImage) -> Float {
        var px = [Float](repeating: 0, count: 4)
        let context = CGContext(
            data: &px, width: 1, height: 1, bitsPerComponent: 32, bytesPerRow: 16,
            space: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return px[1]
    }

    private func grey(_ code: UInt8) -> CGImage {
        var px: [UInt8] = [code, code, code, 255]
        let context = CGContext(
            data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return context.makeImage()!
    }

    func testThePreviewShowsAGreyAsQuickTimeShowsTheExport() throws {
        guard let ffmpeg = EngineLocation.resolveTool("ffmpeg") else { throw XCTSkip("no ffmpeg") }
        let work = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("display-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let movie = work.appendingPathComponent("grey.mp4")
        // Limited-range Y 126 is code (126 - 16) / 219 = 0.5023, which 8-bit 128 (0.5020) matches.
        // Set exactly: a `color=` source's grey is converted to Y, and lands a code value away.
        let encode = Process()
        encode.executableURL = ffmpeg
        encode.arguments = [
            "-v", "error", "-y", "-f", "lavfi", "-i",
            "color=c=black:s=64x64:d=0.2:r=24,format=yuv420p,lutyuv=y=126:u=128:v=128,"
                + "setparams=colorspace=bt709:color_primaries=bt709:color_trc=bt709:range=tv",
            "-c:v", "libx264", "-profile:v", "high", "-crf", "1",
            "-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709", movie.path,
        ]
        try encode.run()
        encode.waitUntilExit()
        XCTAssertEqual(encode.terminationStatus, 0)

        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: movie))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let exported = light(try generator.copyCGImage(at: .zero, actualTime: nil))
        let previewed = light(LiveChain.forDisplay(grey(128)))
        let untagged = light(grey(128))
        XCTAssertEqual(previewed, exported, accuracy: 0.003, "the preview and the export disagree")
        // And the untagged picture really was the mismatch, or this test proves nothing.
        XCTAssertGreaterThan(abs(untagged - exported), 0.03, "untagged already matched")
    }

    /// The Swift display curve is the Python one, which is what every cube is encoded with.
    func testTheDisplayCurveRoundTripsAndMatchesAppleColourSync() throws {
        for code in stride(from: 0.0, through: 1.0, by: 0.05) {
            XCTAssertEqual(
                HueCube.displayEncode(HueCube.displayDecode(code)), code, accuracy: 1e-12)
        }
        let previewed = light(LiveChain.forDisplay(grey(128)))
        XCTAssertEqual(Double(previewed), HueCube.displayDecode(128.0 / 255.0), accuracy: 0.002)
    }
}
