import AppKit
import GradeKit
import SwiftUI

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
    static let leftArrow: UInt16 = 123
    static let rightArrow: UInt16 = 124
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
// that works rather than a set of generic defaults.
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

// Through the engine, so a bundle probes with the ffprobe it carries.
let ffprobe = engine?.resolveTool("ffprobe") ?? EngineLocation.resolveTool("ffprobe")
let clipList = ClipList(probe: ffprobe.map(ClipProbe.init))

let renderQueue = RenderQueue(engine: engine ?? EngineLocation(root: URL(fileURLWithPath: "/")))
// A stored zero means "never set", not "none at once": integer(forKey:) cannot tell those apart,
// and taking it literally quietly halved the default.
let defaultConcurrency = 2
let storedConcurrency = UserDefaults.standard.integer(forKey: DefaultsKey.concurrency)
renderQueue.concurrency = storedConcurrency > 0 ? storedConcurrency : defaultConcurrency

gradeModel?.clips = clipList
let actions = AppActions(clips: clipList, grade: gradeModel, queue: renderQueue)

let mainWindow = MainWindow(
    sidebar: ClipSidebar(
        problems: problems, clips: clipList, queue: renderQueue, grade: gradeModel,
        actions: actions),
    content: ContentPane(
        engine: engine, problems: problems, clips: clipList, grade: gradeModel, actions: actions),
    inspector: InspectorPane(grade: gradeModel, queue: renderQueue, actions: actions),
    grade: gradeModel, actions: actions)
let window = mainWindow.window
actions.window = window
let settings = SettingsWindow(queue: renderQueue)

// THE KEYBOARD. A grading tool lives under the fingers: you look, you nudge, you compare, you move
// to the next clip, and reaching for a mouse between each of those is the difference between a tool
// and a form. A local monitor rather than the menu bar for the two things a menu item cannot do:
// C has to be held rather than pressed, and the arrows mean the crop only while something crops.
NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { event in
    guard let grade = gradeModel, event.window === window else { return event }
    // A key pressed while typing in a field belongs to the field.
    if window.firstResponder is NSTextView { return event }
    let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
    if event.type == .keyUp {
        if key == "c" { grade.endCompare() }
        return event
    }
    // The crop, by the pixel, only while something that crops is asked for; otherwise the arrows
    // belong to whatever has focus, such as the clip list. Shift moves by ten. Only the two arrows
    // along the axis the window moves: up and down on a portrait clip, left and right on a
    // landscape one.
    if grade.cropIsPerClip, let geometry = grade.cropGeometry {
        let step = event.modifierFlags.contains(.shift) ? 10 : 1
        let (back, forward) =
            geometry.axis == .y
            ? (KeyCode.upArrow, KeyCode.downArrow) : (KeyCode.leftArrow, KeyCode.rightArrow)
        if event.keyCode == back {
            grade.nudgeCrop(by: -step)
            return nil
        }
        if event.keyCode == forward {
            grade.nudgeCrop(by: step)
            return nil
        }
    }
    // ONLY WHAT A MENU CANNOT DO. Compare has to be HELD — pressed and released — and a menu item
    // fires once on selection, so it stays here.
    if key == "c" && event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
        // Key repeat sends keyDown again while held; one compare per press.
        if !event.isARepeat { grade.beginCompare() }
        return nil
    }
    return event
}

// Reopen the last project, so a shoot in progress is still in progress tomorrow. Its crop offsets
// are the part that cannot be recovered by guessing.
if gradeModel != nil,
    let remembered = UserDefaults.standard.url(forKey: DefaultsKey.lastProject),
    FileManager.default.fileExists(atPath: remembered.path)
{
    actions.openProject(at: remembered)
}

let delegate = AppDelegate(actions: actions)
app.delegate = delegate
// Built by hand because the bundle is assembled by a script rather than by Xcode.
let commands = MainMenu.Commands()
MainMenu.install(commands: commands)

// The rows say which clips finished; this only fetches the person back if they went elsewhere.
renderQueue.onFinished = { _, _ in
    if !app.isActive { app.requestUserAttention(.informationalRequest) }
}
// Wired after the model exists, since every one of them needs it.
commands.settings = { settings.show() }
commands.addClips = { actions.chooseClips() }
commands.openProject = { actions.openProject() }
commands.saveProject = { actions.saveProject() }
commands.previousClip = { actions.step(-1) }
commands.nextClip = { actions.step(1) }
commands.exportClip = { actions.export(.selected) }
commands.exportAll = { actions.export(.all) }
commands.toggleSidebar = { mainWindow.toggleSidebar(nil) }
commands.toggleInspector = { mainWindow.toggleInspector(nil) }
commands.isEnabled = { which in
    if which == \.exportClip { return actions.exportBlocker(.selected) == nil }
    if which == \.exportAll { return actions.exportBlocker(.all) == nil }
    if which == \.saveProject { return gradeModel != nil }
    return true
}
commands.title = { which in
    if which == \.toggleSidebar {
        return mainWindow.isSidebarShown ? "Hide Sidebar" : "Show Sidebar"
    }
    if which == \.toggleInspector {
        return mainWindow.isInspectorShown ? "Hide Inspector" : "Show Inspector"
    }
    return nil
}

window.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)
app.run()
