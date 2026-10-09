// PermissionsCommand.swift — `meet42 permissions`: see and grant the four privacy permissions meet42 needs.
//
//   meet42 permissions [--json]
//   meet42 permissions request <calendar|microphone|speech|screen> [--json]
//   meet42 permissions open <calendar|microphone|speech|screen>
//
// Every verb that asks macOS about a permission first re-executes itself (`Meet42Daemon.daemonize`, the same
// step `record start` takes) with "disclaim responsibility" set, so the status it reads and the prompt it
// shows belong to meet42 itself rather than to whatever launched it (a terminal, or the Work42 app). A plain
// re-exec is not enough: without the disclaim, `meet42 permissions` reports the PARENT's grants. The
// one-time `--reexec` flag marks the second pass.

import AVFoundation
import CoreGraphics
import EventKit
import Foundation
import Meet42CalendarSync
import Meet42Kit
import Speech

@MainActor
enum PermissionsCommand {

    static func permissions(args: [String]) async {
        let positionals = CLI.positionals(args)
        switch positionals.first {
        case nil:
            list(args: args)
        case "request":
            await request(args: args, name: positionals.dropFirst().first)
        case "open":
            open(name: positionals.dropFirst().first)
        case let unknown?:
            CLI.fail("meet42 permissions: unknown subcommand '\(unknown)'. Use: (none) | request <name> | open <name>", code: 2)
        }
    }

    // MARK: - list

    private static func list(args: [String]) {
        reexec(args: args, argv: ["permissions"])
        let entries = Meet42Permission.allCases.map { Meet42PermissionEntry(name: $0, status: status(of: $0)) }
        print(CLI.wantsJSON(args) ? Meet42PermissionReport.json(entries) : Meet42PermissionReport.table(entries))
    }

    // MARK: - request

    private static func request(args: [String], name: String?) async {
        let permission = parse(name)
        reexec(args: args, argv: ["permissions", "request", permission.rawValue])

        let before = status(of: permission)
        // macOS only ever shows its prompt for a permission nobody has decided on yet; asking again for
        // one that is denied or restricted is silent. Report that honestly instead of pretending to ask.
        if before == .notDetermined || !permission.canBeRequestedWithPrompt {
            _ = await ask(permission)
        }
        let entry = Meet42PermissionEntry(name: permission, status: status(of: permission))

        if CLI.wantsJSON(args) {
            print(Meet42PermissionReport.json(entry))
        } else {
            print("\(permission.displayName): \(entry.status.rawValue)")
        }
        if let guidance = Meet42PermissionReport.guidance(for: entry) { CLI.warn(guidance) }
        exit(entry.status == .granted ? 0 : 1)
    }

    /// Shows the system prompt for `permission` (screen recording has none: it asks macOS to list meet42 and
    /// opens the Settings page).
    private static func ask(_ permission: Meet42Permission) async -> Bool {
        switch permission {
        case .calendar:
            return (try? await EKEventStore().requestFullAccessToEvents()) ?? false
        case .microphone:
            return await AVCaptureDevice.requestAccess(for: .audio)
        case .speech:
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
            }
        case .screen:
            let granted = CGRequestScreenCaptureAccess()
            if !granted { openSettings(permission) }
            return granted
        }
    }

    // MARK: - open

    private static func open(name: String?) {
        openSettings(parse(name))
    }

    private static func openSettings(_ permission: Meet42Permission) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [permission.settingsURL]
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            CLI.fail("meet42 permissions: couldn't open System Settings: \(error)", code: 1)
        }
    }

    // MARK: - status

    /// The current state of `permission`, read by the process that will be asking for it.
    static func status(of permission: Meet42Permission) -> Meet42PermissionStatus {
        switch permission {
        case .calendar:
            switch EKEventStore.authorizationStatus(for: .event) {
            case .fullAccess: return .granted
            case .notDetermined: return .notDetermined
            case .restricted: return .restricted
            // Write-only access cannot read events, which is all meet42 does with the calendar.
            case .denied, .writeOnly: return .denied
            @unknown default: return .denied
            }
        case .microphone:
            return map(AVCaptureDevice.authorizationStatus(for: .audio))
        case .speech:
            switch SFSpeechRecognizer.authorizationStatus() {
            case .authorized: return .granted
            case .notDetermined: return .notDetermined
            case .restricted: return .restricted
            case .denied: return .denied
            @unknown default: return .denied
            }
        case .screen:
            // CoreGraphics has no "never asked": it is either on or it is not.
            return CGPreflightScreenCaptureAccess() ? .granted : .denied
        }
    }

    private static func map(_ status: AVAuthorizationStatus) -> Meet42PermissionStatus {
        switch status {
        case .authorized: return .granted
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied: return .denied
        @unknown default: return .denied
        }
    }

    // MARK: - helpers

    private static func parse(_ name: String?) -> Meet42Permission {
        guard let name, !name.isEmpty else {
            CLI.fail("meet42 permissions: a permission name is required (calendar, microphone, speech, screen)", code: 2)
        }
        guard let permission = Meet42Permission(argument: name) else {
            CLI.fail("meet42 permissions: unknown permission '\(name)' (calendar, microphone, speech, screen)", code: 2)
        }
        return permission
    }

    /// First pass: detach and re-exec so macOS keys the permission to meet42's own signature. A no-op on the
    /// second pass (the `--reexec` flag is present).
    private static func reexec(args: [String], argv: [String]) {
        let isReexec = Meet42Daemon.isReexec(args)
        let json = CLI.wantsJSON(args) ? ["--json"] : []
        Meet42Daemon.daemonize(reexecArgv: argv + json + ["--reexec"], isReexec: isReexec)
    }
}
