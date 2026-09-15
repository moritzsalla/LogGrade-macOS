import XCTest
@testable import GradeKit

/// Driven by a stand-in engine: these tests are about the queue, and real renders would make them
/// slow, footage-dependent and about something else.
final class RenderQueueTests: XCTestCase {
    private func waitForQueue(_ queue: RenderQueue, timeout: TimeInterval = 30) {
        let done = expectation(description: "queue")
        DispatchQueue.global().async {
            queue.start(environment: { _ in [:] })
            done.fulfill()
        }
        wait(for: [done], timeout: timeout)
        // The queue publishes on the main queue, so let those land before asserting. POLLED for
        // every job finishing rather than a fixed pause, which is a guess about scheduling.
        // Progress and outputs are published before the finished state, so they have landed too.
        let deadline = Date().addingTimeInterval(5)
        while !queue.jobs.allSatisfy({ $0.state.isFinished }) && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
    }

    func testAFailedClipDoesNotTakeTheBatchWithIt() throws {
        // The engine learned this the hard way: a two-clip run whose first render failed never
        // attempted the second. In a nineteen-clip run a failure at clip three costs the other
        // sixteen, silently.
        let engine = try stubEngine(script: """
        #!/bin/bash
        case "$1" in
          *BAD*) echo 'GRADE_CODE=RENDER_FAILED' >&2; exit 1;;
          *) echo '{"event":"run_done","rendered":1,"skipped":0,"failed":0}'; exit 0;;
        esac
        """)
        defer { try? FileManager.default.removeItem(at: engine.root) }

        let queue = RenderQueue(engine: engine)
        queue.concurrency = 1
        queue.enqueue([(URL(fileURLWithPath: "/tmp/A.mov"), "A", nil),
                       (URL(fileURLWithPath: "/tmp/BAD.mov"), "BAD", nil),
                       (URL(fileURLWithPath: "/tmp/C.mov"), "C", 48)])
        waitForQueue(queue)

        XCTAssertEqual(queue.jobs.map(\.stem), ["A", "BAD", "C"])
        XCTAssertEqual(queue.jobs[0].state, .done)
        XCTAssertEqual(queue.jobs[2].state, .done, "the clip after the failure never ran")
        guard case .failed(let reason) = queue.jobs[1].state else {
            return XCTFail("expected a failure, got \(queue.jobs[1].state)")
        }
        XCTAssertFalse(reason.isEmpty, "a failure with no reason is not usable")
    }

    func testASkippedClipIsNotReportedAsDone() throws {
        // The engine exits 0 for a clip it refused. A queue that shows that as done is the
        // interface lying about what is on disk.
        let engine = try stubEngine(script: """
        #!/bin/bash
        echo 'GRADE_CODE=REFUSE_UNMEASURED' >&2
        echo '{"event":"clip_skipped","clip":"BROKEN","code":"REFUSE_UNMEASURED"}'
        echo '{"event":"run_done","rendered":0,"skipped":1,"failed":0}'
        exit 0
        """)
        defer { try? FileManager.default.removeItem(at: engine.root) }
        let queue = RenderQueue(engine: engine)
        queue.enqueue([(URL(fileURLWithPath: "/tmp/BROKEN.mov"), "BROKEN", nil)])
        waitForQueue(queue)
        XCTAssertEqual(queue.jobs[0].state, .skipped(.unmeasured))
    }

    func testProgressAndOutputsAreRecordedPerClip() throws {
        let engine = try stubEngine(script: """
        #!/bin/bash
        echo '{"event":"progress","label":"reels","state":"continue","frame":12}'
        echo '{"event":"progress","label":"reels","state":"end","frame":48}'
        echo '{"event":"output","clip":"A","deliverable":"reels","path":"/tmp/A_reels.mp4","bytes":10}'
        echo '{"event":"run_done","rendered":1,"skipped":0,"failed":0}'
        """)
        defer { try? FileManager.default.removeItem(at: engine.root) }
        let queue = RenderQueue(engine: engine)
        queue.enqueue([(URL(fileURLWithPath: "/tmp/A.mov"), "A", 48)])
        waitForQueue(queue)
        XCTAssertEqual(queue.jobs[0].frame, 48)
        XCTAssertEqual(queue.jobs[0].outputs.map(\.lastPathComponent), ["A_reels.mp4"])
    }

    func testCancelStopsTheEngineAndWhatItSpawned() throws {
        // Terminating the shell alone is not enough: grade.sh spends its time inside ffmpeg, a
        // child in the same group, which would carry on encoding into a staging file nobody wants.
        //
        // ASKED DIRECTLY, by pid. The first version of this test watched for a file the orphan
        // would write later, and passed whether or not the cancel reached it — the queue returns
        // as soon as the shell dies, so nothing had been written yet either way.
        let pidFile = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(UUID().uuidString).pid")
        // The pid written is the GRANDCHILD's: shell, subshell, sleep. That is the shape that
        // matters, because ffmpeg sits at the same depth once a subshell is involved. `$!` rather
        // than `$BASHPID`, which does not exist in the bash 3.2 macOS ships.
        //
        // AND IT LEAVES THE PROCESS GROUP. Foundation starts the engine as the leader of its own
        // group and `Process.terminate()` signals that whole group, so a grandchild that stays in
        // it dies with no help from `EngineRun.stop`'s walk of descendants. Written that way, this
        // test stayed green with the walk replaced by a no-op. `setpgrp` puts the grandchild where
        // only the walk can reach it, which is the case the walk exists for.
        let engine = try stubEngine(script: """
        #!/bin/bash
        ( perl -e 'setpgrp(0, 0); exec "sleep", "30"' & echo $! > "\(pidFile.path)"; wait ) &
        wait
        """)
        var pid: Int32 = 0
        defer {
            // A failure here would otherwise leave a sleep running for thirty seconds.
            if pid > 0 { kill(pid, SIGKILL) }
            try? FileManager.default.removeItem(at: engine.root)
            try? FileManager.default.removeItem(at: pidFile)
        }
        let queue = RenderQueue(engine: engine)
        queue.enqueue([(URL(fileURLWithPath: "/tmp/A.mov"), "A", 48)])

        let finished = expectation(description: "queue")
        DispatchQueue.global().async {
            queue.start(environment: { _ in [:] })
            finished.fulfill()
        }
        // POLLED, not a fixed wait. It was 1.5 seconds, which held when the suite ran serially and
        // failed under `swift test --parallel`: with the render tests starting at the same moment,
        // the stub had not written its pid yet and the read threw before the cancel was reached.
        let deadline = Date().addingTimeInterval(15)
        while pid == 0 && Date() < deadline {
            pid = (try? String(contentsOf: pidFile, encoding: .utf8))
                .flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 0
            if pid == 0 { Thread.sleep(forTimeInterval: 0.05) }
        }
        XCTAssertGreaterThan(pid, 0, "the stub engine never reported a child")
        XCTAssertEqual(kill(pid, 0), 0, "the child was not running before the cancel")

        queue.cancel()
        wait(for: [finished], timeout: 15)
        // Polled too: SIGTERM is asynchronous, but five seconds is far past any honest delivery.
        let gone = Date().addingTimeInterval(5)
        while kill(pid, 0) == 0 && Date() < gone { Thread.sleep(forTimeInterval: 0.05) }

        let survived = kill(pid, 0) == 0
        XCTAssertFalse(survived, "the child outlived the cancel")
        // Forget a pid that is already gone, so the cleanup cannot signal whatever reuses it.
        if !survived { pid = 0 }
    }

    func testSweepingLeavesNoStagingFileBehind() throws {
        // A killed render leaves a .partial file rather than a damaged deliverable, because the
        // engine stages every render. The next run would sweep it, but a cancel should not leave
        // litter for a run that may never happen.
        let work = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        let final = work.appendingPathComponent("dist/03-final")
        try FileManager.default.createDirectory(at: final, withIntermediateDirectories: true)
        let partial = final.appendingPathComponent("IMG_0609_reels.partial.mp4")
        let keeper = final.appendingPathComponent("IMG_0609_reels.mp4")
        try Data("x".utf8).write(to: partial)
        try Data("y".utf8).write(to: keeper)
        defer { try? FileManager.default.removeItem(at: work) }

        let swept = RenderQueue.sweepStagingFiles(in: work)
        XCTAssertEqual(swept.map(\.lastPathComponent), ["IMG_0609_reels.partial.mp4"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: keeper.path),
                      "a finished deliverable is not litter")
    }

    func testConcurrencyIsBoundedAndNeverZero() throws {
        let queue = RenderQueue(engine: try stubEngine(script: "#!/bin/bash\nexit 0\n"))
        queue.concurrency = 99
        XCTAssertEqual(queue.concurrency, 4, "more than four fight for memory bandwidth")
        queue.concurrency = 0
        XCTAssertEqual(queue.concurrency, 1, "zero would be a queue that never runs")
    }
}

final class ProgressTests: XCTestCase {
    func testAFrameCountMeansNothingWithoutATotal() {
        var job = RenderQueue.Job(clip: URL(fileURLWithPath: "/tmp/A.mov"), stem: "A")
        job.frame = 412
        XCTAssertNil(job.fractionDone, "412 of what? that is the whole problem")
        job.totalFrames = 824
        XCTAssertEqual(job.fractionDone ?? 0, 0.5, accuracy: 1e-9)
        // A render that overruns its estimate should not report 130%.
        job.frame = 900
        XCTAssertEqual(job.fractionDone ?? 0, 1.0, accuracy: 1e-9)
    }

    func testTheFrameCountComesFromTheMeasuredClip() {
        let fields = ClipProbe.Fields(codec: "prores", pixelFormat: "yuv422p10le",
                                      primaries: "bt2020", transfer: "unknown",
                                      width: 3840, height: 2160,
                                      duration: 26.5, frameRate: 24)
        XCTAssertEqual(fields.frameCount, 636)
        // And it says nothing rather than guessing when ffprobe did not answer.
        let unmeasured = ClipProbe.Fields(codec: "prores", pixelFormat: "yuv422p10le",
                                          primaries: "bt2020", transfer: "unknown",
                                          width: 3840, height: 2160,
                                          duration: nil, frameRate: 24)
        XCTAssertNil(unmeasured.frameCount)
    }
}

/// Retrying a clip that did not make it.
///
/// A failed clip does not stop the batch — that was settled — but until now it was also final,
/// which meant fixing the cause and re-adding the clip by hand. These cover the state reset only;
/// that a retry actually re-renders is the engine's job and is covered by the delivery test.
extension RenderQueueTests {
    func testRetryPutsAFinishedJobBackInTheQueue() throws {
        let queue = RenderQueue(engine: EngineLocation(root: URL(fileURLWithPath: "/nowhere")))
        queue.enqueue([(URL(fileURLWithPath: "/tmp/A.mov"), "A", nil)])
        let id = try XCTUnwrap(queue.jobs.first?.id)
        queue.setOutcome(id, state: .failed("disk full"), outputs: [URL(fileURLWithPath: "/x")],
                         frame: 12)

        queue.retry(id)
        XCTAssertEqual(queue.jobs.first?.state, .waiting)
        // CLEARED WITH IT. A frame count and an output path from the attempt that failed describe
        // a render that does not exist; leaving them would show progress for work not done.
        XCTAssertNil(queue.jobs.first?.frame)
        XCTAssertEqual(queue.jobs.first?.outputs, [])
    }

    func testRetryLeavesAFinishedSuccessAlone() throws {
        let queue = RenderQueue(engine: EngineLocation(root: URL(fileURLWithPath: "/nowhere")))
        queue.enqueue([(URL(fileURLWithPath: "/tmp/A.mov"), "A", nil),
                       (URL(fileURLWithPath: "/tmp/B.mov"), "B", nil)])
        let a = try XCTUnwrap(queue.jobs.first?.id)
        let b = try XCTUnwrap(queue.jobs.last?.id)
        queue.setOutcome(a, state: .done, outputs: [URL(fileURLWithPath: "/a.mp4")], frame: 90)
        queue.setOutcome(b, state: .skipped(.unmeasured), outputs: [], frame: nil)

        queue.retryAllFailed()
        XCTAssertEqual(queue.jobs.first?.state, .done, "a delivered clip was queued again")
        XCTAssertEqual(queue.jobs.first?.outputs.count, 1, "its output was thrown away")
        XCTAssertEqual(queue.jobs.last?.state, .waiting, "a skipped clip was not offered a retry")
    }

    func testAWaitingJobIsNotResetByRetry() throws {
        let queue = RenderQueue(engine: EngineLocation(root: URL(fileURLWithPath: "/nowhere")))
        queue.enqueue([(URL(fileURLWithPath: "/tmp/A.mov"), "A", nil)])
        let id = try XCTUnwrap(queue.jobs.first?.id)
        queue.retry(id)
        XCTAssertEqual(queue.jobs.first?.state, .waiting)
    }
}
