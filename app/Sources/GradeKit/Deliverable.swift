import Foundation

/// How a custom deliverable handles its crop offset.
///
/// PRESETS NEVER HAVE AN OFFSET: they emit bare names and always follow the clip's CROP_Y.
/// Custom deliverables can specify `.centre` to crop to a fixed centre, or nil to follow CROP_Y.
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
/// CROPOFFSET ON CUSTOM SHAPES ONLY. Presets always emit their bare name; adding an offset would
/// change their output filename, breaking existing renders. Custom deliverables can specify a fixed
/// centre offset (emitting `name:aw:ah:centre`) or follow the clip's `CROP_Y` (emitting `name:aw:ah`).
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
        var result = "\(name):\(aspectWidth):\(aspectHeight)"
        if let offset = cropOffset, offset == .centre {
            result += ":centre"
        }
        return result
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

    /// Whether this deliverable crops and needs a per-clip offset to be decided.
    ///
    /// A DELIVERABLE WITH CENTRE OFFSET DOES NOT NEED PER-CLIP FRAMING. It crops but has a fixed
    /// centre, so Convert can run without asking. One that follows CROP_Y is blocked per-clip.
    public var needsClipOffset: Bool {
        cropsPortraitMaster && cropOffset == nil
    }

    /// Validation error for custom deliverables.
    public enum ValidationError: Equatable, CustomStringConvertible {
        case emptyName
        case invalidNameCharacters
        case duplicateName
        case zeroAspect
        case negativeAspect
        case nonIntegerAspect

        public var description: String {
            switch self {
            case .emptyName:
                return "Name cannot be empty."
            case .invalidNameCharacters:
                return "Name contains characters ffmpeg reads as filter syntax."
            case .duplicateName:
                return "A deliverable with this name already exists."
            case .zeroAspect:
                return "Aspect must be greater than zero."
            case .negativeAspect:
                return "Aspect must be greater than zero."
            case .nonIntegerAspect:
                return "Aspect must be whole numbers."
            }
        }
    }

    /// Check if a name is valid for a deliverable.
    ///
    /// THE NAME GUARD MIRRORS require_clip_name IN lib.sh: it rejects names that would reach
    /// ffmpeg's filter graph or break path composition. Presets bypass this because they are
    /// known-good constants.
    public static func validateName(_ name: String, against existing: [Deliverable]) -> ValidationError? {
        if name.isEmpty { return .emptyName }
        let invalidChars = Set("/'\",;[]\\:")
        if name.contains(where: { invalidChars.contains($0) }) {
            return .invalidNameCharacters
        }
        if existing.contains(where: { $0.name == name }) {
            return .duplicateName
        }
        return nil
    }

    /// Check if aspects are valid for a deliverable.
    public static func validateAspect(width: Int, height: Int) -> ValidationError? {
        if width <= 0 || height <= 0 { return .zeroAspect }
        return nil
    }
}
