// The half of app/drive/loggrade.sh that needs a macOS API: permissions, window ids, the
// accessibility tree, pressing a control, a clean quit. Compiled once by loggrade.sh and cached by
// the source's hash; `swift ax.swift` would recompile it on every call, several seconds each.
//
// Everything targets a PID, never the name "LogGrade": the user's own copy of the app from the main
// checkout may be running beside the one under test, and both are called LogGrade.
import AppKit
import ApplicationServices
import CoreGraphics

func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(1)
}

func attr(_ el: AXUIElement, _ name: String) -> AnyObject? {
    var value: AnyObject?
    return AXUIElementCopyAttributeValue(el, name as CFString, &value) == .success ? value : nil
}

func text(_ el: AXUIElement, _ name: String) -> String {
    guard let v = attr(el, name) else { return "" }
    if let s = v as? String { return s }
    if let n = v as? NSNumber { return n.stringValue }
    return ""
}

func frame(_ el: AXUIElement) -> CGRect? {
    guard let p = attr(el, kAXPositionAttribute), let s = attr(el, kAXSizeAttribute) else {
        return nil
    }
    var point = CGPoint.zero
    var size = CGSize.zero
    AXValueGetValue(p as! AXValue, .cgPoint, &point)
    AXValueGetValue(s as! AXValue, .cgSize, &size)
    return CGRect(origin: point, size: size)
}

func children(_ el: AXUIElement) -> [AXUIElement] {
    (attr(el, kAXChildrenAttribute) as? [AXUIElement]) ?? []
}

/// Title, description, identifier and value: SwiftUI puts a button's words in the title, an
/// icon-only button's in the description, and a label's in the value, so a match looks at all four.
func words(_ el: AXUIElement) -> [String] {
    [kAXTitleAttribute, kAXDescriptionAttribute, kAXIdentifierAttribute, kAXValueAttribute]
        .map { text(el, $0) }
}

func line(_ el: AXUIElement) -> String {
    let names = ["", "desc=", "id=", "val="]
    var out = text(el, kAXRoleAttribute)
    for (name, word) in zip(names, words(el)) where !word.isEmpty {
        let short = word.count > 60 ? String(word.prefix(60)) + "…" : word
        out += " \(name)\"\(short.replacingOccurrences(of: "\n", with: " "))\""
    }
    if let f = frame(el) {
        out += " @\(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))x\(Int(f.height))"
    }
    return out
}

func walk(_ el: AXUIElement, depth: Int = 0, visit: (AXUIElement, Int) -> Bool) {
    guard visit(el, depth), depth < 60 else { return }
    for child in children(el) { walk(child, depth: depth + 1, visit: visit) }
}

func appElement(_ pid: pid_t) -> AXUIElement {
    guard AXIsProcessTrusted() else {
        fail(
            """
            ACCESSIBILITY NOT GRANTED to the app running this shell. The user must add their terminal \
            (or the app hosting Claude Code) in System Settings > Privacy & Security > Accessibility, \
            then restart it.
            """)
    }
    return AXUIElementCreateApplication(pid)
}

func matches(_ pid: pid_t, _ needle: String) -> [AXUIElement] {
    var found: [AXUIElement] = []
    walk(appElement(pid)) { el, _ in
        if words(el).contains(where: { $0.caseInsensitiveCompare(needle) == .orderedSame }) {
            found.append(el)
        }
        return true
    }
    // The window's own control before the menu item of the same name: "Export clip" is both.
    return found.filter { text($0, kAXRoleAttribute) != kAXMenuItemRole }
        + found.filter { text($0, kAXRoleAttribute) == kAXMenuItemRole }
}

/// Polls, because a control appears only once the splash and the first render are done; a fixed
/// sleep is either too short on a cold start or wasted on a warm one.
func waitFor(_ pid: pid_t, _ needle: String, _ timeout: Double) -> [AXUIElement] {
    let deadline = Date().addingTimeInterval(timeout)
    while true {
        let found = matches(pid, needle)
        if !found.isEmpty { return found }
        if Date() > deadline {
            fail("no element titled, described or valued \"\(needle)\" after \(timeout)s")
        }
        usleep(250_000)
    }
}

func windows(_ pid: pid_t) -> [[String: Any]] {
    let all =
        CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
        as? [[String: Any]] ?? []
    return all.filter { ($0[kCGWindowOwnerPID as String] as? pid_t) == pid }
}

func area(_ w: [String: Any]) -> Double {
    let b = w[kCGWindowBounds as String] as? [String: Double] ?? [:]
    return (b["Width"] ?? 0) * (b["Height"] ?? 0)
}

let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else {
    fail(
        "usage: ax perm | windows PID | fit PID | front PID | tree PID | wait PID TEXT [SECS] | press PID TEXT [SECS] | quit PID"
    )
}
let pid = args.count > 1 ? pid_t(args[1]) ?? 0 : 0

switch command {
case "perm":
    // Screen Recording is silent when missing: screencapture still writes a PNG, of the wallpaper.
    print("accessibility=\(AXIsProcessTrusted() ? "yes" : "no")")
    print("screen-recording=\(CGPreflightScreenCaptureAccess() ? "yes" : "no")")

case "windows":
    // Largest first, so the first line is the main window; sheets, popovers and open menus are
    // separate windows of the same PID and follow it.
    for w in windows(pid).sorted(by: { area($0) > area($1) }) {
        let b = w[kCGWindowBounds as String] as? [String: Double] ?? [:]
        let layer = w[kCGWindowLayer as String] as? Int ?? 0
        // x,y,w,h in points: the form `screencapture -R` takes.
        let rect = ["X", "Y", "Width", "Height"].map { String(Int(b[$0] ?? 0)) }.joined(
            separator: ",")
        print("\(w[kCGWindowNumber as String]!)\tlayer=\(layer)\t\(rect)")
    }

case "fit":
    // A second instance cascades from the saved frame and can hang off the bottom of the screen;
    // a mouse click, a region capture or a README shot then misses part of the window.
    guard let screen = NSScreen.main else { fail("no screen") }
    let full = screen.frame
    let visible = screen.visibleFrame
    let top = full.maxY - visible.maxY
    for window in (attr(appElement(pid), kAXWindowsAttribute) as? [AXUIElement]) ?? [] {
        guard let f = frame(window), f.width > 400 else { continue }
        var origin = CGPoint(x: visible.minX, y: top)
        var size = CGSize(width: min(f.width, visible.width), height: min(f.height, visible.height))
        AXUIElementSetAttributeValue(
            window, kAXPositionAttribute as CFString, AXValueCreate(.cgPoint, &origin)!)
        AXUIElementSetAttributeValue(
            window, kAXSizeAttribute as CFString, AXValueCreate(.cgSize, &size)!)
    }

case "front":
    NSRunningApplication(processIdentifier: pid)?.activate(options: [.activateIgnoringOtherApps])

case "tree":
    walk(appElement(pid)) { el, depth in
        // The menu bar is two hundred lines of standard items nobody drives through this tool.
        if text(el, kAXRoleAttribute) == kAXMenuBarRole { return false }
        print(String(repeating: "  ", count: depth) + line(el))
        return true
    }

case "wait":
    guard args.count > 2 else { fail("usage: ax wait PID TEXT [SECS]") }
    let found = waitFor(pid, args[2], args.count > 3 ? Double(args[3]) ?? 15 : 15)
    for el in found { print(line(el)) }

case "press":
    guard args.count > 2 else { fail("usage: ax press PID TEXT [SECS]") }
    let found = waitFor(pid, args[2], args.count > 3 ? Double(args[3]) ?? 15 : 15)
    if found.count > 1 {
        FileHandle.standardError.write(
            "\(found.count) matches, pressing the first:\n".data(using: .utf8)!)
        for el in found {
            FileHandle.standardError.write(("  " + line(el) + "\n").data(using: .utf8)!)
        }
    }
    let target = found[0]
    var actions: CFArray?
    AXUIElementCopyActionNames(target, &actions)
    if ((actions as? [String]) ?? []).contains(kAXPressAction) {
        // AXPress needs neither focus nor a visible window, which is why it beats a mouse click.
        let result = AXUIElementPerformAction(target, kAXPressAction as CFString)
        guard result == .success else { fail("AXPress failed: \(result.rawValue)") }
    } else {
        // A row or a text field has no AXPress. A real click needs the window in front.
        guard let f = frame(target) else { fail("no AXPress and no frame: \(line(target))") }
        NSRunningApplication(processIdentifier: pid)?.activate(options: [.activateIgnoringOtherApps]
        )
        usleep(400_000)
        let centre = CGPoint(x: f.midX, y: f.midY)
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            CGEvent(
                mouseEventSource: nil, mouseType: type, mouseCursorPosition: centre,
                mouseButton: .left)?
                .post(tap: .cghidEventTap)
            usleep(80_000)
        }
    }
    print("pressed: " + line(target))

case "quit":
    guard let running = NSRunningApplication(processIdentifier: pid) else { exit(0) }
    running.terminate()
    // kill(pid, 0), not isTerminated: that property is updated through a run loop this tool never runs.
    let alive = { kill(pid, 0) == 0 }
    let deadline = Date().addingTimeInterval(10)
    while alive() && Date() < deadline { usleep(200_000) }
    // A quit the app did not honour in ten seconds is a stuck export or a modal; the next launch
    // must not attach to it.
    if alive() {
        running.forceTerminate()
        print("did not quit in 10s; force-terminated \(pid)")
    }

default:
    fail("unknown command \(command)")
}
