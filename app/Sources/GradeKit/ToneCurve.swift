import Foundation

/// The tone curve, read from the engine's own generator.
///
/// THIS IS THE DECISION THAT KEEPS THE CURVE IN ONE PLACE. The obvious way to draw a curve beside
/// a set of sliders is to port the maths into the app, and that port would be the third
/// implementation — the one the parity harness cannot see, because it knows how to slice the
/// formula out of exactly two files. Subprocessing `make-tone-lut.py --stdout` instead costs about
/// a tenth of a second and cannot drift: the curve the interface draws is the curve the render
/// applies, because it is the same bytes.
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
    /// solve moves 2.02 by enough to be obvious in the shadows. Subprocessed rather than ported,
    /// for the reason the curve itself is subprocessed — one home, no drift.
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
