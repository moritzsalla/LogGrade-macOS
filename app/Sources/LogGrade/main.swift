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

    @ObservedObject var toaster: Toaster

    var body: some View {
        content
            // Top trailing, which is where macOS puts a notification, and clear of both the clip
            // list and the controls.
            .overlay(alignment: .topTrailing) {
                ToastView(toaster: toaster).padding(Space.l)
            }
    }

    private var content: some View {
        // The startup screen stands in for the whole window until there is a clip. An empty
        // three-column layout with a dimmed inspector looks broken rather than empty.
        if clips.entries.isEmpty {
            return AnyView(StartupView(
                problems: problems,
                recentProject: UserDefaults.standard.url(forKey: "lastProject"),
                onOpenProject: { url in try? grade?.openProject(at: url) },
                onChooseFiles: {
                    let panel = NSOpenPanel()
                    panel.allowsMultipleSelection = true
                    panel.canChooseDirectories = true
                    panel.prompt = "Add"
                    if panel.runModal() == .OK { clips.add(panel.urls) }
                }))
        }
        return AnyView(columns)
    }

    private var columns: some View {
        HSplitView {
            clipColumn.frame(minWidth: 240, idealWidth: 264, maxWidth: 340)
            if let grade {
                PreviewView(model: grade, preview: grade.preview).frame(minWidth: 320)
                InspectorView(model: grade).frame(minWidth: 372, maxWidth: 420)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("no engine").font(Type.heading)
                        .foregroundColor(Palette.ink)
                    Text("point LOGGRADE_ENGINE at a checkout, or rebuild the bundle.")
                        .font(Type.label).foregroundColor(Palette.inkSecondary)
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
                        .font(Type.value)
                        .foregroundColor(Palette.inkTertiary)
                        .lineLimit(2).truncationMode(.head)
                }
                ForEach(problems.indices, id: \.self) { i in
                    Text(problems[i].description)
                        .font(Type.caption).foregroundColor(Palette.lamp)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 10)

            if let grade {
                HStack(spacing: 10) {
                    Button("open project") { openProject(grade) }
                        .buttonStyle(.borderless).font(Type.label)
                    Button("save project") { saveProject(grade) }
                        .buttonStyle(.borderless).font(Type.label)
                    if let url = grade.projectURL {
                        Text(url.lastPathComponent)
                            .font(Type.value)
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
                    .font(Type.label)
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
                    .font(Type.value)
                    .foregroundColor(Palette.ink)
                Text(entry.verdict.description)
                    .font(Type.caption)
                    .foregroundColor(entry.isUsable ? Palette.inkSecondary : Palette.lamp)
                    .fixedSize(horizontal: false, vertical: true)
                if let f = entry.fields { Readout(text: f.summary, muted: true) }
            }
            Spacer(minLength: 4)
            Button {
                clips.remove(entry.stem)
            } label: {
                Image(systemName: "xmark").font(Type.caption)
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
    // The crop, by the pixel. Arrow keys only mean the crop while a Feed render is asked for;
    // otherwise they belong to whatever has focus. Shift moves by ten, the way a nudge does
    // everywhere else on this platform.
    if grade.project.delivery.feed, grade.cropGeometry != nil {
        let step = event.modifierFlags.contains(.shift) ? 10 : 1
        if event.keyCode == 126 { grade.nudgeCrop(by: -step); return nil }   // up
        if event.keyCode == 125 { grade.nudgeCrop(by: step); return nil }    // down
    }
    switch key {
    case "c":
        grade.isComparing = grade.preview.comparison != nil
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
let toaster = Toaster()
gradeModel?.toaster = toaster
renderQueue.onFinished = { delivered, failed in
    if failed == 0 {
        toaster.show("checkmark.circle.fill", "Export finished",
                     delivered == 1 ? "1 clip delivered" : "\(delivered) clips delivered")
    } else {
        toaster.show("exclamationmark.triangle.fill", "Export finished with problems",
                     "\(delivered) delivered, \(failed) not — see the queue")
    }
}
window.contentView = NSHostingView(rootView: RootView(engine: engine, problems: problems,
                                                      clips: clipList, queue: renderQueue,
                                                      grade: gradeModel, toaster: toaster))
window.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)
app.run()
