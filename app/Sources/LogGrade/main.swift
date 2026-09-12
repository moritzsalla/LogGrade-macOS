import AppKit
import GradeKit
import SwiftUI

// A bare executable rather than a bundle, so `swift run` works from a terminal and the build stays
// scriptable. app/make-app.sh wraps this same binary into LogGrade.app with an Info.plist, which
// is what makes it behave like an application — a dock icon, a menu bar, and the ability to be a
// drop target in the Finder.
//
// NSApplication is driven by hand instead of using the @main App lifecycle, because that lifecycle
// assumes a bundle: without one, the window opens behind everything and never takes focus.
struct RootView: View {
    let engine: EngineLocation?
    let problems: [EngineLocation.Problem]
    @ObservedObject var clips: ClipList

    var grade: GradeModel?

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 14) {
                header
                dropZone
                if !clips.entries.isEmpty { clipTable }
                Spacer()
            }
            .padding(16)
            .frame(minWidth: 300)

            if let grade {
                PreviewView(model: grade).padding(16).frame(minWidth: 280)
                InspectorView(model: grade).frame(minWidth: 330)
            } else {
                Text("no engine, so nothing to grade with")
                    .foregroundStyle(.secondary).padding()
            }
        }
        .frame(minWidth: 1040, minHeight: 620)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("LogGrade").font(.title)
            if let engine {
                Text(engine.root.path)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            if engine == nil {
                Text("nothing to run: point LOGGRADE_ENGINE at a checkout, or rebuild the bundle")
                    .font(.caption).foregroundStyle(.orange)
            } else if !problems.isEmpty {
                ForEach(problems.indices, id: \.self) { i in
                    Text(problems[i].description).font(.caption).foregroundStyle(.orange)
                }
            }
        }
    }

    private var dropZone: some View {
        RoundedRectangle(cornerRadius: 10)
            .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
            .foregroundStyle(.secondary)
            .frame(height: 76)
            .overlay(Text("drop Apple Log clips here").foregroundStyle(.secondary))
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                // Real paths, which is the whole reason this is a native app: a browser drop hands
                // over bytes, not a location, and the engine needs a location.
                for provider in providers {
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in
                        guard let url else { return }
                        DispatchQueue.main.async {
                            for added in clips.add([url]) {
                                clips.loadThumbnail(for: added.stem)
                                selectIfNothingSelected(added)
                            }
                        }
                    }
                }
                return true
            }
    }

    private var clipTable: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(clips.entries) { entry in
                    HStack(alignment: .top, spacing: 10) {
                        thumbnail(entry)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.stem).font(.system(.body, design: .monospaced))
                            // The verdict, in full. A refused clip stays in the list carrying its
                            // reason: a file that vanishes when dropped reads as a broken
                            // interface, and the reason is what the person needs.
                            Text(entry.verdict.description)
                                .font(.caption)
                                .foregroundStyle(entry.isUsable ? .green : .orange)
                                .fixedSize(horizontal: false, vertical: true)
                            if let f = entry.fields {
                                Text(f.summary)
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if entry.isUsable {
                            Button(grade?.selectedClip?.stem == entry.stem ? "selected" : "select") {
                                grade?.selectedClip = entry
                                grade?.renderPreview()
                            }
                            .buttonStyle(.borderless)
                        }
                        Button("remove") { clips.remove(entry.stem) }.buttonStyle(.borderless)
                    }
                    Divider()
                }
            }
        }
    }

    /// Drop a clip and it is the one being graded. Making someone click "select" first is a step
    /// with no decision in it, and the whole app is shaped around the drop.
    private func selectIfNothingSelected(_ entry: ClipList.Entry) {
        guard let grade, grade.selectedClip == nil, entry.isUsable else { return }
        grade.selectedClip = entry
        grade.renderPreview()
    }

    private func thumbnail(_ entry: ClipList.Entry) -> some View {
        Group {
            if let image = entry.thumbnail {
                Image(decorative: image, scale: 1)
                    .resizable().aspectRatio(contentMode: .fit)
            } else {
                RoundedRectangle(cornerRadius: 4).fill(.quaternary)
            }
        }
        .frame(width: 44, height: 78)
    }
}

/// Files handed over by the Finder, which is the affordance the Info.plist's document type
/// promises: drop clips on the dock icon, or Open With. Declaring the type without handling the
/// message is a promise the app does not keep — the Finder accepted the drop and nothing happened.
final class AppDelegate: NSObject, NSApplicationDelegate {
    let clips: ClipList
    let grade: GradeModel?
    init(clips: ClipList, grade: GradeModel?) { self.clips = clips; self.grade = grade }

    func application(_ sender: NSApplication, open urls: [URL]) {
        for added in clips.add(urls) {
            clips.loadThumbnail(for: added.stem)
            if let grade, grade.selectedClip == nil, added.isUsable {
                grade.selectedClip = added
                grade.renderPreview()
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)

let engine = EngineLocation.locate()
let problems = engine?.preflight() ?? []

let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 620, height: 380),
    styleMask: [.titled, .closable, .miniaturizable, .resizable],
    backing: .buffered,
    defer: false)
window.title = "LogGrade"
window.center()
let clipList = ClipList(probe: EngineLocation.resolveTool("ffprobe").map(ClipProbe.init))

// The look the app opens on is the engine's own look.json: the shipped grade, which is a look
// that works rather than a set of generic defaults. The Bench learned that lesson first.
let gradeModel: GradeModel? = engine.flatMap { e in
    (try? Look(data: Data(contentsOf: e.lookFile))).map { GradeModel(engine: e, look: $0) }
}
let delegate = AppDelegate(clips: clipList, grade: gradeModel)
app.delegate = delegate
window.contentView = NSHostingView(rootView: RootView(engine: engine, problems: problems,
                                                      clips: clipList, grade: gradeModel))
window.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)
app.run()
