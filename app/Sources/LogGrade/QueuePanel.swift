import GradeKit
import SwiftUI

/// The render queue: what is waiting, what is running, and what happened to each clip.
///
/// A list rather than a modal bar, per the Deliver page model, because a batch is a set of
/// independent jobs and one of them failing is information about that clip rather than about the
/// run. The engine already keeps a failed clip from taking the batch with it; this shows which one.
struct QueuePanel: View {
    // Not observed: see `GradeModel.changes`.
    let model: GradeModel
    @ObservedObject private var changes: GradeModel.Changes

    init(model: GradeModel, queue: RenderQueue) {
        self.model = model
        _changes = ObservedObject(wrappedValue: model.changes)
        self.queue = queue
    }
    @ObservedObject var queue: RenderQueue

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Button(queue.isRunning ? "Converting…" : "Convert") { model.convert(queue: queue) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .tint(Palette.plate)
                    .disabled(whyNot != nil)
                    .help(whyNot ?? "Render every clip in the list")
                if queue.isRunning {
                    Button("stop") { model.cancel(queue: queue) }
                        .buttonStyle(.borderless)
                }
                // Only when there is something to retry, and it re-runs through convert so a
                // crop offset or a look value fixed since the failure is picked up.
                if !queue.isRunning && needsRetry > 0 {
                    Button(needsRetry == 1 ? "retry 1 clip" : "retry \(needsRetry) clips") {
                        queue.retryAllFailed()
                        model.convert(queue: queue)
                    }
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

            // A DISABLED BUTTON THAT DOES NOT SAY WHY IS A DEAD END. Convert can be blocked for
            // four different reasons and the interface used to show the same grey rectangle for
            // all of them, leaving the only remaining move to guess. Whatever is in the way is
            // named where the button is, not in a panel somewhere else.
            if let reason = whyNot, !queue.isRunning {
                Label(reason, systemImage: "exclamationmark.circle")
                    .font(Type.caption)
                    .foregroundColor(Palette.lamp)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if queue.jobs.isEmpty {
                Text("Convert renders every clip in the list.")
                    .font(Type.caption).foregroundColor(Palette.inkTertiary)
            } else {
                // A BAR PER CLIP, not a percentage. A number tells you how far along something
                // is; a bar tells you at a glance without reading, which is what you want from a
                // panel you are not looking at. Determinate whenever the engine has said how many
                // frames the clip has, indeterminate until then, and absent once it is finished —
                // a full bar and a finished bar look the same, which is why it goes away.
                ForEach(queue.jobs) { job in
                    HStack(spacing: Space.s) {
                        Text(job.stem)
                            .font(Type.value)
                            .foregroundColor(Palette.ink)
                            .frame(width: 90, alignment: .leading)
                        if job.state == .running {
                            if let fraction = job.fractionDone {
                                ProgressView(value: fraction)
                                    .progressViewStyle(.linear)
                                    .controlSize(.small)
                                    .tint(Palette.plate)
                                    .frame(width: 92)
                            } else {
                                ProgressView()
                                    .progressViewStyle(.linear)
                                    .controlSize(.small)
                                    .frame(width: 92)
                            }
                        }
                        Text(describe(job))
                            .font(Type.caption)
                            .foregroundColor(colour(job.state))
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        if !queue.isRunning, job.state.isFinished, job.state != .done {
                            Button("retry") {
                                queue.retry(job.id)
                                model.convert(queue: queue)
                            }
                            .buttonStyle(.borderless).font(Type.caption)
                        }
                    }
                }
            }
        }
        .padding(Space.l)
        .background(Palette.panel)
    }

    /// Why Convert cannot run, in the words of whatever is actually stopping it. Nil when it can.
    private var whyNot: String? {
        if queue.isRunning { return "A conversion is already running." }
        if model.clipNames.isEmpty { return "Add a clip first." }
        if model.project.delivery.targets.isEmpty {
            return "Choose at least one deliverable."
        }
        if let blocker = model.blockers.first { return blocker.description }
        if model.outputDirectory == nil { return "Choose a folder to save into." }
        return nil
    }

    /// How many clips ended in something other than success. A skipped clip counts: the engine
    /// refused it for a reason the person can usually fix, which is exactly what a retry is for.
    private var needsRetry: Int {
        queue.jobs.filter { $0.state.isFinished && $0.state != .done }.count
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
                    UserDefaults.standard.set($0, forKey: DefaultsKey.concurrency)
                })
    }
}
