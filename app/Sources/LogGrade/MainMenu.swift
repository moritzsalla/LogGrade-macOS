import AppKit

/// The menu bar, in the HIG's order: App, File, Edit, View, Clip, Window, Help.
///
/// NOT COSMETIC. Without it ⌘Q does not quit, ⌘W does not close, and ⌘C, ⌘V, ⌘X and ⌘A do nothing
/// in a text field, because the standard editing commands reach a field by travelling up the
/// responder chain FROM a menu item. Every toolbar item is here too, which is what makes it
/// reachable from the keyboard.
///
/// Built by hand because this app is assembled by a script rather than by Xcode, which would
/// otherwise supply it from a nib.
///
/// The one exception is hold-to-compare: a menu item fires on press and this needs press AND
/// release, so it stays on the window's key monitor and is listed here so at least it can be found.
enum MainMenu {
    typealias Command = KeyPath<Commands, () -> Void>

    static func install(commands: Commands) {
        let main = NSMenu()
        let name = "LogGrade"

        let appMenu = submenu(of: main, "")
        appMenu.addItem(
            withTitle: "About \(name)",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(action(commands, "Settings…", ",", [.command], \.settings))
        appMenu.addItem(.separator())
        let services = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        services.submenu = NSMenu(title: "Services")
        NSApp.servicesMenu = services.submenu
        appMenu.addItem(services)
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "Hide \(name)", action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h")
        let hideOthers = appMenu.addItem(
            withTitle: "Hide Others",
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(
            withTitle: "Show All",
            action: #selector(NSApplication.unhideAllApplications(_:)),
            keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "Quit \(name)", action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q")

        let file = submenu(of: main, "File")
        file.addItem(action(commands, "Add Clips…", "o", [.command], \.addClips))
        file.addItem(.separator())
        file.addItem(action(commands, "Open Project…", "o", [.command, .shift], \.openProject))
        let recent = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        recent.submenu = NSMenu(title: "Open Recent")
        recent.submenu?.delegate = commands
        file.addItem(recent)
        file.addItem(action(commands, "Save Project…", "s", [.command], \.saveProject))
        file.addItem(.separator())
        file.addItem(
            withTitle: "Close", action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w")

        // THE REASON THE MENU BAR HAD TO EXIST. These carry the standard selectors and no target,
        // so AppKit walks the responder chain and the text field that has focus handles them.
        let edit = submenu(of: main, "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: "")
        edit.addItem(
            withTitle: "Select All", action: #selector(NSText.selectAll(_:)),
            keyEquivalent: "a")

        let view = submenu(of: main, "View")
        let toolbar = view.addItem(
            withTitle: "Show Toolbar", action: #selector(NSWindow.toggleToolbarShown(_:)),
            keyEquivalent: "t")
        toolbar.keyEquivalentModifierMask = [.command, .option]
        view.addItem(action(commands, "Hide Sidebar", "s", [.command, .control], \.toggleSidebar))
        view.addItem(
            action(commands, "Hide Inspector", "i", [.command, .option], \.toggleInspector))
        view.addItem(.separator())
        let fullScreen = view.addItem(
            withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)),
            keyEquivalent: "f")
        fullScreen.keyEquivalentModifierMask = [.command, .control]

        let clip = submenu(of: main, "Clip")
        clip.addItem(action(commands, "Previous Clip", "[", [.command], \.previousClip))
        clip.addItem(action(commands, "Next Clip", "]", [.command], \.nextClip))
        clip.addItem(.separator())
        // No shortcut: it has to be held, and a menu item cannot express that.
        let compare = NSMenuItem(title: "Compare (Hold C)", action: nil, keyEquivalent: "")
        compare.isEnabled = false
        clip.addItem(compare)
        clip.addItem(.separator())
        clip.addItem(action(commands, "Export Clip", "\r", [.command], \.exportClip))
        clip.addItem(action(commands, "Export All Clips", "\r", [.command, .shift], \.exportAll))

        // The presets are fixed (docs/BACKLOG.md), so their items are built once.
        let look = submenu(of: main, "Look")
        for (i, name) in commands.presetNames.enumerated() {
            let item = NSMenuItem(
                title: name, action: #selector(Commands.pickPreset(_:)),
                keyEquivalent: i < 9 ? String(i + 1) : "")
            item.target = commands
            item.representedObject = name
            look.addItem(item)
        }
        look.addItem(.separator())
        look.addItem(action(commands, "Reset Adjustments", "", [], \.resetAdjustments))

        let windowMenu = submenu(of: main, "Window")
        windowMenu.addItem(
            withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)),
            keyEquivalent: "m")
        windowMenu.addItem(
            withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)),
            keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(
            withTitle: "Bring All to Front",
            action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")

        // Empty but present: macOS adds its menu search field here.
        let help = submenu(of: main, "Help")

        NSApp.mainMenu = main
        NSApp.windowsMenu = windowMenu
        NSApp.helpMenu = help
    }

    private static func submenu(of main: NSMenu, _ title: String) -> NSMenu {
        let item = NSMenuItem()
        let menu = NSMenu(title: title)
        item.submenu = menu
        main.addItem(item)
        return menu
    }

    /// The app's own actions, held as closures so this file knows nothing about the model.
    final class Commands: NSObject, NSMenuItemValidation, NSMenuDelegate {
        var settings: () -> Void = {}
        var addClips: () -> Void = {}
        var openProject: () -> Void = {}
        var saveProject: () -> Void = {}
        var toggleSidebar: () -> Void = {}
        var toggleInspector: () -> Void = {}
        var previousClip: () -> Void = {}
        var nextClip: () -> Void = {}
        var exportClip: () -> Void = {}
        var exportAll: () -> Void = {}
        var resetAdjustments: () -> Void = {}

        var presetNames: [String] = []
        var currentPreset: () -> String? = { nil }
        var applyPreset: (String) -> Void = { _ in }
        var openRecent: (URL) -> Void = { _ in }

        /// Asked each time a menu opens, so an item is disabled rather than hidden (HIG).
        var isEnabled: (Command) -> Bool = { _ in true }
        /// A title that follows state, such as Show/Hide Sidebar; nil keeps the item's own.
        var title: (Command) -> String? = { _ in nil }

        @objc fileprivate func run(_ sender: NSMenuItem) {
            guard let which = sender.representedObject as? CommandBox else { return }
            self[keyPath: which.command]()
        }

        @objc fileprivate func pickPreset(_ sender: NSMenuItem) {
            (sender.representedObject as? String).map(applyPreset)
        }

        @objc fileprivate func pickRecent(_ sender: NSMenuItem) {
            (sender.representedObject as? URL).map(openRecent)
        }

        @objc fileprivate func clearRecent(_ sender: NSMenuItem) { RecentProjects.clear() }

        func menuNeedsUpdate(_ menu: NSMenu) { MainMenu.fillRecent(menu, self) }

        func validateMenuItem(_ item: NSMenuItem) -> Bool {
            if let preset = item.representedObject as? String {
                let current = currentPreset()
                item.state = preset == current ? .on : .off
                return current != nil
            }
            guard let which = item.representedObject as? CommandBox else { return true }
            if let title = title(which.command) { item.title = title }
            return isEnabled(which.command)
        }
    }

    /// Rebuilt each time it opens, so it lists what is on disk now.
    private static func fillRecent(_ menu: NSMenu, _ commands: Commands) {
        menu.removeAllItems()
        for url in RecentProjects.urls {
            let item = NSMenuItem(
                title: MainWindow.projectName(url), action: #selector(Commands.pickRecent(_:)),
                keyEquivalent: "")
            item.target = commands
            item.representedObject = url
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Clear Menu", action: #selector(Commands.clearRecent(_:)), keyEquivalent: ""
        ).target = commands
    }

    /// A key path in an object, which is what `representedObject` can hold.
    private final class CommandBox {
        let command: Command
        init(_ command: Command) { self.command = command }
    }

    private static func action(
        _ commands: Commands, _ title: String, _ key: String,
        _ modifiers: NSEvent.ModifierFlags, _ which: Command
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(Commands.run(_:)), keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = commands
        // A key path, so the closure run is whatever the app has set by the time somebody picks
        // it rather than whatever was set when the menu was built.
        item.representedObject = CommandBox(which)
        return item
    }
}
