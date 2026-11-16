// Meet42WidgetsTests.swift — the widget id -> view map the iPad app hosts the meet42 widgets through.

import Foundation
import SwiftUI
import Testing
import Work42PluginKit
@testable import Meet42Widgets

private struct StubComposer: WidgetComposerService {
    nonisolated func insert(text: String) async throws {}
    nonisolated func attach(sourceLabel: String, excerpt: String, body: String) async throws {}
}

private struct StubShell: WidgetShellService {
    nonisolated func run(command: String) async throws -> WidgetShellResult {
        WidgetShellResult(stdout: "", stderr: "", exitCode: 0)
    }
}

private struct StubIntents: WidgetIntentsService {
    nonisolated func execute(id: String, params: [String: WidgetJSONValue]) async throws {}
}

private struct StubStorage: WidgetStorageService {
    nonisolated func get(namespace: String, key: String) async throws -> WidgetJSONValue? { nil }
    nonisolated func list(namespace: String) async throws -> [String: WidgetJSONValue] { [:] }
    nonisolated func set(key: String, value: WidgetJSONValue) async throws {}
    nonisolated func delete(key: String) async throws {}
}

private struct StubPill: WidgetPillService {
    nonisolated func present(widgetId: String, sessionId: String) async throws {}
    nonisolated func dismiss(widgetId: String) async throws {}
    nonisolated func isPresented(widgetId: String) async throws -> Bool { false }
}

private func services() -> SessionServices {
    SessionServices(
        composer: StubComposer(), shell: StubShell(), intents: StubIntents(), storage: StubStorage(), pill: StubPill(),
        sessionId: "s1")
}

@Suite("Meet42Widgets")
struct Meet42WidgetsTests {

    @Test("the plugin has five widgets, each id once")
    func fiveWidgets() {
        #expect(Meet42Widget.allIDs == ["annotations", "calendar", "event-details", "permissions", "recording"])
        #expect(Set(Meet42Widget.allIDs).count == 5)
    }

    @Test("every id builds a widget whose own id is that id")
    @MainActor
    func everyIDBuildsItsWidget() {
        for id in Meet42Widget.allIDs {
            #expect(Meet42Widget.makeWidget(id: id)?.id == id, "\(id)")
        }
    }

    @Test("a layout's name for a widget resolves to the plugin's id, and nothing else does")
    func normalizesLayoutNames() {
        #expect(Meet42Widget.normalizedID("calendar") == "calendar")
        #expect(Meet42Widget.normalizedID("widget:calendar") == "calendar")
        #expect(Meet42Widget.normalizedID("widget:meet42-calendar") == "calendar")
        #expect(Meet42Widget.normalizedID("widget:meet42-event-details-2") == "event-details")
        #expect(Meet42Widget.normalizedID("event-details") == "event-details")
        #expect(Meet42Widget.normalizedID("widget:mail") == nil)
        #expect(Meet42Widget.normalizedID("chat") == nil)
        #expect(Meet42Widget.normalizedID("") == nil)
        #expect(Meet42Widget.normalizedID("calendar-x") == nil)
    }

    @Test("the Brief and Recap are artifact tiles, not widgets: this library has no view for them")
    @MainActor
    func artifactsAreNotWidgets() {
        for id in ["brief", "summary", "people"] {
            #expect(Meet42Widget.normalizedID(id) == nil, "\(id)")
            #expect(Meet42Widget.rootView(id: id, services: services()) == nil, "\(id)")
        }
    }

    @Test("rootView gives a view for each hosted widget and none for anything else")
    @MainActor
    func rootViews() {
        for id in Meet42Widget.hostedIDs {
            #expect(Meet42Widget.rootView(id: id, services: services()) != nil, "\(id)")
            #expect(Meet42Widget.rootView(id: "widget:\(id)", services: services()) != nil, "widget:\(id)")
        }
        #expect(Meet42Widget.rootView(id: "mail", services: services()) == nil)
    }

    @Test("only the calendar is activated on a host: its view needs the store activate builds")
    func activation() {
        #expect(Meet42Widget.activatedIDs == ["calendar"])
    }
}
