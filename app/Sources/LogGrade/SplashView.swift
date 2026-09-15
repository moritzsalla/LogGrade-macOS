import AppKit
import SwiftUI

/// A brief mark, not a screen to act on.
///
/// LIKE PHOTOSHOP'S LICENCE SPLASH, not a startup screen: it says what app this is for about a
/// second, then gets out of the way of whatever `RootView` would otherwise show — the empty state
/// with its Choose/Reopen buttons if there are no clips yet, the three columns if there are. It
/// carries no action of its own, so there is nothing here to click past.
struct SplashView: View {
    var body: some View {
        AppMark()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Palette.surround)
    }
}

/// The icon and the name, the one thing this splash and the startup screen both open with —
/// built once so a size or font change cannot update one and miss the other.
struct AppMark: View {
    var body: some View {
        VStack(spacing: Space.m) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 72, height: 72)
            Text("LogGrade").font(Type.splash)
                .foregroundColor(Palette.ink)
        }
    }
}
