import Foundation

/// Runs the engine and reads what it says.
///
/// The app's whole relationship with the image is here: it sets environment variables the engine's
/// own header documents, spawns `grade.sh`, and consumes its two streams. It never builds a filter
/// string — `EndToEndTests` asserts that by rendering one clip through the shell and through this
/// adapter and comparing the bytes, and ADR 0008 carries why.
public final class EngineRun {
    public struct Outcome: Equatable {
        public let exitCode: Int32
        public let events: [EngineEvent]
        public let codes: [EngineCode]
        /// Lines on stdout that were not events. Kept rather than dropped: under JSON=1 stdout is
        /// supposed to carry nothing else, so anything here is a defect worth seeing — a verdict
        /// written to the wrong stream was exactly that, once.
        public let malformed: [String]
        public let stderrText: String

        public var succeeded: Bool { exitCode == 0 }
    }

    /// Stops a running engine and everything it spawned, so no encode carries on writing to a
    /// staging file nobody is waiting for any more.
    public static func stop(_ process: Process) {
        // THE WHOLE TREE, deepest first, and then the group. Foundation starts the engine as the
        // leader of its own process group and `terminate()` signals that group, so today every
        // ffmpeg `grade.sh` starts dies from the last line alone — measured. The walk is for a
        // descendant that has left the group, which nothing in scripts/ does yet and which would
        // otherwise keep the encode running and the stdout pipe open, so the run would not even
        // return. `RenderQueueTests` builds exactly that grandchild, because one that stays in the
        // group passed with this loop removed.
        for pid in descendants(of: process.processIdentifier).reversed() {
            kill(pid, SIGTERM)
        }
        process.terminate()
    }

    /// Every process under this one, breadth-first, so the caller can end them from the leaves up.
    private static func descendants(of pid: Int32) -> [Int32] {
        var found: [Int32] = []
        var frontier = [pid]
        while let parent = frontier.first {
            frontier.removeFirst()
            let probe = Process()
            probe.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
            probe.arguments = ["-P", String(parent)]
            let pipe = Pipe()
            probe.standardOutput = pipe
            probe.standardError = Pipe()
            guard (try? probe.run()) != nil else { continue }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            probe.waitUntilExit()
            let children = String(decoding: data, as: UTF8.self)
                .split(separator: "\n").compactMap {
                    Int32($0.trimmingCharacters(in: .whitespaces))
                }
            found.append(contentsOf: children)
            frontier.append(contentsOf: children)
        }
        return found
    }

    public enum Failure: Error, CustomStringConvertible {
        case cannotRun(EngineLocation.Problem)
        case spawnFailed(String)

        public var description: String {
            switch self {
            case .cannotRun(let p): return p.description
            case .spawnFailed(let s): return "could not start the engine: \(s)"
            }
        }
    }

    private let engine: EngineLocation
    public init(engine: EngineLocation) { self.engine = engine }

    /// The environment the engine needs, on top of whatever it is given.
    ///
    /// PATH IS THE POINT. Every tool in the scripts is a bare name, and a GUI process has no
    /// useful PATH, so this puts the directories where the tools actually are in front — plus the
    /// bundle's own vendored copies, which is where they live once the app is assembled.
    func childEnvironment(extra: [String: String] = [:]) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        var dirs = [engine.root.path] + EngineLocation.toolSearchPaths
        if let existing = env["PATH"] { dirs += existing.split(separator: ":").map(String.init) }
        env["PATH"] = dirs.joined(separator: ":")
        // The engine reads its look from here, so the app can hand it a generated one per render
        // without touching the checkout's own file.
        env["LOOK_FILE"] = env["LOOK_FILE"] ?? engine.lookFile.path
        for (k, v) in extra { env[k] = v }
        return env
    }

    /// Spawns the engine and returns once it has exited. `onEvent` is called as the lines arrive,
    /// on an arbitrary queue, so a queue view can update while a render runs.
    @discardableResult
    public func run(
        arguments: [String],
        environment: [String: String] = [:],
        onStart: ((Process) -> Void)? = nil,
        onEvent: ((EngineEvent) -> Void)? = nil
    ) throws -> Outcome {
        let problems = engine.preflight()
        if let first = problems.first { throw Failure.cannotRun(first) }

        let process = Process()
        process.executableURL = engine.gradeScript
        process.arguments = arguments
        process.currentDirectoryURL = engine.root
        var env = childEnvironment(extra: environment)
        env["JSON"] = "1"  // the app always wants the machine-readable stream
        process.environment = env

        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err

        var events: [EngineEvent] = []
        var codes: [EngineCode] = []
        var malformed: [String] = []
        var stderrText = ""
        let lock = NSLock()

        // Both pipes are drained on their own queues. Reading one to completion before the other
        // deadlocks as soon as the engine fills the pipe it is not being read from, which a real
        // render does within seconds.
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "gradekit.engine.io", attributes: .concurrent)

        queue.async(group: group) {
            var buffer = ""
            while let chunk = try? out.fileHandleForReading.read(upToCount: 4096), !chunk.isEmpty {
                buffer += String(decoding: chunk, as: UTF8.self)
                while let nl = buffer.firstIndex(of: "\n") {
                    let line = String(buffer[buffer.startIndex..<nl])
                    buffer = String(buffer[buffer.index(after: nl)...])
                    do {
                        if let event = try EngineEvent.decode(line: line) {
                            lock.lock()
                            events.append(event)
                            lock.unlock()
                            onEvent?(event)
                        }
                    } catch {
                        lock.lock()
                        malformed.append(line)
                        lock.unlock()
                    }
                }
            }
            if !buffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                lock.lock()
                malformed.append(buffer)
                lock.unlock()
            }
        }

        queue.async(group: group) {
            var buffer = ""
            while let chunk = try? err.fileHandleForReading.read(upToCount: 4096), !chunk.isEmpty {
                let text = String(decoding: chunk, as: UTF8.self)
                lock.lock()
                stderrText += text
                lock.unlock()
                buffer += text
                while let nl = buffer.firstIndex(of: "\n") {
                    let line = String(buffer[buffer.startIndex..<nl])
                    buffer = String(buffer[buffer.index(after: nl)...])
                    if line.hasPrefix("GRADE_CODE=") {
                        let code = EngineCode(rawValue: String(line.dropFirst("GRADE_CODE=".count)))
                        lock.lock()
                        codes.append(code)
                        lock.unlock()
                    }
                }
            }
        }

        do {
            try process.run()
            onStart?(process)
        } catch {
            throw Failure.spawnFailed(String(describing: error))
        }
        process.waitUntilExit()
        // BOUNDED, because a reader blocks until every holder of the pipe's write end is gone —
        // and an orphan that survived a kill is exactly such a holder. Without a bound, cancelling
        // a render would hang the queue until an encode nobody wants finishes.
        if group.wait(timeout: .now() + 5) == .timedOut {
            out.fileHandleForReading.closeFile()
            err.fileHandleForReading.closeFile()
            // A short grace for the readers to append what they already hold, and bounded again for
            // the same orphan: the outcome is returned either way, because a line lost here costs
            // less than a queue that never finishes.
            _ = group.wait(timeout: .now() + 2)
        }

        lock.lock()
        let outcome = Outcome(
            exitCode: process.terminationStatus, events: events, codes: codes,
            malformed: malformed, stderrText: stderrText)
        lock.unlock()
        return outcome
    }
}
