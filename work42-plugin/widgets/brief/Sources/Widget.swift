// Widget.swift — meet42's Meeting brief widget.
//
// Shows the session artifact `meeting-brief` (written by the agent in the Prepare for Meeting stage, following
// the meet42-brief skill) full size, through the shared pinned-artifact view. It has no actions: to rebuild the
// brief, ask the agent. It contributes the header label "Preparing brief…" / "Brief ready", which opens this
// widget through its `meet42://widget/brief` link.

import Foundation
import Observation
import SwiftUI
import Work42UI
import Work42PluginKit

private let briefArtifactId = "meeting-brief"
private let briefLink = URL(string: "meet42://widget/brief")!

@Observable
@MainActor
final class BriefWidget: Work42Widget, Work42WidgetBackground {

    let id = "brief"
    let title = "Meeting brief"
    let icon = "doc.richtext"
    var linkIntents: [WidgetLinkIntentSpec] {
        // The host reveals the widget before calling `perform`, which is all the link has to do.
        [WidgetLinkIntentSpec(matchers: [.regex(#"^meet42://widget/brief$"#)], perform: { _ in })]
    }
    var minSize: WidgetMinSize { WidgetMinSize(width: 320, height: 240) }

    func activate(services: SessionServices) {
        PinnedArtifactLocator.register(sessionId: services.sessionId, worktreePath: services.worktreePath)
    }

    func deactivate() {}

    func makeView(services: SessionServices) -> AnyView {
        AnyView(PinnedArtifactView(
            services: services, artifactId: briefArtifactId,
            emptyTitle: "No brief yet",
            emptyMessage: "The agent prepares this brief before the meeting.",
            symbol: "doc.richtext"
        ))
    }

    func makeBackgroundAgent() -> any WidgetBackgroundAgent { BriefLabelAgent() }
}

/// One per session: keeps the brief label current on every tab.
@Observable
@MainActor
final class BriefLabelAgent: WidgetBackgroundAgent {

    private(set) var headerLabels: [WidgetHeaderLabel] = []

    @ObservationIgnored private var task: Task<Void, Never>?

    func start(services: WidgetBackgroundServices) {
        task?.cancel()
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh(services)
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private func refresh(_ services: WidgetBackgroundServices) async {
        let ready = PinnedArtifactLocator.exists(
            sessionId: services.sessionId, worktreePath: nil, artifactId: briefArtifactId
        )
        var labels: [WidgetHeaderLabel] = []
        if ready {
            labels = [WidgetHeaderLabel(text: "Brief ready", systemIcon: "doc.richtext", tint: .success, url: briefLink)]
        } else if await currentStage(services) == "Prepare for Meeting" {
            labels = [WidgetHeaderLabel(text: "Preparing brief\u{2026}", systemIcon: "hourglass", tint: .neutral, url: briefLink)]
        }
        if labels != headerLabels { headerLabels = labels }
    }

    /// The session's workflow stage, from `work42 workflow show --json` (`current_stage`).
    private func currentStage(_ services: WidgetBackgroundServices) async -> String? {
        let command = "work42 workflow show --session '\(services.sessionId)' --json"
        guard let result = try? await services.shell.run(command: command), result.exitCode == 0,
              let data = result.stdout.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return object["current_stage"] as? String
    }
}

@_cdecl("work42_widget_sdk_version")
public func work42_widget_sdk_version() -> Int32 { WidgetSDK.abiVersion }

@_cdecl("work42_widget_main")
public func work42_widget_main() -> UnsafeMutableRawPointer {
    nonisolated(unsafe) var result: UnsafeMutableRawPointer!
    MainActor.assumeIsolated {
        result = WidgetEntryPoint.register(BriefWidget())
    }
    return result
}
