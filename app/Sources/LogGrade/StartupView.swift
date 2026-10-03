import AppKit
import GradeKit
import SwiftUI

/// What you see before there is anything to grade.
///
/// WHY IT EXISTS. The first thing this app needs is a clip, so the picture pane's first job is to
/// say where to put one.
///
/// It also carries the two things worth knowing before a first render, since this is the only
/// moment nobody is busy: what the app expects as input, and whether the engine behind it is
/// actually runnable. A preflight failure discovered here costs a sentence; discovered at convert
/// time it costs a three-minute render.
struct StartupView: View {
    let problems: [String]
    let recentProject: URL?
    let onOpenProject: (URL) -> Void
    let onChooseFiles: () -> Void

    var body: some View {
        VStack(spacing: Space.xl) {
            Spacer()
            VStack(spacing: Space.m) {
                AppMark()
                Text("A grading tool for iPhone ProRes Apple Log footage.")
                    .font(Type.label)
                    .foregroundColor(Palette.inkSecondary)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: Space.s) {
                Button(action: onChooseFiles) {
                    Label("Add Clips…", systemImage: "plus")
                        .frame(width: 190)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)

                if let recent = recentProject {
                    Button {
                        onOpenProject(recent)
                    } label: {
                        Label(
                            "Reopen \(recent.deletingPathExtension().lastPathComponent)",
                            systemImage: "clock.arrow.circlepath"
                        )
                        .frame(width: 190)
                    }
                    .controlSize(.large)
                    .buttonStyle(.bordered)
                }

                Text("or drag clips onto this window")
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
                        Text(problems[i])
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
            Text(
                "Apple Log ProRes only. Already-converted footage is refused rather than graded "
                    + "a second time."
            )
            .font(Type.caption)
            .foregroundColor(Palette.inkTertiary)
            .padding(.bottom, Space.xl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.surround)
    }
}

/// The icon and the name.
struct AppMark: View {
    var body: some View {
        VStack(spacing: Space.m) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)
            Text("LogGrade").font(.title2.weight(.semibold))
                .foregroundColor(Palette.ink)
        }
    }
}
