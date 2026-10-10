// Widget.swift — meet42's Summary widget.
//
// Shows the session artifact `meeting-summary` (written by the agent in the Summary stage, following the
// meet42-summary skill) full size, through the shared pinned-artifact view, in the same style as the Meeting
// brief. It has no actions: to rewrite the summary, ask the agent. It contributes the header label
// "Summary ready · N action items" (N from session storage `meeting/summary`), which opens this widget through
// its `meet42://widget/summary` link.

import Foundation
import Observation
import SwiftUI
import Work42UI
import Work42PluginKit

private let summaryArtifactId = "meeting-summary"
private let summaryLink = URL(string: "meet42://widget/summary")!

@Observable
@MainActor
final class SummaryWidget: Work42Widget, Work42WidgetBackground {

    let id = "summary"
    let title = "Meet42 Summary"
    let icon = "doc.text"
    var linkIntents: [WidgetLinkIntentSpec] {
        [WidgetLinkIntentSpec(matchers: [.regex(#"^meet42://widget/summary$"#)], perform: { _ in })]
    }
    var minSize: WidgetMinSize { WidgetMinSize(width: 320, height: 240) }

    func activate(services: SessionServices) {
        PinnedArtifactLocator.register(sessionId: services.sessionId, worktreePath: services.worktreePath)
    }

    func deactivate() {}

    func makeView(services: SessionServices) -> AnyView {
        AnyView(PinnedArtifactView(
            services: services, artifactId: summaryArtifactId,
            emptyTitle: "No summary yet",
            emptyMessage: "The agent writes the summary when the meeting ends.",
            symbol: "doc.text"
        ))
    }

    func makeBackgroundAgent() -> any WidgetBackgroundAgent { SummaryLabelAgent() }
}

/// One per session: keeps the summary label current on every tab.
@Observable
@MainActor
final class SummaryLabelAgent: WidgetBackgroundAgent {

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
        var labels: [WidgetHeaderLabel] = []
        if let count = await actionItemCount(services) {
            let text = count == 1 ? "Summary ready \u{00B7} 1 action item" : "Summary ready \u{00B7} \(count) action items"
            labels = [WidgetHeaderLabel(text: text, systemIcon: "doc.text", tint: .success, url: summaryLink)]
        } else if PinnedArtifactLocator.exists(
            sessionId: services.sessionId, worktreePath: nil, artifactId: summaryArtifactId
        ) {
            labels = [WidgetHeaderLabel(text: "Summary ready", systemIcon: "doc.text", tint: .success, url: summaryLink)]
        }
        if labels != headerLabels { headerLabels = labels }
    }

    /// `meeting/summary` is `{"artifact":"meeting-summary","action_items":N}`; nil when unset or not that shape.
    private func actionItemCount(_ services: WidgetBackgroundServices) async -> Int? {
        guard case .object(let object)? = try? await services.storage.get(namespace: "meeting", key: "summary"),
              case .number(let n)? = object["action_items"] else { return nil }
        return Int(n)
    }
}

@_cdecl("work42_widget_sdk_version")
public func work42_widget_sdk_version() -> Int32 { WidgetSDK.abiVersion }

@_cdecl("work42_widget_main")
public func work42_widget_main() -> UnsafeMutableRawPointer {
    nonisolated(unsafe) var result: UnsafeMutableRawPointer!
    MainActor.assumeIsolated {
        result = WidgetEntryPoint.register(SummaryWidget())
    }
    return result
}
