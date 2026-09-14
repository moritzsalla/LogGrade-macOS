import AppKit
import GradeKit

/// The things the app does that are not a view: bring clips in, open and save a shoot.
///
/// WHY A CLASS AND NOT VIEW CODE. Each of these now has two callers — a control in the window and
/// an item in the menu bar — and a SwiftUI view is a struct that is rebuilt constantly, so a menu
/// item cannot hold one. Keeping them here also means there is exactly ONE door for clips: a drop
/// on the window, the startup screen's button, File ▸ Add Clips and files handed over by the Finder
/// or the dock all arrive at `take`, which is what stopped the last two import bugs from being
/// three. The Finder's door was a copy in `AppDelegate` until it was routed here.
final class AppActions {
    private let clips: ClipList
    private let grade: GradeModel?
    private let queue: RenderQueue
    private let toaster: Toaster

    init(clips: ClipList, grade: GradeModel?, queue: RenderQueue, toaster: Toaster) {
        self.clips = clips
        self.grade = grade
        self.queue = queue
        self.toaster = toaster
    }

    /// Every clip that enters the app enters here.
    func take(_ urls: [URL]) {
        for added in clips.add(urls) {
            guard let grade, grade.selectedClip == nil, added.isUsable else { continue }
            grade.selectedClip = added
            grade.renderPreview()
        }
    }

    func chooseClips() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.prompt = "Add"
        if panel.runModal() == .OK { take(panel.urls) }
    }

    /// A shoot is the unit of work, so it is saved and reopened as one: presets, delivery, and
    /// every clip's crop offset. Without this the crop decisions — the one thing that cannot be
    /// guessed — live only as long as the window is open.
    func saveProject() {
        guard let grade else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = grade.projectURL?.lastPathComponent ?? "shoot.loggrade.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try grade.saveProject(to: url)
        } catch {
            // SAID, not beeped. A beep is indistinguishable from a key the window refused, and a
            // shoot's crop decisions that were not saved are the one loss this panel exists to stop.
            toaster.show("exclamationmark.triangle.fill", "Project not saved",
                         String(describing: error))
        }
    }

    func openProject() {
        guard grade != nil else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openProject(at: url)
    }

    /// The panel, the startup screen's Reopen and the reopen at launch all land here, so none of
    /// them can fail without saying so.
    func openProject(at url: URL) {
        guard let grade else { return }
        do {
            try grade.openProject(at: url)
        } catch {
            toaster.show("exclamationmark.triangle.fill",
                         "Couldn’t open \(url.lastPathComponent)", String(describing: error))
        }
    }

    func convert() { grade?.convert(queue: queue) }
    func step(_ direction: Int) { grade?.step(direction, in: clips.usable) }
}
