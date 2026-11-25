// swift-tools-version: 6.2
//
// meet42 — the open-source macOS calendar + meetings CLI (meet42-plugin-conversion, M1), callable by any agent, with NO
// dependency on work42/Flow42Core. It owns its stores (calendar.db, people.db) and holds no privacy permission: since 2.0.0
// Work42 records the audio, transcribes and reads the calendars for the meet42 plugin.
//
// `Meet42Kit` is the calendar + people domain, ported from Flow42Core/Calendar + Flow42Core/People and stripped of all work42
// coupling; `Meet42Capture` is what a recording leaves for the CLI to read; `meet42` is the executable and its verbs.
//
// The meet42 plugin's extension sources (work42-plugin/extension/Sources) are ALSO built here, as the `Meet42Widgets` library
// the Work42 iPad app links (macOS 15, iOS 26). The extension compiles on its own from that folder against the app's SDK
// frameworks, so the folder stays the single source of the plugin's widgets: it is one SwiftPM target (`Meet42PluginWidgets`)
// built from the same files, minus `Extension.swift` (the extension's `@main`, which needs ExtensionKit), and
// `Sources/Meet42Widgets` maps a widget id to its view.

import Foundation
import PackageDescription

// The public SDK is two independent packages (see work42/app/Package.swift for why). `WORK42_SDK_PATH` selects
// another checkout; otherwise the sibling `work42-sdk` next to this repository is used. A standalone clone, or a
// release build of the CLI, has no SDK checkout: then only the CLI targets exist and nothing new is resolved.
let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let work42SDKRoot = ProcessInfo.processInfo.environment["WORK42_SDK_PATH"]
    .flatMap { $0.isEmpty ? nil : $0 }
    ?? "\(packageRoot)/../work42-sdk"
let hasSDK = FileManager.default.fileExists(atPath: "\(work42SDKRoot)/Work42PluginKit/Package.swift")
    && FileManager.default.fileExists(atPath: "\(work42SDKRoot)/Work42UI/Package.swift")

// Exactly what `work42 plugin build` passes swiftc, so a widget means the same thing in both builds.
let widgetSettings: [SwiftSetting] = [
    .enableUpcomingFeature("ExistentialAny"),
    .defaultIsolation(MainActor.self),
]

let sdkDependencies: [Target.Dependency] = [
    .product(name: "Work42UI", package: "Work42UI"),
    .product(name: "Work42PluginKit", package: "Work42PluginKit"),
]

var products: [Product] = [
    .library(name: "Meet42Kit", targets: ["Meet42Kit"]),
    .library(name: "Meet42Capture", targets: ["Meet42Capture"]),
    .executable(name: "meet42", targets: ["meet42"]),
]

// No external dependencies: capturing audio, transcribing and reading the calendars are Work42's (2.0.0), done through its
// services for the meet42 extension, so the speaker-diarization engine (FluidAudio) and EventKit left with them.
var dependencies: [Package.Dependency] = []

var targets: [Target] = [
    .target(
        name: "Meet42Kit",
        path: "Sources/Meet42Kit",
        linkerSettings: [.linkedLibrary("sqlite3")]
    ),
    // Meet42Capture: what a recording leaves for `meet42` to read and the tools around it — the transcript files
    // (conversation.jsonl, speakers.json), the My Notes file, the microphone choice, the trace log. It no longer captures
    // anything: the meet42 extension records through Work42's audio service.
    .target(
        name: "Meet42Capture",
        dependencies: ["Meet42Kit"],
        path: "Sources/Meet42Capture"
    ),
    // meet42: the CLI executable + its verbs. Manual arg dispatch (no ArgumentParser), driving the in-package targets only.
    .executableTarget(
        name: "meet42",
        dependencies: ["Meet42Kit", "Meet42Capture"],
        path: "Sources/meet42"
    ),
    .testTarget(
        name: "Meet42KitTests",
        dependencies: ["Meet42Kit"],
        path: "Tests/Meet42KitTests"
    ),
    .testTarget(
        name: "Meet42CaptureTests",
        dependencies: ["Meet42Capture"],
        path: "Tests/Meet42CaptureTests"
    ),
]

if hasSDK {
    products.append(.library(name: "Meet42Widgets", targets: ["Meet42Widgets"]))
    dependencies += [
        .package(name: "Work42UI", path: "\(work42SDKRoot)/Work42UI"),
        .package(name: "Work42PluginKit", path: "\(work42SDKRoot)/Work42PluginKit"),
    ]
    // The five widgets, in one module: the extension's sources minus its `@main`.
    targets.append(.target(
        name: "Meet42PluginWidgets",
        dependencies: sdkDependencies,
        path: "work42-plugin/extension/Sources",
        exclude: ["Extension.swift"],
        swiftSettings: widgetSettings
    ))
    // Meet42Widgets: widget id -> root view, the one entry point the iPad app (and anything else that hosts these
    // widgets without the plugin loader) calls.
    targets.append(.target(
        name: "Meet42Widgets",
        dependencies: sdkDependencies + [.target(name: "Meet42PluginWidgets")],
        path: "Sources/Meet42Widgets",
        swiftSettings: widgetSettings
    ))
    targets.append(.testTarget(
        name: "Meet42WidgetsTests",
        dependencies: ["Meet42Widgets", .target(name: "Meet42PluginWidgets")] + sdkDependencies,
        path: "Tests/Meet42WidgetsTests",
        swiftSettings: widgetSettings
    ))
}

let package = Package(
    name: "meet42",
    platforms: [.macOS(.v15), .iOS(.v26)],
    products: products,
    dependencies: dependencies,
    targets: targets
)
