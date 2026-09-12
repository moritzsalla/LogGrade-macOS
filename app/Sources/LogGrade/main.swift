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
    @ObservedObject var queue: RenderQueue
    var grade: GradeModel?

    var body: some View {
        HSplitView {
            clipColumn.frame(minWidth: 240, idealWidth: 264, maxWidth: 340)
            if let grade {
                PreviewView(model: grade).frame(minWidth: 320)
                InspectorView(model: grade).frame(minWidth: 372, maxWidth: 420)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("no engine").font(.system(size: 13, weight: .medium))
                        .foregroundColor(Palette.ink)
                    Text("point LOGGRADE_ENGINE at a checkout, or rebuild the bundle.")
                        .font(.system(size: 11)).foregroundColor(Palette.inkSecondary)
                    Spacer()
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .background(Palette.surround)
            }
        }
        .frame(minWidth: 1080, minHeight: 660)
        .background(Palette.surround)
    }

    private var clipColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text("LogGrade")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(Palette.ink)
                if let engine {
                    Text(engine.root.path)
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundColor(Palette.inkTertiary)
                        .lineLimit(2).truncationMode(.head)
                }
                ForEach(problems.indices, id: \.self) { i in
                    Text(problems[i].description)
                        .font(.system(size: 10.5)).foregroundColor(Palette.lamp)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 10)

            if let grade {
                HStack(spacing: 10) {
                    Button("open project") { openProject(grade) }
                        .buttonStyle(.borderless).font(.system(size: 11))
                    Button("save project") { saveProject(grade) }
                        .buttonStyle(.borderless).font(.system(size: 11))
                    if let url = grade.projectURL {
                        Text(url.lastPathComponent)
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundColor(Palette.inkTertiary)
                            .lineLimit(1).truncationMode(.head)
                    }
                }
                .padding(.horizontal, 16).padding(.bottom, 12)
            }

            dropZone.padding(.horizontal, 16)

            if clips.entries.isEmpty {
                Spacer()
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(clips.entries) { entry in clipRow(entry) }
                    }
                    .padding(.top, 14)
                }
            }
            if let grade {
                Divider().overlay(Palette.hairline)
                DeliveryPanel(model: grade)
                Divider().overlay(Palette.hairline)
                QueuePanel(model: grade, queue: queue)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Palette.panel)
    }

    private var dropZone: some View {
        RoundedRectangle(cornerRadius: 3)
            .strokeBorder(Palette.hairline, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            .frame(height: 56)
            .overlay(
                Text("drop Apple Log clips")
                    .font(.system(size: 11))
                    .foregroundColor(Palette.inkTertiary))
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                // Real paths, which is the reason this is an app and not a page: a browser drop
                // hands over bytes, and the engine needs a location.
                for provider in providers {
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in
                        guard let url else { return }
                        DispatchQueue.main.async {
                            for added in clips.add([url]) {
                                clips.loadThumbnail(for: added.stem)
                                selectIfNothingSelected(added)
                            }
                            grade?.clipNames = clips.usable.map(\.stem)
                            grade?.clipEntries = clips.usable
                        }
                    }
                }
                return true
            }
    }

    /// A clip reads as its frame first: that is how a person recognises it. The selected one is
    /// marked on its leading edge in the colour this tool measures, rather than by a filled row,
    /// so nothing bright sits next to a photograph.
    private func clipRow(_ entry: ClipList.Entry) -> some View {
        let selected = grade?.selectedClip?.stem == entry.stem
        return HStack(alignment: .top, spacing: 10) {
            Rectangle()
                .fill(selected ? Palette.plate : Color.clear)
                .frame(width: 2)
            thumbnail(entry)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.stem)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(Palette.ink)
                Text(entry.verdict.description)
                    .font(.system(size: 10))
                    .foregroundColor(entry.isUsable ? Palette.inkSecondary : Palette.lamp)
                    .fixedSize(horizontal: false, vertical: true)
                if let f = entry.fields { Readout(text: f.summary, muted: true) }
            }
            Spacer(minLength: 4)
            Button {
                clips.remove(entry.stem)
            } label: {
                Image(systemName: "xmark").font(.system(size: 8))
                    .foregroundColor(Palette.inkTertiary)
            }
            .buttonStyle(.plain)
            .padding(.trailing, 12)
        }
        .padding(.vertical, 9)
        .contentShape(Rectangle())
        .onTapGesture {
            guard entry.isUsable, let grade else { return }
            grade.selectedClip = entry
            grade.renderPreview()
        }
        .overlay(Rectangle().fill(Palette.hairline).frame(height: 1), alignment: .bottom)
    }

    /// A shoot is the unit of work, so it is saved and reopened as one: presets, delivery, and
    /// every clip's crop offset. Without this the crop decisions — the one thing that cannot be
    /// guessed — live only as long as the window is open.
    private func saveProject(_ grade: GradeModel) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = grade.projectURL?.lastPathComponent ?? "shoot.loggrade.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try grade.saveProject(to: url) } catch { NSSound.beep() }
    }

    private func openProject(_ grade: GradeModel) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try grade.openProject(at: url) } catch { NSSound.beep() }
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
                Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fill)
            } else {
                Rectangle().fill(Palette.well)
            }
        }
        .frame(width: 40, height: 71)
        .clipped()
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
            grade?.clipNames = clips.usable.map(\.stem)
            grade?.clipEntries = clips.usable
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
// The window is part of the room: a light title bar beside a graded frame is a bright object in
// the field of view, which is the thing a grading suite is dark to avoid.
window.appearance = NSAppearance(named: .darkAqua)
window.titlebarAppearsTransparent = true
window.backgroundColor = NSColor(red: 0.098, green: 0.098, blue: 0.098, alpha: 1)
// Remembered between launches: where the window was, and what was open. Setting the frame
// autosave name makes macOS keep the size and position; the rest is a handful of defaults.
window.setFrameAutosaveName("LogGradeMain")
if window.frame.origin == .zero { window.center() }
let clipList = ClipList(probe: EngineLocation.resolveTool("ffprobe").map(ClipProbe.init))

// The look the app opens on is the engine's own look.json: the shipped grade, which is a look
// that works rather than a set of generic defaults. The Bench learned that lesson first.
let gradeModel: GradeModel? = engine.flatMap { e in
    (try? Look(data: Data(contentsOf: e.lookFile))).map { GradeModel(engine: e, look: $0) }
}
// THE KEYBOARD. A grading tool lives under the fingers: you look, you nudge, you compare, you move
// to the next clip, and reaching for a mouse between each of those is the difference between a tool
// and a form. A local monitor rather than a menu because this app has no menu bar to hang
// shortcuts on, and because C has to be held rather than pressed.
NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { event in
    guard let grade = gradeModel else { return event }
    // A key pressed while typing in a field belongs to the field.
    if window.firstResponder is NSTextView { return event }
    let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
    if event.type == .keyUp {
        if key == "c" { grade.isComparing = false }
        return event
    }
    switch key {
    case "c":
        grade.isComparing = grade.comparisonImage != nil
        return nil
    case "p", " ":
        grade.renderPreview()
        return nil
    case "[":
        grade.step(-1, in: clipList.usable)
        return nil
    case "]":
        grade.step(1, in: clipList.usable)
        return nil
    default:
        return event
    }
}

let renderQueue = RenderQueue(engine: engine ?? EngineLocation(root: URL(fileURLWithPath: "/")))

// Reopen the last project, so a shoot in progress is still in progress tomorrow. Its crop offsets
// are the part that cannot be recovered by guessing.
if let grade = gradeModel,
   let remembered = UserDefaults.standard.url(forKey: "lastProject"),
   FileManager.default.fileExists(atPath: remembered.path) {
    try? grade.openProject(at: remembered)
}
// A stored zero means "never set", not "none at once": integer(forKey:) cannot tell those apart,
// and taking it literally quietly halved the default.
let storedConcurrency = UserDefaults.standard.integer(forKey: "concurrency")
renderQueue.concurrency = storedConcurrency > 0 ? storedConcurrency : 2

let delegate = AppDelegate(clips: clipList, grade: gradeModel)
app.delegate = delegate
window.contentView = NSHostingView(rootView: RootView(engine: engine, problems: problems,
                                                      clips: clipList, queue: renderQueue,
                                                      grade: gradeModel))
window.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)
app.run()
