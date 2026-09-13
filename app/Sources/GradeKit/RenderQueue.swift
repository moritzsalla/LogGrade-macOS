import Foundation

/// The clips waiting to be rendered, and what happened to each.
///
/// A FAILED CLIP MUST NOT TAKE THE BATCH WITH IT. The engine learned that the hard way — a
/// two-clip run whose first render failed never attempted the second, printed no summary, and left
/// its report ending mid-file. In an unattended nineteen-clip run a failure at clip three silently
/// costs the other sixteen. So every job is isolated, its failure is recorded against the clip, and
/// the queue carries on.
public final class RenderQueue: ObservableObject {
    public struct Job: Identifiable, Equatable {
        public let id = UUID()
        public let clip: URL
        public let stem: String
        public var state: State = .waiting
        /// Frames rendered so far, from the engine's progress events. Nil until it says.
        public var frame: Int?
        public var outputs: [URL] = []
        /// How many frames this clip has, when it could be measured. Without it a frame count is a
        /// number with no scale, which is what "rendering, frame 412" was.
        public var totalFrames: Int?

        public var fractionDone: Double? {
            guard let frame, let totalFrames, totalFrames > 0 else { return nil }
            return min(1, Double(frame) / Double(totalFrames))
        }

        public init(clip: URL, stem: String, totalFrames: Int? = nil) {
            self.clip = clip
            self.stem = stem
            self.totalFrames = totalFrames
        }
    }

    public enum State: Equatable {
        case waiting
        case running
        case done
        case skipped(EngineCode)
        case failed(String)
        case cancelled

        public var isFinished: Bool {
            switch self {
            case .waiting, .running: return false
            default: return true
            }
        }
    }

    @Published public private(set) var jobs: [Job] = []
    @Published public private(set) var isRunning = false

    /// How many renders at once. One clip does not saturate a modern machine, because several
    /// filters in this chain are serial — so two to four is close to a linear gain on a batch, and
    /// it is the largest cheap win available. More than four and they fight for memory bandwidth.
    public var concurrency: Int = 2 {
        didSet { concurrency = min(4, max(1, concurrency)) }
    }

    private let engine: EngineLocation
    private let lock = NSLock()
    private var running: [UUID: Process] = [:]
    private var cancelled = false

    public init(engine: EngineLocation) { self.engine = engine }

    /// Sets a job's outcome directly.
    ///
    /// INTERNAL, and only the tests call it. The queue's own route to a finished state runs the
    /// engine, and what `retry` has to get right is what happens AFTER a job finished, not how it
    /// got there — so the tests set the outcome and skip the render.
    func setOutcome(_ id: Job.ID, state: State, outputs: [URL] = [], frame: Int? = nil) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[i].state = state
        jobs[i].outputs = outputs
        jobs[i].frame = frame
    }

    /// Puts a finished job back in the queue.
    ///
    /// RESET RATHER THAN RE-RUN. A clip usually fails for a reason the person then fixes — a
    /// missing crop offset, a full disk, a look value the engine refused — so the retry has to
    /// pick up whatever changed, which means going through `start(environment:)` again and asking
    /// the caller for a fresh environment. Re-running a captured one would repeat the failure and
    /// look like the fix did not work.
    ///
    /// The previous outputs and frame count are cleared with it: a half-written progress figure
    /// from the attempt that failed is worse than none.
    public func retry(_ id: Job.ID) {
        guard let i = jobs.firstIndex(where: { $0.id == id }), jobs[i].state.isFinished else {
            return
        }
        jobs[i].state = .waiting
        jobs[i].frame = nil
        jobs[i].outputs = []
    }

    /// Every job that did not finish cleanly, back in the queue at once. The button a person
    /// actually wants after fixing one thing that broke several clips.
    public func retryAllFailed() {
        for job in jobs where job.state.isFinished {
            if case .done = job.state { continue }
            retry(job.id)
        }
    }

    public func enqueue(_ clips: [(url: URL, stem: String, frames: Int?)]) {
        for clip in clips where !jobs.contains(where: { $0.stem == clip.stem && !$0.state.isFinished }) {
            jobs.append(Job(clip: clip.url, stem: clip.stem, totalFrames: clip.frames))
        }
    }

    public func clearFinished() {
        jobs.removeAll { $0.state.isFinished }
    }

    /// Runs everything waiting. Returns when the queue is empty or cancelled.
    public func start(environment: @escaping (String) -> [String: String]) {
        lock.lock(); cancelled = false; lock.unlock()
        setRunning(true)

        let group = DispatchGroup()
        let slots = DispatchSemaphore(value: concurrency)
        let pool = DispatchQueue(label: "gradekit.queue", attributes: .concurrent)

        for index in jobs.indices where jobs[index].state == .waiting {
            let job = jobs[index]
            slots.wait()
            if isCancelled() {
                slots.signal()
                update(job.id) { $0.state = .cancelled }
                continue
            }
            group.enter()
            pool.async { [weak self] in
                defer { slots.signal(); group.leave() }
                self?.run(job, environment: environment(job.stem))
            }
        }
        group.wait()
        setRunning(false)
    }

    private func run(_ job: Job, environment: [String: String]) {
        update(job.id) { $0.state = .running }
        do {
            let outcome = try EngineRun(engine: engine).run(
                arguments: [job.clip.path],
                environment: environment,
                onStart: { [weak self] process in
                    self?.lock.lock()
                    self?.running[job.id] = process
                    self?.lock.unlock()
                },
                onEvent: { [weak self] event in
                    switch event.name {
                    case "progress":
                        if let frame = event.int("frame") {
                            self?.update(job.id) { $0.frame = frame }
                        }
                    case "output":
                        if let path = event.path {
                            self?.update(job.id) { $0.outputs.append(URL(fileURLWithPath: path)) }
                        }
                    default:
                        break
                    }
                })
            lock.lock(); running[job.id] = nil; lock.unlock()

            if isCancelled() {
                update(job.id) { $0.state = .cancelled }
            } else if outcome.succeeded {
                // A skip is not a success: the engine exits 0 for a clip it refused, and a queue
                // that shows it as done is the interface lying about what is on disk.
                if let code = outcome.codes.first(where: { $0 == .notPortrait
                                                        || $0 == .fpsWouldNeedRetiming }) {
                    update(job.id) { $0.state = .skipped(code) }
                } else {
                    update(job.id) { $0.state = .done }
                }
            } else {
                let reason = outcome.codes.first?.message
                    ?? outcome.stderrText.split(separator: "\n").first.map(String.init)
                    ?? "the engine exited \(outcome.exitCode)"
                update(job.id) { $0.state = .failed(reason) }
            }
        } catch {
            update(job.id) { $0.state = .failed(String(describing: error)) }
        }
    }

    /// Stops everything and leaves nothing half-written.
    ///
    /// The engine stages every render and installs it only once it is complete, so a killed render
    /// leaves a `.partial` file rather than a damaged deliverable. It would be swept by the next
    /// run, but a queue that cancels should not leave litter for a run that may never happen.
    public func cancel() {
        lock.lock()
        cancelled = true
        let processes = Array(running.values)
        running.removeAll()
        lock.unlock()
        for process in processes where process.isRunning {
            EngineRun.stop(process)
        }
    }

    /// Removes staging files under a work directory. Called after a cancel, and safe any time: a
    /// `.partial` file is by definition not a deliverable.
    @discardableResult
    public static func sweepStagingFiles(in workDirectory: URL,
                                         fileManager: FileManager = .default) -> [URL] {
        let dist = workDirectory.appendingPathComponent("dist")
        guard let walker = fileManager.enumerator(at: dist, includingPropertiesForKeys: nil) else {
            return []
        }
        var swept: [URL] = []
        for case let url as URL in walker where url.lastPathComponent.contains(".partial.") {
            try? fileManager.removeItem(at: url)
            swept.append(url)
        }
        return swept
    }

    // MARK: - state

    private func isCancelled() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    private func setRunning(_ value: Bool) {
        DispatchQueue.main.async { self.isRunning = value }
    }

    private func update(_ id: UUID, _ change: @escaping (inout Job) -> Void) {
        DispatchQueue.main.async {
            guard let index = self.jobs.firstIndex(where: { $0.id == id }) else { return }
            change(&self.jobs[index])
        }
    }
}
