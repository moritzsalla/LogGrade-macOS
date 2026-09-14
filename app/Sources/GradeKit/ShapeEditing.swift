import Foundation

/// What the engine made of one deliverable: the fields `deliverable_spec` prints, or its refusal in
/// its own words.
public enum DeliverableResolution: Equatable {
    case resolved(Fields)
    case refused(String)

    /// Strings, as the engine printed them. Reading them into integers here would hide the one
    /// case that needs catching: the engine accepting a term Swift cannot hold as written.
    public struct Fields: Equatable {
        public let name: String
        public let aspectWidth: String
        public let aspectHeight: String
        /// `-`, `centre`, or a pixel count.
        public let offset: String
        /// What the output file is named after: `<clip>_<suffix>.mp4`.
        public let suffix: String
    }
}

extension EngineLocation {
    public var library: URL { root.appendingPathComponent("scripts/lib.sh") }

    /// Asks the engine whether a shape is one it will render, rather than restating its rules.
    ///
    /// A Swift copy of `require_clip_name` shipped with this editor and was already wrong: it let
    /// a space through, which the engine also accepted and then split into the wrong fields. The
    /// only way the editor and the render agree is for the editor to ask the renderer.
    ///
    /// TWO CALLS, because the spec is split on `:` before its name is checked: `a:b` entered as a
    /// name reaches `deliverable_spec` as name `a`, aspect `b`, and is refused for a non-integer
    /// aspect the person never typed. Checking the name alone first gives the refusal that is
    /// true. Synchronous: it is one bash sourcing one file, on a Save button.
    public func resolveDeliverable(name: String, spec: String) -> DeliverableResolution {
        let process = Process()
        // Absolute, because a launched app's PATH is not a shell's. lib.sh's top level needs only
        // builtins and coreutils, all of which live where a GUI process can see them.
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        let script = #"source "$0"; require_clip_name "$1" >/dev/null && deliverable_spec "$2""#
        process.arguments = ["-c", script, library.path, name, spec]
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do { try process.run() } catch {
            return .refused("could not ask the engine: \(error.localizedDescription)")
        }
        let stdout = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let stderr = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let said = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return .refused(said.isEmpty ? "the engine refused \(spec) without saying why" : said)
        }
        let fields = stdout.trimmingCharacters(in: .newlines)
            .split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        guard fields.count == 5 else {
            return .refused("the engine resolved \(spec) as '\(stdout)', which is not five fields")
        }
        return .resolved(.init(name: fields[0], aspectWidth: fields[1], aspectHeight: fields[2],
                               offset: fields[3], suffix: fields[4]))
    }
}

/// The editor's form, as typed. Text rather than numbers so what reaches the engine is what was
/// entered: parsing first would turn `-1` into a Swift refusal and `1.5` into nothing, each in
/// words the engine does not use.
public struct ShapeDraft: Equatable {
    public var name: String
    public var aspectWidth: String
    public var aspectHeight: String
    public var centre: Bool

    public init(name: String = "", aspectWidth: String = "", aspectHeight: String = "",
                centre: Bool = false) {
        self.name = name
        self.aspectWidth = aspectWidth
        self.aspectHeight = aspectHeight
        self.centre = centre
    }

    public init(_ deliverable: Deliverable) {
        self.init(name: deliverable.name, aspectWidth: String(deliverable.aspectWidth),
                  aspectHeight: String(deliverable.aspectHeight),
                  centre: deliverable.cropOffset == .centre)
    }

    public var spec: String {
        "\(name):\(aspectWidth):\(aspectHeight)" + (centre ? ":centre" : "")
    }
}

/// Which editor is open. The shape being edited travels WITH the request to open it, so there is
/// no second variable for Add to forget to clear — which is how Add after Edit opened as that edit.
public enum ShapeEditorMode: Identifiable, Equatable {
    case adding
    case editing(Deliverable)

    public var id: String {
        switch self {
        case .adding: return "adding"
        case .editing(let d): return "editing \(d.spec)"
        }
    }

    public var original: Deliverable? {
        if case .editing(let d) = self { return d }
        return nil
    }

    public var draft: ShapeDraft { original.map(ShapeDraft.init) ?? ShapeDraft() }
}

/// Why a shape was not saved. Only `engine` is about whether the shape can be rendered, and it
/// carries the engine's text; the rest are about this shape among the others the project knows.
public enum ShapeRefusal: Equatable, CustomStringConvertible {
    case engine(String)
    case presetName(String)
    case duplicateName(String)
    case sameOutputFile(other: String, suffix: String)
    case notAsWritten(String)

    public var description: String {
        switch self {
        case .engine(let said):
            return said
        case .presetName(let name):
            return "'\(name)' is a preset's name. A shape called that writes a different file from "
                + "the preset and would be listed as if it were the preset."
        case .duplicateName(let name):
            return "A shape named '\(name)' already exists. Names are compared ignoring case, "
                + "because the disk compares filenames that way."
        case .sameOutputFile(let other, let suffix):
            return "This writes <clip>_\(suffix).mp4, which '\(other)' already writes."
        case .notAsWritten(let term):
            return "The engine did not read '\(term)' as one whole number as written. "
                + "Enter each aspect term as plain digits."
        }
    }
}

extension Project.Delivery {
    /// Saves a shape from the editor, or says why not, changing nothing on a refusal.
    ///
    /// DUPLICATES ARE CHECKED AGAINST EVERY SHAPE THE PROJECT KNOWS, presets included whether
    /// ticked or not. A custom `reels` 9:16 compares equal to nothing and still reads as the
    /// preset everywhere a name is shown, and unticking the preset later would leave a shape that
    /// looks like it. The output file is compared too, with the engine's own suffix, because
    /// `reels-stories` at 9:16 is a different name that writes the preset's file.
    public mutating func save(_ draft: ShapeDraft, replacing original: Deliverable?,
                              resolve: (_ name: String, _ spec: String) -> DeliverableResolution)
        -> ShapeRefusal? {
        let fields: DeliverableResolution.Fields
        switch resolve(draft.name, draft.spec) {
        case .refused(let said): return .engine(said)
        case .resolved(let f): fields = f
        }
        // The engine can accept what it read differently: `1:1` in one aspect box becomes an
        // aspect and a pixel offset, and a 20-digit term passes its `-le` test by erroring. Each
        // term has to come back as the digits typed, and survive Int unchanged, to be stored.
        for (typed, read) in [(draft.aspectWidth, fields.aspectWidth),
                              (draft.aspectHeight, fields.aspectHeight)] {
            guard typed == read, let n = Int(read), String(n) == read else {
                return .notAsWritten(typed)
            }
        }
        guard fields.offset == (draft.centre ? "centre" : "-"),
              let width = Int(fields.aspectWidth), let height = Int(fields.aspectHeight) else {
            return .notAsWritten(draft.spec)
        }

        let others = (Deliverable.presets + targets.filter { !Deliverable.presets.contains($0) })
            .filter { $0 != original }
        let key = Self.filenameKey(draft.name)
        if let preset = Deliverable.presets.first(where: { Self.filenameKey($0.name) == key }) {
            return .presetName(preset.name)
        }
        if let same = others.first(where: { Self.filenameKey($0.name) == key }) {
            return .duplicateName(same.name)
        }
        let suffix = Self.filenameKey(fields.suffix)
        for other in others {
            if case .resolved(let theirs) = resolve(other.name, other.spec),
               Self.filenameKey(theirs.suffix) == suffix {
                return .sameOutputFile(other: other.name, suffix: fields.suffix)
            }
        }
        save(Deliverable(name: draft.name, aspectWidth: width, aspectHeight: height,
                         cropOffset: draft.centre ? .centre : nil),
             replacing: original)
        return nil
    }

    /// How the disk tells two names apart. APFS is case-insensitive and normalisation-insensitive
    /// by default, so `Square` and `square` — or a composed and a decomposed é — are one file.
    static func filenameKey(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping.lowercased()
    }
}
