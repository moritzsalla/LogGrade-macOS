/// Rec.709's luma coefficients, and the chroma scales that follow from them.
///
/// ONE COPY, because three places need them to be the same numbers: `LiveGrade` models the plane
/// split ffmpeg does around `lut1d`, `Scopes` measures the frame that split produced, and
/// `CorrectionCube` transcribes the generator's luminance mix. A scope that disagreed with the
/// model about what luma is would show a picture the grade did not make.
///
/// The scales are written as literals rather than computed as 2(1 - k): the golden `LiveGradeTests`
/// compares against was made from these spellings, and `2 * (1 - 0.0722)` is not bit-identical to
/// `1.8556`.
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
