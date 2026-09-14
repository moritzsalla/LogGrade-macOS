import Foundation

/// The tone curve, from the engine's own generator or from an exact transcription of it.
///
/// The curve was first only subprocessed from `make-tone-lut.py --stdout`, so the interface drew
/// the same bytes the render applied and a port had nothing to drift from. That cost about a tenth
/// of a second per control change, which put the tone sliders a frame or two behind the pointer,
/// so `generated(tone:size:)` and `solvedGamma(clipYAVG:...)` now compute it in process. They are
/// licensed the way `CorrectionCube` is — `ToneCurvePortTests` holds every entry to the
/// generator's output — and the subprocess path stays, because that test needs it.
public struct ToneCurve: Equatable {
    /// Output value for each input, evenly spaced over 0...1. The generator writes 4096 of them.
    public let samples: [Double]

    public init(samples: [Double]) { self.samples = samples }

    public func value(at x: Double) -> Double {
        guard !samples.isEmpty else { return x }
        let clamped = min(1, max(0, x))
        let position = clamped * Double(samples.count - 1)
        let low = Int(position)
        let high = min(samples.count - 1, low + 1)
        let t = position - Double(low)
        return samples[low] * (1 - t) + samples[high] * t
    }

    public enum Failure: Error, CustomStringConvertible {
        case generatorFailed(String)
        case noTable(String)

        public var description: String {
            switch self {
            case .generatorFailed(let s): return "the tone generator failed: \(s)"
            case .noTable(let s): return "the generator wrote no table: \(s)"
            }
        }
    }

    /// The gamma the engine will actually apply to this clip.
    ///
    /// THE SLIDER IS NOT THE CURVE. With exposure matching on — which is the engine's default and
    /// what every render in this app uses — `tone.gamma` is the REFERENCE gamma, and the engine
    /// solves a per-clip gamma from it so that every clip lands where the look was tuned. Drawing
    /// or previewing the slider value directly shows a curve nothing renders: on this footage the
    /// solve moves 2.02 by enough to be obvious in the shadows. This runs the engine's own solver;
    /// the in-process port below is what the interface calls, and this is what it is held to.
    public static func solvedGamma(using solver: URL, clipYAVG: Double, referenceYAVG: Double,
                                   referenceGamma: Double) -> Double {
        let process = Process()
        process.executableURL = solver
        process.arguments = [String(clipYAVG), String(referenceYAVG), String(referenceGamma)]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        // A solver that will not run is not a reason to draw nothing; the reference gamma is what
        // the engine itself falls back to when the probe says nothing usable.
        do { try process.run() } catch { return referenceGamma }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let value = Double(String(decoding: data, as: UTF8.self)
                  .trimmingCharacters(in: .whitespacesAndNewlines))
        else { return referenceGamma }
        return value
    }

    /// The curve, built here, so a slider is dragged against a picture rather than against a
    /// subprocess.
    ///
    /// A SECOND IMPLEMENTATION, LICENSED THE SAME WAY AS `CorrectionCube`. Generating this through
    /// Python costs about a tenth of a second, which put the tone controls a frame or two behind
    /// the pointer; the maths itself is twelve lines. `ToneCurvePortTests` builds all 4096 entries
    /// both ways and requires them to agree to the precision the generator prints, so the two
    /// cannot drift without a test naming which one moved. The reasoning for every term lives in
    /// `scripts/make-tone-lut.py`'s header and is not repeated here.
    public static func generated(tone: Look.Tone, size: Int = 4096) -> ToneCurve {
        /// Smooth compression toward 0...1 with strength k; k = 0 is a no-op.
        func soft(_ x: Double, _ k: Double) -> Double {
            if k <= 0 { return min(1, max(0, x)) }
            if x <= 0 { return 0 }
            if x >= 1 { return 1 }
            return x + k * (x * x * (3 - 2 * x) - x)
        }
        var samples = [Double](repeating: 0, count: size)
        let last = Double(size - 1)
        for i in 0..<size {
            let x = Double(i) / last
            var v = tone.gamma == 1 ? x : pow(x, tone.gamma)
            v = (v - tone.pivot) * tone.contrast + tone.pivot
            if v < tone.pivot {
                let t = tone.pivot > 0 ? v / tone.pivot : 0
                v = soft(max(0, t), tone.toe) * tone.pivot
            } else {
                let span = 1 - tone.pivot
                let t = span > 0 ? (v - tone.pivot) / span : 0
                v = tone.pivot + soft(min(1, max(0, t)), tone.shoulder) * span
            }
            v = v * (1 - tone.black) + tone.black
            samples[i] = min(1, max(0, v))
        }
        return ToneCurve(samples: samples)
    }

    /// The gamma the engine will apply to this clip, solved here for the same reason.
    ///
    /// Ten lines of arithmetic that used to be a process launch on the drag path. The clamp and
    /// the two domain guards are the generator's, and `ToneCurvePortTests` holds the two against
    /// each other across the range including both guards.
    public static func solvedGamma(clipYAVG: Double, referenceYAVG: Double,
                                   referenceGamma: Double, peak: Double = 1023) -> Double {
        let y = clipYAVG / peak
        let r = referenceYAVG / peak
        // Outside the open unit interval there is no solve: log(0) raises and y == 1 makes the
        // denominator zero. Both mean "this probe tells us nothing", not "this clip is broken".
        guard y > 0, y < 1, r > 0, r < 1 else { return referenceGamma }
        return min(3.2, max(1.2, referenceGamma * log(r) / log(y)))
    }

    /// Runs the engine's generator and parses what it writes. Arguments are the same names the
    /// engine passes, so there is one spelling of each parameter across the two languages.
    public static func generate(using generator: URL, tone: Look.Tone) throws -> ToneCurve {
        let process = Process()
        process.executableURL = generator
        process.arguments = ["--stdout",
                             "--gamma", String(tone.gamma),
                             "--pivot", String(tone.pivot),
                             "--contrast", String(tone.contrast),
                             "--toe", String(tone.toe),
                             "--shoulder", String(tone.shoulder),
                             "--black", String(tone.black)]
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do { try process.run() } catch {
            throw Failure.generatorFailed(String(describing: error))
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errorText = String(decoding: err.fileHandleForReading.readDataToEndOfFile(),
                               as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw Failure.generatorFailed(errorText) }

        var samples: [Double] = []
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let parts = line.split(separator: " ")
            // A .cube's table rows are three equal values for a 1D curve; the header lines are
            // TITLE and LUT_1D_SIZE and are skipped by failing to parse.
            guard parts.count == 3, let first = Double(parts[0]) else { continue }
            samples.append(first)
        }
        guard samples.count > 1 else { throw Failure.noTable(errorText) }
        return ToneCurve(samples: samples)
    }
}
