import Foundation

/// A crop offset a deliverable carries for itself, which the engine lets beat the run's `CROP_OFFSET`.
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

    /// 9:16 — Reels and Stories.
    public static let reels = Deliverable(name: "reels", aspectWidth: 9, aspectHeight: 16)
    /// 4:5 — a Feed post.
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

    /// Whether this shape crops a clip, by geometry rather than by name: 4:5 is a crop of a 9:16
    /// master and the whole frame of a 4:5 one, and 9:16 is a crop of a landscape one.
    ///
    /// THE ENGINE IS STILL THE AUTHORITY. It decides per clip, from the frame it decoded. This is
    /// the interface's cheaper question — "must I ask for a crop offset before Convert can run?" —
    /// so the app can say it before a render starts instead of discovering it from an exit code.
    ///
    /// A CLIP NOT YET MEASURED is answered as a 9:16 master, the shape this camera shoots portrait.
    /// The size arrives with the clip's first preview. Answering "crops" instead would block every
    /// unpreviewed clip on reels; the cost of this guess is that a landscape clip nobody previewed
    /// reaches the engine, which refuses it by name (`REFUSE_CROP_NO_OFFSET`) rather than
    /// rendering it.
    public func crops(_ source: FrameSize?) -> Bool {
        guard let source else { return aspectWidth * 16 != aspectHeight * 9 }
        return CropGeometry(source: source, deliverable: self).crops
    }

    /// Whether this shape crops the clip AND takes its offset from the clip's `CROP_OFFSET`, which
    /// is what has to be decided per clip before Convert can run. A shape carrying `centre` still
    /// crops — its box is still drawn — but the engine lets its own offset win, so there is
    /// nothing to ask.
    public func needsClipOffset(_ source: FrameSize?) -> Bool {
        crops(source) && cropOffset == nil
    }
}
