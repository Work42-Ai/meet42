// Hosting.swift — the one way a host that is not the extension builds these widgets (the Work42 iPad app, through
// `Meet42Widgets`). Compiled into the extension too, where nothing calls it.

import Work42PluginKit

/// A new instance of the widget `id`, or nil when it is not one of meet42's widgets.
@MainActor
public func meet42MakeWidget(id: String) -> (any Work42Widget)? {
    switch id {
    case "annotations": AnnotationsWidget()
    case "calendar": CalendarWidget()
    case "event-details": EventDetailsWidget()
    case "permissions": PermissionsWidget()
    case "recording": RecordingWidget()
    default: nil
    }
}
