import Foundation

/// A comma-separated list of numbers as look.json spells the halation tint, or nil when any part
/// is not a number. Whitespace around a part is tolerated because Python's `float` tolerates it.
///
/// EMPTY PARTS ARE KEPT, and so refused. Swift's default split drops them, which read "1," as the
/// single value 1 — a list lib.sh's `require_numbers` rejects.
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
        public var contrast: Double
        public var saturation: Double

        public init(
            exposure: Double = 0, temp: Double = 0, tint: Double = 0,
            contrast: Double = 1, saturation: Double = 1
        ) {
            self.exposure = exposure
            self.temp = temp
            self.tint = tint
            self.contrast = contrast
            self.saturation = saturation
        }

        /// The arguments the engine's generator takes, spelled once so the interface and the
        /// render cannot disagree about which knob is which.
        public func generatorArguments(size: Int) -> [String] {
            [
                "--stdout", "--exposure", String(exposure), "--temp", String(temp),
                "--tint", String(tint), "--contrast", String(contrast),
                "--saturation", String(saturation), "--size", String(size),
            ]
        }

        /// True when this correction does nothing: the render leaves a neutral correction out,
        /// and so does the live chain.
        public var isNeutral: Bool {
            exposure == 0 && temp == 0 && tint == 0 && contrast == 1 && saturation == 1
        }
    }

    /// The glow bright things spill into their surroundings, computed in linear light before
    /// Apple's conversion. `scripts/make-halation-luts.py` carries what each number means and
    /// `docs/adr/0012` why it sits where it does. A strength of zero leaves the stage out.
    public struct Halation: Equatable {
        public var strength: Double
        public var threshold: Double
        public var radius: Double
        /// "r,g,b", the engine's wire format.
        public var tint: String

        // Public only because a public initialiser's default argument has to be.
        public static let defaultTint = "1,0.3,0.05"

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
        /// EXACTLY THREE: grade.sh splits the tint into three fields and refuses anything else, so
        /// accepting "1" here would preview a glow the render declines to produce.
        public var tintValues: (Double, Double, Double)? {
            guard let v = numbers(in: tint), v.count == 3 else { return nil }
            return (v[0], v[1], v[2])
        }
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
    public var grainStrength: Double
    public var stabilisationSmoothing: Double
    /// The centre-weighted log-average, in stops from 0.18, each clip is metered to.
    public var matchReferenceStops: Double
    public var finish: Finish
    /// Everything this type does not model, kept verbatim so a written file is complete.
    public var preserved: [String: Any]

    public static func == (a: Look, b: Look) -> Bool {
        a.convertCube == b.convertCube && a.correct == b.correct && a.halation == b.halation
            && a.grainStrength == b.grainStrength
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
            contrast: try number(correctBlock, "contrast", "correct.contrast"),
            saturation: try number(correctBlock, "saturation", "correct.saturation"))
        let halationBlock = try block("halation")
        halation = Halation(
            strength: try number(halationBlock, "strength", "halation.strength"),
            threshold: try number(halationBlock, "threshold", "halation.threshold"),
            radius: try number(halationBlock, "radius", "halation.radius"),
            tint: try text(halationBlock, "tint", "halation.tint"))
        convertCube = try text(try block("convert"), "cube", "convert.cube")
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

        // "hue", "tone" and "colour" are the retired stages an older look file still carries.
        // Dropped rather than preserved, so a file this writes holds only what the engine reads.
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
            "contrast": correct.contrast, "saturation": correct.saturation,
        ]
        root["halation"] = [
            "strength": halation.strength, "threshold": halation.threshold,
            "radius": halation.radius, "tint": halation.tint,
        ]
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
    /// ALL FIVE ARE THE CORRECTION, which runs in log before the preset's cube
    /// (make-correct-lut.py's header says why).
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
    /// Only what a person switches. Halation belongs to a preset, not to the panel, so it has no
    /// bypass. The stabiliser is not here either: it is
    /// switched per clip (`Project.ClipSettings.stabilise`).
    public enum Stage: String, CaseIterable {
        case adjust = "Adjust"
        case denoise = "Denoise"
        case grain = "Grain"
    }

    /// This look with the given stages written as the values the engine leaves out, so a bypass
    /// is a look like any other and the live tier, the exact frame and the export all agree.
    ///
    /// ADJUST RESETS TO NEUTRAL, NOT TO THE PRESET. Every preset keeps the correction neutral (its
    /// character is the conversion cube), so the panel's sliders are the only thing that moves it,
    /// and switching Adjust off is the preset as shipped.
    public func bypassing(_ stages: Set<Stage>) -> Look {
        var out = self
        for stage in stages {
            switch stage {
            case .adjust:
                out.correct = Correct()
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
