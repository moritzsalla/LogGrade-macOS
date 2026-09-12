import Foundation

/// `look.json`, which is the engine's wire format and stays that way.
///
/// NO FALLBACKS, INHERITED. The engine's `look()` stops the run on a missing key rather than
/// substituting a default, deliberately: a silent substitution is a different look rendered under
/// the same name. That makes the key set a contract, so this type carries every key it does not
/// model in `preserved` and writes them back — the same arrangement the Bench uses, and for the
/// same reason. A file this writes must be complete or the engine aborts on its first read.
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
            exposure == 0 && temp == 0 && tint == 0
                && slope == "1,1,1" && offset == "0,0,0" && power == "1,1,1"
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
    /// The film-emulation cube's stem in `luts/looks/`, or "none".
    public var lookLUT: String
    public var tone: Tone
    public var colour: Colour
    public var grainStrength: Double
    public var stabilisationSmoothing: Double
    public var matchReferenceYAVG: Double
    /// Everything this type does not model, kept verbatim so a written file is complete.
    public var preserved: [String: Any]

    public static func == (a: Look, b: Look) -> Bool {
        a.correct == b.correct && a.lookLUT == b.lookLUT && a.tone == b.tone
            && a.colour == b.colour && a.grainStrength == b.grainStrength
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

        let c = try block("correct")
        correct = Correct(
            exposure: try number(c, "exposure", "correct.exposure"),
            temp: try number(c, "temp", "correct.temp"),
            tint: try number(c, "tint", "correct.tint"),
            slope: try text(c, "slope", "correct.slope"),
            offset: try text(c, "offset", "correct.offset"),
            power: try text(c, "power", "correct.power"),
            lumMix: try number(c, "lum_mix", "correct.lum_mix"))
        lookLUT = try text(try block("look"), "lut", "look.lut")
        let t = try block("tone")
        tone = Tone(gamma: try number(t, "gamma", "tone.gamma"),
                    pivot: try number(t, "pivot", "tone.pivot"),
                    contrast: try number(t, "contrast", "tone.contrast"),
                    toe: try number(t, "toe", "tone.toe"),
                    shoulder: try number(t, "shoulder", "tone.shoulder"),
                    black: try number(t, "black", "tone.black"))
        let col = try block("colour")
        colour = Colour(saturation: try number(col, "saturation", "colour.saturation"),
                        warmth: try number(col, "warmth", "colour.warmth"))
        grainStrength = try number(try block("grain"), "strength", "grain.strength")
        stabilisationSmoothing = try number(try block("stabilisation"), "smoothing",
                                            "stabilisation.smoothing")
        matchReferenceYAVG = try number(try block("match"), "reference_yavg",
                                        "match.reference_yavg")

        var extra = root
        for known in ["correct", "look", "tone", "colour", "grain", "stabilisation", "match"] {
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
        root["look"] = ["lut": lookLUT]
        root["tone"] = [
            "gamma": tone.gamma, "pivot": tone.pivot, "contrast": tone.contrast,
            "toe": tone.toe, "shoulder": tone.shoulder, "black": tone.black,
        ]
        root["colour"] = ["saturation": colour.saturation, "warmth": colour.warmth]
        root["grain"] = ["strength": grainStrength]
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
