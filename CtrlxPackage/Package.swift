// swift-tools-version: 6.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

/// Packages only consumed by Apple-platform targets (macOS app, iOS app, E2E,
/// GallagerCLI). They are hidden from the Linux SPM graph so the relay's Docker
/// build doesn't waste time resolving them — and so a future bump that requires
/// a newer Swift toolchain doesn't block deploys. The Linux relay only needs
/// Vapor / VaporAPNS / swift-crypto / swift-log / swift-dependencies / Yams (no,
/// Yams is Apple-only via GallagerCLI) — anything else here would be dead weight
/// on the relay build.
///
/// (ProjectNavigator 1.7.0 was the canary: it required Swift 6.2 while the
/// jammy Docker image then shipped Swift 6.1, blocking `swift package resolve`.
/// The relay now pins swift:6.3-jammy — bumped so swift-dependencies' package
/// traits (declared only in its Swift 6.3 manifest) resolve on Linux too — but
/// the same rule holds: keep Apple-only deps off the Linux graph.)
func macOnlyDependencies() -> [Package.Dependency] {
    #if os(macOS)
        return [
            .package(url: "https://github.com/gpambrozio/SFSymbolsMacro", branch: "swift-syntax-602"),
            .package(
                url: "https://github.com/jicezeng/SwiftTerm.git",
                revision: "9597ec7fea4cd51ed6bccdd20f4e462028e955ce"
            ),
            .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.4"),
            .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
            .package(url: "https://github.com/mchakravarty/ProjectNavigator", exact: "1.10.1"),
            .package(url: "https://github.com/gonzalezreal/textual", from: "0.5.0"),
            .package(url: "https://github.com/jpsim/Yams", from: "5.0.0"),
            .package(url: "https://github.com/gpambrozio/GitWorkbench", exact: "1.6.0"),
        ]
    #else
        return []
    #endif
}

/// `#if os(macOS)` does not work *inside* a Target dependency array literal
/// (SPM's manifest parser rejects it as `expected expression in container
/// literal`). So per-target helpers return the slice of Apple-only deps for each
/// consumer; the target's `dependencies:` array concatenates with `+`.
func macOnlyTargetDependencies(for target: String) -> [Target.Dependency] {
    #if os(macOS)
        switch target {
        case "CtrlxCommon":
            return [.sfSymbolsMacro, .swiftTerm]
        case "CtrlxFeature":
            return [.swiftTerm]
        case "CtrlxServerFeature":
            return [.swiftTerm, .sparkle, .textual, .projectNavigator, .files, .gitWorkbench, .gitWorkbenchGitKit]
        case "CtrlxServerFeatureTests":
            return [.swiftTerm]
        case "CtrlxExternalServerTests":
            return [.swiftTerm, "CtrlxCommon"]
        case "CtrlxE2E":
            return [.argumentParser]
        case "GallagerCLI":
            return [.argumentParser, .yams]
        default:
            return []
        }
    #else
        return []
    #endif
}

extension Target.Dependency {
    /// Cross-platform packages — needed by the Linux relay deployable.
    static var vapor: Self {
        .product(name: "Vapor", package: "vapor")
    }

    static var vaporAPNS: Self {
        .product(name: "VaporAPNS", package: "apns")
    }

    static var asyncHTTPClient: Self {
        .product(name: "AsyncHTTPClient", package: "async-http-client")
    }

    static var crypto: Self {
        .product(name: "Crypto", package: "swift-crypto")
    }

    static var logging: Self {
        .product(name: "Logging", package: "swift-log")
    }

    static var dependencies: Self {
        .product(name: "Dependencies", package: "swift-dependencies")
    }

    static var dependenciesMacros: Self {
        .product(name: "DependenciesMacros", package: "swift-dependencies")
    }

    static var dependenciesTestSupport: Self {
        .product(name: "DependenciesTestSupport", package: "swift-dependencies")
    }

    static var clocks: Self {
        .product(name: "Clocks", package: "swift-clocks")
    }

    static var concurrencyExtras: Self {
        .product(name: "ConcurrencyExtras", package: "swift-concurrency-extras")
    }

    // Apple-platform-only packages. The static vars are gated behind
    // `#if os(macOS)` so the manifest itself compiles on Linux (where the
    // referenced packages aren't declared in the dependencies graph). Any
    // target dependency arrays that reference these must use the same gate.
    #if os(macOS)
        static var sfSymbolsMacro: Self {
            .product(name: "SFSymbolsMacro", package: "SFSymbolsMacro")
        }

        static var swiftTerm: Self {
            .product(name: "SwiftTerm", package: "SwiftTerm")
        }

        static var sparkle: Self {
            .product(name: "Sparkle", package: "Sparkle", condition: .when(platforms: [.macOS]))
        }

        static var textual: Self {
            .product(name: "Textual", package: "textual")
        }

        static var argumentParser: Self {
            .product(name: "ArgumentParser", package: "swift-argument-parser")
        }

        static var yams: Self {
            .product(name: "Yams", package: "Yams")
        }

        static var projectNavigator: Self {
            .product(name: "ProjectNavigator", package: "ProjectNavigator")
        }

        static var files: Self {
            .product(name: "Files", package: "ProjectNavigator")
        }

        /// GitWorkbench — the dependency-free SwiftUI git-changes component.
        static var gitWorkbench: Self {
            .product(name: "GitWorkbench", package: "GitWorkbench")
        }

        /// GitWorkbenchGitKit — the ready-made provider backed by the system
        /// `git` CLI (used as the Git tab's `liveValue`).
        static var gitWorkbenchGitKit: Self {
            .product(name: "GitWorkbenchGitKit", package: "GitWorkbench")
        }
    #endif

    static var ctrlxNetworking: Self {
        "CtrlxNetworking"
    }

    static var gallagerPluginProtocol: Self {
        "GallagerPluginProtocol"
    }

    static var claudeCodePluginCore: Self {
        "ClaudeCodePluginCore"
    }

    static var stopFinalityDataset: Self {
        "StopFinalityDataset"
    }

    static var codexPluginCore: Self {
        "CodexPluginCore"
    }

    static var ctrlxCommon: Self {
        "CtrlxCommon"
    }

    /// Foundation-only emoji table + keyword search, shared by the picker UI
    /// (CtrlxCommon) and the CLI (Gallager). No resources — the data is
    /// baked into source (no Bundle.module for the bare GallagerCLI copied
    /// into the app bundle). NOTE: because this target is shared by the app
    /// and the CLI executable, Xcode links it as a dynamic framework; the
    /// copy phase adds an rpath so the bundled CLI finds it — see
    /// docs/superpowers/specs/2026-07-03-emoji-data-shipping-design.md
    /// before restructuring.
    static var gallagerEmoji: Self {
        "GallagerEmoji"
    }

    static var ctrlxEncryption: Self {
        "CtrlxEncryption"
    }

    static var ctrlxFeature: Self {
        "CtrlxFeature"
    }

    static var ctrlxServerFeature: Self {
        "CtrlxServerFeature"
    }

    static var ctrlxExternalServer: Self {
        "CtrlxExternalServer"
    }

    static var ctrlxExternalServerLib: Self {
        "CtrlxExternalServerLib"
    }

    static var ctrlxE2ELib: Self {
        "CtrlxE2ELib"
    }
}

/// Products, dependencies, and targets are extracted into typed top-level `let`s
/// so the manifest type-checker can resolve each in isolation. Inlining all three
/// inside the `Package(...)` call exceeds the Linux Swift 6.x type-checker
/// heuristic and fails the relay's Docker build with "the compiler is unable to
/// type-check this expression in reasonable time."
let products: [Product] = [
    // Products define the executables and libraries a package produces, making them visible to other packages.
    .library(
        name: "CtrlxNetworking",
        targets: ["CtrlxNetworking"]
    ),
    .library(
        name: "GallagerPluginProtocol",
        targets: ["GallagerPluginProtocol"]
    ),
    .library(
        name: "ClaudeCodePluginCore",
        targets: ["ClaudeCodePluginCore"]
    ),
    .library(
        name: "CodexPluginCore",
        targets: ["CodexPluginCore"]
    ),
    .library(
        name: "CtrlxCommon",
        targets: ["CtrlxCommon"]
    ),
    .library(
        name: "GallagerEmoji",
        targets: ["GallagerEmoji"]
    ),
    .library(
        name: "CtrlxEncryption",
        targets: ["CtrlxEncryption"]
    ),
    .library(
        name: "CtrlxFeature",
        targets: ["CtrlxFeature"]
    ),
    .library(
        name: "CtrlxServerFeature",
        targets: ["CtrlxServerFeature"]
    ),
    .executable(
        name: "CtrlxExternalServer",
        targets: ["CtrlxExternalServer"]
    ),
    .library(
        name: "CtrlxExternalServerLib",
        targets: ["CtrlxExternalServerLib"]
    ),
    .executable(
        name: "CtrlxE2E",
        targets: ["CtrlxE2E"]
    ),
    .executable(
        name: "GallagerCLI",
        targets: ["GallagerCLI"]
    ),
    .executable(
        name: "EchoPluginSidecar",
        targets: ["EchoPluginSidecar"]
    ),
    .executable(
        name: "StopFinalityEval",
        targets: ["StopFinalityEval"]
    ),
]

let packageDependencies: [Package.Dependency] = [
    .package(url: "https://github.com/vapor/vapor", from: "4.0.0"),
    .package(url: "https://github.com/vapor/apns.git", from: "5.0.0"),
    .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.21.0"),
    .package(url: "https://github.com/apple/swift-crypto.git", from: "4.5.1"),
    .package(url: "https://github.com/apple/swift-log.git", from: "1.14.0"),
    // Only `Clocks` + `Foundation` traits are enabled — the app's built-in
    // dependency values are `\.continuousClock` (Clocks) and `\.date`
    // (Foundation, added for PluginUpdateManager's testable "now"). Dropping the
    // default `CombineSchedulers`/`FoundationNetworking` traits removes the
    // combine-schedulers package from the graph; Foundation is a system module,
    // not an extra package, so enabling it doesn't grow the dependency graph.
    // Requires a Swift 6.3+ toolchain (the only swift-dependencies manifest that
    // declares traits is its 6.3 one); the relay Dockerfile is pinned to
    // swift:6.3 to match.
    .package(url: "https://github.com/pointfreeco/swift-dependencies", from: "1.14.1", traits: ["Clocks", "Foundation"]),
    .package(url: "https://github.com/pointfreeco/swift-clocks", from: "1.0.4"),
    .package(url: "https://github.com/pointfreeco/swift-concurrency-extras", from: "1.0.0"),
] + macOnlyDependencies()

let targets: [Target] = [
    // Targets are the basic building blocks of a package, defining a module or a test suite.
    // Targets can depend on other targets in this package and products from dependencies.

    // Platform-agnostic networking models (no SwiftUI dependencies)
    // Used by external server on Linux and by Apple platform apps
    .target(
        name: "CtrlxNetworking",
        dependencies: [
            .ctrlxEncryption,
        ]
    ),
    // The durable plugin contract: PluginCore / PluginHost / IngressFrame /
    // value types / manifest. Cross-platform; depends only on networking models.
    .target(
        name: "GallagerPluginProtocol",
        dependencies: [
            .ctrlxNetworking,
        ]
    ),
    .target(
        name: "CtrlxCommon",
        dependencies: [
            .ctrlxNetworking,
            .ctrlxEncryption,
            .gallagerEmoji,
            .logging,
        ] + macOnlyTargetDependencies(for: "CtrlxCommon")
    ),
    // Foundation-only emoji table + keyword search (issue #630). Shared by the
    // picker UI and the CLI so "trash" → 🗑️ everywhere. Data is generated by
    // scripts/generate-emoji-data.py into EmojiData.swift (no runtime bundle).
    .target(
        name: "GallagerEmoji"
    ),
    // Per-agent plugin cores. Each conforms to PluginCore and owns all
    // agent-specific logic (scanner, installer, translator, keystrokes,
    // settings). Only the registry in CtrlxServerFeature names these
    // concrete types — the dispatcher/runtime stay agent-neutral (spec §4.1).
    .target(
        name: "ClaudeCodePluginCore",
        dependencies: [
            .gallagerPluginProtocol,
            .ctrlxNetworking,
            .ctrlxCommon,
            .dependencies,
            .dependenciesMacros,
        ]
    ),
    .target(
        name: "CodexPluginCore",
        dependencies: [
            .gallagerPluginProtocol,
            .ctrlxNetworking,
            .ctrlxCommon,
            // Shares the migrated Claude hook-parsing types (HookAction/HookEvent
            // /*Body/ClaudeCodeTool/AnyCodable + AskUserQuestion keystroke helper);
            // Codex hook payloads parse through the same enum (spec §16).
            .claudeCodePluginCore,
            .dependencies,
            .dependenciesMacros,
        ]
    ),
    // End-to-end encryption module using CryptoKit (Apple) / Swift Crypto (Linux)
    .target(
        name: "CtrlxEncryption",
        dependencies: [
            .crypto,
            .dependencies,
            .dependenciesMacros,
        ]
    ),
    .target(
        name: "CtrlxFeature",
        dependencies: [
            .ctrlxNetworking,
            .ctrlxCommon,
            .ctrlxEncryption,
            .dependencies,
            .dependenciesMacros,
        ] + macOnlyTargetDependencies(for: "CtrlxFeature")
    ),
    .target(
        name: "CtrlxServerFeature",
        dependencies: [
            .ctrlxCommon,
            .ctrlxEncryption,
            .gallagerPluginProtocol,
            .claudeCodePluginCore,
            .codexPluginCore,
            .vapor,
            .dependencies,
            .dependenciesMacros,
        ] + macOnlyTargetDependencies(for: "CtrlxServerFeature"),
        resources: [
            .process("Resources"),
            // Bundled plugin manifests/assets, copied verbatim so the per-plugin
            // directory structure (plugins/<id>/plugin.json + assets) survives
            // into CtrlX.app/Contents/Resources (spec §9). `.copy` (not
            // `.process`) keeps the tree and avoids flattening same-named files.
            .copy("PluginBundles/plugins"),
        ]
    ),
    // External server library (all business logic, importable by tests and E2E)
    .target(
        name: "CtrlxExternalServerLib",
        dependencies: [
            .ctrlxNetworking,
            .ctrlxEncryption,
            .vapor,
            .vaporAPNS,
            .asyncHTTPClient,
        ]
    ),
    // External server executable (thin wrapper around library)
    .executableTarget(
        name: "CtrlxExternalServer",
        dependencies: [
            .ctrlxExternalServerLib,
            .vapor,
        ],
        swiftSettings: [
            // Match Docker build flags to catch issues locally before deployment
            .unsafeFlags(["-cross-module-optimization"], .when(configuration: .release)),
        ]
    ),
    // E2E test coordinator library
    .target(
        name: "CtrlxE2ELib",
        dependencies: [
            .ctrlxNetworking,
            .ctrlxServerFeature,
            .ctrlxExternalServerLib,
            // The DSL hook-delivery step builds length-prefixed `IngressFrame`s
            // (and, for the round-trip scenarios, `EchoDirective` payloads) to
            // write to the app's ingress socket — the same codec the app reads.
            .gallagerPluginProtocol,
            .vapor,
            .logging,
        ],
        resources: [
            .copy("Scenarios/Scripts"),
            .copy("Scenarios/SampleFiles"),
        ]
    ),
    // E2E test coordinator executable
    .executableTarget(
        name: "CtrlxE2E",
        dependencies: [
            .ctrlxE2ELib,
        ] + macOnlyTargetDependencies(for: "CtrlxE2E")
    ),
    // CLI for controlling Gallager from the command line (API + editor).
    // Bundled inside the app and invoked via the VISUAL environment variable.
    .executableTarget(
        name: "GallagerCLI",
        dependencies: [
            .gallagerEmoji,
        ] + macOnlyTargetDependencies(for: "GallagerCLI"),
        path: "Sources/Gallager"
    ),
    // Real out-of-process echo sidecar for integration tests (spec §17.3).
    // Reads Content-Length-framed JSON-RPC on stdin; answers each method and
    // emits notifications to stdout. Not gated by #if DEBUG so it ships in
    // Release builds (the executable is a separate product, not linked into
    // the app). Used by EchoPluginSidecarIntegrationTests to prove the full
    // spawn → transport → RPC pipeline through SidecarSupervisor.
    .executableTarget(
        name: "EchoPluginSidecar",
        dependencies: [.gallagerPluginProtocol, .ctrlxNetworking, .logging],
        path: "Sources/EchoPluginSidecar"
    ),
    // Shared dataset for the stop-finality eval (spec
    // docs/superpowers/specs/2026-07-30-stop-finality-evaluations-design.md):
    // committed seed cases (past field failures — the regression suite) ride
    // as a bundled resource; mined cases load from ~/.ctrlx/eval and are
    // never committed (verbatim excerpts from real sessions).
    .target(
        name: "StopFinalityDataset",
        resources: [.copy("Resources/seed-cases.json")]
    ),
    // macOS-26 cross-check + labeling helper for the stop-finality judge
    // (spec docs/superpowers/specs/2026-07-30-stop-finality-evaluations-
    // design.md). Scores the SAME dataset as the StopFinalityEvaluations
    // suite against THIS machine's model — run on the daily (macOS 26) Mac
    // before promoting a prompt tuned on the 27-beta model. Run manually on
    // a Mac with Apple Intelligence (`swift run StopFinalityEval`); CI only
    // compiles it.
    .executableTarget(
        name: "StopFinalityEval",
        dependencies: [.claudeCodePluginCore, .stopFinalityDataset]
    ),
    .testTarget(
        name: "CtrlxNetworkingTests",
        dependencies: [
            "CtrlxNetworking",
            .ctrlxEncryption,
        ]
    ),
    .testTarget(
        name: "GallagerPluginProtocolTests",
        dependencies: [
            .gallagerPluginProtocol,
            .ctrlxNetworking,
        ]
    ),
    .testTarget(
        name: "ClaudeCodePluginCoreTests",
        dependencies: [
            .claudeCodePluginCore,
            .gallagerPluginProtocol,
            .dependenciesTestSupport,
        ]
    ),
    .testTarget(
        name: "StopFinalityDatasetTests",
        dependencies: [.stopFinalityDataset]
    ),
    // Hill-climbing eval for the stop-finality judge on Apple's Evaluations
    // framework (WWDC26 session 335; spec docs/superpowers/specs/
    // 2026-07-30-stop-finality-evaluations-design.md). Compiles to an empty
    // suite on pre-macOS-27 SDKs and CI (#if canImport(Evaluations)); RUNS
    // only on a macOS 27 beta Mac with Apple Intelligence enabled.
    .testTarget(
        name: "StopFinalityEvaluations",
        dependencies: [
            .claudeCodePluginCore,
            .stopFinalityDataset,
        ]
    ),
    .testTarget(
        name: "CodexPluginCoreTests",
        dependencies: [
            .codexPluginCore,
            .claudeCodePluginCore,
            .gallagerPluginProtocol,
            .dependenciesTestSupport,
        ]
    ),
    .testTarget(
        name: "GallagerEmojiTests",
        dependencies: [
            .gallagerEmoji,
        ]
    ),
    .testTarget(
        name: "CtrlxCommonTests",
        dependencies: [
            "CtrlxCommon",
            .dependenciesTestSupport,
            .clocks,
            .concurrencyExtras,
            // Stands up a mute WebSocket server for the half-open liveness watchdog test.
            .vapor,
        ]
    ),
    .testTarget(
        name: "CtrlxEncryptionTests",
        dependencies: [
            "CtrlxEncryption",
            .dependenciesTestSupport,
        ]
    ),
    .testTarget(
        name: "CtrlxFeatureTests",
        dependencies: [
            "CtrlxFeature",
            .dependenciesTestSupport,
        ]
    ),
    .testTarget(
        name: "CtrlxServerFeatureTests",
        dependencies: [
            "CtrlxServerFeature",
            .dependenciesTestSupport,
            .clocks,
            .concurrencyExtras,
            .vapor,
        ] + macOnlyTargetDependencies(for: "CtrlxServerFeatureTests")
    ),
    .testTarget(
        name: "CtrlxExternalServerTests",
        dependencies: [
            .ctrlxExternalServerLib,
            .product(name: "VaporTesting", package: "vapor"),
        ] + macOnlyTargetDependencies(for: "CtrlxExternalServerTests")
    ),
    .testTarget(
        name: "CtrlxE2ETests",
        dependencies: [
            .ctrlxE2ELib,
        ]
    ),
]

let package = Package(
    name: "CtrlxPackage",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: products,
    dependencies: packageDependencies,
    targets: targets
)
