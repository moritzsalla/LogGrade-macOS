import AppKit

/// The menu bar.
///
/// IT DID NOT EXIST, AND THAT IS NOT COSMETIC. An NSApplication with no main menu shows the
/// application name and nothing else, and three things people expect from any Mac app silently do
/// not work: ⌘Q does not quit, ⌘W does not close, and — the one that matters most here — ⌘C, ⌘V,
/// ⌘X and ⌘A do nothing in a text field, because the standard editing commands reach a field by
/// travelling up the responder chain FROM a menu item. Every typed readout in this app was
/// therefore type-only, with no way to copy a value out of one or paste one in.
///
/// The menu is built by hand because this app is assembled by a script rather than by Xcode, which
/// would otherwise supply it from a nib.
///
/// WHAT LIVES HERE AND WHAT DOES NOT. Actions with a keyboard shortcut belong in a menu, where
/// they are discoverable and where macOS draws the shortcut next to the name. The one exception is
/// hold-to-compare: a menu item fires on press and this needs press AND release, so it stays on
/// the window's key monitor and is listed here without a shortcut so at least it can be found.
enum MainMenu {
    static func install(commands: Commands) {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        let name = "LogGrade"
        appMenu.addItem(withTitle: "About \(name)",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide \(name)", action: #selector(NSApplication.hide(_:)),
                        keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others",
                                         action: #selector(NSApplication.hideOtherApplications(_:)),
                                         keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All",
                        action: #selector(NSApplication.unhideAllApplications(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit \(name)", action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let fileItem = NSMenuItem()
        let file = NSMenu(title: "File")
        file.addItem(action(commands, "Add Clips…", "o", [.command], \.addClips))
        file.addItem(.separator())
        file.addItem(action(commands, "Open Project…", "o", [.command, .shift], \.openProject))
        file.addItem(action(commands, "Save Project…", "s", [.command], \.saveProject))
        file.addItem(.separator())
        file.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)),
                     keyEquivalent: "w")
        fileItem.submenu = file
        main.addItem(fileItem)

        // THE REASON THE MENU BAR HAD TO EXIST. These four are not implemented here — they carry
        // the standard selectors and no target, so AppKit walks the responder chain and the text
        // field that has focus handles them. Without the menu items there is nothing to walk from.
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)),
                     keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let clipItem = NSMenuItem()
        let clip = NSMenu(title: "Clip")
        clip.addItem(action(commands, "Previous Clip", "[", [.command], \.previousClip))
        clip.addItem(action(commands, "Next Clip", "]", [.command], \.nextClip))
        clip.addItem(.separator())
        // No shortcut: it has to be held, and a menu item cannot express that.
        let compare = NSMenuItem(title: "Compare (hold C)", action: nil, keyEquivalent: "")
        compare.isEnabled = false
        clip.addItem(compare)
        clip.addItem(.separator())
        clip.addItem(action(commands, "Convert", "\r", [.command], \.convert))
        clipItem.submenu = clip
        main.addItem(clipItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)),
                           keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)),
                           keyEquivalent: "")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)

        NSApp.mainMenu = main
        NSApp.windowsMenu = windowMenu
    }

    /// The app's own actions, held as closures so this file knows nothing about the model.
    final class Commands: NSObject {
        var addClips: () -> Void = {}
        var openProject: () -> Void = {}
        var saveProject: () -> Void = {}
        var previousClip: () -> Void = {}
        var nextClip: () -> Void = {}
        var convert: () -> Void = {}

        @objc fileprivate func run(_ sender: NSMenuItem) {
            (sender.representedObject as? () -> Void)?()
        }
    }

    private static func action(_ commands: Commands, _ title: String, _ key: String,
                               _ modifiers: NSEvent.ModifierFlags,
                               _ which: KeyPath<Commands, () -> Void>) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(Commands.run(_:)), keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = commands
        // Captured lazily, so the closure the menu runs is whatever the app has set by the time
        // somebody picks it rather than whatever was set when the menu was built.
        item.representedObject = { [weak commands] in commands?[keyPath: which]() } as () -> Void
        return item
    }
}
