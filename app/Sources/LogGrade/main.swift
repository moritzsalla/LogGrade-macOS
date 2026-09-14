import AppKit
import GradeKit
import SwiftUI

/// The window: the startup screen until there is a clip, then clips, picture and inspector.
struct RootView: View {
    let engine: EngineLocation?
    /// Already in words. The engine's preflight and a look.json that would not parse are both
    /// reasons nothing will render, and the person needs the reason rather than its type.
    let problems: [String]
    @ObservedObject var clips: ClipList
    @ObservedObject var queue: RenderQueue
    /// NOT OBSERVED HERE, which is why every read of its state sits in a subview that observes it.
    /// An optional cannot be an @ObservedObject, and reading `selectedClip` or `projectURL` in this
    /// body left the selection marker and the project name stale until something this view does
    /// observe happened to change.
    var grade: GradeModel?

    @ObservedObject var toaster: Toaster
    let actions: AppActions

    private static let thumbnailWidth: CGFloat = 40
    /// The clips' portrait 9:16, derived rather than typed.
    private static let thumbnailHeight = (thumbnailWidth * 16 / 9).rounded()

    var body: some View {
        content
            // ON THE WHOLE WINDOW, not on a dashed box inside one column. The startup screen says
            // "or drag them onto this window" and it replaces that column entirely, so the only
            // drop target in the app disappeared exactly when it was being advertised.
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in accept(providers) }
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
                recentProject: UserDefaults.standard.url(forKey: DefaultsKey.lastProject),
                onOpenProject: actions.openProject(at:),
                onChooseFiles: actions.chooseClips))
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
                    Text(engine == nil ? "no engine" : "no look").font(Type.heading)
                        .foregroundColor(Palette.ink)
                    Text(engine == nil
                         ? "point LOGGRADE_ENGINE at a checkout, or rebuild the bundle."
                         : "The engine’s look.json could not be read. The reason is listed above "
                           + "the clips.")
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
                    .font(Type.title)
                    .foregroundColor(Palette.ink)
                if let engine {
                    Text(engine.root.path)
                        .font(Type.value)
                        .foregroundColor(Palette.inkTertiary)
                        .lineLimit(2).truncationMode(.head)
                }
                ForEach(problems.indices, id: \.self) { i in
                    Text(problems[i])
                        .font(Type.caption).foregroundColor(Palette.lamp)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 10)

            if let grade {
                HStack(spacing: 10) {
                    Button("open project") { actions.openProject() }
                        .buttonStyle(.borderless).font(Type.label)
                    Button("save project") { actions.saveProject() }
                        .buttonStyle(.borderless).font(Type.label)
                    ProjectName(model: grade)
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
    }

    /// Takes a drop of file URLs. Real paths, which is the reason this is an app and not a page: a
    /// browser drop hands over bytes, and the engine needs a location.
    private func accept(_ providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                DispatchQueue.main.async { actions.take([url]) }
            }
        }
        return true
    }

    /// A clip reads as its frame first: that is how a person recognises it. The selected one is
    /// marked on its leading edge in the colour this tool measures, rather than by a filled row,
    /// so nothing bright sits next to a photograph.
    private func clipRow(_ entry: ClipList.Entry) -> some View {
        HStack(alignment: .top, spacing: 10) {
            if let grade {
                SelectionMark(model: grade, stem: entry.stem)
            } else {
                Color.clear.frame(width: SelectionMark.width)
            }
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

    private func thumbnail(_ entry: ClipList.Entry) -> some View {
        Group {
            if let image = entry.thumbnail {
                Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fill)
            } else {
                Rectangle().fill(Palette.well)
            }
        }
        .frame(width: Self.thumbnailWidth, height: Self.thumbnailHeight)
        .clipped()
    }
}

/// The selected clip's edge marker, observing the model itself — see `RootView.grade`.
private struct SelectionMark: View {
    @ObservedObject var model: GradeModel
    let stem: String

    static let width: CGFloat = 2

    var body: some View {
        Rectangle()
            .fill(model.selectedClip?.stem == stem ? Palette.plate : Color.clear)
            .frame(width: Self.width)
    }
}

/// The open project's file name, observing the model itself — see `RootView.grade`.
private struct ProjectName: View {
    @ObservedObject var model: GradeModel

    var body: some View {
        if let url = model.projectURL {
            Text(url.lastPathComponent)
                .font(Type.value)
                .foregroundColor(Palette.inkTertiary)
                .lineLimit(1).truncationMode(.head)
        }
    }
}

/// Files handed over by the Finder, which is the affordance the Info.plist's document type
/// promises: drop clips on the dock icon, or Open With. Declaring the type without handling the
/// message is a promise the app does not keep — the Finder accepted the drop and nothing happened.
final class AppDelegate: NSObject, NSApplicationDelegate {
    let actions: AppActions
    init(actions: AppActions) { self.actions = actions }

    func application(_ sender: NSApplication, open urls: [URL]) { actions.take(urls) }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }
}

/// The two virtual key codes the crop nudge answers to, as `Carbon.HIToolbox` numbers them.
private enum KeyCode {
    static let upArrow: UInt16 = 126
    static let downArrow: UInt16 = 125
}

// A bare executable rather than a bundle, so `swift run` works from a terminal and the build stays
// scriptable. app/make-app.sh wraps this same binary into LogGrade.app with an Info.plist, which
// is what makes it behave like an application — a dock icon, a menu bar, and the ability to be a
// drop target in the Finder.
//
// NSApplication is driven by hand instead of using the @main App lifecycle, because that lifecycle
// assumes a bundle: without one, the window opens behind everything and never takes focus.
let app = NSApplication.shared
app.setActivationPolicy(.regular)

let engine = EngineLocation.locate()

// The look the app opens on is the engine's own look.json: the shipped grade, which is a look
// that works rather than a set of generic defaults. The Bench learned that lesson first.
//
// A LOOK THAT WILL NOT PARSE IS NAMED, not folded into "no engine". Swallowing the error sent
// people to LOGGRADE_ENGINE when the checkout was found and only its look.json was broken.
var lookProblem: String?
let gradeModel: GradeModel? = engine.flatMap { e in
    do {
        return GradeModel(engine: e, look: try Look(data: Data(contentsOf: e.lookFile)))
    } catch {
        lookProblem = "look.json could not be read: \(error)"
        return nil
    }
}
let problems = (engine?.preflight() ?? []).map(\.description) + (lookProblem.map { [$0] } ?? [])

// Sized for the startup screen, which is what a first launch shows; the three columns declare
// their own minimum in `RootView.columns`.
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
window.backgroundColor = NSColor(Palette.surround)
// Remembered between launches: where the window was, and what was open. Setting the frame
// autosave name makes macOS keep the size and position; the rest is a handful of defaults.
window.setFrameAutosaveName("LogGradeMain")
if window.frame.origin == .zero { window.center() }
let clipList = ClipList(probe: EngineLocation.resolveTool("ffprobe").map(ClipProbe.init))

// THE KEYBOARD. A grading tool lives under the fingers: you look, you nudge, you compare, you move
// to the next clip, and reaching for a mouse between each of those is the difference between a tool
// and a form. A local monitor rather than the menu bar for the two things a menu item cannot do:
// C has to be held rather than pressed, and the arrows mean the crop only while something crops.
NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { event in
    guard let grade = gradeModel else { return event }
    // A key pressed while typing in a field belongs to the field.
    if window.firstResponder is NSTextView { return event }
    let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
    if event.type == .keyUp {
        if key == "c" { grade.isComparing = false }
        return event
    }
    // The crop, by the pixel. Arrow keys only mean the crop while something that crops is asked
    // for; otherwise they belong to whatever has focus. Shift moves by ten, the way a nudge does
    // everywhere else on this platform.
    if grade.project.delivery.anyTargetCrops, grade.cropGeometry != nil {
        let step = event.modifierFlags.contains(.shift) ? 10 : 1
        if event.keyCode == KeyCode.upArrow { grade.nudgeCrop(by: -step); return nil }
        if event.keyCode == KeyCode.downArrow { grade.nudgeCrop(by: step); return nil }
    }
    // ONLY WHAT A MENU CANNOT DO. Compare has to be HELD — pressed and released — and a menu item
    // fires once on selection, so it stays here. Everything else moved to the menu bar, where
    // macOS draws the shortcut beside the name and people can find it without being told.
    if key == "c" {
        grade.isComparing = grade.preview.comparison != nil
        return nil
    }
    return event
}

let renderQueue = RenderQueue(engine: engine ?? EngineLocation(root: URL(fileURLWithPath: "/")))
// A stored zero means "never set", not "none at once": integer(forKey:) cannot tell those apart,
// and taking it literally quietly halved the default.
let defaultConcurrency = 2
let storedConcurrency = UserDefaults.standard.integer(forKey: DefaultsKey.concurrency)
renderQueue.concurrency = storedConcurrency > 0 ? storedConcurrency : defaultConcurrency

gradeModel?.clips = clipList
// The toaster before the actions, because a failed open or save is reported through it.
let toaster = Toaster()
gradeModel?.toaster = toaster
let actions = AppActions(clips: clipList, grade: gradeModel, queue: renderQueue, toaster: toaster)

// Reopen the last project, so a shoot in progress is still in progress tomorrow. Its crop offsets
// are the part that cannot be recovered by guessing.
if gradeModel != nil,
   let remembered = UserDefaults.standard.url(forKey: DefaultsKey.lastProject),
   FileManager.default.fileExists(atPath: remembered.path) {
    actions.openProject(at: remembered)
}

let delegate = AppDelegate(actions: actions)
app.delegate = delegate
// THE MENU BAR, which this app did not have. Without it ⌘Q does not quit and the standard
// editing commands never reach a text field, because they travel up the responder chain from a
// menu item. Built by hand because the bundle is assembled by a script rather than by Xcode.
let commands = MainMenu.Commands()
MainMenu.install(commands: commands)

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
                                                      grade: gradeModel, toaster: toaster,
                                                      actions: actions))
// Wired after the model exists, since every one of them needs it.
commands.addClips = { actions.chooseClips() }
commands.openProject = { actions.openProject() }
commands.saveProject = { actions.saveProject() }
commands.previousClip = { actions.step(-1) }
commands.nextClip = { actions.step(1) }
commands.convert = { actions.convert() }

window.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)
app.run()
