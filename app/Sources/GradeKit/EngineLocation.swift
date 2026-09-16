import Foundation

/// Where the engine is, and whether it can actually run.
///
/// This exists because of one fact about GUI processes on macOS: they do not inherit the shell's
/// PATH. Every tool the engine calls — ffmpeg, ffprobe, jq, python3 — is a bare name in the
/// scripts, and on this machine ffmpeg lives in ~/.local/bin, which a launched app has never heard
/// of. So the app resolves each one to an absolute path and hands them over explicitly, and it
/// refuses to start a render it knows will die with an opaque non-zero exit.
///
/// It also checks the scripts and the cube a render needs, because a missing one fails inside
/// ffmpeg with a raw filter error naming a path nobody chose.
public struct EngineLocation {
    /// The repo root: the directory holding `scripts/`, `luts/` and `look.json`.
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public var gradeScript: URL { root.appendingPathComponent("scripts/grade.sh") }
    public var lookFile: URL { root.appendingPathComponent("look.json") }
    public var toneGenerator: URL { root.appendingPathComponent("scripts/make-tone-lut.py") }
    public var correctGenerator: URL { root.appendingPathComponent("scripts/make-correct-lut.py") }
    public var halationGenerator: URL {
        root.appendingPathComponent("scripts/make-halation-luts.py")
    }
    public var filmCubes: URL { root.appendingPathComponent("luts/film") }
    public var renderingCubes: URL { root.appendingPathComponent("luts/rendering") }
    public var presetFolder: URL { root.appendingPathComponent("presets") }

    /// The cube `convert.cube` names: the renderings, then the film stocks, or nil when the file
    /// is not there. The same order `resolve_conversion` in lib.sh searches, and the reason it is
    /// an order rather than one folder is that both hold cubes that go in the same slot.
    public func conversionCube(named stem: String, fileManager: FileManager = .default) -> URL? {
        guard !stem.isEmpty, !stem.contains("/"), !stem.hasPrefix(".") else { return nil }
        for folder in [renderingCubes, filmCubes] {
            let url = folder.appendingPathComponent("\(stem).cube")
            if fileManager.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    /// The picker's order, by preset file stem: the look that matters most first
    /// (docs/BACKLOG.md). A stem not named here follows, alphabetically, so a new preset file
    /// still appears without an edit.
    public static let presetOrder = ["portra160", "portra800", "super8"]

    /// The presets the engine ships, `presets/*.json`, each a complete look with a `name`, in
    /// `presetOrder`. A file that is not a complete look is left out rather than offered half-read.
    public func shippedPresets(fileManager: FileManager = .default) -> [Project.Preset] {
        let found = stems(in: presetFolder, fileManager: fileManager, extension: "json")
        let ordered =
            Self.presetOrder.filter(found.contains)
            + found.filter { !Self.presetOrder.contains($0) }
        return ordered.compactMap { stem in
            let url = presetFolder.appendingPathComponent("\(stem).json")
            guard let data = try? Data(contentsOf: url), let look = try? Look(data: data),
                let name = look.preserved["name"] as? String
            else { return nil }
            return Project.Preset(name: name, look: look)
        }
    }

    /// What a preflight can conclude. Each case names the thing to fix, because "could not render"
    /// is the message this whole type exists to avoid.
    public enum Problem: Equatable, CustomStringConvertible {
        case missingFile(URL)
        case notExecutable(URL)
        case missingTool(String)
        case pythonDoesNotRun(URL)

        public var description: String {
            switch self {
            case .missingFile(let u):
                return "missing: \(u.path)"
            case .notExecutable(let u):
                return "not executable: \(u.path)"
            case .missingTool(let name):
                return "\(name) is not on any path this app knows about"
            case .pythonDoesNotRun(let u):
                return """
                    python3 at \(u.path) does not run. On a Mac without the command line developer \
                    tools it is only a placeholder. Install them with: xcode-select --install
                    """
            }
        }
    }

    /// The tools the engine shells out to, by bare name, in the order the scripts need them.
    static let requiredTools = ["ffmpeg", "ffprobe", "jq", "python3"]

    /// Directories searched for those tools, ahead of whatever PATH says. `~/.local/bin` is first
    /// because that is where this machine's ffmpeg is, and a launched app's PATH does not include
    /// it. Homebrew's two prefixes follow, so the same build works on an Apple silicon machine.
    public static var toolSearchPaths: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
    }

    /// Absolute path for a tool, or nil. Searched explicitly rather than by asking the shell,
    /// because the shell a GUI process would spawn has the same impoverished PATH it does.
    public static func resolveTool(
        _ name: String,
        extraPaths: [String] = [],
        fileManager: FileManager = .default
    ) -> URL? {
        var dirs = extraPaths + toolSearchPaths
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            dirs += path.split(separator: ":").map(String.init)
        }
        for dir in dirs where !dir.isEmpty {
            let candidate = URL(fileURLWithPath: dir).appendingPathComponent(name)
            if fileManager.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    /// A tool as a render will find it: the engine's own directory first, because that is where
    /// make-app.sh vendors ffmpeg, ffprobe and jq, and `EngineRun` puts it first on the child's
    /// PATH. Resolving without it made a bundle carrying all three report them missing on any Mac
    /// that had no copy of its own in ~/.local/bin or Homebrew — which is every fresh one.
    public func resolveTool(_ name: String, fileManager: FileManager = .default) -> URL? {
        Self.resolveTool(name, extraPaths: [root.path], fileManager: fileManager)
    }

    private func stems(
        in folder: URL, fileManager: FileManager, extension ext: String = "cube"
    ) -> [String] {
        let urls =
            (try? fileManager.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == ext }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted()
    }

    /// Everything wrong with this engine, in the order a person would fix it. Empty means it runs.
    public func preflight(fileManager: FileManager = .default) -> [Problem] {
        var problems: [Problem] = []
        for url in [gradeScript, toneGenerator, correctGenerator, halationGenerator] {
            if !fileManager.fileExists(atPath: url.path) {
                problems.append(.missingFile(url))
            } else if !fileManager.isExecutableFile(atPath: url.path) {
                problems.append(.notExecutable(url))
            }
        }
        for url in [lookFile] where !fileManager.fileExists(atPath: url.path) {
            problems.append(.missingFile(url))
        }
        // ONLY THE CONVERSION THE LOOK ASKS FOR: every cube a render can reach is committed now
        // that Apple's is gone, so a missing one is a damaged checkout, not something to download.
        if let stem = try? Look(data: Data(contentsOf: lookFile)).convertCube,
            conversionCube(named: stem, fileManager: fileManager) == nil
        {
            problems.append(.missingFile(renderingCubes.appendingPathComponent("\(stem).cube")))
        }
        for tool in Self.requiredTools {
            guard let url = resolveTool(tool, fileManager: fileManager) else {
                problems.append(.missingTool(tool))
                continue
            }
            if tool == "python3" && !Self.runs(url) {
                problems.append(.pythonDoesNotRun(url))
            }
        }
        return problems
    }

    /// Whether a tool exits cleanly when asked to do nothing.
    ///
    /// ONLY python3 IS RUN, because only python3 can exist without being installed. macOS ships
    /// /usr/bin/python3 as one of the developer-tools placeholders (the same file as /usr/bin/git),
    /// so it is executable on every Mac and the existence check above passes. Without the tools it
    /// exits non-zero and asks to install them, which a render would hit at its first generator.
    static func runs(_ tool: URL) -> Bool {
        let process = Process()
        process.executableURL = tool
        process.arguments = ["-c", "pass"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    /// Where the engine is, in the order the app should look.
    ///
    /// FOUND THE HARD WAY. The first version asked the current working directory, which is `/`
    /// when a bundle is launched from the Finder — so the app opened and said it had no engine
    /// while sitting two directories away from one. An app has to look next to ITSELF.
    ///
    /// 1. `LOGGRADE_ENGINE`, an explicit override. This is the debug arrangement: point a build at
    ///    a working copy and the shell scripts stay editable without rebuilding the bundle.
    /// 2. The bundle's own copy, `Contents/Resources/engine`, which is what make-app.sh vendors so
    ///    the app does not break when a checkout moves.
    /// 3. Upwards from the executable, which is how `swift run` inside the repo finds it.
    /// 4. Upwards from the working directory, last, because it is the one a launched app lies
    ///    about.
    public static func locate(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        executable: URL? = Bundle.main.executableURL,
        workingDirectory: URL = URL(
            fileURLWithPath:
                FileManager.default.currentDirectoryPath),
        fileManager: FileManager = .default
    ) -> EngineLocation? {
        if let override = environment["LOGGRADE_ENGINE"], !override.isEmpty {
            let candidate = EngineLocation(root: URL(fileURLWithPath: override))
            if candidate.looksLikeAnEngine(fileManager: fileManager) { return candidate }
        }
        if let executable {
            // Contents/MacOS/LogGrade -> Contents/Resources/engine
            let bundled =
                executable
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Resources/engine")
            let candidate = EngineLocation(root: bundled)
            if candidate.looksLikeAnEngine(fileManager: fileManager) { return candidate }
            if let up = discover(
                from: executable.deletingLastPathComponent(),
                fileManager: fileManager)
            {
                return up
            }
        }
        return discover(from: workingDirectory, fileManager: fileManager)
    }

    /// The two files that make a directory an engine rather than a directory.
    public func looksLikeAnEngine(fileManager: FileManager = .default) -> Bool {
        fileManager.fileExists(atPath: gradeScript.path)
            && fileManager.fileExists(atPath: lookFile.path)
    }

    /// Walks up from a starting directory looking for the engine. Used by the tests to find the
    /// checkout they live in, and by a debug build pointed at a working copy.
    public static func discover(
        from start: URL,
        fileManager: FileManager = .default
    ) -> EngineLocation? {
        var dir = start.standardizedFileURL
        while dir.path != "/" {
            let candidate = EngineLocation(root: dir)
            if candidate.looksLikeAnEngine(fileManager: fileManager) { return candidate }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }
}
