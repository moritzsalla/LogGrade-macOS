import Foundation

/// A delivery shape: a name and an aspect, and nothing about pixels.
///
/// WHY THIS IS DATA AND NOT AN ENUM OF TWO CASES. It was `reels: Bool, feed: Bool` here and a
/// two-branch `case` in the engine, which meant the set of shapes this tool can produce was
/// closed — a third one was an edit to the pipeline rather than a value. Instagram's two survive
/// as presets; they are no longer the only options. See docs/adr/0010.
///
/// THERE ARE NO PIXEL SIZES HERE, deliberately. Height follows the aspect off the shared delivery
/// width, and that arithmetic lives in the engine (`deliverable_height` in scripts/lib.sh) because
/// the engine is what renders. Carrying a second copy of it in Swift is exactly the duplication
/// ADR 0008 exists to prevent.
public struct Deliverable: Equatable, Hashable {
    public let name: String
    public let aspectWidth: Int
    public let aspectHeight: Int

    public init(name: String, aspectWidth: Int, aspectHeight: Int) {
        self.name = name
        self.aspectWidth = aspectWidth
        self.aspectHeight = aspectHeight
    }

    /// 9:16 — Reels and Stories, the whole portrait frame.
    public static let reels = Deliverable(name: "reels", aspectWidth: 9, aspectHeight: 16)
    /// 4:5 — a Feed post, cropped out of the portrait master.
    public static let feed = Deliverable(name: "feed", aspectWidth: 4, aspectHeight: 5)

    /// The shapes the interface offers as checkboxes. The panel is generated from this list, so a
    /// preset added here appears in the app without a UI edit.
    public static let presets: [Deliverable] = [.reels, .feed]

    /// What goes into the engine's `DELIVERABLES`.
    ///
    /// A PRESET EMITS ITS BARE NAME, never its expanded `reels:9:16` form, and that is a
    /// filename-stability guard rather than brevity: the engine's presets carry output suffixes
    /// (`reels-stories_9x16`, `feed_4x5`) that an arbitrary spec cannot reproduce, so an expanded
    /// preset would silently start writing `reels_9x16.mp4` beside somebody's existing files.
    public var spec: String {
        Self.presets.contains(self) ? name : "\(name):\(aspectWidth):\(aspectHeight)"
    }

    /// Whether this shape is a crop of a 9:16 master, by cross-multiplication rather than by name:
    /// 4:5 is a crop of a 9:16 master and the whole frame of a 4:5 one, so the question is about
    /// ratios and never about which preset it is.
    ///
    /// THE ENGINE IS STILL THE AUTHORITY. It decides per clip, from the frame it actually decoded,
    /// and refuses a window that does not fit. This is the interface's cheaper question — "must I
    /// ask for a crop offset before Convert can run?" — answered against the 9:16 master this
    /// pipeline takes, so the app can say it before a render starts instead of discovering it from
    /// an exit code.
    public var cropsPortraitMaster: Bool {
        aspectWidth * 16 != aspectHeight * 9
    }
}
