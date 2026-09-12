import AVFoundation
import Foundation

/// The clips the interface is working on, with what was measured about each.
///
/// ObservableObject rather than @Observable: the latter is macOS 14 and this builds against 13.
/// A bats test greps for it, because the failure would only appear on the machine that cannot be
/// used to fix it.
public final class ClipList: ObservableObject {
    public struct Entry: Identifiable, Equatable {
        /// The filename stem, which is the join key back to the footage and to the camera's own
        /// capture order. Never renamed, and what the project file keys on.
        public var id: String { stem }
        public let stem: String
        public let url: URL
        public let verdict: ClipProbe.Verdict
        public let fields: ClipProbe.Fields?
        public var thumbnail: CGImage?

        public var isUsable: Bool { verdict.isAppleLog }
    }

    @Published public private(set) var entries: [Entry] = []

    private let probe: ClipProbe?
    public init(probe: ClipProbe?) { self.probe = probe }

    /// Adds clips, measuring each. Refused ones are KEPT in the list with their reason rather than
    /// dropped: a file that silently disappears when you drop it reads as a broken interface, and
    /// the reason is the thing the person needs.
    @discardableResult
    public func add(_ urls: [URL]) -> [Entry] {
        var added: [Entry] = []
        for url in urls where !entries.contains(where: { $0.url == url }) {
            let stem = url.deletingPathExtension().lastPathComponent
            let fields = probe?.fields(of: url)
            let verdict = probe?.verdict(for: url)
                ?? .unreadable("no ffprobe available to measure with")
            let entry = Entry(stem: stem, url: url, verdict: verdict, fields: fields,
                              thumbnail: nil)
            entries.append(entry)
            added.append(entry)
        }
        return added
    }

    public func remove(_ stem: String) {
        entries.removeAll { $0.stem == stem }
    }

    public var usable: [Entry] { entries.filter(\.isUsable) }

    /// One frame, for the list. Not a preview of the grade — that comes from the engine, through
    /// the real chain, because a still decoded here has had no conversion applied and would
    /// mispredict every reading.
    public func loadThumbnail(for stem: String, atSeconds seconds: Double = 1) {
        guard let index = entries.firstIndex(where: { $0.stem == stem }) else { return }
        let url = entries[index].url
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let generator = AVAssetImageGenerator(asset: AVAsset(url: url))
            generator.appliesPreferredTrackTransform = true   // honour the display matrix
            generator.maximumSize = CGSize(width: 240, height: 240)
            let time = CMTime(seconds: seconds, preferredTimescale: 600)
            guard let image = try? generator.copyCGImage(at: time, actualTime: nil) else { return }
            DispatchQueue.main.async {
                guard let self, let i = self.entries.firstIndex(where: { $0.stem == stem }) else {
                    return
                }
                self.entries[i].thumbnail = image
            }
        }
    }
}
