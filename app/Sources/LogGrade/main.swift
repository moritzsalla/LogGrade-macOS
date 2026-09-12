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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("LogGrade").font(.largeTitle)
            if let engine {
                Text("engine: \(engine.root.path)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            } else {
                Text("no engine found").foregroundStyle(.red)
            }
            if engine == nil {
                // NOT "ready". An empty problem list means nothing was checked when there is no
                // engine to check, and reporting that as ready is the fail-open shape this whole
                // preflight exists to avoid — it is what the first build of this window did.
                Text("nothing to run: point LOGGRADE_ENGINE at a checkout, or rebuild the bundle")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.orange)
            } else if problems.isEmpty {
                Text("preflight: ready").foregroundStyle(.green)
            } else {
                // Named, not summarised. "Could not render" is the message the preflight exists to
                // replace, and the engine's own refusals cite the file that carries the reason.
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(problems.indices, id: \.self) { i in
                        Text(problems[i].description)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.orange)
                    }
                }
            }
            Spacer()
        }
        .padding(24)
        .frame(minWidth: 520, minHeight: 320, alignment: .topLeading)
    }
}

let engine = EngineLocation.locate()
let problems = engine?.preflight() ?? []

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 620, height: 380),
    styleMask: [.titled, .closable, .miniaturizable, .resizable],
    backing: .buffered,
    defer: false)
window.title = "LogGrade"
window.center()
window.contentView = NSHostingView(rootView: RootView(engine: engine, problems: problems))
window.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)
app.run()
