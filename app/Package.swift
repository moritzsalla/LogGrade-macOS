// swift-tools-version:5.9
//
// PINNED DELIBERATELY, and a bats test greps these two lines. Xcode 15.2 is the newest release for
// this machine's macOS, which caps Swift at 5.9 and the SDK at 14.2. The risk is one-directional:
// a session on a newer Mac that raises the tools version or reaches for a newer API leaves the
// always-available machine unable to build at all. See CLAUDE.md.
//
// SwiftPM RATHER THAN AN .xcodeproj. The plan said to commit a project file to avoid adding a
// build tool; authoring a pbxproj by hand is worse than either option, and Xcode opens a
// Package.swift natively — so nothing is lost, `swift build` and `swift test` work from a
// terminal, and the app bundle is assembled by app/make-app.sh.
import PackageDescription

let package = Package(
    name: "LogGrade",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "GradeKit", targets: ["GradeKit"]),
        .executable(name: "LogGrade", targets: ["LogGrade"]),
    ],
    targets: [
        .target(name: "GradeKit"),
        .executableTarget(name: "LogGrade", dependencies: ["GradeKit"]),
        .testTarget(name: "GradeKitTests", dependencies: ["GradeKit"]),
    ]
)
