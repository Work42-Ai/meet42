// PermissionsWidget.swift — meet42's Permissions widget.
//
// A small tile that shows, one row each, the four macOS privacy permissions meet42 uses (Calendar, Microphone, Speech
// recognition, System audio) and gives each its own action: Grant (nobody has been asked) or Open Settings (anything else).
// Work42 holds these permissions for the plugin, not meet42 and not this extension (macOS does not give them to an
// extension), so every fact and every action goes through `services.permissions` (SDK 3.3.0):
//
//   permissions.status(_:)    where one stands, without asking anyone
//   permissions.request(_:)   asks as the first use would: Work42's pill, then macOS's own prompt (which names Work42)
//
// All four rows are always shown, granted or not. The `meet42` command line is still what agents read the calendar and the
// recordings with, so the tile also says which version is installed, and says so when it is not.

import Foundation
import Observation
import SwiftUI
import Work42UI
import Work42PluginKit

// MARK: - Model

/// One permission and where it stands.
struct PermissionRow: Identifiable, Equatable {
    let permission: PluginPermission
    let status: PluginPermissionStatus
    var id: String { permission.rawValue }
}

/// The four permissions, in display order, with the words and glyphs the rows use.
struct PermissionInfo {
    let permission: PluginPermission
    let title: String
    let purpose: String
    let symbol: String
    let tile: Color
    /// The System Settings page where this permission is switched on for Work42.
    let settingsPane: String

    static let all: [PermissionInfo] = [
        .init(permission: .calendars, title: "Calendar", purpose: "List meetings and prepare sessions",
              symbol: "calendar", tile: Color(red: 1.00, green: 0.27, blue: 0.23), settingsPane: "Privacy_Calendars"),
        .init(permission: .microphone, title: "Microphone", purpose: "Record meeting audio locally",
              symbol: "mic.fill", tile: Color(red: 1.00, green: 0.62, blue: 0.04), settingsPane: "Privacy_Microphone"),
        .init(permission: .speechRecognition, title: "Speech recognition", purpose: "On-device transcription",
              symbol: "waveform", tile: Color(red: 0.37, green: 0.36, blue: 0.90), settingsPane: "Privacy_SpeechRecognition"),
        .init(permission: .systemAudio, title: "System audio", purpose: "Hear the other side of the call",
              symbol: "speaker.wave.2.fill", tile: Color(red: 0.19, green: 0.69, blue: 0.78), settingsPane: "Privacy_AudioCapture"),
    ]

    static func info(for permission: PluginPermission) -> PermissionInfo? { all.first { $0.permission == permission } }

    /// The page that opens System Settings at this permission.
    var settingsURL: URL { URL(string: "x-apple.systempreferences:com.apple.preference.security?\(settingsPane)")! }
}

/// What a row's status pill and button say. Pure, so it is easy to reason about.
enum PermissionPresentation {
    enum Action: Equatable { case request, openSettings }
    enum Tone { case good, bad, warn, neutral }

    static func pillText(_ status: PluginPermissionStatus) -> String {
        switch status {
        case .granted: "Granted"
        case .notAsked: "Not asked"
        case .denied: "Denied"
        case .notDeclared: "Not declared"
        @unknown default: "Unknown"
        }
    }

    static func tone(_ status: PluginPermissionStatus) -> Tone {
        switch status {
        case .granted: .good
        case .denied: .bad
        case .notDeclared: .warn
        case .notAsked: .neutral
        @unknown default: .neutral
        }
    }

    /// Ask only when nobody has been asked; everything else opens Settings.
    static func action(_ status: PluginPermissionStatus) -> Action {
        status == .notAsked ? .request : .openSettings
    }

    static func summary(_ rows: [PermissionRow]) -> String {
        let attention = rows.filter { $0.status != .granted }.count
        return attention == 0 ? "All \(rows.count) allowed" : "\(attention) of \(rows.count) need attention"
    }

    /// Whether the plugin can record and read the calendar: every permission granted.
    static func isReady(_ rows: [PermissionRow]) -> Bool { rows.allSatisfy { $0.status == .granted } }
}

/// The installed `meet42` command line, when there is one.
struct Meet42CLIInfo: Equatable {
    var version: String?
    var directory: String
}

@MainActor
@Observable
final class PermissionsModel {
    enum Phase: Equatable {
        case loading
        case failed(String)
        case ready([PermissionRow])
    }

    var phase: Phase = .loading
    /// The command line, or nil when it is not installed.
    var cli: Meet42CLIInfo?
    var cliChecked = false
    var busy: Set<PluginPermission> = []

    @ObservationIgnored var services: SessionServices?

    /// Reads the four statuses. The command line is looked for the first time and when `recheckCLI` is set (the person pressed
    /// Check again), not on every poll: it costs a process.
    func refresh(recheckCLI: Bool = false) async {
        guard let services else { return }
        var rows: [PermissionRow] = []
        for info in PermissionInfo.all {
            do {
                rows.append(PermissionRow(permission: info.permission, status: try await services.permissions.status(info.permission)))
            } catch {
                phase = .failed((error as? WidgetServiceError)?.errorDescription ?? error.localizedDescription)
                return
            }
        }
        phase = .ready(rows)
        if recheckCLI || !cliChecked { await refreshCLI() }
    }

    private func refreshCLI() async {
        guard let services else { return }
        defer { cliChecked = true }
        guard let located = try? await services.shell.run(command: "command -v meet42"), located.exitCode == 0,
              !located.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            cli = nil
            return
        }
        let path = located.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        var version: String?
        if let result = try? await services.shell.run(command: "meet42 --version"), result.exitCode == 0 {
            version = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "meet42 v", with: "")
        }
        cli = Meet42CLIInfo(version: version, directory: (path as NSString).deletingLastPathComponent)
    }

    func request(_ permission: PluginPermission) async {
        guard let services, !busy.contains(permission) else { return }
        busy.insert(permission)
        defer { busy.remove(permission) }
        _ = try? await services.permissions.request(permission)
        await refresh()
    }

    func openSettings(_ permission: PluginPermission) {
        guard let services, let info = PermissionInfo.info(for: permission) else { return }
        services.platform.open(info.settingsURL)
    }
}

// MARK: - Widget

@MainActor
@Observable
final class PermissionsWidget: Work42Widget, Work42WidgetCustomHeader {

    let id = "permissions"
    let title = "meet42 permissions"
    let icon = "lock.shield"
    var linkIntents: [WidgetLinkIntentSpec] {
        // The "meet42 needs setup" label links here; the host reveals the widget before `perform`.
        [WidgetLinkIntentSpec(matchers: [.regex(#"^meet42://widget/permissions$"#)], perform: { _ in })]
    }
    var minSize: WidgetMinSize { WidgetMinSize(width: 300, height: 260) }
    var contentPadding: Double { 0 }

    @ObservationIgnored private let model = PermissionsModel()

    func activate(services: SessionServices) {
        model.services = services
    }

    func makeView(services: SessionServices) -> AnyView {
        model.services = services
        return AnyView(PermissionsBody(model: model))
    }

    func makeHeaderView() -> AnyView {
        AnyView(PermissionsHeader(model: model))
    }
}

// MARK: - Header

private struct PermissionsHeader: View {
    let model: PermissionsModel

    var body: some View {
        HStack(spacing: DT.s8) {
            WidgetHeaderTitle(name: "meet42 permissions")
            Spacer(minLength: DT.s8)
            HeaderPill([
                HeaderSegment(id: "refresh", systemImage: "arrow.clockwise", label: "Check again") {
                    Task { await model.refresh(recheckCLI: true) }
                }
            ])
        }
    }
}

// MARK: - Body

private struct PermissionsBody: View {
    let model: PermissionsModel

    var body: some View {
        Group {
            switch model.phase {
            case .loading:
                ProgressView().controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                FailedView(message: message, model: model)
            case .ready(let rows):
                ReadyView(rows: rows, model: model)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // A permission switched on in System Settings shows up within a few seconds: the extension is not the frontmost app, so
        // it is never told Work42 came back. The poll lasts as long as the tile is on screen.
        .task {
            while !Task.isCancelled {
                await model.refresh()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }
}

private struct ReadyView: View {
    let rows: [PermissionRow]
    let model: PermissionsModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DT.s12) {
                meta
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        if index > 0 { Divider().opacity(0.4) }
                        PermissionRowView(row: row, model: model)
                    }
                }
                .background(RoundedRectangle(cornerRadius: DT.rCard + 2, style: .continuous).fill(DT.chipFill))
                .overlay(RoundedRectangle(cornerRadius: DT.rCard + 2, style: .continuous).strokeBorder(DT.chipStroke, lineWidth: 0.5))
                Text("Work42 holds these for meet42. System Settings lists them under Work42.")
                    .font(.system(size: DT.f9))
                    .foregroundStyle(.tertiary)
                if model.cliChecked && model.cli == nil { missingCLI }
            }
            .padding(.horizontal, DT.s16)
            .padding(.bottom, DT.s16)
        }
    }

    private var meta: some View {
        HStack(spacing: 6) {
            Text(PermissionPresentation.summary(rows))
                .font(.system(size: DT.f10))
                .foregroundStyle(.secondary)
            if let cli = model.cli {
                if let version = cli.version { chip("meet42 \(version)") }
                chip(cli.directory.replacingOccurrences(of: RealHome.path, with: "~"))
            }
        }
    }

    private var missingCLI: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("The meet42 command line isn\u{2019}t installed")
                .font(.system(size: DT.f10, weight: .semibold))
            Text("Agents read your calendar and recordings with it. Ask the agent in a session to set up meet42.")
                .font(.system(size: DT.f9))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(DT.s12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: DT.rCard, style: .continuous).fill(DT.chipFill))
    }

    private func chip(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10.5, design: .monospaced))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .glassPillSurface()
            .lineLimit(1)
    }
}

private struct PermissionRowView: View {
    let row: PermissionRow
    let model: PermissionsModel

    var body: some View {
        let info = PermissionInfo.info(for: row.permission)
        HStack(spacing: DT.s12) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous).fill(info?.tile ?? .gray)
                Image(systemName: info?.symbol ?? "questionmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 1) {
                Text(info?.title ?? row.permission.displayName).font(.system(size: DT.f10, weight: .semibold))
                Text(info?.purpose ?? "").font(.system(size: DT.f9)).foregroundStyle(.secondary)
            }
            Spacer(minLength: DT.s8)
            pill
            action
        }
        .padding(.horizontal, DT.s12)
        .padding(.vertical, 10)
    }

    private var pill: some View {
        let color: Color
        switch PermissionPresentation.tone(row.status) {
        case .good: color = DT.green
        case .bad: color = DT.red
        case .warn: color = DT.amber
        case .neutral: color = .secondary
        }
        return Text(PermissionPresentation.pillText(row.status))
            .font(.system(size: DT.f9, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .glassPillSurface(tint: nil)
    }

    @ViewBuilder
    private var action: some View {
        switch PermissionPresentation.action(row.status) {
        case .request:
            Button("Grant") { Task { await model.request(row.permission) } }
                .glassSubtleCapsule(tint: DT.systemAccent)
                .disabled(model.busy.contains(row.permission))
        case .openSettings:
            Button("Open Settings") { model.openSettings(row.permission) }
                .glassPlainCapsule()
        }
    }
}

private struct FailedView: View {
    let message: String
    let model: PermissionsModel

    var body: some View {
        VStack(spacing: DT.s8) {
            Image(systemName: "exclamationmark.triangle").font(.system(size: 20)).foregroundStyle(DT.amber)
            Text("Couldn\u{2019}t read the permissions").font(.system(size: DT.f12, weight: .semibold))
            Text(message).font(.system(size: DT.f9)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Try again") { Task { await model.refresh(recheckCLI: true) } }.glassPlainCapsule()
        }
        .padding(DT.s20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
