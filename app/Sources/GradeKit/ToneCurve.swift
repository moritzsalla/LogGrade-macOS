import Foundation

/// The tone curve, as the engine's generator defines it.
///
/// PORTED, AND HELD TO THE ORIGINAL. The app draws and previews with `generated(tone:)` and
/// `generated(tone:)`, a transcription of `make-tone-lut.py`. The function that subprocesses the
/// script instead — `generate(using:tone:)` — is not called by the app at
/// all: they are the oracles `ToneCurvePortTests` compares the transcriptions against, value for
/// value, so the curve the interface draws cannot drift from the curve the render applies without
/// a test naming which one moved. Subprocessing on every control change was the first design, and
/// at about a tenth of a second a call it left the tone controls a frame or two behind the pointer.
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

    /// Runs the engine's generator and parses what it writes: the oracle `generated(tone:)` is held
    /// to. Arguments are the same names the engine passes, so there is one spelling of each
    /// parameter across the two languages.
    public static func generate(using generator: URL, tone: Look.Tone) throws -> ToneCurve {
        let process = Process()
        process.executableURL = generator
        process.arguments = [
            "--stdout",
            "--gamma", String(tone.gamma),
            "--pivot", String(tone.pivot),
            "--contrast", String(tone.contrast),
            "--toe", String(tone.toe),
            "--shoulder", String(tone.shoulder),
            "--black", String(tone.black),
        ]
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do { try process.run() } catch {
            throw Failure.generatorFailed(String(describing: error))
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errorText = String(
            decoding: err.fileHandleForReading.readDataToEndOfFile(),
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
