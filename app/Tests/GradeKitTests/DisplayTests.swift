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

    /// A Rec.709-tagged H.264 of flat grey at limited-range luma `y`, as AVFoundation shows it.
    private func exported(y: Int, in work: URL) throws -> Float {
        guard let ffmpeg = EngineLocation.resolveTool("ffmpeg") else { throw XCTSkip("no ffmpeg") }
        let movie = work.appendingPathComponent("grey-\(y).mp4")
        // Set exactly: a `color=` source's grey is converted to Y, and lands a code value away.
        let encode = Process()
        encode.executableURL = ffmpeg
        encode.arguments = [
            "-v", "error", "-y", "-f", "lavfi", "-i",
            "color=c=black:s=64x64:d=0.2:r=24,format=yuv420p,lutyuv=y=\(y):u=128:v=128,"
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
        return light(try generator.copyCGImage(at: .zero, actualTime: nil))
    }

    /// Checked in the shadows as well as at mid grey: the inverse BT.709 OETF agrees with playback
    /// at mid grey and shows luma 36 over twice as light, so a mid-grey check alone passed it.
    func testThePreviewShowsAGreyAsQuickTimeShowsTheExport() throws {
        let work = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("display-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        // Luma 36 is code 20/219 = 0.0913 and 126 is 0.5023; 8-bit 23 (0.0902) and 128 (0.5020)
        // land within the tolerance of them.
        for (y, code) in [(36, UInt8(23)), (126, UInt8(128))] {
            let exported = try exported(y: y, in: work)
            let previewed = light(LiveChain.forDisplay(grey(code)))
            XCTAssertEqual(
                previewed, exported, accuracy: 0.0015,
                "luma \(y): the preview and the export disagree")
            XCTAssertEqual(
                Double(exported), LiveChain.displayDecode(Double(y - 16) / 219), accuracy: 0.0015,
                "luma \(y): playback is not the curve the cubes are encoded for")
            if y == 126 {
                // The untagged picture really was the mismatch, or this proves nothing about tagging.
                XCTAssertGreaterThan(
                    abs(light(grey(code)) - exported), 0.03, "untagged already matched")
            }
        }
    }

    /// The Swift display curve is the Python one, which is what every cube is encoded with.
    func testTheDisplayCurveRoundTrips() {
        for code in stride(from: 0.0, through: 1.0, by: 0.05) {
            XCTAssertEqual(
                LiveChain.displayEncode(LiveChain.displayDecode(code)), code, accuracy: 1e-12)
        }
    }
}
