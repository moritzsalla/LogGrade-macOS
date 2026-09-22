/// Rec.709's luma coefficients, and the chroma scales that follow from them.
///
/// ONE COPY, because `Scopes` and `CorrectionCube` (the generator's saturation) need the same
/// numbers.
enum Rec709 {
    static let kr = 0.2126
    static let kg = 0.7152
    static let kb = 0.0722
    /// B - Y divided by this is Cb; R - Y divided by `crScale` is Cr.
    static let cbScale = 1.8556
    static let crScale = 1.5748

    @inline(__always)
    static func luma(_ r: Double, _ g: Double, _ b: Double) -> Double {
        kr * r + kg * g + kb * b
    }
}
