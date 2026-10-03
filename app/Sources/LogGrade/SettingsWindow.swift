import AppKit
import GradeKit
import SwiftUI

/// App ▸ Settings… (⌘,). Only what is set once and rarely: a grade's controls stay beside the
/// picture.
///
/// A WINDOW BUILT BY HAND, because SwiftUI's `Settings` scene needs the `App` lifecycle this
/// bundle does not use (main.swift).
final class SettingsWindow {
    private let queue: RenderQueue
    private var window: NSWindow?

    init(queue: RenderQueue) { self.queue = queue }

    func show() {
        if window == nil {
            let made = NSWindow(
                contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered,
                defer: false)
            made.title = "LogGrade Settings"
            made.isReleasedWhenClosed = false
            made.contentView = NSHostingView(rootView: SettingsForm(queue: queue))
            made.center()
            window = made
        }
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct SettingsForm: View {
    @ObservedObject var queue: RenderQueue

    var body: some View {
        Form {
            Picker("Export at once:", selection: concurrency) {
                Text("1 clip").tag(1)
                Text("2 clips").tag(2)
                Text("3 clips").tag(3)
            }
            .disabled(queue.isRunning)
            Text("More at once finishes a batch sooner and makes the Mac busier meanwhile.")
                .font(.caption)
                .foregroundColor(Palette.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Space.xl)
        .frame(width: 380)
    }

    private var concurrency: Binding<Int> {
        Binding(
            get: { queue.concurrency },
            set: {
                queue.concurrency = $0
                UserDefaults.standard.set($0, forKey: DefaultsKey.concurrency)
            })
    }
}
