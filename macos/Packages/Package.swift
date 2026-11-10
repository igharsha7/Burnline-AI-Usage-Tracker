// swift-tools-version: 6.2
//
//  Package.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

// The five Burnline modules, as one local package so `swift test` exercises all
// of them without Xcode. The dependency edges below are the architecture's
// import rule; ArchitectureTests re-checks it against the source, because the
// compiler alone does not reliably reject an undeclared import between targets
// of the same package.

import PackageDescription

/// Approachable Concurrency, applied everywhere. Main-actor default isolation is
/// deliberately not here: a library ships nonisolated API and lets the caller
/// decide where work runs.
let approachableConcurrency: [SwiftSetting] = [
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
]

/// Views and their view models run on the main actor, so the UI module opts in.
let mainActorByDefault: [SwiftSetting] = approachableConcurrency + [
    .defaultIsolation(MainActor.self),
]

let package = Package(
    name: "BurnlinePackages",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "BurnlineCore", targets: ["BurnlineCore"]),
        .library(name: "BurnlineStore", targets: ["BurnlineStore"]),
        .library(name: "BurnlineProviders", targets: ["BurnlineProviders"]),
        .library(name: "BurnlineServices", targets: ["BurnlineServices"]),
        .library(name: "BurnlineUI", targets: ["BurnlineUI"]),
    ],
    dependencies: [
        // MIT, so AGPL-compatible. A wrapper over SQLite, not a replacement: the
        // file stays a plain SQLite database any platform can open.
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.11.1"),
        // BSD-3-Clause (dual-licensed with GPLv2; used under BSD), so
        // AGPL-compatible. Codex compresses archived sessions with zstd, and
        // macOS has no zstd decoder of its own. Pinned: it is C, built from source.
        .package(url: "https://github.com/facebook/zstd.git", exact: "1.5.7"),
        // Apache-2.0, so AGPL-compatible. Plays the Streaks card's fire, a
        // Lottie animation, which SwiftUI has no player for.
        .package(url: "https://github.com/airbnb/lottie-spm.git", from: "4.6.1"),
        // MIT, so AGPL-compatible. In-app updates: checks a signed feed of
        // versions and installs a new one, verified against Burnline's key.
        .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.10.1"),
    ],
    targets: [
        .target(name: "BurnlineCore",
                swiftSettings: approachableConcurrency),
        .target(name: "BurnlineStore",
                dependencies: ["BurnlineCore", .product(name: "GRDB", package: "GRDB.swift")],
                swiftSettings: approachableConcurrency),
        .target(name: "BurnlineProviders",
                dependencies: ["BurnlineCore", "BurnlineStore", .product(name: "libzstd", package: "zstd")],
                swiftSettings: approachableConcurrency),
        .target(name: "BurnlineServices",
                dependencies: ["BurnlineCore", "BurnlineStore", "BurnlineProviders"],
                swiftSettings: approachableConcurrency),
        .target(name: "BurnlineUI",
                dependencies: ["BurnlineCore", "BurnlineServices", .product(name: "Lottie", package: "lottie-spm"),
                               .product(name: "Sparkle", package: "Sparkle")],
                // The providers' marks, the Streaks card's pixel font and its
                // fire, kept as published and outside the license (see their
                // READMEs).
                resources: [.copy("ProviderLogos"), .copy("Fonts"), .copy("Animations")],
                swiftSettings: mainActorByDefault),

        // Scratch directories that clean themselves up. Tests only; no
        // product exposes it, so it never reaches the app.
        .target(name: "BurnlineTestSupport",
                swiftSettings: approachableConcurrency),

        .testTarget(name: "BurnlineCoreTests",
                    dependencies: ["BurnlineCore"],
                    swiftSettings: approachableConcurrency),
        .testTarget(name: "BurnlineStoreTests",
                    dependencies: ["BurnlineTestSupport", "BurnlineCore", "BurnlineStore"],
                    swiftSettings: approachableConcurrency),
        .testTarget(name: "BurnlineProvidersTests",
                    dependencies: ["BurnlineTestSupport", "BurnlineCore", "BurnlineStore", "BurnlineProviders",
                                   .product(name: "libzstd", package: "zstd")],
                    swiftSettings: approachableConcurrency),
        .testTarget(name: "BurnlineServicesTests",
                    dependencies: ["BurnlineTestSupport", "BurnlineCore", "BurnlineStore", "BurnlineProviders", "BurnlineServices"],
                    swiftSettings: approachableConcurrency),
        .testTarget(name: "BurnlineUITests",
                    dependencies: ["BurnlineTestSupport", "BurnlineCore", "BurnlineStore", "BurnlineProviders",
                                   "BurnlineServices", "BurnlineUI"],
                    swiftSettings: mainActorByDefault),
        .testTarget(name: "ArchitectureTests",
                    swiftSettings: approachableConcurrency),
    ]
)
