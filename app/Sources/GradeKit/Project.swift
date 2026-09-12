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
        public init(name: String, look: Look) { self.name = name; self.look = look }
    }

    /// What is decided per clip, and nowhere else.
    public struct ClipSettings: Equatable {
        /// The 4:5 crop's vertical offset. Nil means undecided, which is not the same as zero:
        /// the engine refuses a Feed render across several clips without one, because the offset
        /// is a composition call and one clip's framing applied to eighteen others produces files
        /// that all look done.
        public var cropOffset: Int?
        /// Where the preview frame is taken from.
        public var previewSeconds: Double
        public var stabilise: Bool
        /// A departure from the project's preset, for this clip alone. Nil means it follows.
        public var lookOverride: Look?

        public init(cropOffset: Int? = nil, previewSeconds: Double = 1,
                    stabilise: Bool = true, lookOverride: Look? = nil) {
            self.cropOffset = cropOffset
            self.previewSeconds = previewSeconds
            self.stabilise = stabilise
            self.lookOverride = lookOverride
        }
    }

    public struct Delivery: Equatable {
        public var reels: Bool
        public var feed: Bool
        public var height: Int
        /// Nil keeps the source's rate, which is the only lossless answer.
        public var fps: Int?
        public init(reels: Bool = true, feed: Bool = false, height: Int = 1920, fps: Int? = nil) {
            self.reels = reels; self.feed = feed; self.height = height; self.fps = fps
        }
    }

    public var presets: [Preset]
    public var activePreset: String
    public var delivery: Delivery
    /// Keyed by clip stem, which is the join key back to the footage and to the camera's own
    /// capture order. Never renamed.
    public var clips: [String: ClipSettings]
    public var outputDirectory: URL?

    public init(presets: [Preset], activePreset: String, delivery: Delivery = Delivery(),
                clips: [String: ClipSettings] = [:], outputDirectory: URL? = nil) {
        self.presets = presets
        self.activePreset = activePreset
        self.delivery = delivery
        self.clips = clips
        self.outputDirectory = outputDirectory
    }

    public var active: Preset? { presets.first { $0.name == activePreset } }

    /// The look a clip renders with: its own departure, or the project's preset.
    public func look(for clip: String) -> Look? {
        clips[clip]?.lookOverride ?? active?.look
    }

    /// What stops a render before it starts. The interface shows these rather than discovering
    /// them from the engine's refusal, which is the same rule the engine follows itself.
    public enum Blocker: Equatable, CustomStringConvertible {
        case noActivePreset(String)
        case feedWithoutCropOffset([String])

        public var description: String {
            switch self {
            case .noActivePreset(let name):
                return "no preset named \(name)"
            case .feedWithoutCropOffset(let clips):
                return "the 4:5 crop offset is a per-clip framing call, and \(clips.count) "
                    + "clip(s) have none yet: \(clips.sorted().joined(separator: ", "))"
            }
        }
    }

    public func blockers(for clipNames: [String]) -> [Blocker] {
        var found: [Blocker] = []
        if active == nil { found.append(.noActivePreset(activePreset)) }
        if delivery.feed {
            let undecided = clipNames.filter { clips[$0]?.cropOffset == nil }
            if !undecided.isEmpty { found.append(.feedWithoutCropOffset(undecided)) }
        }
        return found
    }

    /// The engine's environment for one clip, built from the project. Variables only — the app
    /// never builds a filter string.
    public func environment(for clip: String, lookFile: URL) -> [String: String] {
        var env: [String: String] = ["LOOK_FILE": lookFile.path]
        env["HEIGHT"] = String(delivery.height)
        if let fps = delivery.fps { env["FPS_OUT"] = String(fps) }
        env["FEED"] = delivery.feed ? "1" : "0"
        if let offset = clips[clip]?.cropOffset { env["CROP_Y"] = String(offset) }
        env["STAB"] = (clips[clip]?.stabilise ?? true) ? "1" : "0"
        return env
    }
}

// MARK: - On disk

extension Project {
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
            if let look = s.lookOverride {
                entry["look_override"] = try JSONSerialization.jsonObject(with: look.serialised())
            }
            clipMap[name] = entry
        }
        var root: [String: Any] = [
            "version": 1,
            "presets": presetList,
            "active_preset": activePreset,
            "delivery": [
                "reels": delivery.reels, "feed": delivery.feed, "height": delivery.height,
            ],
            "clips": clipMap,
        ]
        if let fps = delivery.fps {
            var d = root["delivery"] as! [String: Any]
            d["fps"] = fps
            root["delivery"] = d
        }
        if let out = outputDirectory { root["output_directory"] = out.path }
        return try JSONSerialization.data(withJSONObject: root,
                                          options: [.prettyPrinted, .sortedKeys])
    }

    public init(data: Data) throws {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Look.Invalid.notAnObject
        }
        var loaded: [Preset] = []
        for raw in (root["presets"] as? [[String: Any]] ?? []) {
            guard let name = raw["name"] as? String, let lookObject = raw["look"] else { continue }
            let look = try Look(data: try JSONSerialization.data(withJSONObject: lookObject))
            loaded.append(Preset(name: name, look: look))
        }
        let d = root["delivery"] as? [String: Any] ?? [:]
        var clipMap: [String: ClipSettings] = [:]
        for (name, raw) in (root["clips"] as? [String: [String: Any]] ?? [:]) {
            var override: Look?
            if let o = raw["look_override"] {
                override = try Look(data: try JSONSerialization.data(withJSONObject: o))
            }
            clipMap[name] = ClipSettings(
                cropOffset: (raw["crop_offset"] as? NSNumber)?.intValue,
                previewSeconds: (raw["preview_seconds"] as? NSNumber)?.doubleValue ?? 1,
                stabilise: (raw["stabilise"] as? NSNumber)?.boolValue ?? true,
                lookOverride: override)
        }
        self.init(presets: loaded,
                  activePreset: root["active_preset"] as? String ?? loaded.first?.name ?? "",
                  delivery: Delivery(reels: (d["reels"] as? NSNumber)?.boolValue ?? true,
                                     feed: (d["feed"] as? NSNumber)?.boolValue ?? false,
                                     height: (d["height"] as? NSNumber)?.intValue ?? 1920,
                                     fps: (d["fps"] as? NSNumber)?.intValue),
                  clips: clipMap,
                  outputDirectory: (root["output_directory"] as? String).map {
                      URL(fileURLWithPath: $0)
                  })
    }
}
