// swift-tools-version: 6.4

import PackageDescription

// Upcoming-feature flags that tighten the language, applied to every target.
//
// Warnings-as-errors is deliberately not set here. SwiftPM honours a manifest
// warning setting when a package is used through a path dependency, so a
// warning added by a newer compiler would break that client's build.
// `scripts/check.sh` passes the flag on the command line instead.
let languageSettings: [SwiftSetting] = [
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("ImmutableWeakCaptures"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("InternalImportsByDefault"),
    .enableUpcomingFeature("MemberImportVisibility"),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
]

let package = Package(
    name: "xitdb-swift",
    platforms: [
        .macOS(.v26),
        .iOS(.v26),
    ],
    products: [
        .library(name: "XitDB", targets: ["XitDB"])
    ],
    dependencies: [
        // Build-time only: the command plugin that builds the documentation. No
        // target uses it, so nothing from it is linked into the library and
        // clients of the package do not fetch it (D15). Checked over the network
        // on 2026-11-07: a client package depending on this one by path resolved
        // and built with no Package.resolved, no checkout and no mention of the
        // plugin in its workspace state.
        .package(url: "https://github.com/swiftlang/swift-docc-plugin", from: "1.5.0")
    ],
    targets: [
        .target(
            name: "XitDB",
            swiftSettings: languageSettings + [.strictMemorySafety()]
        ),
        // The benchmark of spec/benchmarks.md. An executable target is an
        // implicit product, so a client could build it; nothing outside this
        // package is meant to, and it brings no dependency.
        .executableTarget(
            name: "XitDBBenchmark",
            dependencies: ["XitDB"],
            swiftSettings: languageSettings
        ),
        .testTarget(
            name: "XitDBTests",
            dependencies: ["XitDB"],
            exclude: ["Resources/fixtures-source.txt"],
            resources: [
                .copy("Resources/test.db"),
                .copy("Resources/fixtures"), .copy("Resources/port-differs"),
            ],
            swiftSettings: languageSettings
        ),
        // Every code block of the README, the articles and the tutorials, as a test
        // that runs it, importing the library as a client does: the proof that the
        // public surface is enough for what the documentation shows.
        .testTarget(
            name: "XitDBExamples",
            dependencies: ["XitDB"],
            swiftSettings: languageSettings
        ),
    ],
    swiftLanguageModes: [.v6]
)
