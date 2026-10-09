// Widget.swift — meet42's Permissions widget (WOR-65).
//
// A small tile on the meet42 session's Brief tab that shows, one row each, the four macOS privacy permissions
// meet42 needs (Calendar, Microphone, Speech recognition, Screen & system audio) and gives each its own
// action: Request (macOS has never been asked) or Open Settings (anything else). Every fact and every action
// comes from the `meet42` CLI:
//
//   meet42 permissions --json                      the four statuses, in this order
//   meet42 permissions request <name> --json       show macOS's prompt for one
//   meet42 permissions open <name>                 open that permission's System Settings page
//
// All four rows are always shown, granted or not. When the CLI is not installed the tile says so and offers
// Set up meet42, which runs `work42 plugin setup meet42` (a chat that follows the plugin's skills).
//
// Links only Work42PluginKit + Work42UI.

import AppKit
import Foundation
import Observation
import SwiftUI
import Work42UI
import Work42PluginKit

// MARK: - Model (local mirror of `meet42 permissions --json`)

/// One entry of `meet42 permissions --json`.
struct PermissionRow: Codable, Identifiable, Equatable {
    let name: String
    let status: String
    var id: String { name }
}

/// The four permissions, in display order, with the words and glyphs the rows use.
struct PermissionInfo {
    let name: String
    let title: String
    let purpose: String
    let symbol: String
    let tile: Color

    static let all: [PermissionInfo] = [
        .init(name: "calendar", title: "Calendar", purpose: "List meetings and prepare sessions",
              symbol: "calendar", tile: Color(red: 1.00, green: 0.27, blue: 0.23)),
        .init(name: "microphone", title: "Microphone", purpose: "Record meeting audio locally",
              symbol: "mic.fill", tile: Color(red: 1.00, green: 0.62, blue: 0.04)),
        .init(name: "speech", title: "Speech recognition", purpose: "On-device transcription",
              symbol: "waveform", tile: Color(red: 0.37, green: 0.36, blue: 0.90)),
        .init(name: "screen", title: "Screen & system audio", purpose: "Hear the other side of the call",
              symbol: "rectangle.on.rectangle", tile: Color(red: 0.19, green: 0.69, blue: 0.78)),
    ]

    static func info(for name: String) -> PermissionInfo? { all.first { $0.name == name } }
}

/// What a row's status pill and button say. Pure, so it is easy to reason about.
enum PermissionPresentation {
    enum Action: Equatable { case request, openSettings }
    enum Tone { case good, bad, warn, neutral }

    static func pillText(name: String, status: String) -> String {
        switch status {
        case "granted": return "Granted"
        case "not_determined": return "Not asked"
        case "restricted": return "Restricted"
        case "denied": return name == "screen" ? "Off" : "Denied"
        default: return status
        }
    }

    static func tone(name: String, status: String) -> Tone {
        switch status {
        case "granted": return .good
        case "restricted": return .warn
        case "denied": return name == "screen" ? .warn : .bad
        default: return .neutral
        }
    }

    /// Request only when macOS has never been asked (and a prompt exists); everything else opens Settings.
    static func action(name: String, status: String) -> Action {
        status == "not_determined" && name != "screen" ? .request : .openSettings
    }

    static func summary(_ rows: [PermissionRow]) -> String {
        let attention = rows.filter { $0.status != "granted" }.count
        return attention == 0 ? "All \(rows.count) allowed" : "\(attention) of \(rows.count) need attention"
    }
}

/// Decodes `meet42 permissions --json`, keeping the display order and ignoring names this widget does not know.
func decodePermissions(_ json: String) -> [PermissionRow]? {
    guard let data = json.data(using: .utf8),
          let rows = try? JSONDecoder().decode([PermissionRow].self, from: data) else { return nil }
    let known = rows.filter { PermissionInfo.info(for: $0.name) != nil }
    return known.sorted { lhs, rhs in
        (PermissionInfo.all.firstIndex { $0.name == lhs.name } ?? 0)
            < (PermissionInfo.all.firstIndex { $0.name == rhs.name } ?? 0)
    }
}

@MainActor
@Observable
final class PermissionsModel {
    enum Phase: Equatable {
        case loading
        case notInstalled
        case failed(String)
        case ready([PermissionRow])
    }

    var phase: Phase = .loading
    var version: String?
    var binaryDirectory: String?
    var busy: Set<String> = []
    var setUpError: String?

    @ObservationIgnored var services: SessionServices?

    func refresh() async {
        guard let services else { return }
        // Is the tool there at all?
        guard let located = try? await services.shell.run(command: "command -v meet42"),
              located.exitCode == 0,
              !located.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            phase = .notInstalled
            version = nil
            binaryDirectory = nil
            return
        }
        let path = located.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        binaryDirectory = (path as NSString).deletingLastPathComponent
        if let v = try? await services.shell.run(command: "meet42 --version"), v.exitCode == 0 {
            version = v.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "meet42 v", with: "")
        }
        guard let result = try? await services.shell.run(command: "meet42 permissions --json") else {
            phase = .failed("Couldn\u{2019}t run meet42.")
            return
        }
        guard result.exitCode == 0, let rows = decodePermissions(result.stdout) else {
            let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            phase = .failed(detail.isEmpty ? "meet42 permissions didn\u{2019}t return a list." : detail)
            return
        }
        phase = .ready(rows)
    }

    func request(_ name: String) async {
        guard let services, !busy.contains(name) else { return }
        busy.insert(name)
        defer { busy.remove(name) }
        _ = try? await services.shell.run(command: "meet42 permissions request \(name) --json")
        await refresh()
    }

    func openSettings(_ name: String) async {
        guard let services else { return }
        _ = try? await services.shell.run(command: "meet42 permissions open \(name)")
    }

    func setUp() async {
        guard let services else { return }
        setUpError = nil
        guard let result = try? await services.shell.run(command: "work42 plugin setup meet42") else {
            setUpError = "Couldn\u{2019}t run work42."
            return
        }
        if result.exitCode != 0 {
            let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            setUpError = detail.isEmpty ? "work42 plugin setup meet42 failed." : detail
        }
    }
}

// MARK: - Widget

@MainActor
@Observable
final class PermissionsWidget: Work42Widget, Work42WidgetCustomHeader {

    let id = "permissions"
    let title = "meet42 permissions"
    let icon = "lock.shield"
    var linkIntents: [WidgetLinkIntentSpec] { [] }
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
            Text("meet42 permissions")
                .font(.system(size: DT.f12, weight: .medium))
                .foregroundStyle(.primary)
            Spacer(minLength: DT.s8)
            Button {
                Task { await model.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .semibold))
            }
            .glassIconButton()
            .help("Check again")
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
            case .notInstalled:
                NotInstalledView(model: model)
            case .failed(let message):
                FailedView(message: message, model: model)
            case .ready(let rows):
                ReadyView(rows: rows, model: model)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task { await model.refresh() }
        // A permission switched on in System Settings shows up as soon as the user comes back.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.refresh() }
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
                if rows.contains(where: { $0.name == "screen" && $0.status != "granted" }) {
                    Label {
                        Text("Screen & system audio can only be switched on in System Settings \u{2192} Privacy & Security \u{2192} Screen & System Audio Recording \u{2192} meet42. Come back here and it updates on its own.")
                            .font(.system(size: DT.f10))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "info.circle").foregroundStyle(.secondary)
                    }
                    .padding(DT.s12)
                    .background(RoundedRectangle(cornerRadius: DT.rCard, style: .continuous).fill(DT.chipFill))
                }
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
            if let version = model.version { chip("meet42 \(version)") }
            if let dir = model.binaryDirectory { chip(dir.replacingOccurrences(of: NSHomeDirectory(), with: "~")) }
        }
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
        let info = PermissionInfo.info(for: row.name)
        HStack(spacing: DT.s12) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous).fill(info?.tile ?? .gray)
                Image(systemName: info?.symbol ?? "questionmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 1) {
                Text(info?.title ?? row.name).font(.system(size: DT.f10, weight: .semibold))
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
        let text = PermissionPresentation.pillText(name: row.name, status: row.status)
        let color: Color
        switch PermissionPresentation.tone(name: row.name, status: row.status) {
        case .good: color = DT.green
        case .bad: color = DT.red
        case .warn: color = DT.amber
        case .neutral: color = .secondary
        }
        return Text(text)
            .font(.system(size: DT.f9, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .glassPillSurface(tint: nil)
    }

    @ViewBuilder
    private var action: some View {
        switch PermissionPresentation.action(name: row.name, status: row.status) {
        case .request:
            Button("Request") { Task { await model.request(row.name) } }
                .glassSubtleCapsule(tint: DT.systemAccent)
                .disabled(model.busy.contains(row.name))
        case .openSettings:
            Button("Open Settings") { Task { await model.openSettings(row.name) } }
                .glassPlainCapsule()
        }
    }
}

private struct NotInstalledView: View {
    let model: PermissionsModel

    var body: some View {
        VStack(spacing: DT.s12) {
            Image(systemName: "terminal")
                .font(.system(size: 22))
                .foregroundStyle(.secondary)
                .frame(width: 44, height: 44)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(DT.chipFill))
            Text("meet42 isn\u{2019}t installed").font(.system(size: DT.f12, weight: .semibold))
            Text("The meet42 command-line tool records and transcribes your meetings. Install it to check its permissions.")
                .font(.system(size: DT.f10))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 300)
            Button("Set up meet42") { Task { await model.setUp() } }
                .glassSubtleCapsule(tint: DT.systemAccent)
            Text("Opens a chat that installs it for you")
                .font(.system(size: DT.f9))
                .foregroundStyle(.tertiary)
            if let error = model.setUpError {
                Text(error).font(.system(size: DT.f9)).foregroundStyle(DT.red).multilineTextAlignment(.center)
            }
        }
        .padding(DT.s20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            Button("Try again") { Task { await model.refresh() } }.glassPlainCapsule()
        }
        .padding(DT.s20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Entry points

@_cdecl("work42_widget_sdk_version")
public func work42_widget_sdk_version() -> Int32 { WidgetSDK.abiVersion }

@_cdecl("work42_widget_main")
public func work42_widget_main() -> UnsafeMutableRawPointer {
    nonisolated(unsafe) var result: UnsafeMutableRawPointer!
    MainActor.assumeIsolated { result = WidgetEntryPoint.register(PermissionsWidget()) }
    return result
}
