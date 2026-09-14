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
        /// The vertical offset of the crop window, shared by every selected deliverable that crops.
        /// Nil means undecided, which is not the same as zero: the engine refuses a cropping render
        /// across several clips without one, because the offset is a composition call and one
        /// clip's framing applied to eighteen others produces files that all look done.
        public var cropOffset: Int?
        /// Where the preview frame is taken from.
        public var previewSeconds: Double
        public var stabilise: Bool
        /// A departure from the project's preset, for this clip alone. Nil means it follows.
        public var lookOverride: Look?

        /// A clip nobody has decided about is stabilised, which is what the engine did for every
        /// clip before the choice existed. One constant, because the interface, the environment
        /// and the project reader each fell back to their own `true`.
        public static let stabilisesByDefault = true

        public init(cropOffset: Int? = nil, previewSeconds: Double = 1,
                    stabilise: Bool = stabilisesByDefault, lookOverride: Look? = nil) {
            self.cropOffset = cropOffset
            self.previewSeconds = previewSeconds
            self.stabilise = stabilise
            self.lookOverride = lookOverride
        }
    }

    public struct Delivery: Equatable {
        /// What to render, in render order. Order is preserved because it is the order the engine
        /// works through, and a person watching a queue should see what they asked for first.
        public var targets: [Deliverable]
        public var height: Int
        /// Nil keeps the source's rate, which is the only lossless answer.
        public var fps: Int?
        /// 1080 wide at 9:16: what Instagram re-encodes to, and the size the grain and the
        /// sharpener were tuned at. A project that names no height gets it, and the interface
        /// warns about anything larger.
        public static let defaultHeight = 1920

        public init(targets: [Deliverable] = [.reels], height: Int = defaultHeight,
                    fps: Int? = nil) {
            self.targets = targets; self.height = height; self.fps = fps
        }

        /// Whether anything selected crops the master, and so has a box to draw.
        public var anyTargetCrops: Bool { targets.contains { $0.cropsPortraitMaster } }

        public var croppingTargets: [Deliverable] { targets.filter { $0.cropsPortraitMaster } }

        /// The cropping shapes that take their offset from the clip, for the blocker that names
        /// them. KEPT APART FROM `croppingTargets`: when these were one predicate, excluding a
        /// `centre` shape from the blocker also removed its box from the picture and made the
        /// panel say nothing crops.
        public var clipFramedTargets: [Deliverable] { targets.filter { $0.needsClipOffset } }

        public var anyTargetNeedsClipOffset: Bool { targets.contains { $0.needsClipOffset } }

        /// The shape the one crop box is drawn in. One the clip frames wins over a `centre` one,
        /// because it is the box that has to be dragged; a `centre` shape alone still gets a box,
        /// fixed, so what it will cut is visible before it is rendered.
        public var cropBoxTarget: Deliverable? {
            clipFramedTargets.first ?? croppingTargets.first
        }

        public func isSelected(_ deliverable: Deliverable) -> Bool {
            targets.contains(deliverable)
        }

        /// Ticking and unticking a shape.
        ///
        /// A SELECTED PRESET LANDS IN PRESET ORDER, not at the end of the list. Appending would
        /// make the render order depend on the order the boxes happened to be clicked, so
        /// unticking reels and ticking it again would quietly move it behind feed — and the order
        /// is what the queue shows and what the engine works through. Shapes that are not presets
        /// keep their own order after them; nothing here can reorder them.
        public mutating func setTarget(_ deliverable: Deliverable, selected: Bool) {
            guard selected else {
                targets.removeAll { $0 == deliverable }
                return
            }
            guard !targets.contains(deliverable) else { return }
            guard let rank = Deliverable.presets.firstIndex(of: deliverable) else {
                targets.append(deliverable)
                return
            }
            let insertAt = targets.firstIndex {
                guard let other = Deliverable.presets.firstIndex(of: $0) else { return true }
                return other > rank
            } ?? targets.count
            targets.insert(deliverable, at: insertAt)
        }

        /// Saving a shape from the editor. An edit replaces the shape it was opened on, in place,
        /// so the render order does not move; nil adds.
        ///
        /// THE ORIGINAL IS PASSED, NOT REMEMBERED. The editor used to find what it was editing in a
        /// view variable that Add never cleared, so Add after Edit opened as that edit and Save
        /// replaced the shape. An edit whose shape has since been removed adds rather than
        /// dropping the save.
        public mutating func save(_ deliverable: Deliverable, replacing original: Deliverable?) {
            if let original, let index = targets.firstIndex(of: original) {
                targets[index] = deliverable
            } else {
                targets.append(deliverable)
            }
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

    /// Keeps a grade under a name and makes it the active preset. A new name adds one; an existing
    /// name replaces it, which is how you save over a preset you have been adjusting. A blank name
    /// is ignored.
    ///
    /// Here rather than in the app's model because the model's target cannot be imported by the
    /// tests: the test for this rule used to re-implement it inline and so tested nothing.
    public mutating func savePreset(named name: String, look: Look) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        if let index = presets.firstIndex(where: { $0.name == trimmed }) {
            presets[index] = .init(name: trimmed, look: look)
        } else {
            presets.append(.init(name: trimmed, look: look))
        }
        activePreset = trimmed
    }

    /// A clip's decisions, or the undecided defaults for a clip with none recorded.
    public func settings(for clip: String) -> ClipSettings {
        clips[clip] ?? ClipSettings()
    }

    /// The look a clip renders with: its own departure, or the project's preset.
    public func look(for clip: String) -> Look? {
        clips[clip]?.lookOverride ?? active?.look
    }

    /// What stops a render before it starts. The interface shows these rather than discovering
    /// them from the engine's refusal, which is the same rule the engine follows itself.
    public enum Blocker: Equatable, CustomStringConvertible {
        case noActivePreset(String)
        /// Which shapes crop, and which clips have not been framed for them yet. The deliverables
        /// are carried as well as the clips because the set is open now: "the 4:5 crop" was a
        /// complete description when there were two shapes and is not one when there are any.
        case cropWithoutOffset(deliverables: [Deliverable], clips: [String])

        public var description: String {
            switch self {
            case .noActivePreset(let name):
                return "no preset named \(name)"
            case .cropWithoutOffset(let deliverables, let clips):
                // "a per-clip framing call" is load-bearing wording, not decoration: it is the
                // whole reason this refusal exists rather than a default nobody saw.
                let shapes = deliverables.map { "\($0.aspectWidth):\($0.aspectHeight)" }
                    .joined(separator: " and ")
                return "the \(shapes) crop offset is a per-clip framing call, and \(clips.count) "
                    + "clip(s) have none yet: \(clips.sorted().joined(separator: ", "))"
            }
        }
    }

    public func blockers(for clipNames: [String]) -> [Blocker] {
        var found: [Blocker] = []
        if active == nil { found.append(.noActivePreset(activePreset)) }
        if delivery.anyTargetNeedsClipOffset {
            let undecided = clipNames.filter { clips[$0]?.cropOffset == nil }
            if !undecided.isEmpty {
                found.append(.cropWithoutOffset(deliverables: delivery.clipFramedTargets,
                                                clips: undecided))
            }
        }
        return found
    }

    /// The engine's environment for one clip, built from the project. Variables only — the app
    /// never builds a filter string.
    public func environment(for clip: String, lookFile: URL) -> [String: String] {
        var env: [String: String] = ["LOOK_FILE": lookFile.path]
        env["HEIGHT"] = String(delivery.height)
        if let fps = delivery.fps { env["FPS_OUT"] = String(fps) }
        // The whole set, comma separated, in order. This was `FEED=1`, which could only ever say
        // one thing about one shape.
        env["DELIVERABLES"] = delivery.targets.map(\.spec).joined(separator: ",")
        if let offset = clips[clip]?.cropOffset { env["CROP_Y"] = String(offset) }
        env["STAB"] = settings(for: clip).stabilise ? "1" : "0"
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
                      w > 0, h > 0 else { return nil }
                // A file without the key was written before a shape could carry an offset, and
                // every shape then followed CROP_Y, which is what nil still means.
                let offset: DeliverableCropOffset? =
                    ($0["crop_offset"] as? String) == "centre" ? .centre : nil
                return Deliverable(name: name, aspectWidth: w, aspectHeight: h,
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
    /// The format this build writes.
    static let fileVersion = filmStagesVersion

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
        var deliveryBlock: [String: Any] = [
            "targets": delivery.targets.map { d in
                var entry: [String: Any] = ["name": d.name, "aspect_width": d.aspectWidth,
                                            "aspect_height": d.aspectHeight]
                if d.cropOffset == .centre { entry["crop_offset"] = "centre" }
                return entry
            },
            "height": delivery.height,
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
        return try JSONSerialization.data(withJSONObject: root,
                                          options: [.prettyPrinted, .sortedKeys])
    }

    /// A look out of a project file, upgraded from the version that wrote it.
    ///
    /// NOT A FALLBACK, and the difference is the whole point. `Look` refuses a missing key because
    /// substituting a value renders a different look under the same name. A version-1 project was
    /// written before the film stages existed, so its looks carry no `halation` or `print` block, no
    /// look strength and no grain weights, for a reason that is known exactly: that look had none. Adding the neutral
    /// values says the same thing the file meant. A version-2 file missing them is damaged, and is
    /// refused like any other.
    static func look(from object: Any, version: Int) throws -> Look {
        var upgraded = object
        if version < filmStagesVersion, var look = object as? [String: Any] {
            if look["halation"] == nil {
                let neutral = Look.Halation()
                look["halation"] = ["strength": 0.0, "threshold": neutral.threshold,
                                    "radius": neutral.radius, "tint": neutral.tint]
            }
            if var film = look["look"] as? [String: Any], film["strength"] == nil {
                film["strength"] = 1.0
                look["look"] = film
            }
            if look["print"] == nil { look["print"] = ["lut": "none", "strength": 1.0] }
            if var grain = look["grain"] as? [String: Any] {
                if grain["shadows"] == nil { grain["shadows"] = 1.0 }
                if grain["highlights"] == nil { grain["highlights"] = 1.0 }
                look["grain"] = grain
            }
            upgraded = look
        }
        return try Look(data: try JSONSerialization.data(withJSONObject: upgraded))
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
            var override: Look?
            if let o = raw["look_override"] {
                override = try Self.look(from: o, version: version)
            }
            clipMap[name] = ClipSettings(
                cropOffset: (raw["crop_offset"] as? NSNumber)?.intValue,
                previewSeconds: (raw["preview_seconds"] as? NSNumber)?.doubleValue ?? 1,
                stabilise: (raw["stabilise"] as? NSNumber)?.boolValue
                    ?? ClipSettings.stabilisesByDefault,
                lookOverride: override)
        }
        self.init(presets: loaded,
                  activePreset: root["active_preset"] as? String ?? loaded.first?.name ?? "",
                  delivery: Delivery(targets: targets,
                                     height: (d["height"] as? NSNumber)?.intValue
                                         ?? Delivery.defaultHeight,
                                     fps: (d["fps"] as? NSNumber)?.intValue),
                  clips: clipMap,
                  outputDirectory: (root["output_directory"] as? String).map {
                      URL(fileURLWithPath: $0)
                  })
    }
}
