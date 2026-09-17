import CryptoKit
import Foundation

/// One project per shoot, holding what is per-clip and what is shared.
///
/// WHY A PROJECT FILE RATHER THAN A SIDECAR PER CLIP. Because that is how the grading suites do
/// it: a Resolve or Baselight project holds every clip's grade in one database, with a separate
/// gallery of looks to apply across clips. Sidecars were the alternative and they lose the thing
/// that makes a nineteen-clip shoot workable, which is applying one decision to all of them.
///
/// It lives outside `src/`, which is read-only for the life of the project.
public struct Project: Equatable {
    /// A named grade: a look LUT together with its tone and trims.
    ///
    /// THE PAIR IS THE POINT. The shipped tone curve was tuned with the Portra cube in the chain,
    /// so swapping the cube alone is a different grade rather than the same grade in another film
    /// stock. A preset therefore carries both, and the interface offers presets rather than a cube
    /// menu beside an unrelated set of sliders.
    public struct Preset: Equatable {
        public var name: String
        public var look: Look
        public init(name: String, look: Look) {
            self.name = name
            self.look = look
        }
    }

    /// What is decided per clip, and nowhere else.
    public struct ClipSettings: Equatable {
        /// The offset of the crop window along whichever axis it moves, shared by every selected
        /// deliverable that crops.
        /// Nil means undecided, which is not the same as zero: the engine refuses a cropping render
        /// across several clips without one, because the offset is a composition call and one
        /// clip's framing applied to eighteen others produces files that all look done.
        public var cropOffset: Int?
        /// Where the preview frame is taken from.
        public var previewSeconds: Double
        public var stabilise: Bool
        public var adjust: Look.Adjust

        /// A clip nobody has decided about is not stabilised: the stabiliser crops and softens,
        /// and a locked-off shot gains nothing for it. One constant, because the interface, the
        /// environment and the project reader each fell back to their own value.
        public static let stabilisesByDefault = false

        public init(
            cropOffset: Int? = nil, previewSeconds: Double = 1,
            stabilise: Bool = stabilisesByDefault, adjust: Look.Adjust = Look.Adjust()
        ) {
            self.cropOffset = cropOffset
            self.previewSeconds = previewSeconds
            self.stabilise = stabilise
            self.adjust = adjust
        }
    }

    public struct Delivery: Equatable {
        /// What to render, in render order. Order is preserved because it is the order the engine
        /// works through, and a person watching a queue should see what they asked for first.
        public var targets: [Deliverable]
        /// The output's SHORT edge, as "1080p" means it: 1080 × 1920 portrait, 1920 × 1080
        /// landscape. The engine takes a width, and a width alone made a 16:9 export at "1080
        /// wide" come out 1080 × 608.
        public var shortSide: Int
        /// Nil keeps the source's rate, which is the only lossless answer.
        public var fps: Int?
        public var codec: Codec
        public var quality: Quality
        public var container: Container
        public var audio: Bool
        /// 1080: what Instagram re-encodes to, and the size the grain and the sharpener were tuned
        /// at. The interface warns about anything larger.
        public static let defaultShortSide = 1080
        public static let shortSides = [720, 1080, 1440, 2160]

        /// The engine's `WIDTH`, from the short edge and the first shape's aspect. Even, because
        /// the encoders refuse odd dimensions.
        public var width: Int {
            guard let shape = targets.first, shape.aspectWidth > shape.aspectHeight else {
                return shortSide
            }
            let w = shortSide * shape.aspectWidth / shape.aspectHeight
            return w - w % 2
        }

        /// The engine's `DELIVERY_CODEC` values, spelled as it spells them.
        public enum Codec: String, CaseIterable {
            case h264, hevc, hevc10, prores422, prores422hq

            public var isProRes: Bool { self == .prores422 || self == .prores422hq }

            public var label: String {
                switch self {
                case .h264: return "H.264"
                case .hevc: return "HEVC"
                case .hevc10: return "HEVC 10-bit"
                case .prores422: return "ProRes 422"
                case .prores422hq: return "ProRes 422 HQ"
                }
            }
        }

        /// `DELIVERY_QUALITY`. ProRes takes auto only: its profile is its quality.
        public enum Quality: String, CaseIterable {
            case auto, high, max
        }

        /// `DELIVERY_CONTAINER`. ProRes is refused in mp4 by the engine.
        public enum Container: String, CaseIterable {
            case mp4, mov
        }

        public init(
            targets: [Deliverable] = [.reels], shortSide: Int = defaultShortSide,
            fps: Int? = nil, codec: Codec = .h264, quality: Quality = .auto,
            container: Container = .mp4, audio: Bool = true
        ) {
            self.targets = targets
            self.shortSide = shortSide
            self.fps = fps
            self.codec = codec
            self.quality = quality
            self.container = container
            self.audio = audio
        }

        /// What renders: ProRes forced to mov and auto quality. Derived here rather than written
        /// back when the codec changes, so switching to ProRes and back keeps the mp4 and the
        /// quality someone chose.
        public var normalised: Delivery {
            var out = self
            if codec.isProRes {
                out.container = .mov
                out.quality = .auto
            }
            return out
        }

        /// Whether anything selected crops this clip, and so has a box to draw. Per clip, because
        /// the same shape crops a landscape clip and takes a portrait one whole.
        public func anyTargetCrops(_ source: FrameSize?) -> Bool {
            targets.contains { $0.crops(source) }
        }

        public func croppingTargets(_ source: FrameSize?) -> [Deliverable] {
            targets.filter { $0.crops(source) }
        }

        /// The cropping shapes that take their offset from the clip, for the blocker that names
        /// them. KEPT APART FROM `croppingTargets`: when these were one predicate, excluding a
        /// `centre` shape from the blocker also removed its box from the picture and made the
        /// panel say nothing crops.
        public func clipFramedTargets(_ source: FrameSize?) -> [Deliverable] {
            targets.filter { $0.needsClipOffset(source) }
        }

        public func anyTargetNeedsClipOffset(_ source: FrameSize?) -> Bool {
            targets.contains { $0.needsClipOffset(source) }
        }

        /// The shape the one crop box is drawn in. One the clip frames wins over a `centre` one,
        /// because it is the box that has to be dragged; a `centre` shape alone still gets a box,
        /// fixed, so what it will cut is visible before it is rendered.
        public func cropBoxTarget(_ source: FrameSize?) -> Deliverable? {
            clipFramedTargets(source).first ?? croppingTargets(source).first
        }
    }

    /// The export picker. The two Instagram presets carry no fields: everything is chosen.
    public enum ExportPreset: String, CaseIterable {
        case instagramStory = "instagram_story"
        case instagramPost = "instagram_post"
        case custom

        public var label: String {
            switch self {
            case .instagramStory: return "Instagram Story"
            case .instagramPost: return "Instagram Post"
            case .custom: return "Custom"
            }
        }

        /// Nil for Custom, which is whatever was set.
        public var fixed: Delivery? {
            switch self {
            case .instagramStory: return Delivery(targets: [.reels])
            case .instagramPost: return Delivery(targets: [.feed])
            case .custom: return nil
            }
        }
    }

    public var presets: [Preset]
    public var activePreset: String
    public var exportPreset: ExportPreset
    /// Custom's fields, kept while a preset is picked so switching back finds them as they were.
    public var customDelivery: Delivery

    /// What renders.
    ///
    /// DERIVED, NOT COPIED, and read-only. A preset's settings are never written into
    /// `customDelivery`, and neither is the normalised form: writing it back would turn a Custom
    /// mp4 into mov for good the moment ProRes was tried. Edits go to `customDelivery`.
    public var delivery: Delivery { exportPreset.fixed ?? customDelivery.normalised }
    /// Keyed by clip stem, which is the join key back to the footage and to the camera's own
    /// capture order. Never renamed.
    public var clips: [String: ClipSettings]
    public var outputDirectory: URL?

    public init(
        presets: [Preset], activePreset: String, delivery: Delivery? = nil,
        exportPreset: ExportPreset? = nil,
        clips: [String: ClipSettings] = [:], outputDirectory: URL? = nil
    ) {
        self.presets = presets
        self.activePreset = activePreset
        // A delivery passed in is a Custom one unless a preset is named; with neither, a new
        // project opens on Instagram Story, the no-fields choice.
        self.customDelivery = delivery ?? Delivery(targets: [Deliverable.defaultCustom])
        self.exportPreset = exportPreset ?? (delivery == nil ? .instagramStory : .custom)
        self.clips = clips
        self.outputDirectory = outputDirectory
    }

    public var active: Preset? { presets.first { $0.name == activePreset } }

    /// The folder a Convert writes: named once for the whole queue, so every clip of a run lands
    /// together and no run overwrites another. The engine's `export_dir` names a command-line run the
    /// same way.
    public static func exportFolder(in destination: URL, at date: Date = Date()) -> URL {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "yyyy-MM-dd HH.mm"
        return destination.appendingPathComponent("LogGrade export \(format.string(from: date))")
    }

    /// Where the engine keeps its working files for a destination (`LOGGRADE_CACHE`): under the
    /// user's Caches, not beside the footage, where the user found them. ONE FOLDER PER DESTINATION,
    /// named by a hash of its path, because the stabilisation cache is fresh against a clip NAME
    /// and two shoots' IMG_0609 must not share one.
    public static func cacheFolder(
        for destination: URL,
        caches: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    ) -> URL {
        let digest = SHA256.hash(data: Data(destination.standardizedFileURL.path.utf8))
        let name = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        return caches.appendingPathComponent("LogGrade", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
    }

    /// Replaces the saved presets with the app's own, keeping the active choice where it still
    /// exists and falling back where it does not.
    ///
    /// PRESETS ARE THE APP'S, NOT THE PROJECT'S. A project file still carries full copies, and
    /// reading those back kept looks whose cube had since been deleted (Pro 400H, RZ67 Portra 400):
    /// the preview could not read the conversion and Convert failed in the engine. "shipped" is
    /// what Neutral was called before, so it keeps a project on the same picture.
    public mutating func adopt(presets current: [Preset], fallback: String) {
        let wanted = activePreset == "shipped" ? fallback : activePreset
        presets = current
        activePreset = current.contains { $0.name == wanted } ? wanted : fallback
    }

    /// A clip's decisions, or the undecided defaults for a clip with none recorded.
    public func settings(for clip: String) -> ClipSettings {
        clips[clip] ?? ClipSettings()
    }

    /// The project with every clip's Adjust at neutral: what the panels that never show Adjust
    /// watch, so a slider drag does not rebuild them sixty times a second.
    public var ignoringAdjustments: Project {
        var out = self
        for name in out.clips.keys { out.clips[name]?.adjust = Look.Adjust() }
        return out
    }

    /// What stops a render before it starts. The interface shows these rather than discovering
    /// them from the engine's refusal, which is the same rule the engine follows itself.
    public enum Blocker: Equatable, CustomStringConvertible {
        case noActivePreset(String)

        public var description: String {
            switch self {
            case .noActivePreset(let name):
                return "no preset named \(name)"
            }
        }
    }

    public var blockers: [Blocker] {
        active == nil ? [.noActivePreset(activePreset)] : []
    }

    /// Clips whose crop nobody has placed, and the shapes that crop them.
    ///
    /// A WARNING, NOT A REFUSAL. Refusing Convert until every clip was dragged kept a batch from
    /// rendering framed wrong, and also kept a non-technical user from rendering at all. An
    /// unplaced clip renders centred (`environment`); this names which ones, so a batch of files
    /// that all look finished still says which were never looked at. The deliverables are carried
    /// because the set is open: "the 4:5 crop" stopped being a full description at three shapes.
    public struct Unframed: Equatable, CustomStringConvertible {
        public let deliverables: [Deliverable]
        public let clips: [String]

        public var description: String {
            let shapes = deliverables.map { "\($0.aspectWidth):\($0.aspectHeight)" }
                .joined(separator: " and ")
            let names = clips.sorted().joined(separator: ", ")
            return clips.count == 1
                ? "\(names) is cropped to \(shapes) at the centre. Drag the crop to place it."
                : "\(clips.count) clips are cropped to \(shapes) at the centre, never placed: "
                    + "\(names)"
        }
    }

    /// `sizes` holds each clip's measured frame, by name. A clip missing from it is answered as
    /// `Deliverable.crops` answers an unmeasured one.
    public func unframed(for clipNames: [String], sizes: [String: FrameSize] = [:]) -> Unframed? {
        let undecided = clipNames.filter {
            clips[$0]?.cropOffset == nil && delivery.anyTargetNeedsClipOffset(sizes[$0])
        }
        guard !undecided.isEmpty else { return nil }
        let shapes = delivery.targets.filter { target in
            undecided.contains { target.needsClipOffset(sizes[$0]) }
        }
        return Unframed(deliverables: shapes, clips: undecided)
    }

    /// The engine's environment for one clip, built from the project. Variables only — the app
    /// never builds a filter string.
    public func environment(for clip: String, lookFile: URL) -> [String: String] {
        var env: [String: String] = ["LOOK_FILE": lookFile.path]
        env["WIDTH"] = String(delivery.width)
        if let fps = delivery.fps { env["FPS_OUT"] = String(fps) }
        env["DELIVERY_CODEC"] = delivery.codec.rawValue
        env["DELIVERY_QUALITY"] = delivery.quality.rawValue
        env["DELIVERY_CONTAINER"] = delivery.container.rawValue
        env["DELIVERY_AUDIO"] = delivery.audio ? "1" : "0"
        // The whole set, comma separated, in order. This was `FEED=1`, which could only ever say
        // one thing about one shape.
        env["DELIVERABLES"] = delivery.targets.map(\.spec).joined(separator: ",")
        // "centre", said explicitly, for a clip nobody placed: the engine refuses a crop with no
        // offset, which is right for the command line and why the app says it out loud.
        env["CROP_OFFSET"] = clips[clip]?.cropOffset.map(String.init) ?? "centre"
        env["STAB"] = settings(for: clip).stabilise ? "1" : "0"
        if !settings(for: clip).adjust.match { env["MATCH"] = "0" }
        return env
    }
}

// MARK: - On disk

extension Project.Delivery {
    /// The selected shapes out of a serialised `delivery` block.
    ///
    /// THE `reels`/`feed` BOOLEANS ARE STILL READ. Every project file written before the set was
    /// opened up carries that pair and no `targets` array, and a reader that ignored them would
    /// open such a project silently showing the default rather than what was saved — a delivery
    /// someone chose, replaced by one nobody did. Dropped only when a `targets` array is present,
    /// which is what this build writes.
    static func targets(fromSerialised d: [String: Any]) -> [Deliverable] {
        if let raw = d["targets"] as? [[String: Any]] {
            let parsed: [Deliverable] = raw.compactMap {
                guard let name = $0["name"] as? String,
                    let w = ($0["aspect_width"] as? NSNumber)?.intValue,
                    let h = ($0["aspect_height"] as? NSNumber)?.intValue,
                    w > 0, h > 0
                else { return nil }
                // A file without the key was written before a shape could carry an offset, and
                // every shape then followed the clip's offset, which is what nil still means.
                let offset: DeliverableCropOffset? =
                    ($0["crop_offset"] as? String) == "centre" ? .centre : nil
                return Deliverable(
                    name: name, aspectWidth: w, aspectHeight: h,
                    cropOffset: offset)
            }
            return parsed
        }
        var legacy: [Deliverable] = []
        if (d["reels"] as? NSNumber)?.boolValue ?? true { legacy.append(.reels) }
        if (d["feed"] as? NSNumber)?.boolValue ?? false { legacy.append(.feed) }
        return legacy
    }
}

extension Project {
    /// The first version whose looks carry the film stages. A file with no version reads as 1.
    /// Kept apart from `fileVersion` so a later bump does not re-apply this upgrade to files that
    /// already have the stages.
    static let filmStagesVersion = 2
    /// The first version whose looks carry a conversion, a finish and a film exposure reference.
    static let conversionVersion = 3
    /// The first version whose looks carry hue curves.
    static let hueVersion = 4
    /// The first version whose looks carry no film look or print cube.
    static let noFilmLookVersion = 5
    /// The first version whose corrections carry contrast and saturation.
    static let sceneTrimsVersion = 6
    /// The format this build writes.
    static let fileVersion = sceneTrimsVersion

    public func serialised() throws -> Data {
        var presetList: [[String: Any]] = []
        for preset in presets {
            presetList.append([
                "name": preset.name,
                "look": try JSONSerialization.jsonObject(with: preset.look.serialised()),
            ])
        }
        var clipMap: [String: Any] = [:]
        for (name, s) in clips {
            var entry: [String: Any] = [
                "preview_seconds": s.previewSeconds,
                "stabilise": s.stabilise,
            ]
            if let offset = s.cropOffset { entry["crop_offset"] = offset }
            if s.adjust != Look.Adjust() {
                entry["adjust"] = [
                    "exposure": s.adjust.exposure, "warmth": s.adjust.warmth,
                    "tint": s.adjust.tint, "contrast": s.adjust.contrast,
                    "saturation": s.adjust.saturation, "match": s.adjust.match,
                ]
            }
            clipMap[name] = entry
        }
        // Custom's fields, whichever preset is picked: `export_preset` says which renders.
        let delivery = customDelivery
        var deliveryBlock: [String: Any] = [
            "export_preset": exportPreset.rawValue,
            "codec": delivery.codec.rawValue,
            "quality": delivery.quality.rawValue,
            "container": delivery.container.rawValue,
            "audio": delivery.audio,
            "targets": delivery.targets.map { d in
                var entry: [String: Any] = [
                    "name": d.name, "aspect_width": d.aspectWidth,
                    "aspect_height": d.aspectHeight,
                ]
                if d.cropOffset == .centre { entry["crop_offset"] = "centre" }
                return entry
            },
            "short_side": delivery.shortSide,
        ]
        if let fps = delivery.fps { deliveryBlock["fps"] = fps }
        var root: [String: Any] = [
            "version": Self.fileVersion,
            "presets": presetList,
            "active_preset": activePreset,
            "delivery": deliveryBlock,
            "clips": clipMap,
        ]
        if let out = outputDirectory { root["output_directory"] = out.path }
        return try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys])
    }

    /// A look out of a project file, upgraded from the version that wrote it.
    ///
    /// NOT A FALLBACK, and the difference is the whole point. `Look` refuses a missing key because
    /// substituting a value renders a different look under the same name. A version-1 project was
    /// written before the film stages existed, so its looks carry no `halation` block and no grain
    /// weights, for a reason that is known exactly: that look had none. Adding the neutral
    /// values says the same thing the file meant. A version-2 file missing them is damaged, and is
    /// refused like any other.
    static func look(from object: Any, version: Int) throws -> Look {
        var upgraded = object
        if version < filmStagesVersion, var look = object as? [String: Any] {
            if look["halation"] == nil {
                let neutral = Look.Halation()
                look["halation"] = [
                    "strength": 0.0, "threshold": neutral.threshold,
                    "radius": neutral.radius, "tint": neutral.tint,
                ]
            }
            if var grain = look["grain"] as? [String: Any] {
                if grain["shadows"] == nil { grain["shadows"] = 1.0 }
                if grain["highlights"] == nil { grain["highlights"] = 1.0 }
                look["grain"] = grain
            }
            upgraded = look
        }
        // Before version 3 every look rendered through Apple's cube, with the delivery finish the
        // engine then hardcoded: no log denoise, no gauge, and the shipped sharpener (now
        // edge-limited, at the amount that measured the old detail).
        //
        // THE CONVERSION IS THE ONE UPGRADE THAT MOVES THE PICTURE. Apple's cube is gone, so such
        // a look opens on this app's own rendering: brighter highlights and more contrast than it
        // was saved with. There is nothing closer to offer, and refusing the file instead would
        // lose the grade entirely.
        if version < conversionVersion, var look = upgraded as? [String: Any] {
            if look["convert"] == nil { look["convert"] = ["cube": Look.neutralConversion] }
            if look["finish"] == nil {
                let finish = Look.Finish()
                look["finish"] = [
                    "denoise": finish.denoise, "sharpen": finish.sharpen, "gauge": finish.gauge,
                ]
            }
            // The block itself may be absent: `reference_yavg` was its only key, and it is gone
            // with Apple's cube. Rebuilding it is what keeps such a file readable at all.
            var match = look["match"] as? [String: Any] ?? [:]
            if match["reference_stops"] == nil {
                match["reference_stops"] = Look.defaultReferenceStops
                look["match"] = match
            }
            upgraded = look
        }
        // Before version 4 there were no hue curves: flat ones render the same picture.
        if version < hueVersion, var look = upgraded as? [String: Any], look["hue"] == nil {
            let flat = Look.Hue()
            look["hue"] = ["rot": flat.rot, "sat": flat.sat, "lum": flat.lum]
            upgraded = look
        }
        // Before version 5 a look could stack a film look and a print cube on the rendering. They
        // are gone: a second stock over a finished picture was a different look, not a finer one,
        // and the presets are the stocks now. Dropped rather than preserved, or `Look` would carry
        // the dead blocks forward verbatim in every file it writes.
        if version < noFilmLookVersion, var look = upgraded as? [String: Any] {
            look.removeValue(forKey: "look")
            look.removeValue(forKey: "print")
            upgraded = look
        }
        // Before version 6 the correction had no contrast or saturation: 1 is what it did.
        if version < sceneTrimsVersion, var look = upgraded as? [String: Any],
            var correct = look["correct"] as? [String: Any]
        {
            if correct["contrast"] == nil { correct["contrast"] = 1.0 }
            if correct["saturation"] == nil { correct["saturation"] = 1.0 }
            look["correct"] = correct
            upgraded = look
        }
        return try Look(data: try JSONSerialization.data(withJSONObject: upgraded))
    }

    /// A saved shape as Custom's one shape: its aspect if the panel lists it, the default if not.
    /// Name and crop offset are dropped, since the panel can set neither.
    static func customShape(from saved: Deliverable?) -> Deliverable {
        guard let saved,
            Deliverable.customAspects.contains(where: {
                $0.0 == saved.aspectWidth && $0.1 == saved.aspectHeight
            })
        else { return Deliverable.defaultCustom }
        return .custom(aspectWidth: saved.aspectWidth, aspectHeight: saved.aspectHeight)
    }

    public init(data: Data) throws {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Look.Invalid.notAnObject
        }
        let version = (root["version"] as? NSNumber)?.intValue ?? 1
        var loaded: [Preset] = []
        for raw in (root["presets"] as? [[String: Any]] ?? []) {
            guard let name = raw["name"] as? String, let lookObject = raw["look"] else { continue }
            let look = try Self.look(from: lookObject, version: version)
            loaded.append(Preset(name: name, look: look))
        }
        let d = root["delivery"] as? [String: Any] ?? [:]
        let targets = Delivery.targets(fromSerialised: d)
        var clipMap: [String: ClipSettings] = [:]
        for (name, raw) in (root["clips"] as? [String: [String: Any]] ?? [:]) {
            // An older file's "look_override" is not read: it pinned a whole look, which the
            // panel can no longer show or undo.
            let a = raw["adjust"] as? [String: Any] ?? [:]
            func number(_ key: String, _ fallback: Double) -> Double {
                (a[key] as? NSNumber)?.doubleValue ?? fallback
            }
            clipMap[name] = ClipSettings(
                cropOffset: (raw["crop_offset"] as? NSNumber)?.intValue,
                previewSeconds: (raw["preview_seconds"] as? NSNumber)?.doubleValue ?? 1,
                stabilise: (raw["stabilise"] as? NSNumber)?.boolValue
                    ?? ClipSettings.stabilisesByDefault,
                adjust: Look.Adjust(
                    exposure: number("exposure", 0), warmth: number("warmth", 0),
                    tint: number("tint", 0), contrast: number("contrast", 1),
                    saturation: number("saturation", 1),
                    match: (a["match"] as? NSNumber)?.boolValue ?? true))
        }
        self.init(
            presets: loaded,
            activePreset: root["active_preset"] as? String ?? loaded.first?.name ?? "",
            delivery: Delivery(
                // Custom renders one shape. A file from when shapes were ticked in any number keeps
                // its first; one with none gets Custom's default rather than nothing to deliver.
                // It becomes one of the aspects the panel lists, so the picker never shows blank
                // for a shape it cannot offer again; anything else opens as the default.
                targets: [Self.customShape(from: targets.first)],
                // A file from before the short edge stored the 9:16 reference height.
                shortSide: (d["short_side"] as? NSNumber)?.intValue
                    ?? (d["height"] as? NSNumber).map { $0.intValue * 9 / 16 }
                    ?? Delivery.defaultShortSide,
                fps: (d["fps"] as? NSNumber)?.intValue,
                // A file from before the codec choice said `ten_bit`, which meant HEVC 10-bit.
                codec: (d["codec"] as? String).flatMap(Delivery.Codec.init(rawValue:))
                    ?? ((d["ten_bit"] as? NSNumber)?.boolValue == true ? .hevc10 : .h264),
                quality: (d["quality"] as? String).flatMap(Delivery.Quality.init(rawValue:))
                    ?? .auto,
                container: (d["container"] as? String)
                    .flatMap(Delivery.Container.init(rawValue:)) ?? .mp4,
                audio: (d["audio"] as? NSNumber)?.boolValue ?? true),
            // A file from before the picker chose its shapes by hand, which is Custom.
            exportPreset: (d["export_preset"] as? String).flatMap(ExportPreset.init(rawValue:))
                ?? .custom,
            clips: clipMap,
            outputDirectory: (root["output_directory"] as? String).map {
                URL(fileURLWithPath: $0)
            })
    }
}
