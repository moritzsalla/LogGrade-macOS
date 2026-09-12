import GradeKit
import SwiftUI

/// The render queue: what is waiting, what is running, and what happened to each clip.
///
/// A list rather than a modal bar, per the Deliver page model, because a batch is a set of
/// independent jobs and one of them failing is information about that clip rather than about the
/// run. The engine already keeps a failed clip from taking the batch with it; this shows which one.
struct QueuePanel: View {
    @ObservedObject var model: GradeModel
    @ObservedObject var queue: RenderQueue

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Button(queue.isRunning ? "converting…" : "convert") { model.convert(queue: queue) }
                    .disabled(queue.isRunning || model.clipNames.isEmpty
                              || !model.blockers.isEmpty)
                if queue.isRunning {
                    Button("stop") { model.cancel(queue: queue) }
                        .buttonStyle(.borderless)
                }
                Spacer()
                Picker("", selection: concurrencyBinding) {
                    Text("1 at a time").tag(1)
                    Text("2 at a time").tag(2)
                    Text("3 at a time").tag(3)
                }
                .labelsHidden().frame(width: 104).disabled(queue.isRunning)
            }

            if queue.jobs.isEmpty {
                Text("nothing queued. convert renders every clip in the list.")
                    .font(.system(size: 10.5)).foregroundColor(Palette.inkTertiary)
            } else {
                ForEach(queue.jobs) { job in
                    HStack(spacing: 8) {
                        Text(job.stem)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(Palette.ink)
                            .frame(width: 90, alignment: .leading)
                        Text(describe(job))
                            .font(.system(size: 10.5))
                            .foregroundColor(colour(job.state))
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                }
            }
        }
        .padding(16)
        .background(Palette.panel)
    }

    /// One clip's state in its own words. A frame count while it runs, the reason when it does
    /// not: "failed" alone sends someone to a log file that the app has already read.
    private func describe(_ job: RenderQueue.Job) -> String {
        switch job.state {
        case .waiting: return "waiting"
        case .running:
            if let fraction = job.fractionDone {
                return "rendering, \(Int(fraction * 100))%"
            }
            return job.frame.map { "rendering, frame \($0)" } ?? "rendering"
        case .done:
            let names = job.outputs.map(\.lastPathComponent)
            return names.isEmpty ? "done" : "done: " + names.joined(separator: ", ")
        case .skipped(let code): return "skipped — " + code.message
        case .failed(let why): return why
        case .cancelled: return "stopped"
        }
    }

    private func colour(_ state: RenderQueue.State) -> Color {
        switch state {
        case .failed, .skipped: return Palette.lamp
        case .running: return Palette.plate
        default: return Palette.inkSecondary
        }
    }

    private var concurrencyBinding: Binding<Int> {
        Binding(get: { queue.concurrency },
                set: {
                    queue.concurrency = $0
                    UserDefaults.standard.set($0, forKey: "concurrency")
                })
    }
}
