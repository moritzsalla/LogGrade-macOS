import Foundation

/// Where a deliverable's crop window sits on the master, and what a drag on the preview means in
/// its terms.
///
/// THE OFFSET IS IN MASTER PIXELS, not preview pixels, because that is what the engine takes and
/// what the project file records. The preview is the same frame at display height, so the mapping
/// is a ratio — but getting it backwards would place the box somewhere the render does not, and a
/// crop that lies is worse than no crop picker at all.
///
/// The bounds are the engine's: the window is as wide as the source and as tall as that width
/// times the aspect, so the offset can run from zero to whatever is left. Past the edge the engine
/// refuses, seconds into a render, which is exactly what picking it here is meant to prevent.
public struct CropGeometry: Equatable {
    public let sourceWidth: Int
    public let sourceHeight: Int
    public let aspectWidth: Int
    public let aspectHeight: Int

    /// THE ASPECT HAS NO DEFAULT, deliberately. It defaulted to 4:5 and `GradeModel` never passed
    /// one, so the box drawn on the picture was a Feed window whatever the cropping deliverable
    /// actually was — a crop that lies, which this type's own header calls worse than no crop
    /// picker at all. Unreachable while Feed was the only cropping preset; reachable the moment a
    /// deliverable became any shape. Requiring it at the call site is what stops it recurring.
    public init(sourceWidth: Int, sourceHeight: Int, aspectWidth: Int, aspectHeight: Int) {
        self.sourceWidth = sourceWidth
        self.sourceHeight = sourceHeight
        self.aspectWidth = aspectWidth
        self.aspectHeight = aspectHeight
    }

    /// The window's height on the master. Even, because libx264 rejects an odd dimension and does
    /// so at encode time, after the graph is built.
    public var windowHeight: Int {
        let h = sourceWidth * aspectHeight / aspectWidth
        return h - h % 2
    }

    public var maximumOffset: Int { max(0, sourceHeight - windowHeight) }

    public func clamp(_ offset: Int) -> Int { min(maximumOffset, max(0, offset)) }

    public func isValid(_ offset: Int) -> Bool { offset >= 0 && offset <= maximumOffset }

    /// The window as a fraction of the frame's height, which is what a view needs in order to draw
    /// it over an image of any size.
    public var windowFraction: Double {
        guard sourceHeight > 0 else { return 1 }
        return Double(windowHeight) / Double(sourceHeight)
    }

    public func fraction(forOffset offset: Int) -> Double {
        guard sourceHeight > 0 else { return 0 }
        return Double(offset) / Double(sourceHeight)
    }

    /// A drag: the top of the box, as a fraction of the displayed frame, becomes an offset on the
    /// master. Clamped here rather than at the edge of the render.
    public func offset(forFraction fraction: Double) -> Int {
        clamp(Int((fraction * Double(sourceHeight)).rounded()))
    }

}
