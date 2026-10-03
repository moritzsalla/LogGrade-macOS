import AppKit
import GradeKit
import SwiftUI

/// The three panes of the window, each hosted in its own split view item (`MainWindow`).
///
/// NOT ONE ROOT VIEW. An `HSplitView` could not collapse a pane, put a toggle in the toolbar, or
/// give the sidebar its standard behaviour; an `NSSplitViewController` can, and it takes one view
/// controller per pane.

/// The middle pane: the picture once there is a clip, the empty state before.
struct ContentPane: View {
    let engine: EngineLocation?
    let problems: [String]
    @ObservedObject var clips: ClipList
    /// NOT OBSERVED HERE: see `ClipSidebar.grade`.
    var grade: GradeModel?
    let actions: AppActions

    var body: some View {
        Group {
            if clips.entries.isEmpty {
                StartupView(
                    problems: problems,
                    recentProject: UserDefaults.standard.url(forKey: DefaultsKey.lastProject),
                    onOpenProject: actions.openProject(at:),
                    onChooseFiles: actions.chooseClips)
            } else if let grade {
                PreviewView(model: grade, preview: grade.preview)
            } else {
                EngineMissing(engineFound: engine != nil)
            }
        }
        .frame(minWidth: 360, minHeight: 480)
        .acceptsClips(actions)
    }
}

/// The trailing pane: the grade, or how it leaves. "No Selection" rather than dimmed controls, as
/// Apple's own inspectors do: a column of disabled sliders reads as broken rather than empty.
///
/// EXPORT IS A TAB HERE, NOT A SHEET, because framing is dragged on the picture while these
/// settings are read, and a sheet would cover the picture.
struct InspectorPane: View {
    var grade: GradeModel?
    @ObservedObject var queue: RenderQueue
    let actions: AppActions

    enum Tab: String { case grade, export }
    @AppStorage(DefaultsKey.inspectorTab) private var tab = Tab.grade

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                Text("Grade").tag(Tab.grade)
                Text("Export").tag(Tab.export)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .padding(Space.m)
            Divider()
            Group {
                if let grade {
                    switch tab {
                    case .grade:
                        SelectionGate(model: grade) { InspectorView(model: grade) }
                    case .export:
                        ScrollView {
                            VStack(alignment: .leading, spacing: 0) {
                                DeliveryPanel(model: grade)
                                Divider()
                                QueuePanel(model: grade, queue: queue)
                            }
                        }
                    }
                } else {
                    Placeholder(text: "No Look")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.panel)
        .acceptsClips(actions)
    }
}

/// Shows its content only while a clip is selected, observing the relay so the inspector itself
/// is not rebuilt by unrelated changes.
private struct SelectionGate<Content: View>: View {
    let model: GradeModel
    @ObservedObject private var changes: GradeModel.Changes
    let content: () -> Content

    init(model: GradeModel, @ViewBuilder content: @escaping () -> Content) {
        self.model = model
        _changes = ObservedObject(wrappedValue: model.changes)
        self.content = content
    }

    var body: some View {
        if model.selectedClip == nil {
            Placeholder(text: "No Selection")
        } else {
            content()
        }
    }
}

private struct Placeholder: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.title3)
            .foregroundColor(Palette.inkTertiary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct EngineMissing: View {
    let engineFound: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Text(engineFound ? "No look" : "No engine").font(Type.heading)
                .foregroundColor(Palette.ink)
            Text(
                engineFound
                    ? "The engine’s look.json could not be read. The reason is listed above the "
                        + "clips."
                    : "Point LOGGRADE_ENGINE at a checkout, or rebuild the bundle."
            )
            .font(Type.label).foregroundColor(Palette.inkSecondary)
            Spacer()
        }
        .padding(Space.l)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Palette.surround)
    }
}

extension View {
    /// ON EVERY PANE, so the whole window is the drop target, as it was before the split.
    func acceptsClips(_ actions: AppActions) -> some View {
        onDrop(of: [.fileURL], isTargeted: nil) { providers in
            // Real paths, which is the reason this is an app and not a page: a browser drop hands
            // over bytes, and the engine needs a location.
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    DispatchQueue.main.async { actions.take([url]) }
                }
            }
            return true
        }
    }
}
