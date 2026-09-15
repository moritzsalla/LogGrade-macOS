import Foundation

/// A starting exposure, black point and contrast, solved from a luma histogram.
///
/// LIGHTROOM'S PLAIN AUTO, NOT AUTO WHITE BALANCE OR AUTO COLOUR. Only the tonal fields
/// (`correct.exposure`, `tone.black`, `tone.contrast`) are touched — never white balance, the CDL
/// wheels, saturation or either LUT. Those are curated choices (the shipped saturation is
/// deliberately off spec, `look.json`'s `_comment`), and a gray-world guess at white balance would
/// fight the exposure-matching this pipeline already does per shoot (ADR 0011), not help it.
///
/// PERCENTILE, NOT THE EXTREMES. The darkest and brightest half percent are read as noise/outliers,
/// the same clip-based approach Lightroom's auto uses, rather than chasing a single hot pixel.
public enum AutoTone {
    public struct Solved: Equatable {
        public let exposure: Double
        public let black: Double
        public let contrast: Double

        public init(exposure: Double, black: Double, contrast: Double) {
            self.exposure = exposure
            self.black = black
            self.contrast = contrast
        }
    }

    static let lowPercentile = 0.005
    static let highPercentile = 0.995
    /// Leaves headroom for the shoulder and grain stages downstream of the tone curve.
    static let targetWhite = 0.92
    /// The shipped look's own black lift (`look.json`'s `tone.black`), so a clip that already has
    /// shadow detail is not pushed past what the shipped grade itself considers a starting point.
    static let targetBlack = 0.03
    static let targetSpread = 0.85

    static let exposureRange = -2.0...2.0
    static let blackRange = 0.0...0.08
    static let contrastRange = 0.85...1.25

    /// `baseExposure`/`baseContrast` are the values `histogram` was measured under, so a second,
    /// corrective pass composes onto the first rather than solving from zero twice.
    public static func solve(
        histogram: Scopes, baseExposure: Double = 0, baseContrast: Double = 1
    ) -> Solved? {
        guard let black = percentile(histogram.luma, lowPercentile),
            let white = percentile(histogram.luma, highPercentile),
            white >= black
        else { return nil }

        let exposure = baseExposure + log2(targetWhite / max(white, 0.001))
        let spread = max(white - black, 0.05)
        let contrast = baseContrast * (targetSpread / spread)
        // Shadows already sitting above the shipped floor need no extra lift; only a floor that
        // measured at (or near) true black gets raised, and only up to that floor.
        let blackLift = max(0, targetBlack - black)

        return Solved(
            exposure: clamp(exposure, to: exposureRange),
            black: clamp(blackLift, to: blackRange),
            contrast: clamp(contrast, to: contrastRange))
    }

    /// The luma level, 0...1, at which the cumulative histogram first reaches `fraction` of the
    /// sampled pixels.
    static func percentile(_ bins: [Int], _ fraction: Double) -> Double? {
        let total = bins.reduce(0, +)
        guard total > 0, bins.count > 1 else { return nil }
        let target = Double(total) * fraction
        var cumulative = 0.0
        for (i, count) in bins.enumerated() {
            cumulative += Double(count)
            if cumulative >= target { return Double(i) / Double(bins.count - 1) }
        }
        return 1
    }

    private static func clamp(_ value: Double, to range: ClosedRange<Double>) -> Double {
        min(range.upperBound, max(range.lowerBound, value))
    }
}
