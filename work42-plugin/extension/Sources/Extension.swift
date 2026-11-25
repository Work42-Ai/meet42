// Extension.swift — meet42's extension (`runtime: extension`): its five widgets and its session hook run in their own process.
// Only the Work42 extension build compiles this file; the SwiftPM `Meet42PluginWidgets` target (the iPad's library) excludes it.
//
// Recording, transcribing and reading the calendars are Work42's, through `services.audio`, `services.speech`,
// `services.calendar` and `services.permissions` (SDK 3.3.0): macOS does not give those permissions to an extension, so Work42
// holds them and does the work for this plugin.

import SwiftUI
import Work42Extension
import Work42PluginKit

/// `nonisolated` is required: ExtensionKit makes this class off the main actor (the widgets stay on it).
@main
nonisolated final class Meet42Extension: Work42PluginExtension {
    required init() {}

    @MainActor var widgets: [ExtensionWidgetFactory] {
        [
            ExtensionWidgetFactory("annotations") { AnnotationsWidget() },
            ExtensionWidgetFactory("calendar") { CalendarWidget() },
            ExtensionWidgetFactory("event-details") { EventDetailsWidget() },
            ExtensionWidgetFactory("permissions") { PermissionsWidget() },
            ExtensionWidgetFactory("recording") { RecordingWidget() },
        ]
    }

    @MainActor var sessionHooks: (any Work42SessionHooks)? { Meet42Hooks() }
}
