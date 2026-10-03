import AppKit
import GradeKit
import SwiftUI

/// The clips, as a standard source list: arrow keys, Delete, a context menu and VoiceOver
/// selection come with `List(selection:)`, and a hand-built column had none of them.
struct ClipSidebar: View {
    let problems: [String]
    @ObservedObject var clips: ClipList
    @ObservedObject var queue: RenderQueue
    /// NOT OBSERVED HERE, which is why every read of its state sits in a subview that observes it.
    /// An optional cannot be an @ObservedObject.
    var grade: GradeModel?
    let actions: AppActions

    var body: some View {
        Group {
            if let grade {
                ClipRows(
                    problems: problems, clips: clips, queue: queue, model: grade, actions: actions)
            } else {
                List { ProblemsSection(problems: problems) }.listStyle(.sidebar)
            }
        }
        .frame(minWidth: 220, maxWidth: .infinity, maxHeight: .infinity)
        .acceptsClips(actions)
    }
}

/// Named with a trailing underscore because `ClipList` is the model it shows.
private struct ClipRows: View {
    let problems: [String]
    @ObservedObject var clips: ClipList
    @ObservedObject var queue: RenderQueue
    // Not observed: see `GradeModel.changes`.
    let model: GradeModel
    @ObservedObject private var changes: GradeModel.Changes
    let actions: AppActions

    init(
        problems: [String], clips: ClipList, queue: RenderQueue, model: GradeModel,
        actions: AppActions
    ) {
        self.problems = problems
        self.clips = clips
        self.queue = queue
        self.model = model
        _changes = ObservedObject(wrappedValue: model.changes)
        self.actions = actions
    }

    private static let thumbnailWidth: CGFloat = 32
    /// The clips' portrait 9:16, derived rather than typed.
    private static let thumbnailHeight = (thumbnailWidth * 16 / 9).rounded()

    var body: some View {
        List(selection: selection) {
            ProblemsSection(problems: problems)
            Section("Clips") {
                ForEach(clips.entries) { entry in
                    row(entry)
                        .tag(entry.stem)
                        .contextMenu { menu(entry) }
                }
            }
        }
        .listStyle(.sidebar)
        // THE SYSTEM ACCENT, NOT GREY. `.tint` does not reach a macOS 13 sidebar's selection, and
        // a user-chosen accent overrides an app's own; grey would mean a hand-drawn list again.
        .onDeleteCommand { model.selectedClip.map { actions.remove($0.stem) } }
    }

    /// Refused clips stay listed with their reason but cannot be selected: there is nothing to
    /// grade in them.
    private var selection: Binding<String?> {
        Binding(
            get: { model.selectedClip?.stem },
            set: { stem in
                guard let stem, let entry = clips.entries.first(where: { $0.stem == stem }),
                    entry.isUsable
                else { return }
                model.selectedClip = entry
            })
    }

    /// A clip reads as its frame first: that is how a person recognises it.
    private func row(_ entry: ClipList.Entry) -> some View {
        HStack(spacing: Space.s) {
            thumbnail(entry)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.stem)
                    .font(.body.monospacedDigit())
                    .foregroundColor(Palette.ink)
                Text(entry.verdict.description)
                    .font(.caption)
                    .foregroundColor(entry.isUsable ? Palette.inkSecondary : Palette.lamp)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            ExportBadge(job: queue.jobs.last(where: { $0.stem == entry.stem }))
        }
        .padding(.vertical, 2)
        .help(entry.fields?.summary ?? entry.verdict.description)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func menu(_ entry: ClipList.Entry) -> some View {
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([entry.url]) }
        if entry.isUsable {
            Button("Export") {
                model.selectedClip = entry
                actions.export(.selected)
            }
        }
        Divider()
        Button("Remove") { actions.remove(entry.stem) }
    }

    private func thumbnail(_ entry: ClipList.Entry) -> some View {
        Group {
            if let image = entry.thumbnail {
                Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fill)
            } else {
                Rectangle().fill(Palette.well)
            }
        }
        .frame(width: Self.thumbnailWidth, height: Self.thumbnailHeight)
        .clipShape(RoundedRectangle(cornerRadius: 3))
    }
}

/// A clip's last export on its row, so a batch can be read from the list without opening the
/// Export tab.
private struct ExportBadge: View {
    let job: RenderQueue.Job?

    var body: some View {
        switch job?.state {
        case .running:
            if let fraction = job?.fractionDone {
                ProgressView(value: fraction).progressViewStyle(.circular).controlSize(.small)
                    .help("Exporting, \(Int(fraction * 100))%")
            } else {
                ProgressView().controlSize(.small).help("Exporting")
            }
        case .waiting:
            Image(systemName: "clock").foregroundColor(Palette.inkTertiary).help(
                "Waiting to export")
        case .done:
            Image(systemName: "checkmark.circle").foregroundColor(Palette.inkSecondary)
                .help("Exported")
        case .failed, .skipped:
            Image(systemName: "exclamationmark.triangle").foregroundColor(Palette.lamp)
                .help("Not exported — see the Export tab")
        case .cancelled, nil:
            EmptyView()
        }
    }
}

/// The engine's own complaints, named before anything is rendered.
private struct ProblemsSection: View {
    let problems: [String]

    var body: some View {
        if !problems.isEmpty {
            Section("Problems") {
                ForEach(problems.indices, id: \.self) { i in
                    Label(problems[i], systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundColor(Palette.lamp)
                }
            }
        }
    }
}
