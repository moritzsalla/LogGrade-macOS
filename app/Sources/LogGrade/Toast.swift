import SwiftUI

/// A short message that appears, says one thing, and leaves.
///
/// WHAT IT IS FOR. An export finishes while you are looking somewhere else — used to be visible
/// only as a row changing colour in the queue panel, which you may not have open — and a project
/// that failed to save or open needs saying, not just refusing. A notification that dismisses
/// itself is what macOS uses for exactly this — something worth knowing, not worth interrupting
/// for. NOT for a clip's first decode: the controls going live is that moment's own notice, and a
/// toast in the corner only sat on top of them (`GradeModel.refreshSource`).
struct Toast: Identifiable, Equatable {
    let id = UUID()
    let symbol: String
    let title: String
    let detail: String?
}

final class Toaster: ObservableObject {
    @Published private(set) var current: Toast?
    private var dismissal: DispatchWorkItem?

    /// Always called on the main queue: every caller is either a SwiftUI action or a completion
    /// the model already hopped to main. Asserted rather than assumed, because a published write
    /// from another thread is a crash that only happens on someone else's machine.
    func show(_ symbol: String, _ title: String, _ detail: String? = nil) {
        dispatchPrecondition(condition: .onQueue(.main))
        dismissal?.cancel()
        withAnimation(.easeOut(duration: 0.18)) {
            current = Toast(symbol: symbol, title: title, detail: detail)
        }
        // Four seconds: long enough to read two lines, short enough not to sit over the picture
        // while you work. It is never the only place something is reported.
        let job = DispatchWorkItem { [weak self] in
            withAnimation(.easeIn(duration: 0.22)) { self?.current = nil }
        }
        dismissal = job
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: job)
    }

    func dismiss() {
        dismissal?.cancel()
        withAnimation(.easeIn(duration: 0.15)) { current = nil }
    }
}

struct ToastView: View {
    @ObservedObject var toaster: Toaster

    var body: some View {
        if let toast = toaster.current {
            HStack(spacing: Space.s) {
                Image(systemName: toast.symbol)
                    .font(Type.symbol)
                    .foregroundColor(Palette.plate)
                VStack(alignment: .leading, spacing: 1) {
                    Text(toast.title).font(Type.label).foregroundColor(Palette.ink)
                    if let detail = toast.detail {
                        Text(detail).font(Type.caption).foregroundColor(Palette.inkSecondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Space.m)
            .padding(.vertical, Space.s + 2)
            .frame(width: 300, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Palette.panel)
                    .shadow(color: .black.opacity(0.45), radius: 12, y: 4)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Palette.hairline, lineWidth: 1)
            )
            .onTapGesture { toaster.dismiss() }
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}
