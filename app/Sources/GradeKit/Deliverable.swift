import Foundation

/// A crop offset a deliverable carries for itself, which the engine lets beat the run's `CROP_Y`.
///
/// ONLY CENTRE, not a pixel count. A pixel offset is a composition call about one clip, and this
/// value applies to every clip in the project; `centre` is resolved per clip against the frame the
/// engine measured, which is the one fixed offset that means the same thing on all of them.
public enum DeliverableCropOffset: Equatable, Hashable {
    case centre
}

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
///
/// A PRESET WITH AN OFFSET IS NOT THE PRESET. Equality includes `cropOffset`, so a project file
/// entry `reels` 9:16 `centre` is a custom shape and goes to the engine as `reels:9:16:centre`,
/// writing `reels_9x16` rather than the preset's file. Nothing stops a hand-edited project file
/// saying that; the editor refuses a preset's name, which is what keeps the interface from
/// producing it.
public struct Deliverable: Equatable, Hashable {
    public let name: String
    public let aspectWidth: Int
    public let aspectHeight: Int
    public let cropOffset: DeliverableCropOffset?

    public init(name: String, aspectWidth: Int, aspectHeight: Int,
                cropOffset: DeliverableCropOffset? = nil) {
        self.name = name
        self.aspectWidth = aspectWidth
        self.aspectHeight = aspectHeight
        self.cropOffset = cropOffset
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
        if Self.presets.contains(self) { return name }
        let shape = "\(name):\(aspectWidth):\(aspectHeight)"
        return cropOffset == .centre ? shape + ":centre" : shape
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

    /// Whether this shape crops AND takes its offset from the clip's `CROP_Y`, which is what has to
    /// be decided per clip before Convert can run. A shape carrying `centre` still crops — its box
    /// is still drawn — but the engine lets its own offset beat `CROP_Y`, so there is nothing to
    /// ask.
    public var needsClipOffset: Bool {
        cropsPortraitMaster && cropOffset == nil
    }
}
