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
    targets: [
        .target(
            name: "XitDB",
            swiftSettings: languageSettings + [.strictMemorySafety()]
        ),
        .testTarget(
            name: "XitDBTests",
            dependencies: ["XitDB"],
            swiftSettings: languageSettings
        ),
    ],
    swiftLanguageModes: [.v6]
)
