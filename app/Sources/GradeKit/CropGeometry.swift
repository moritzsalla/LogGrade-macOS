import Foundation

/// Where a deliverable's crop window sits on the master, and what a drag on the preview means in
/// its terms.
///
/// THE OFFSET IS IN MASTER PIXELS, not preview pixels, because that is what the engine takes and
/// what the project file records. The preview is the same frame at display height, so the mapping
/// is a ratio — but getting it backwards would place the box somewhere the render does not, and a
/// crop that lies is worse than no crop picker at all.
///
/// The bounds are the engine's (`crop_window` in scripts/lib.sh): the largest window of the aspect
/// that fits, which always fills one source axis and so moves along the other only — up and down on
/// a portrait frame, left and right on a landscape one. Past the edge the engine refuses, seconds
/// into a render, which is exactly what picking it here is meant to prevent.
public struct CropGeometry: Equatable {
    public enum Axis: Equatable { case x, y }

    public let sourceWidth: Int
    public let sourceHeight: Int
    public let aspectWidth: Int
    public let aspectHeight: Int

    /// THE ASPECT HAS NO DEFAULT, deliberately. It defaulted to 4:5 and `GradeModel` never passed
    /// one, so the box drawn on the picture was a Feed window whatever the cropping deliverable
    /// actually was — a crop that lies, which this type's own header calls worse than no crop
    /// picker at all. Requiring it at the call site is what stops it recurring.
    public init(sourceWidth: Int, sourceHeight: Int, aspectWidth: Int, aspectHeight: Int) {
        self.sourceWidth = sourceWidth
        self.sourceHeight = sourceHeight
        self.aspectWidth = aspectWidth
        self.aspectHeight = aspectHeight
    }

    public init(source: FrameSize, deliverable: Deliverable) {
        self.init(
            sourceWidth: source.width, sourceHeight: source.height,
            aspectWidth: deliverable.aspectWidth, aspectHeight: deliverable.aspectHeight)
    }

    /// The y axis first, as the engine tries it, so a portrait source keeps its full-width window.
    private var fullWidthHeight: Int {
        let h = sourceWidth * aspectHeight / aspectWidth
        return h - h % 2
    }

    public var axis: Axis { fullWidthHeight <= sourceHeight ? .y : .x }

    /// The window on the master. Even, because libx264 rejects an odd dimension and does so at
    /// encode time, after the graph is built.
    public var windowWidth: Int {
        guard axis == .x else { return sourceWidth }
        let w = sourceHeight * aspectWidth / aspectHeight
        return w - w % 2
    }

    public var windowHeight: Int { axis == .y ? fullWidthHeight : sourceHeight }

    /// Whether there is a window to place at all. False for a shape that is the source's own.
    public var crops: Bool { windowWidth != sourceWidth || windowHeight != sourceHeight }

    private var sourceLength: Int { axis == .y ? sourceHeight : sourceWidth }
    private var windowLength: Int { axis == .y ? windowHeight : windowWidth }

    public var maximumOffset: Int { max(0, sourceLength - windowLength) }

    /// Where the engine puts a `centre` window: half the slack, rounded down to even. A copy of
    /// `crop_prefix` in scripts/lib.sh, held to it by `CropGeometryTests` on an odd slack, because
    /// a box drawn a row off the render is the crop that lies.
    public var centreOffset: Int {
        let half = maximumOffset / 2
        return half - half % 2
    }

    public func clamp(_ offset: Int) -> Int { min(maximumOffset, max(0, offset)) }

    public func isValid(_ offset: Int) -> Bool { offset >= 0 && offset <= maximumOffset }

    /// The window as a fraction of the frame along the crop's axis, which is what a view needs in
    /// order to draw it over an image of any size.
    public var windowFraction: Double {
        guard sourceLength > 0 else { return 1 }
        return Double(windowLength) / Double(sourceLength)
    }

    public func fraction(forOffset offset: Int) -> Double {
        guard sourceLength > 0 else { return 0 }
        return Double(offset) / Double(sourceLength)
    }

    /// A drag: the leading edge of the box, as a fraction of the displayed frame along the axis,
    /// becomes an offset on the master. Clamped here rather than at the edge of the render.
    public func offset(forFraction fraction: Double) -> Int {
        clamp(Int((fraction * Double(sourceLength)).rounded()))
    }

    /// The `crop=` filter the engine builds for this window at an offset, for tests and nothing else.
    func filter(at offset: Int) -> String {
        axis == .y
            ? "crop=\(windowWidth):\(windowHeight):0:\(offset),\n"
            : "crop=\(windowWidth):\(windowHeight):\(offset):0,\n"
    }
}

/// A clip's DECODED frame, as the engine measured it and reported in `clip_planned`. Not the
/// container's dimensions, which this camera reports unrotated (see `ClipProbe`).
public struct FrameSize: Equatable {
    public let width: Int
    public let height: Int
    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}
