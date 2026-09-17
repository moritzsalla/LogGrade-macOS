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
        public var contrast: Double
        public var saturation: Double

        public init(
            exposure: Double = 0, temp: Double = 0, tint: Double = 0,
            slope: String = "1,1,1", offset: String = "0,0,0", power: String = "1,1,1",
            lumMix: Double = 1, contrast: Double = 1, saturation: Double = 1
        ) {
            self.exposure = exposure
            self.temp = temp
            self.tint = tint
            self.slope = slope
            self.offset = offset
            self.power = power
            self.lumMix = lumMix
            self.contrast = contrast
            self.saturation = saturation
        }

        /// The three ASC CDL controls, which is what a colourist's wheels are. The names on the
        /// left are the wire format's; the names on the right are what the interface shows,
        /// because nobody reaches for "slope".
        public enum Wheel: String, CaseIterable {
            case offset  // lift
            case power  // gamma
            case slope  // gain

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
        /// move for a look nobody changed.
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

        static func replacing(
            _ triple: (Double, Double, Double), _ channel: Int,
            with value: Double
        ) -> (Double, Double, Double) {
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
            let current =
                Self.parse(text(for: wheel)) ?? (wheel.neutral, wheel.neutral, wheel.neutral)
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
            [
                "--stdout", "--exposure", String(exposure), "--temp", String(temp),
                "--tint", String(tint), "--slope", slope, "--offset", offset, "--power", power,
                "--lum-mix", String(lumMix), "--contrast", String(contrast),
                "--saturation", String(saturation), "--size", String(size),
            ]
        }

        /// True when this correction does nothing. The engine decides this for itself — the
        /// generator owns the rule — but the interface needs to know whether to show the stage as
        /// active, and a neutral correction is one the render leaves out.
        public var isNeutral: Bool {
            guard exposure == 0, temp == 0, tint == 0, contrast == 1, saturation == 1 else {
                return false
            }
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

        public init(
            strength: Double = 0, threshold: Double = 1, radius: Double = 0.006,
            tint: String = Halation.defaultTint
        ) {
            self.strength = strength
            self.threshold = threshold
            self.radius = radius
            self.tint = tint
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

    /// The delivery finish. `denoise` is a strength (0 leaves the stage out), `sharpen` the
    /// sharpener's amount, and `gauge` either "none" or a film format's texture ("super8").
    /// `scripts/lib.sh` carries what each does; like grain, none of them is in a still.
    public struct Finish: Equatable {
        public var denoise: Double
        public var sharpen: Double
        public var gauge: String

        public init(denoise: Double = 0, sharpen: Double = 0.6, gauge: String = "none") {
            self.denoise = denoise
            self.sharpen = sharpen
            self.gauge = gauge
        }
    }

    /// The hue curves: per-colour hue, saturation and lightness, twelve knots each at every 30
    /// degrees of Oklab hue. `scripts/make-hue-lut.py` carries what they do and why. Kept as the
    /// engine's comma-separated text, for the reason `Correct` keeps its wheels as text.
    public struct Hue: Equatable {
        public enum Curve: String, CaseIterable {
            case rot, sat, lum

            /// The generator's bound on a knot, which the interface's range follows.
            public var limit: Double {
                switch self {
                case .rot: return 60
                case .sat: return 1
                case .lum: return 0.5
                }
            }
        }

        public var rot: String
        public var sat: String
        public var lum: String

        public static let flat = Array(repeating: "0", count: HueCube.knots).joined(separator: ",")

        public init(rot: String = flat, sat: String = flat, lum: String = flat) {
            self.rot = rot
            self.sat = sat
            self.lum = lum
        }

        private func text(_ curve: Curve) -> String {
            switch curve {
            case .rot: return rot
            case .sat: return sat
            case .lum: return lum
            }
        }

        /// The twelve knots, or nil where the generator would refuse the text: a wrong count, a
        /// non-number, or a knot past its bound.
        public func values(_ curve: Curve) -> [Double]? {
            guard let v = numbers(in: text(curve)), v.count == HueCube.knots,
                v.allSatisfy({ $0.isFinite && abs($0) <= curve.limit })
            else { return nil }
            return v
        }

        public func value(_ curve: Curve, _ knot: Int) -> Double {
            values(curve)?[knot] ?? 0
        }

        public mutating func setValue(_ curve: Curve, _ knot: Int, _ value: Double) {
            var v = values(curve) ?? Array(repeating: 0, count: HueCube.knots)
            v[knot] = min(curve.limit, max(-curve.limit, value))
            let written = v.map { String(format: "%g", $0) }.joined(separator: ",")
            switch curve {
            case .rot: rot = written
            case .sat: sat = written
            case .lum: lum = written
            }
        }

        /// Parsed, as the generator decides it: "0.0,..." is as neutral as "0,...".
        public var isNeutral: Bool {
            Curve.allCases.allSatisfy { values($0)?.allSatisfy { $0 == 0 } ?? false }
        }

        public func generatorArguments(size: Int) -> [String] {
            ["--stdout", "--rot", rot, "--sat", sat, "--lum", lum, "--size", String(size)]
        }
    }

    /// The app's own rendering of Apple Log, and the shipped default (`luts/rendering/neutral.cube`,
    /// `scripts/make-rendering-lut.py`). Apple's own cube was an option until it was dropped: it
    /// spent the highlight latitude before any grade saw it, and could not be redistributed.
    public static let neutralConversion = "neutral"
    /// What an older project's looks are given for `match.reference_stops`.
    static let defaultReferenceStops = -0.4

    /// The conversion out of Apple Log: a cube's stem in `luts/rendering/` or `luts/film/`. It
    /// renders the log picture in one scene-referred step, and the engine meters each clip's
    /// exposure and white balance in linear before it (`scripts/solve-exposure.py`).
    public var convertCube: String
    public var correct: Correct
    public var halation: Halation
    public var hue: Hue
    public var tone: Tone
    public var colour: Colour
    public var grainStrength: Double
    public var stabilisationSmoothing: Double
    /// The centre-weighted log-average, in stops from 0.18, each clip is metered to.
    public var matchReferenceStops: Double
    public var finish: Finish
    /// Everything this type does not model, kept verbatim so a written file is complete.
    public var preserved: [String: Any]

    public static func == (a: Look, b: Look) -> Bool {
        a.convertCube == b.convertCube && a.correct == b.correct && a.halation == b.halation
            && a.hue == b.hue && a.tone == b.tone
            && a.colour == b.colour && a.grainStrength == b.grainStrength
            && a.stabilisationSmoothing == b.stabilisationSmoothing
            && a.matchReferenceStops == b.matchReferenceStops && a.finish == b.finish
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
            lumMix: try number(correctBlock, "lum_mix", "correct.lum_mix"),
            contrast: try number(correctBlock, "contrast", "correct.contrast"),
            saturation: try number(correctBlock, "saturation", "correct.saturation"))
        let halationBlock = try block("halation")
        halation = Halation(
            strength: try number(halationBlock, "strength", "halation.strength"),
            threshold: try number(halationBlock, "threshold", "halation.threshold"),
            radius: try number(halationBlock, "radius", "halation.radius"),
            tint: try text(halationBlock, "tint", "halation.tint"))
        convertCube = try text(try block("convert"), "cube", "convert.cube")
        let hueBlock = try block("hue")
        hue = Hue(
            rot: try text(hueBlock, "rot", "hue.rot"), sat: try text(hueBlock, "sat", "hue.sat"),
            lum: try text(hueBlock, "lum", "hue.lum"))
        let toneBlock = try block("tone")
        tone = Tone(
            gamma: try number(toneBlock, "gamma", "tone.gamma"),
            pivot: try number(toneBlock, "pivot", "tone.pivot"),
            contrast: try number(toneBlock, "contrast", "tone.contrast"),
            toe: try number(toneBlock, "toe", "tone.toe"),
            shoulder: try number(toneBlock, "shoulder", "tone.shoulder"),
            black: try number(toneBlock, "black", "tone.black"))
        let colourBlock = try block("colour")
        colour = Colour(
            saturation: try number(colourBlock, "saturation", "colour.saturation"),
            warmth: try number(colourBlock, "warmth", "colour.warmth"))
        let grainBlock = try block("grain")
        grainStrength = try number(grainBlock, "strength", "grain.strength")
        stabilisationSmoothing = try number(
            try block("stabilisation"), "smoothing",
            "stabilisation.smoothing")
        matchReferenceStops = try number(
            try block("match"), "reference_stops", "match.reference_stops")
        let finishBlock = try block("finish")
        finish = Finish(
            denoise: try number(finishBlock, "denoise", "finish.denoise"),
            sharpen: try number(finishBlock, "sharpen", "finish.sharpen"),
            gauge: try text(finishBlock, "gauge", "finish.gauge"))

        var extra = root
        for known in [
            "convert", "correct", "halation", "hue", "tone", "colour", "grain", "stabilisation",
            "match", "finish",
        ] {
            extra.removeValue(forKey: known)
        }
        preserved = extra
    }

    public func serialised() throws -> Data {
        var root: [String: Any] = preserved
        root["convert"] = ["cube": convertCube]
        root["correct"] = [
            "exposure": correct.exposure, "temp": correct.temp, "tint": correct.tint,
            "slope": correct.slope, "offset": correct.offset, "power": correct.power,
            "lum_mix": correct.lumMix, "contrast": correct.contrast,
            "saturation": correct.saturation,
        ]
        root["halation"] = [
            "strength": halation.strength, "threshold": halation.threshold,
            "radius": halation.radius, "tint": halation.tint,
        ]
        root["hue"] = ["rot": hue.rot, "sat": hue.sat, "lum": hue.lum]
        root["tone"] = [
            "gamma": tone.gamma, "pivot": tone.pivot, "contrast": tone.contrast,
            "toe": tone.toe, "shoulder": tone.shoulder, "black": tone.black,
        ]
        root["colour"] = ["saturation": colour.saturation, "warmth": colour.warmth]
        root["grain"] = [
            "strength": grainStrength
        ]
        root["stabilisation"] = ["smoothing": stabilisationSmoothing]
        root["match"] = ["reference_stops": matchReferenceStops]
        root["finish"] = [
            "denoise": finish.denoise, "sharpen": finish.sharpen, "gauge": finish.gauge,
        ]
        return try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys])
    }

    /// What a person moves on one clip, on top of the batch's look: the Adjust section.
    ///
    /// ONLY THE MOVES, NOT A WHOLE LOOK. A per-clip copy of the look pinned that clip to whatever
    /// preset was active when it was adjusted, so switching the batch's look silently skipped it.
    /// Exposure, warmth and tint add to the correction; contrast and saturation scale, so either
    /// leaves a preset's own value (neutral in every shipped preset) where it was.
    ///
    /// ALL FIVE ARE THE CORRECTION, which runs in log before the preset's cube. Contrast and
    /// saturation once scaled the tone curve and colour trims after it, where a contrast push
    /// fought the cube's shoulder instead of feeding it (make-correct-lut.py's header).
    public struct Adjust: Equatable {
        public var exposure: Double
        public var warmth: Double
        public var tint: Double
        public var contrast: Double
        public var saturation: Double
        /// Per-clip exposure metering, which makes a shoot land together. Per clip because a
        /// deliberately dark scene needs a way out of it while the rest of the shoot keeps it.
        public var match: Bool

        public init(
            exposure: Double = 0, warmth: Double = 0, tint: Double = 0,
            contrast: Double = 1, saturation: Double = 1, match: Bool = true
        ) {
            self.exposure = exposure
            self.warmth = warmth
            self.tint = tint
            self.contrast = contrast
            self.saturation = saturation
            self.match = match
        }

        public func applied(to look: Look) -> Look {
            var out = look
            out.correct.exposure += exposure
            out.correct.temp += warmth
            out.correct.tint += tint
            out.correct.contrast *= contrast
            out.correct.saturation *= saturation
            return out
        }
    }

    /// A stage of the chain that can be switched off. The raw value is the inspector's title,
    /// which is also the key its open state is remembered under.
    ///
    /// Only what a person switches. Halation, hue curves and the tone internals belong to a
    /// preset, not to the panel, so they have no bypass. The stabiliser is not here either: it is
    /// switched per clip (`Project.ClipSettings.stabilise`).
    public enum Stage: String, CaseIterable {
        case adjust = "Adjust"
        case denoise = "Denoise"
        case grain = "Grain"
    }

    /// This look with the given stages written as the values the engine leaves out, so a bypass
    /// is a look like any other and the live tier, the exact frame and the export all agree.
    ///
    /// ADJUST RESETS TO NEUTRAL, NOT TO THE PRESET. Every preset keeps correct, tone and colour
    /// neutral (its character is the conversion cube), so the panel's sliders are the only thing
    /// that moves them, and switching Adjust off is the preset as shipped.
    public func bypassing(_ stages: Set<Stage>) -> Look {
        var out = self
        for stage in stages {
            switch stage {
            case .adjust:
                out.correct = Correct()
                out.tone = Tone(
                    gamma: 1, pivot: tone.pivot, contrast: 1, toe: 0, shoulder: 0,
                    black: 0)
                out.colour = Colour(saturation: 1, warmth: 0)
            case .denoise: out.finish.denoise = 0
            case .grain: out.grainStrength = 0
            }
        }
        return out
    }

    /// Writes a complete look.json somewhere the engine can be pointed at with LOOK_FILE, so a
    /// render never edits the checkout's own file.
    public func write(to url: URL) throws {
        try serialised().write(to: url, options: .atomic)
    }
}
