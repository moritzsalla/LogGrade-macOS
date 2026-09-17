import AVFoundation
import CoreImage
import Foundation

/// The clip's log frame at a timecode, decoded in this process, for the live tier to grade.
///
/// WHY NOT THE ENGINE. `grade.sh FRAME_STAGE=source` was the live tier's frame, and every clip
/// selection waited 2–3.5 s for it (a bash start, generators, a 4K decode, a PNG). AVFoundation
/// decodes the same 10-bit frame in 0.1–0.2 s for ProRes and ~0.9 s for HEVC on the Intel Mac.
///
/// HELD TO THE ENGINE'S FRAME, not trusted: `NativeSourceTests` compares it with
/// `FRAME_STAGE=source` on real footage. Measured at 480 high: mean 0.2–0.3 code values, 99.9th
/// percentile 5–13, worst 21–25 on IMG_0607 (ProRes portrait), IMG_0444 (ProRes landscape) and
/// IMG_0102 (HEVC landscape). The residue is Lanczos against Lanczos at hard edges; the live chain's
/// own budget against the render is mean 1.3, percentile 18.
///
/// Three things had to match what ffmpeg does, and each was measured wrong first:
///   - NO COLOUR MANAGEMENT. Only the YCbCr-to-RGB matrix, on the log values as stored, as
///     `format=gbrp16le` does. Core Image would otherwise read a transfer function into them.
///   - ORIENTATION through the track's transform, conjugated by Core Image's upward y axis. Applied
///     directly, a portrait clip came out rotated the wrong way (mean 39 code values off).
///   - AN EVEN WIDTH. `scale=-2:H` rounds the width to even, so the horizontal factor is that width
///     over the source's. Using the vertical factor both ways left a landscape frame's columns
///     drifting (99.9th percentile 62).
public enum NativeSource {
    public struct Frame {
        /// 16-bit RGB of the log picture, `height` high, as `LiveChain.converted` reads it.
        public let image: CGImage
        /// The decoded, oriented frame before resampling: what the engine's clip_planned reports.
        public let sourceSize: FrameSize
    }

    public enum Failure: Error, CustomStringConvertible {
        case noVideoTrack
        case noFrame
        case renderFailed

        public var description: String {
            switch self {
            case .noVideoTrack: return "the clip has no video track"
            case .noFrame: return "no frame could be decoded at that time"
            case .renderFailed: return "the frame could not be converted"
            }
        }
    }

    static let context = CIContext(options: [
        .workingColorSpace: NSNull(), .outputColorSpace: NSNull(),
    ])

    public static func frame(of url: URL, at seconds: Double, height: Int) throws -> Frame {
        let asset = AVAsset(url: url)
        guard let track = asset.tracks(withMediaType: .video).first else {
            throw Failure.noVideoTrack
        }
        let reader = try AVAssetReader(asset: asset)
        // THE FIRST FRAME AT OR AFTER the timecode, as ffmpeg's `-ss` gives. The reader alone
        // returns the frame SHOWING at a time, one frame early whenever no frame starts exactly
        // there (29.97 fps, a non-zero start); so it starts a little before and skips ahead.
        let wanted = CMTime(seconds: seconds, preferredTimescale: 600)
        reader.timeRange = CMTimeRange(
            start: CMTime(seconds: max(0, seconds - 0.2), preferredTimescale: 600),
            duration: CMTime(seconds: 0.4, preferredTimescale: 600))
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String:
                    kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange
            ])
        reader.add(output)
        guard reader.startReading() else { throw Failure.noFrame }
        var sample = output.copyNextSampleBuffer()
        var last = sample
        // Half a millisecond of slack: the timebases differ, and 1.0 s must still count as 1.0 s.
        let slack = CMTime(value: 1, timescale: 2000)
        while let current = sample,
            CMTimeCompare(CMTimeAdd(CMSampleBufferGetPresentationTimeStamp(current), slack), wanted)
                < 0
        {
            last = current
            sample = output.copyNextSampleBuffer()
        }
        // A clip that ends before the timecode gives its last frame, as ffmpeg's seek does.
        guard let chosen = sample ?? last, let buffer = CMSampleBufferGetImageBuffer(chosen)
        else { throw Failure.noFrame }
        defer { reader.cancelReading() }

        let image = oriented(buffer, by: track.preferredTransform)
        let size = FrameSize(width: Int(image.extent.width), height: Int(image.extent.height))
        let scale = Double(height) / image.extent.height
        let width = Int((image.extent.width * scale / 2).rounded()) * 2
        return Frame(image: try scaled(image, width: width, height: height), sourceSize: size)
    }

    /// The decoded picture, colour values untouched, turned upright by the track's transform.
    static func oriented(_ buffer: CVPixelBuffer, by transform: CGAffineTransform) -> CIImage {
        var image = CIImage(cvPixelBuffer: buffer, options: [.colorSpace: NSNull()])
        let flipBefore = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: image.extent.height)
        image = image.transformed(by: flipBefore.concatenating(transform))
        image = image.transformed(
            by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        return image.transformed(
            by: CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: image.extent.height))
    }

    /// Lanczos to exactly `width` x `height`, the two factors set separately as ffmpeg's are, into
    /// 16-bit RGB with no colour management.
    static func scaled(_ image: CIImage, width: Int, height: Int) throws -> CGImage {
        let scale = Double(height) / image.extent.height
        guard let lanczos = CIFilter(name: "CILanczosScaleTransform") else {
            throw Failure.renderFailed
        }
        lanczos.setValue(image, forKey: kCIInputImageKey)
        lanczos.setValue(scale, forKey: kCIInputScaleKey)
        lanczos.setValue(
            (Double(width) / image.extent.width) / scale, forKey: kCIInputAspectRatioKey)
        guard let scaled = lanczos.outputImage,
            let rendered = context.createCGImage(
                scaled, from: CGRect(x: 0, y: 0, width: width, height: height),
                format: .RGBA16, colorSpace: CGColorSpaceCreateDeviceRGB())
        else { throw Failure.renderFailed }
        return rendered
    }
}
