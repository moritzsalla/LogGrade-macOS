import Foundation

/// What a clip is, measured rather than assumed.
///
/// WHY ffprobe AND NOT AVFoundation. Apple Log is identified definitively by a log transfer
/// function on the format description — and that extension does not exist on macOS 13. Measured on
/// this machine against a real Apple Log clip: the format description carries BitsPerComponent,
/// CVImageBufferColorPrimaries, CVImageBufferYCbCrMatrix and nine other keys, and no transfer
/// function of any kind. So the check that would be authoritative is unavailable at the
/// deployment target, and ffprobe is what is left.
///
/// HOW THIS CAMERA LIES TO ffprobe, which is why every field is read one at a time. The video
/// stream prints TWICE for these files, csv output carries a trailing comma, and an audio stream
/// selector returns nothing despite audio being present. The engine's own docs carry the
/// measurements. So: one field per call, `-of default=nw=1:nk=1`, first line taken, and the value
/// validated before it is believed.
///
/// NO ORIENTATION ANSWER HERE, deliberately. The container's width and height are not what
/// the filter graph sees: this camera stores rotation as a display-matrix flag and ffmpeg
/// autorotates on decode, so a vertical clip measures 3840x2160 here — measured, on real
/// footage, which is how the first version of this type got it wrong. Orientation is decided
/// by decoding a frame, which the engine does and reports in `clip_planned`
/// (`PreviewRenderer.Frame.sourceSize`). See docs/adr/0005_ORIENTATION_IS_AN_INGEST_CONCERN.md.
public struct ClipProbe {
    public let ffprobe: URL
    public init(ffprobe: URL) { self.ffprobe = ffprobe }

    public struct Fields: Equatable {
        public var codec: String
        public var pixelFormat: String
        public var primaries: String
        public var transfer: String
        public var width: Int
        public var height: Int
        /// Seconds, and frames per second resolved from ffprobe's rational, so a queue can turn
        /// "frame 412" into a fraction of the work. Nil when ffprobe does not answer, which it sometimes does not.
        public var duration: Double?
        public var frameRate: Double?

        /// How many frames a render of this clip has to get through.
        public var frameCount: Int? {
            guard let duration, let frameRate, frameRate > 0 else { return nil }
            return Int((duration * frameRate).rounded())
        }

        /// One line for the interface. Built here rather than interpolated in a view, because
        /// SwiftUI formats an interpolated Int with the locale's separators — so 3840 rendered as
        /// "3.840" on a German system, which reads as a decimal.
        public var summary: String {
            "\(codec) \(pixelFormat) \(primaries) \(width)x\(height)"
        }
    }

    public enum Verdict: Equatable, CustomStringConvertible {
        /// The signature of Apple Log: BT.2020 primaries, no transfer function named, 10-bit.
        case appleLog
        /// Rec.709 or sRGB: already through a conversion. Grading it again applies the conversion
        /// twice, which is the *bleached* failure with a new cause.
        case alreadyConverted(String)
        case notLog(String)
        case unreadable(String)

        public var description: String {
            switch self {
            case .appleLog:
                return "Apple Log"
            case .alreadyConverted(let why):
                return "already converted: \(why). Grading it again would apply Apple's "
                    + "conversion twice — see CONTEXT.md on \"bleached\"."
            case .notLog(let why):
                return "not Apple Log: \(why)"
            case .unreadable(let why):
                return "could not measure: \(why)"
            }
        }

        public var isAppleLog: Bool { self == .appleLog }
    }

    private func field(_ entry: String, of url: URL) -> String? {
        let process = Process()
        process.executableURL = ffprobe
        process.arguments = ["-v", "error", "-select_streams", "v:0",
                             "-show_entries", "stream=\(entry)",
                             "-of", "default=nw=1:nk=1", url.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        // FIRST line only: this camera's files print the video stream twice, so a naive read of
        // the whole output gets two values and a blank line.
        let text = String(decoding: data, as: UTF8.self)
        guard let first = text.split(separator: "\n").first(where: {
            !$0.trimmingCharacters(in: .whitespaces).isEmpty
        }) else { return nil }
        // And a trailing comma appears on camera originals, so it is stripped rather than trusted.
        return first.trimmingCharacters(in: CharacterSet(charactersIn: " ,\r"))
    }

    public func fields(of url: URL) -> Fields? {
        guard let codec = field("codec_name", of: url),
              let pix = field("pix_fmt", of: url),
              let w = field("width", of: url).flatMap(Int.init),
              let h = field("height", of: url).flatMap(Int.init) else { return nil }
        var rate: Double?
        if let raw = field("r_frame_rate", of: url) {
            let parts = raw.split(separator: "/").compactMap { Double($0) }
            if parts.count == 2, parts[1] != 0 { rate = parts[0] / parts[1] }
            else if parts.count == 1 { rate = parts[0] }
        }
        return Fields(codec: codec,
                      pixelFormat: pix,
                      primaries: field("color_primaries", of: url) ?? "unknown",
                      transfer: field("color_transfer", of: url) ?? "unknown",
                      width: w, height: h,
                      duration: field("duration", of: url).flatMap(Double.init),
                      frameRate: rate)
    }

    /// A SIGNATURE, not proof, and the interface says so. What it rules out is the case that
    /// matters: footage that has already been converted, which would otherwise be converted again.
    public func verdict(for url: URL) -> Verdict {
        guard let f = fields(of: url) else {
            return .unreadable("ffprobe read no video stream from \(url.lastPathComponent)")
        }
        let converted = ["bt709", "smpte170m", "iec61966-2-1", "srgb"]
        if converted.contains(f.transfer) {
            return .alreadyConverted("its transfer function is \(f.transfer)")
        }
        if converted.contains(f.primaries) {
            return .alreadyConverted("its primaries are \(f.primaries)")
        }
        guard f.primaries == "bt2020" else {
            return .notLog("its primaries are \(f.primaries), and Apple Log is BT.2020")
        }
        guard f.pixelFormat.contains("10") || f.pixelFormat.contains("12") else {
            return .notLog("it is \(f.pixelFormat), and Apple Log is at least 10-bit")
        }
        return .appleLog
    }
}
