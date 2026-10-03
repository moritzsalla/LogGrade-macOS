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
            // THE SELECTED CLIP IS THE TOOLBAR'S EXPORT, the window's one prominent action; this
            // section is the whole list and what happened to each clip.
            HStack(spacing: Space.s) {
                if queue.isRunning {
                    Button("Stop") { model.cancel(queue: queue) }
                } else if model.clipNames.count > 1 {
                    Button("Export All \(model.clipNames.count)") {
                        model.convert(queue: queue, .all)
                    }
                    .disabled(whyNotAll != nil)
                    .help(whyNotAll ?? "Render every clip in the list, each with its own grade")
                }
                // Only when there is something to retry, and it re-runs through convert so a
                // crop offset or a look value fixed since the failure is picked up.
                if !queue.isRunning && needsRetry > 0 {
                    Button(needsRetry == 1 ? "Retry 1 Clip" : "Retry \(needsRetry) Clips") {
                        queue.retryAllFailed()
                        model.convert(queue: queue, nil)
                    }
                }
            }

            // A DISABLED BUTTON THAT DOES NOT SAY WHY IS A DEAD END. Export can be blocked for
            // several reasons, and whichever is in the way is named here and on the toolbar's
            // tooltip.
            if let reason = model.exportBlocker(queue: queue, .selected), !queue.isRunning {
                Label(reason, systemImage: "exclamationmark.circle")
                    .font(Type.caption)
                    .foregroundColor(Palette.lamp)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if queue.jobs.isEmpty {
                Text("Export in the toolbar renders the selected clip with its own grade.")
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
                            Button("Retry") {
                                queue.retry(job.id)
                                model.convert(queue: queue, nil)
                            }
                            .buttonStyle(.link).font(Type.caption)
                        }
                    }
                }
            }
        }
        .padding(Space.l)
        .background(Palette.panel)
    }

    private var whyNotAll: String? { model.exportBlocker(queue: queue, .all) }

    /// How many clips ended in something other than success. A skipped clip counts: the engine
    /// refused it for a reason the person can usually fix, which is exactly what a retry is for.
    private var needsRetry: Int {
        queue.jobs.filter { $0.state.isFinished && $0.state != .done }.count
    }

    /// One clip's state in its own words. A frame count while it runs, the reason when it does
    /// not: "failed" alone sends someone to a log file that the app has already read.
    private func describe(_ job: RenderQueue.Job) -> String {
        switch job.state {
        case .waiting: return "Waiting"
        case .running:
            let doing = job.analysing ? "Analysing shake" : "Rendering"
            if let fraction = job.fractionDone {
                return "\(doing), \(Int(fraction * 100))%"
            }
            return job.frame.map { "\(doing), frame \($0)" } ?? doing
        case .done:
            let names = job.outputs.map(\.lastPathComponent)
            return names.isEmpty ? "Done" : "Done: " + names.joined(separator: ", ")
        case .skipped(let code): return "Skipped — " + code.message
        case .failed(let why): return why
        case .cancelled: return "Stopped"
        }
    }

    private func colour(_ state: RenderQueue.State) -> Color {
        switch state {
        case .failed, .skipped: return Palette.lamp
        default: return Palette.inkSecondary
        }
    }
}
