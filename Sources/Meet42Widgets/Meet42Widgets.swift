// Meet42Widgets.swift — meet42's widgets, hosted without the plugin loader.
//
// On the Mac the plugin loader builds each widget from its own Sources folder and Work42 hosts it. Anything else that
// shows these widgets (the Work42 iPad app) links this library instead: one SwiftPM target per widget, built from the
// SAME files, and this file maps a widget id to its view. The widgets reach the Mac only through `SessionServices`
// (shell, storage, files, platform), so on an iPad those calls are answered by the paired Mac.
//
// What stays on the Mac, on purpose: the action-area intents (Record, Stop, Join, the calendar's navigation) and the
// background agents (call detection, header labels). The Mac hosts and runs them, and the iPad already shows and
// triggers the Mac's intents. This library only draws each widget's content.

import SwiftUI
import Work42PluginKit

import Meet42AnnotationsWidget
import Meet42CalendarWidget
import Meet42EventDetailsWidget
import Meet42PermissionsWidget
import Meet42RecordingWidget

public enum Meet42Widget {

    /// Every widget id this plugin has, in the order the plugin lists them.
    /// (The Brief and Recap are not widgets: they are the session's `meeting-brief` and `meeting-summary` artifacts, which
    /// Work42 draws as artifact tiles on every device.)
    public static let allIDs = ["annotations", "calendar", "event-details", "permissions", "recording"]

    /// The widget ids this library draws on every platform.
    public static var hostedIDs: [String] { allIDs }

    /// The plugin's own id for a widget id as a layout names it: `calendar`, `widget:calendar`, `meet42-calendar` (the
    /// name a widget gets when another plugin already has `calendar`) and `widget:meet42-calendar-2` all give
    /// `calendar`. Nil when it is not one of these widgets.
    public static func normalizedID(_ id: String) -> String? {
        var name = id
        if name.hasPrefix("widget:") { name.removeFirst("widget:".count) }
        if name.hasPrefix("meet42-") { name.removeFirst("meet42-".count) }
        if allIDs.contains(name) { return name }
        // A numbered duplicate, `calendar-2`.
        if let dash = name.lastIndex(of: "-"), Int(name[name.index(after: dash)...]) != nil {
            let base = String(name[..<dash])
            if allIDs.contains(base) { return base }
        }
        return nil
    }

    /// A new instance of the widget, or nil when `id` is not one of these widgets.
    @MainActor
    public static func makeWidget(id: String) -> (any Work42Widget)? {
        switch normalizedID(id) {
        case "annotations": Meet42AnnotationsWidget.meet42MakeWidget()
        case "calendar": Meet42CalendarWidget.meet42MakeWidget()
        case "event-details": Meet42EventDetailsWidget.meet42MakeWidget()
        case "permissions": Meet42PermissionsWidget.meet42MakeWidget()
        case "recording": Meet42RecordingWidget.meet42MakeWidget()
        default: nil
        }
    }

    /// The widget ids whose view needs `activate` to have run. Calendar's view reads a store the widget creates there.
    /// The others read what they show through `services`; their `activate` only starts polls that feed the Mac's
    /// action-area intents (recording polls the CLI every 2 s), which on an iPad would be pure link traffic.
    static let activatedIDs: Set<String> = ["calendar"]

    /// The widget's content view for `id`, or nil when it is not one of these widgets.
    @MainActor
    public static func rootView(id: String, services: SessionServices) -> AnyView? {
        guard let name = normalizedID(id), hostedIDs.contains(name), let widget = makeWidget(id: name) else { return nil }
        return AnyView(MountedWidget(widget: widget, services: services, activates: activatedIDs.contains(name)))
    }
}

/// Keeps one widget instance for as long as its view is on screen, and runs its lifecycle.
private struct MountedWidget: View {
    @State private var widget: any Work42Widget
    let services: SessionServices
    let activates: Bool

    init(widget: any Work42Widget, services: SessionServices, activates: Bool) {
        _widget = State(initialValue: widget)
        self.services = services
        self.activates = activates
    }

    var body: some View {
        widget.makeView(services: services)
            .onAppear { if activates { widget.activate(services: services) } }
            .onDisappear { if activates { widget.deactivate() } }
    }
}
