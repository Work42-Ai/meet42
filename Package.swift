// swift-tools-version: 6.2
//
// meet42 — the standalone, open-source macOS CLI (meet42-plugin-conversion,
// M1). A local private transcription + calendar + people tool callable by any
// agent, with NO dependency on work42/Flow42Core and its own TCC/Developer ID
// (signing wired in s7). It owns its stores (calendar.db, people.db), will
// download its own models, and carries its own usage-description plist.
//
// s6 lands the foundation: the `Meet42Kit` domain target (calendar + people
// domain, ported from Flow42Core/Calendar + Flow42Core/People, stripped of all
// work42 coupling). The capture engine (Meet42Capture, s8), the EventKit sync
// (Meet42CalendarSync, s7), and the CLI executable + verbs (s9) land in their
// own targets on top of this.
//
// The meet42 plugin's widgets (work42-plugin/widgets/<name>/Sources) are ALSO built here, as the
// `Meet42Widgets` library the Work42 iPad app links (macOS 15, iOS 26). A plugin widget compiles on its own from
// its own Sources folder against the app's SDK frameworks, so those folders stay the single source of each
// widget: each is one SwiftPM target (`Meet42<Name>Widget`) built from the same files, with the dylib entry points
// compiled out (MEET42_WIDGETS_LIBRARY), and `Sources/Meet42Widgets` maps a widget id to its view.

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

// Exactly what `work42 plugin build` passes swiftc (PluginSwiftCompiler.arguments), so a widget means the same
// thing in both builds.
let widgetSettings: [SwiftSetting] = [
    .enableUpcomingFeature("ExistentialAny"),
    .defaultIsolation(MainActor.self),
    .define("MEET42_WIDGETS_LIBRARY"),
]

/// The five widgets: folder under work42-plugin/widgets, and the SwiftPM target built from it.
let widgets: [(folder: String, target: String)] = [
    ("annotations", "Meet42AnnotationsWidget"),
    ("calendar", "Meet42CalendarWidget"),
    ("event-details", "Meet42EventDetailsWidget"),
    ("permissions", "Meet42PermissionsWidget"),
    ("recording", "Meet42RecordingWidget"),
]

let sdkDependencies: [Target.Dependency] = [
    .product(name: "Work42UI", package: "Work42UI"),
    .product(name: "Work42PluginKit", package: "Work42PluginKit"),
]

var products: [Product] = [
    .library(name: "Meet42Kit", targets: ["Meet42Kit"]),
    .library(name: "Meet42CalendarSync", targets: ["Meet42CalendarSync"]),
    .library(name: "Meet42Capture", targets: ["Meet42Capture"]),
    .executable(name: "meet42", targets: ["meet42"]),
]

var dependencies: [Package.Dependency] = [
    // FluidAudio: on-device (CoreML/ANE) speaker diarization, used by
    // Meet42Capture's SpeakerDiarizationService (matches the version
    // pinned in work42/app/Package.swift).
    .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.12.4"),
]

var targets: [Target] = [
    .target(
        name: "Meet42Kit",
        path: "Sources/Meet42Kit",
        linkerSettings: [.linkedLibrary("sqlite3")]
    ),
    .target(
        name: "Meet42CalendarSync",
        dependencies: ["Meet42Kit"],
        path: "Sources/Meet42CalendarSync",
        linkerSettings: [.linkedFramework("EventKit")]
    ),
    // Meet42Capture (s8): audio-capture + transcription + diarization
    // engine, ported from Flow42Core/Recording + Work42App/Meetings with
    // all work42 coupling stripped. Depends on Meet42Kit for MeetingMeta
    // (the calendar-snapshot attendee cap) and FluidAudio for on-device
    // speaker diarization.
    .target(
        name: "Meet42Capture",
        dependencies: [
            "Meet42Kit",
            .product(name: "FluidAudio", package: "FluidAudio"),
        ],
        path: "Sources/Meet42Capture"
    ),
    // meet42 (s9): the CLI executable + its verbs. Manual arg dispatch
    // (no ArgumentParser), driving the three in-package targets only.
    .executableTarget(
        name: "meet42",
        dependencies: ["Meet42Kit", "Meet42CalendarSync", "Meet42Capture"],
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
    for widget in widgets {
        targets.append(.target(
            name: widget.target,
            dependencies: sdkDependencies,
            path: "work42-plugin/widgets/\(widget.folder)/Sources",
            swiftSettings: widgetSettings
        ))
    }
    // Meet42Widgets: widget id -> root view, the one entry point the iPad app (and anything else that hosts these
    // widgets without the plugin loader) calls.
    targets.append(.target(
        name: "Meet42Widgets",
        dependencies: sdkDependencies + widgets.map { .target(name: $0.target) },
        path: "Sources/Meet42Widgets",
        swiftSettings: widgetSettings
    ))
    targets.append(.testTarget(
        name: "Meet42WidgetsTests",
        dependencies: ["Meet42Widgets"] + sdkDependencies,
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
