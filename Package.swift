// swift-tools-version:6.0
import PackageDescription

// Tagen — native macOS AI assistant.
//
// Module layout (modular monolith):
//   TagenCore    – platform-independent logic: geometry, context, model clients, orchestration,
//                  action policy, computer-use executor, voice state machine, persistence, security.
//   TagenAgents  – Codex / Claude Code bridge (subprocess + JSONL protocols). Platform-independent.
//   TagenMac     – macOS-only implementations of the TagenCore protocols (AX, ScreenCaptureKit,
//                  Vision, overlays, Speech, AVFoundation, CGEvent, Keychain, hotkeys).
//   Tagen        – the menu-bar application (SwiftUI + AppKit).
//   TagenFixtureApp / tagen-gui-check – isolated GUI fixture + live computer-use verification tool.
//   tagen-cli    – headless CLI (agent bridge, text ask) used for integration testing.
//   tagen-approval-mcp – stdio MCP server that relays Claude Code permission prompts to the app.
let package = Package(
    name: "Tagen",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Tagen", targets: ["Tagen"]),
        .executable(name: "TagenFixtureApp", targets: ["TagenFixtureApp"]),
        .executable(name: "tagen-gui-check", targets: ["tagen-gui-check"]),
        .executable(name: "tagen-live-probe", targets: ["tagen-live-probe"]),
        .executable(name: "tagen-cli", targets: ["tagen-cli"]),
        .executable(name: "tagen-approval-mcp", targets: ["tagen-approval-mcp"]),
        .library(name: "TagenCore", targets: ["TagenCore"]),
        .library(name: "TagenAgents", targets: ["TagenAgents"]),
    ],
    targets: [
        .systemLibrary(
            name: "CSQLite",
            path: "Sources/CSQLite",
            providers: [.apt(["libsqlite3-dev"])]
        ),
        .target(name: "TagenCore", dependencies: ["CSQLite"]),
        .target(name: "TagenAgents", dependencies: ["TagenCore"]),
        .target(name: "TagenMac", dependencies: ["TagenCore", "TagenAgents"]),
        .executableTarget(name: "Tagen", dependencies: ["TagenCore", "TagenAgents", "TagenMac"]),
        .executableTarget(name: "TagenFixtureApp"),
        .executableTarget(name: "tagen-gui-check", dependencies: ["TagenCore", "TagenMac"]),
        .executableTarget(name: "tagen-live-probe", dependencies: ["TagenCore", "TagenMac"]),
        .executableTarget(name: "tagen-cli", dependencies: ["TagenCore", "TagenAgents"]),
        .executableTarget(name: "tagen-approval-mcp", dependencies: ["TagenAgents"]),
        .testTarget(name: "TagenCoreTests", dependencies: ["TagenCore"]),
        .testTarget(
            name: "TagenAgentsTests",
            dependencies: ["TagenAgents", "TagenCore"],
            exclude: ["Fixtures"]
        ),
        .testTarget(name: "TagenMacTests", dependencies: ["TagenMac", "TagenCore"]),
    ]
)
