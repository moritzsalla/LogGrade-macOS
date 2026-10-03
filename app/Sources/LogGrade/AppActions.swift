import AppKit
import GradeKit

/// The things the app does that are not a view: bring clips in, open and save a shoot.
///
/// WHY A CLASS AND NOT VIEW CODE. Each of these has several callers — the toolbar, the menu bar, a
/// context menu — and a SwiftUI view is a struct that is rebuilt constantly, so a menu item cannot
/// hold one. Keeping them here also means there is exactly ONE door for clips: a drop on the
/// window, the startup screen's button, File ▸ Add Clips and files handed over by the Finder or
/// the dock all arrive at `take`, which is what stopped the last two import bugs from being three.
final class AppActions {
    private let clips: ClipList
    private let grade: GradeModel?
    private let queue: RenderQueue
    /// Where alerts are attached, as sheets.
    weak var window: NSWindow?

    init(clips: ClipList, grade: GradeModel?, queue: RenderQueue) {
        self.clips = clips
        self.grade = grade
        self.queue = queue
        grade?.reportProblem = { [weak self] title, detail in self?.alert(title, detail) }
    }

    /// Every clip that enters the app enters here.
    func take(_ urls: [URL]) {
        for added in clips.add(urls) {
            guard let grade, grade.selectedClip == nil, added.isUsable else { continue }
            grade.selectedClip = added
        }
    }

    /// The neighbour takes the selection, so the keyboard can keep removing.
    func remove(_ stem: String) {
        let usable = clips.usable
        guard let (entry, position) = clips.remove(stem) else { return }
        // The clip's grade and framing stay in the project, so putting it back restores them.
        window?.undoManager?.registerUndo(withTarget: self) { $0.restore(entry, at: position) }
        window?.undoManager?.setActionName("Remove Clip")
        guard let grade, grade.selectedClip?.stem == stem else { return }
        let index = usable.firstIndex(where: { $0.stem == stem }) ?? 0
        let rest = usable.filter { $0.stem != stem }
        grade.selectedClip = rest.isEmpty ? nil : rest[min(index, rest.count - 1)]
    }

    private func restore(_ entry: ClipList.Entry, at position: Int) {
        clips.restore(entry, at: position)
        if entry.isUsable { grade?.selectedClip = entry }
        window?.undoManager?.registerUndo(withTarget: self) { $0.remove(entry.stem) }
        window?.undoManager?.setActionName("Remove Clip")
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
            // SAID, not beeped: unsaved crop decisions are the one loss this exists to stop.
            alert("The project couldn’t be saved.", String(describing: error))
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
            alert("“\(url.lastPathComponent)” couldn’t be opened.", String(describing: error))
        }
    }

    func export(_ scope: GradeModel.ExportScope) { grade?.convert(queue: queue, scope) }
    func exportBlocker(_ scope: GradeModel.ExportScope) -> String? {
        grade.map { $0.exportBlocker(queue: queue, scope) } ?? "No look is loaded."
    }
    func step(_ direction: Int) { grade?.step(direction, in: clips.usable) }

    private func alert(_ title: String, _ detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        if let window, window.isVisible {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}
