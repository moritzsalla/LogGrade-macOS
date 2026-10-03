import AppKit
import Combine
import GradeKit
import SwiftUI

/// The window: clips, picture and inspector in a standard split view, under a unified toolbar.
///
/// APPKIT, NOT `NavigationSplitView`. This app drives NSApplication by hand (main.swift), and the
/// split view controller is what gives the sidebar its standard toggle, the toolbar its tracking
/// separator, and the inspector its own collapsible column on macOS 13.
final class MainWindow: NSObject, NSToolbarDelegate, NSToolbarItemValidation {
    let window: NSWindow
    private let split = NSSplitViewController()
    private let sidebarItem: NSSplitViewItem
    private let inspectorItem: NSSplitViewItem
    private let grade: GradeModel?
    private let actions: AppActions
    private var watching: Set<AnyCancellable> = []

    init(
        sidebar: some View, content: some View, inspector: some View, grade: GradeModel?,
        actions: AppActions
    ) {
        self.grade = grade
        self.actions = actions
        sidebarItem = NSSplitViewItem(sidebarWithViewController: Self.host(sidebar))
        sidebarItem.minimumThickness = 220
        sidebarItem.maximumThickness = 340
        let contentItem = NSSplitViewItem(viewController: Self.host(content))
        contentItem.minimumThickness = 360
        inspectorItem = NSSplitViewItem(inspectorWithViewController: Self.host(inspector))
        inspectorItem.minimumThickness = 320
        inspectorItem.maximumThickness = 440
        // The toolbar spans the whole window, so its trailing items sit at the window's edge.
        inspectorItem.allowsFullHeightLayout = false
        split.splitViewItems = [sidebarItem, contentItem, inspectorItem]
        // Divider positions and collapsed panes, remembered between launches.
        split.splitView.autosaveName = "LogGradeSplit"

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1240, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        super.init()

        window.contentViewController = split
        window.toolbarStyle = .unified
        window.titleVisibility = .visible
        // No forced appearance: the window follows the system, and `Palette` adapts with it.
        window.backgroundColor = NSColor(Palette.surround)
        window.minSize = NSSize(width: 960, height: 600)
        let toolbar = NSToolbar(identifier: "LogGradeMain")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.setFrameAutosaveName("LogGradeMain")
        if window.frame.origin == .zero { window.center() }

        updateTitle()
        if let grade {
            grade.$selectedClip.combineLatest(grade.$projectURL)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.updateTitle() }
                .store(in: &watching)
        }
    }

    private static func host(_ view: some View) -> NSViewController {
        let host = NSHostingController(rootView: view)
        // The split view sizes the panes; letting each pane also size the window fought it.
        host.sizingOptions = .minSize
        return host
    }

    /// The clip, which is what the window is showing; the shoot it belongs to underneath. Not the
    /// app's name, which the menu bar already says.
    private func updateTitle() {
        let project = grade?.projectURL.map(Self.projectName)
        if let clip = grade?.selectedClip?.stem {
            window.title = clip
            window.subtitle = project ?? ""
        } else {
            window.title = project ?? "LogGrade"
            window.subtitle = ""
        }
    }

    static func projectName(_ url: URL) -> String {
        url.lastPathComponent.replacingOccurrences(of: ".loggrade.json", with: "")
            .replacingOccurrences(of: ".json", with: "")
    }

    // MARK: - panes

    var isSidebarShown: Bool { !sidebarItem.isCollapsed }
    var isInspectorShown: Bool { !inspectorItem.isCollapsed }

    @objc func toggleSidebar(_ sender: Any?) { split.toggleSidebar(sender) }

    /// By hand: `NSSplitViewController.toggleInspector` is macOS 14.
    @objc func toggleInspector(_ sender: Any?) {
        inspectorItem.animator().isCollapsed.toggle()
    }

    // MARK: - toolbar

    private enum Item {
        static let compare = NSToolbarItem.Identifier("compare")
        static let addClips = NSToolbarItem.Identifier("addClips")
        static let export = NSToolbarItem.Identifier("export")
        static let inspector = NSToolbarItem.Identifier("inspector")
    }

    /// Three groups, as the HIG asks: the sidebar's, the picture's, and the action with the
    /// inspector it opens beside.
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            .toggleSidebar, .sidebarTrackingSeparator, .flexibleSpace,
            Item.compare, Item.addClips, .space, Item.export, Item.inspector,
        ]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(
        _ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: id)
        item.target = self
        switch id {
        case Item.compare:
            item.label = "Compare"
            item.image = NSImage(
                systemSymbolName: "square.split.2x1", accessibilityDescription: "Compare")
            item.toolTip = "Show the look as it ships, without this clip’s adjustments (hold C)"
            item.action = #selector(toggleCompare(_:))
        case Item.addClips:
            item.label = "Add Clips"
            item.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Add Clips")
            item.toolTip = "Add Apple Log clips"
            item.action = #selector(addClips(_:))
        case Item.export:
            item.label = "Export"
            // A word, not a symbol: the window's one action should not need decoding.
            item.title = "Export"
            item.isBordered = true
            item.action = #selector(exportClip(_:))
        case Item.inspector:
            item.label = "Inspector"
            item.image = NSImage(
                systemSymbolName: "sidebar.right", accessibilityDescription: "Inspector")
            item.toolTip = "Show or hide the inspector"
            item.action = #selector(toggleInspector(_:))
        default:
            return nil
        }
        return item
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        switch item.itemIdentifier {
        case Item.export:
            let reason = actions.exportBlocker(.selected)
            item.toolTip = reason ?? "Export the selected clip"
            return reason == nil
        case Item.compare:
            return grade?.selectedClip != nil
        case Item.addClips:
            return true
        default:
            return true
        }
    }

    @objc func toggleCompare(_ sender: Any?) {
        guard let grade else { return }
        if grade.isComparing { grade.endCompare() } else { grade.beginCompare() }
    }

    @objc func addClips(_ sender: Any?) { actions.chooseClips() }
    @objc func exportClip(_ sender: Any?) { actions.export(.selected) }
}
