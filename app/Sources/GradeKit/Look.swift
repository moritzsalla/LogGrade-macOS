import Foundation

/// A comma-separated list of numbers as look.json spells a CDL wheel or a tint, or nil when any
/// part is not a number. Whitespace around a part is tolerated because Python's `float` tolerates
/// it, and the generators are what decide what a file means.
///
/// EMPTY PARTS ARE KEPT, and so refused. Swift's default split drops them, which read "1," as the
/// single value 1 — a CDL the generator and lib.sh's `require_numbers` both reject.
func numbers(in text: String) -> [Double]? {
    var values: [Double] = []
    for part in text.split(separator: ",", omittingEmptySubsequences: false) {
        guard let v = Double(part.trimmingCharacters(in: .whitespaces)) else { return nil }
        values.append(v)
    }
    return values.isEmpty ? nil : values
}

/// `look.json`, which is the engine's wire format and stays that way.
///
/// NO FALLBACKS, INHERITED. The engine's `look()` stops the run on a missing key rather than
/// substituting a default, deliberately: a silent substitution is a different look rendered under
/// the same name. That makes the key set a contract, so this type carries every key it does not
/// model in `preserved` and writes them back — the arrangement the retired Bench used, for the same
/// reason. A file this writes must be complete or the engine aborts on its first read.
public struct Look: Equatable {
    public struct Correct: Equatable {
        public var exposure: Double
        public var temp: Double
        public var tint: Double
        public var slope: String
        public var offset: String
        public var power: String
        public var lumMix: Double

        public init(exposure: Double = 0, temp: Double = 0, tint: Double = 0,
                    slope: String = "1,1,1", offset: String = "0,0,0", power: String = "1,1,1",
                    lumMix: Double = 1) {
            self.exposure = exposure; self.temp = temp; self.tint = tint
            self.slope = slope; self.offset = offset; self.power = power; self.lumMix = lumMix
        }

        /// The three ASC CDL controls, which is what a colourist's wheels are. The names on the
        /// left are the wire format's; the names on the right are what the interface shows,
        /// because nobody reaches for "slope".
        public enum Wheel: String, CaseIterable {
            case offset   // lift
            case power    // gamma
            case slope    // gain

            /// The value that does nothing. Lift adds, so its neutral is zero; the other two
            /// multiply or exponentiate, so theirs is one.
            public var neutral: Double { self == .offset ? 0 : 1 }
        }

        /// THE WIRE FORMAT IS A STRING, AND THE ROUND TRIP HAS TO BE EXACT.
        ///
        /// These are stored as "1,1,1" because that is what the engine's generator takes, and the
        /// generator decides whether a correction is neutral by PARSING them. An interface that
        /// joins three doubles the obvious way writes "1.0,1.0,1.0" — which is the same correction
        /// and a different string. Drag a wheel and return it to centre and the correction would
        /// stop counting as neutral, the cube would go into the graph, and a default render would
        /// stop being byte-identical to the precursor's for a look nobody changed.
        ///
        /// So the formatter is %g, which is the generator's own, and neutrality is decided by
        /// parsing rather than by comparing text.
        ///
        /// ONE VALUE MEANS THREE, because the correction generator accepts that and a hand-edited
        /// look.json may use it. `CorrectionCube` reads the wheels through this too, so the
        /// preview and the neutrality check cannot disagree about what a wheel says.
        static func parse(_ text: String) -> (Double, Double, Double)? {
            guard let v = numbers(in: text) else { return nil }
            if v.count == 1 { return (v[0], v[0], v[0]) }
            return v.count == 3 ? (v[0], v[1], v[2]) : nil
        }

        static func format(_ v: (Double, Double, Double)) -> String {
            [v.0, v.1, v.2].map { String(format: "%g", $0) }.joined(separator: ",")
        }

        private func text(for wheel: Wheel) -> String {
            switch wheel {
            case .slope: return slope
            case .offset: return offset
            case .power: return power
            }
        }

        /// One channel of a triple. Channel is 0, 1, 2 for red, green, blue; anything past green
        /// reads blue, as it always has.
        static func component(_ triple: (Double, Double, Double), _ channel: Int) -> Double {
            switch channel {
            case 0: return triple.0
            case 1: return triple.1
            default: return triple.2
            }
        }

        static func replacing(_ triple: (Double, Double, Double), _ channel: Int,
                              with value: Double) -> (Double, Double, Double) {
            var changed = triple
            switch channel {
            case 0: changed.0 = value
            case 1: changed.1 = value
            default: changed.2 = value
            }
            return changed
        }

        /// One channel of one wheel. Channel is 0, 1, 2 for red, green, blue.
        public func value(_ wheel: Wheel, _ channel: Int) -> Double {
            guard let t = Self.parse(text(for: wheel)) else { return wheel.neutral }
            return Self.component(t, channel)
        }

        public mutating func setValue(_ wheel: Wheel, _ channel: Int, _ value: Double) {
            let current = Self.parse(text(for: wheel)) ?? (wheel.neutral, wheel.neutral, wheel.neutral)
            let written = Self.format(Self.replacing(current, channel, with: value))
            switch wheel {
            case .slope: slope = written
            case .offset: offset = written
            case .power: power = written
            }
        }

        /// The arguments the engine's generator takes, spelled once so the interface and the
        /// render cannot disagree about which knob is which.
        public func generatorArguments(size: Int) -> [String] {
            ["--stdout", "--exposure", String(exposure), "--temp", String(temp),
             "--tint", String(tint), "--slope", slope, "--offset", offset, "--power", power,
             "--lum-mix", String(lumMix), "--size", String(size)]
        }

        /// True when this correction does nothing. The engine decides this for itself — the
        /// generator owns the rule — but the interface needs to know whether to show the stage as
        /// active, and a neutral correction is what keeps a render identical to the precursor's.
        public var isNeutral: Bool {
            guard exposure == 0, temp == 0, tint == 0 else { return false }
            // PARSED, not compared as text — the generator decides this by parsing too, and
            // "1.0,1.0,1.0" is the same correction as "1,1,1". Comparing strings here made a
            // wheel returned to centre read as an active correction.
            for wheel in Wheel.allCases {
                guard let t = Self.parse(text(for: wheel)) else { return false }
                let n = wheel.neutral
                if t.0 != n || t.1 != n || t.2 != n { return false }
            }
            return true
        }
    }

    /// The glow bright things spill into their surroundings, computed in linear light before
    /// Apple's conversion. `scripts/make-halation-luts.py` carries what each number means and
    /// `docs/adr/0012` why it sits where it does. A strength of zero leaves the stage out.
    public struct Halation: Equatable {
        public var strength: Double
        public var threshold: Double
        public var radius: Double
        /// "r,g,b", the engine's wire format, for the reason `Correct` keeps its wheels as text.
        public var tint: String

        /// The engine's default tint, and what a malformed one is rebuilt from when a channel is set.
        static let defaultTintValues = (1.0, 0.3, 0.05)
        // Public only because a public initialiser's default argument has to be.
        public static let defaultTint = Correct.format(defaultTintValues)

        public init(strength: Double = 0, threshold: Double = 1, radius: Double = 0.006,
                    tint: String = Halation.defaultTint) {
            self.strength = strength; self.threshold = threshold
            self.radius = radius; self.tint = tint
        }

        public var isNeutral: Bool { strength == 0 }

        /// The tint as numbers, or nil when the text is not three of them — which the engine
        /// refuses, so the live picture refuses it too.
        ///
        /// EXACTLY THREE, unlike a CDL wheel. grade.sh splits the tint into three fields and
        /// refuses anything else, so accepting "1" here would preview a glow the render declines to
        /// produce. How many numbers is each consumer's rule; only the splitting is shared.
        public var tintValues: (Double, Double, Double)? {
            guard let v = numbers(in: tint), v.count == 3 else { return nil }
            return (v[0], v[1], v[2])
        }

        public func tint(_ channel: Int) -> Double {
            guard let t = tintValues else { return 0 }
            return Correct.component(t, channel)
        }

        public mutating func setTint(_ channel: Int, _ value: Double) {
            let current = tintValues ?? Self.defaultTintValues
            tint = Correct.format(Correct.replacing(current, channel, with: value))
        }
    }

    public struct Tone: Equatable {
        public var gamma: Double
        public var pivot: Double
        public var contrast: Double
        public var toe: Double
        public var shoulder: Double
        public var black: Double
    }

    public struct Colour: Equatable {
        public var saturation: Double
        public var warmth: Double
    }

    public var correct: Correct
    public var halation: Halation
    /// The film-emulation cube's stem in `luts/looks/`, or "none".
    public var lookLUT: String
    /// How far the look's cube moves the picture, 0 to 1. At 1 there is no blend in the render.
    public var lookStrength: Double
    /// The print-film cube's stem in `luts/print/`, or "none". It follows the look.
    public var printLUT: String
    public var printStrength: Double
    public var tone: Tone
    public var colour: Colour
    public var grainStrength: Double
    /// The grain's weight at black and at white, 1 at the midtones. Both at 1 is flat grain, and
    /// leaves the weighting out of the render. `grain.shadows` and `grain.highlights` in the file.
    public var grainShadows: Double
    public var grainHighlights: Double
    public var stabilisationSmoothing: Double
    public var matchReferenceYAVG: Double
    /// Everything this type does not model, kept verbatim so a written file is complete.
    public var preserved: [String: Any]

    public static func == (a: Look, b: Look) -> Bool {
        a.correct == b.correct && a.halation == b.halation && a.lookLUT == b.lookLUT
            && a.lookStrength == b.lookStrength && a.printLUT == b.printLUT
            && a.printStrength == b.printStrength && a.tone == b.tone
            && a.colour == b.colour && a.grainStrength == b.grainStrength
            && a.grainShadows == b.grainShadows && a.grainHighlights == b.grainHighlights
            && a.stabilisationSmoothing == b.stabilisationSmoothing
            && a.matchReferenceYAVG == b.matchReferenceYAVG
    }

    public enum Invalid: Error, CustomStringConvertible {
        case notAnObject
        case missing(String)

        public var description: String {
            switch self {
            case .notAnObject: return "look.json is not a JSON object"
            case .missing(let key): return "look.json: missing \(key)"
            }
        }
    }

    public init(data: Data) throws {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Invalid.notAnObject
        }
        func block(_ name: String) throws -> [String: Any] {
            guard let b = root[name] as? [String: Any] else { throw Invalid.missing(name) }
            return b
        }
        func number(_ b: [String: Any], _ name: String, _ path: String) throws -> Double {
            guard let n = b[name] as? NSNumber else { throw Invalid.missing(path) }
            return n.doubleValue
        }
        func text(_ b: [String: Any], _ name: String, _ path: String) throws -> String {
            guard let s = b[name] as? String else { throw Invalid.missing(path) }
            return s
        }

        let correctBlock = try block("correct")
        correct = Correct(
            exposure: try number(correctBlock, "exposure", "correct.exposure"),
            temp: try number(correctBlock, "temp", "correct.temp"),
            tint: try number(correctBlock, "tint", "correct.tint"),
            slope: try text(correctBlock, "slope", "correct.slope"),
            offset: try text(correctBlock, "offset", "correct.offset"),
            power: try text(correctBlock, "power", "correct.power"),
            lumMix: try number(correctBlock, "lum_mix", "correct.lum_mix"))
        let halationBlock = try block("halation")
        halation = Halation(strength: try number(halationBlock, "strength", "halation.strength"),
                            threshold: try number(halationBlock, "threshold", "halation.threshold"),
                            radius: try number(halationBlock, "radius", "halation.radius"),
                            tint: try text(halationBlock, "tint", "halation.tint"))
        let lookBlock = try block("look")
        lookLUT = try text(lookBlock, "lut", "look.lut")
        lookStrength = try number(lookBlock, "strength", "look.strength")
        let printBlock = try block("print")
        printLUT = try text(printBlock, "lut", "print.lut")
        printStrength = try number(printBlock, "strength", "print.strength")
        let toneBlock = try block("tone")
        tone = Tone(gamma: try number(toneBlock, "gamma", "tone.gamma"),
                    pivot: try number(toneBlock, "pivot", "tone.pivot"),
                    contrast: try number(toneBlock, "contrast", "tone.contrast"),
                    toe: try number(toneBlock, "toe", "tone.toe"),
                    shoulder: try number(toneBlock, "shoulder", "tone.shoulder"),
                    black: try number(toneBlock, "black", "tone.black"))
        let colourBlock = try block("colour")
        colour = Colour(saturation: try number(colourBlock, "saturation", "colour.saturation"),
                        warmth: try number(colourBlock, "warmth", "colour.warmth"))
        let grainBlock = try block("grain")
        grainStrength = try number(grainBlock, "strength", "grain.strength")
        grainShadows = try number(grainBlock, "shadows", "grain.shadows")
        grainHighlights = try number(grainBlock, "highlights", "grain.highlights")
        stabilisationSmoothing = try number(try block("stabilisation"), "smoothing",
                                            "stabilisation.smoothing")
        matchReferenceYAVG = try number(try block("match"), "reference_yavg",
                                        "match.reference_yavg")

        var extra = root
        for known in ["correct", "halation", "look", "print", "tone", "colour", "grain", "stabilisation", "match"] {
            extra.removeValue(forKey: known)
        }
        preserved = extra
    }

    public func serialised() throws -> Data {
        var root: [String: Any] = preserved
        root["correct"] = [
            "exposure": correct.exposure, "temp": correct.temp, "tint": correct.tint,
            "slope": correct.slope, "offset": correct.offset, "power": correct.power,
            "lum_mix": correct.lumMix,
        ]
        root["halation"] = [
            "strength": halation.strength, "threshold": halation.threshold,
            "radius": halation.radius, "tint": halation.tint,
        ]
        root["look"] = ["lut": lookLUT, "strength": lookStrength]
        root["print"] = ["lut": printLUT, "strength": printStrength]
        root["tone"] = [
            "gamma": tone.gamma, "pivot": tone.pivot, "contrast": tone.contrast,
            "toe": tone.toe, "shoulder": tone.shoulder, "black": tone.black,
        ]
        root["colour"] = ["saturation": colour.saturation, "warmth": colour.warmth]
        root["grain"] = ["strength": grainStrength, "shadows": grainShadows,
                         "highlights": grainHighlights]
        root["stabilisation"] = ["smoothing": stabilisationSmoothing]
        root["match"] = ["reference_yavg": matchReferenceYAVG]
        return try JSONSerialization.data(withJSONObject: root,
                                          options: [.prettyPrinted, .sortedKeys])
    }

    /// Writes a complete look.json somewhere the engine can be pointed at with LOOK_FILE, so a
    /// render never edits the checkout's own file.
    public func write(to url: URL) throws {
        try serialised().write(to: url, options: .atomic)
    }
}
