import Foundation
import Testing
@testable import Meet42Kit

@Suite("meet42 permissions model")
struct PermissionModelTests {

    private let all: [Meet42PermissionEntry] = [
        .init(name: .calendar, status: .granted),
        .init(name: .microphone, status: .notDetermined),
        .init(name: .speech, status: .denied),
        .init(name: .systemAudio, status: .restricted),
    ]

    @Test("the four permissions come in the agreed order")
    func order() {
        #expect(Meet42Permission.allCases.map(\.rawValue) == ["calendar", "microphone", "speech", "systemAudio"])
    }

    @Test("names parse case-insensitively and reject anything else")
    func parsing() {
        #expect(Meet42Permission(argument: "calendar") == .calendar)
        #expect(Meet42Permission(argument: "MICROPHONE") == .microphone)
        #expect(Meet42Permission(argument: "Speech") == .speech)
        #expect(Meet42Permission(argument: "SYSTEMAUDIO") == .systemAudio)
        #expect(Meet42Permission(argument: "camera") == nil)
        #expect(Meet42Permission(argument: "") == nil)
        #expect(Meet42Permission(argument: "screen") == nil)
    }

    @Test("JSON is a compact array of name/status in the given order")
    func jsonShape() throws {
        let json = Meet42PermissionReport.json(all)
        #expect(json == #"[{"name":"calendar","status":"granted"},{"name":"microphone","status":"not_determined"},{"name":"speech","status":"denied"},{"name":"systemAudio","status":"restricted"}]"#)
        let decoded = try JSONDecoder().decode([Meet42PermissionEntry].self, from: Data(json.utf8))
        #expect(decoded == all)
    }

    @Test("a single entry encodes as one object")
    func singleEntry() {
        #expect(Meet42PermissionReport.json(.init(name: .systemAudio, status: .granted)) == #"{"name":"systemAudio","status":"granted"}"#)
    }

    @Test("an empty report is an empty array")
    func emptyJSON() {
        #expect(Meet42PermissionReport.json([]) == "[]")
    }

    @Test("every status has the documented wire value")
    func statusValues() {
        #expect(Meet42PermissionStatus.granted.rawValue == "granted")
        #expect(Meet42PermissionStatus.denied.rawValue == "denied")
        #expect(Meet42PermissionStatus.notDetermined.rawValue == "not_determined")
        #expect(Meet42PermissionStatus.restricted.rawValue == "restricted")
    }

    @Test("each permission opens its own System Settings page")
    func settingsPages() {
        let base = "x-apple.systempreferences:com.apple.preference.security?"
        #expect(Meet42Permission.calendar.settingsURL == base + "Privacy_Calendars")
        #expect(Meet42Permission.microphone.settingsURL == base + "Privacy_Microphone")
        #expect(Meet42Permission.speech.settingsURL == base + "Privacy_SpeechRecognition")
        #expect(Meet42Permission.systemAudio.settingsURL == base + "Privacy_AudioCapture")
        #expect(Set(Meet42Permission.allCases.map(\.settingsURL)).count == 4)
    }

    @Test("every permission can be requested with the system prompt")
    func promptable() {
        #expect(Meet42Permission.allCases.allSatisfy { $0.canBeRequestedWithPrompt })
    }

    @Test("the table has one aligned row per permission")
    func table() {
        let lines = Meet42PermissionReport.table(all).split(separator: "\n").map(String.init)
        #expect(lines.count == 4)
        #expect(lines[0].hasPrefix("Calendar") && lines[0].hasSuffix("granted"))
        #expect(lines[3].hasPrefix("System audio") && lines[3].hasSuffix("restricted"))
        // Statuses start in the same column.
        let statusColumn = lines.map { line -> Int in
            let last = line.split(separator: " ").last!
            return line.count - last.count
        }
        #expect(Set(statusColumn).count == 1, "statuses line up")
    }

    @Test("guidance: nothing to say when granted")
    func noGuidanceWhenGranted() {
        #expect(Meet42PermissionReport.guidance(for: .init(name: .microphone, status: .granted)) == nil)
    }

    @Test("guidance: system audio denied points at System Settings")
    func systemAudioGuidance() throws {
        let text = try #require(Meet42PermissionReport.guidance(for: .init(name: .systemAudio, status: .denied)))
        #expect(text.contains("System Settings"))
        #expect(text.contains("meet42 permissions open systemAudio"))
    }

    @Test("guidance: denied tells the user macOS will not ask again")
    func deniedGuidance() throws {
        let text = try #require(Meet42PermissionReport.guidance(for: .init(name: .calendar, status: .denied)))
        #expect(text.contains("won't ask again"))
        #expect(text.contains("meet42 permissions open calendar"))
    }

    @Test("guidance: restricted says it can't be changed here")
    func restrictedGuidance() throws {
        let text = try #require(Meet42PermissionReport.guidance(for: .init(name: .speech, status: .restricted)))
        #expect(text.contains("restricted"))
    }

    @Test("guidance: never-asked points at request")
    func undecidedGuidance() throws {
        let text = try #require(Meet42PermissionReport.guidance(for: .init(name: .microphone, status: .notDetermined)))
        #expect(text.contains("meet42 permissions request microphone"))
    }

    @Test("names are human-readable for the table and the widget")
    func displayNames() {
        #expect(Meet42Permission.allCases.map(\.displayName) == ["Calendar", "Microphone", "Speech recognition", "System audio"])
    }
}
