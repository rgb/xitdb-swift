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
        .library(name: "XitDB", targets: ["XitDB"]),
        .library(name: "XitDBHashing", targets: ["XitDBHashing"]),
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
        // The hashes a store names: SHA-256 and SHA-1 as CryptoKit's where it
        // exists and as the portable implementations where it does not, and
        // SipHash-128; each conforms to XitDB's KeyHashing. No dependency: the
        // package takes none (D15).
        .target(
            name: "XitDBHashing",
            dependencies: ["XitDB"],
            swiftSettings: languageSettings + [.strictMemorySafety()]
        ),
        // The benchmark of spec/benchmarks.md. An executable target is an
        // implicit product, so a client could build it; nothing outside this
        // package is meant to, and it brings no dependency.
        .executableTarget(
            name: "XitDBBenchmark",
            dependencies: ["XitDB", "XitDBHashing"],
            swiftSettings: languageSettings
        ),
        // The corruption fuzzer, which checks that a damaged file gives an error
        // and never a trap or a hang (R23): a tool for the gate and for
        // `scripts/fuzz.sh`, and no more meant for a client than the benchmark.
        .executableTarget(
            name: "XitDBFuzz",
            dependencies: ["XitDB", "XitDBHashing"],
            swiftSettings: languageSettings
        ),
        .testTarget(
            name: "XitDBHashingTests",
            dependencies: ["XitDBHashing"],
            swiftSettings: languageSettings
        ),
        .testTarget(
            name: "XitDBTests",
            dependencies: ["XitDB", "XitDBHashing"],
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
        // The examples hash with CryptoKit where it exists, as the articles'
        // readers on Apple platforms do, and with XitDBHashing where it does not.
        .testTarget(
            name: "XitDBExamples",
            dependencies: ["XitDB", "XitDBHashing"],
            swiftSettings: languageSettings
        ),
    ],
    swiftLanguageModes: [.v6]
)
