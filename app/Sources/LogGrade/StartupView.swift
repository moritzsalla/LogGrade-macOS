import AppKit
import GradeKit
import SwiftUI

/// What you see before there is anything to grade.
///
/// WHY IT EXISTS. An empty three-column window with a dimmed inspector is a screen that looks
/// broken rather than empty. The first thing this app needs is a clip, so the first thing it shows
/// is where to put one — the same move Photoshop and the Final Cut library window make, for the
/// same reason: give the empty state one job and say what it is.
///
/// It also carries the two things worth knowing before a first render, since this is the only
/// moment nobody is busy: what the app expects as input, and whether the engine behind it is
/// actually runnable. A preflight failure discovered here costs a sentence; discovered at convert
/// time it costs a three-minute render.
struct StartupView: View {
    let problems: [EngineLocation.Problem]
    let recentProject: URL?
    let onOpenProject: (URL) -> Void
    let onChooseFiles: () -> Void

    var body: some View {
        VStack(spacing: Space.xl) {
            Spacer()
            VStack(spacing: Space.m) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 72, height: 72)
                Text("LogGrade").font(.system(size: 22, weight: .semibold))
                    .foregroundColor(Palette.ink)
                Text("Grade Apple Log clips from an iPhone and deliver them for Instagram.")
                    .font(Type.label)
                    .foregroundColor(Palette.inkSecondary)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: Space.s) {
                Button(action: onChooseFiles) {
                    Label("Choose clips…", systemImage: "photo.badge.plus")
                        .frame(width: 190)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .tint(Palette.plate)

                if let recent = recentProject {
                    Button { onOpenProject(recent) } label: {
                        Label("Reopen \(recent.deletingPathExtension().lastPathComponent)",
                              systemImage: "clock.arrow.circlepath")
                            .frame(width: 190)
                    }
                    .controlSize(.large)
                    .buttonStyle(.bordered)
                }

                Text("or drag them onto this window")
                    .font(Type.caption)
                    .foregroundColor(Palette.inkTertiary)
                    .padding(.top, Space.xs)
            }

            if !problems.isEmpty {
                // NAMED HERE RATHER THAN AT CONVERT TIME. Every one of these stops a render, and
                // finding out at the end of one is the difference between a sentence and an hour.
                VStack(alignment: .leading, spacing: Space.xs) {
                    Label("The engine isn’t ready", systemImage: "exclamationmark.triangle.fill")
                        .font(Type.label)
                        .foregroundColor(Palette.lamp)
                    ForEach(problems.indices, id: \.self) { i in
                        Text(problems[i].description)
                            .font(Type.caption)
                            .foregroundColor(Palette.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(Space.m)
                .frame(width: 420, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Palette.panel))
            }
            Spacer()
            Text("Apple Log ProRes only. Already-converted footage is refused rather than graded "
                 + "a second time.")
                .font(Type.caption)
                .foregroundColor(Palette.inkTertiary)
                .padding(.bottom, Space.xl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.surround)
    }
}
