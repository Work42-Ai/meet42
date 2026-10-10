// PermissionModel.swift — the permissions meet42 needs, as plain data.
//
// `meet42 permissions` reports four macOS privacy permissions. This file is the framework-free half: their
// names, the normalised statuses, the System Settings pages that switch them, and the exact JSON / table the
// verb prints. The real status checks and prompts (EventKit, AVFoundation, Speech, CoreGraphics) live in the
// executable, so this part tests without touching TCC.

import Foundation

/// The four permissions, in the order every surface lists them.
public enum Meet42Permission: String, CaseIterable, Codable, Sendable {
    /// Calendar: list meetings and prepare sessions.
    case calendar
    /// Microphone: record meeting audio locally.
    case microphone
    /// Speech recognition: on-device transcription.
    case speech
    /// System audio recording only (macOS "System Audio Recording Only"): hear the other side of a call.
    /// meet42 never records the screen.
    case systemAudio

    /// The name a user types after `meet42 permissions request|open`. Case-insensitive.
    public init?(argument: String) {
        let key = argument.lowercased()
        guard let match = Meet42Permission.allCases.first(where: { $0.rawValue.lowercased() == key }) else { return nil }
        self = match
    }

    /// Short human name, as the table and the widget label it.
    public var displayName: String {
        switch self {
        case .calendar: return "Calendar"
        case .microphone: return "Microphone"
        case .speech: return "Speech recognition"
        case .systemAudio: return "System audio"
        }
    }

    /// The System Settings page that switches this permission (`open <url>`).
    public var settingsURL: String {
        let base = "x-apple.systempreferences:com.apple.preference.security?"
        switch self {
        case .calendar: return base + "Privacy_Calendars"
        case .microphone: return base + "Privacy_Microphone"
        case .speech: return base + "Privacy_SpeechRecognition"
        case .systemAudio: return base + "Privacy_AudioCapture"
        }
    }

    /// Every permission can be requested with the system prompt; once the user has answered, macOS never
    /// asks again and only System Settings can change it.
    public var canBeRequestedWithPrompt: Bool { true }
}

/// A permission's state, normalised across the four different system APIs.
public enum Meet42PermissionStatus: String, Codable, Sendable {
    case granted
    case denied
    /// Never asked: `request` shows the system prompt.
    case notDetermined = "not_determined"
    /// Blocked by policy (parental controls, MDM); the user cannot change it.
    case restricted
}

public struct Meet42PermissionEntry: Codable, Equatable, Sendable {
    public let name: Meet42Permission
    public let status: Meet42PermissionStatus

    public init(name: Meet42Permission, status: Meet42PermissionStatus) {
        self.name = name
        self.status = status
    }
}

public enum Meet42PermissionReport {

    /// `[{"name":"calendar","status":"granted"},…]` in the order given, compact and with stable key order.
    public static func json(_ entries: [Meet42PermissionEntry]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(entries), let text = String(data: data, encoding: .utf8) else { return "[]" }
        return text
    }

    /// One entry as a JSON object (what `request --json` prints).
    public static func json(_ entry: Meet42PermissionEntry) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(entry), let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    /// A readable table: `Calendar            granted`.
    public static func table(_ entries: [Meet42PermissionEntry]) -> String {
        let width = (entries.map { $0.name.displayName.count }.max() ?? 0) + 2
        return entries.map { entry in
            let name = entry.name.displayName
            return name + String(repeating: " ", count: max(width - name.count, 1)) + entry.status.rawValue
        }.joined(separator: "\n")
    }

    /// What to tell the user after a `request` that did not end in `granted`.
    public static func guidance(for entry: Meet42PermissionEntry) -> String? {
        switch (entry.status, entry.name) {
        case (.granted, _):
            return nil
        case (.restricted, _):
            return "\(entry.name.displayName) is restricted on this Mac (a profile or parental control) and "
                + "can't be changed here."
        case (.denied, _):
            return "\(entry.name.displayName) was turned off for meet42. macOS won't ask again: switch it on "
                + "in System Settings (`meet42 permissions open \(entry.name.rawValue)`)."
        case (.notDetermined, _):
            return "\(entry.name.displayName) is still undecided. Run `meet42 permissions request "
                + "\(entry.name.rawValue)` from a terminal or Work42 so macOS can show its prompt."
        }
    }
}
