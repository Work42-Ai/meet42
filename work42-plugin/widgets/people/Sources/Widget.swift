// Widget.swift — meet42's People widget.
//
// The guests of the session's calendar event, read live from `meet42 show <event_id> --json` (the same source as
// Event details), grouped by reply: Going, Maybe, No reply (pending and unknown) and Declined. Each person gets
// the shared avatar (colour from their email), their name or, when the calendar has none, their email, and
// Organizer / You chips. An ad-hoc event session shows "No guest list".
//
//   • Header label (every tab): one grouped pill — up to 3 avatar segments and "N people · a going", amber while
//     anyone is tentative, pending or unknown — which opens this widget (`meet42://widget/people`).
//
// The shared decoder, avatars and helpers live in work42-plugin/shared/MeetEvent.swift.

import AppKit
import Foundation
import Observation
import SwiftUI
import Work42UI
import Work42PluginKit

private let peopleLink = URL(string: "meet42://widget/people")!

// MARK: - Widget

@Observable
@MainActor
final class PeopleWidget: Work42Widget, Work42WidgetBackground {

    let id = "people"
    let title = "People"
    let icon = "person.2.fill"
    var linkIntents: [WidgetLinkIntentSpec] {
        [WidgetLinkIntentSpec(matchers: [.regex(#"^meet42://widget/people$"#)], perform: { _ in })]
    }
    var minSize: WidgetMinSize { WidgetMinSize(width: 280, height: 220) }

    func activate(services: SessionServices) {}
    func deactivate() {}

    func makeView(services: SessionServices) -> AnyView {
        AnyView(PeopleView(services: services))
    }

    func makeBackgroundAgent() -> any WidgetBackgroundAgent { PeopleLabelAgent() }
}

// MARK: - Label agent (one per session)

@Observable
@MainActor
final class PeopleLabelAgent: WidgetBackgroundAgent {

    private(set) var headerLabels: [WidgetHeaderLabel] = []

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var avatarPNG: [String: Data] = [:]

    func start(services: WidgetBackgroundServices) {
        task?.cancel()
        task = Task { [weak self] in
            while !Task.isCancelled {
                if case .loaded(let event) = await MeetEventLoader.load(shell: services.shell, storage: services.storage) {
                    self?.update(event)
                } else if self?.headerLabels.isEmpty == false {
                    self?.headerLabels = []
                }
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private func update(_ event: MeetEvent) {
        guard !event.attendees.isEmpty else {
            if !headerLabels.isEmpty { headerLabels = [] }
            return
        }
        let group = "meet42.people"
        var labels: [WidgetHeaderLabel] = event.attendees.prefix(3).map { person in
            WidgetHeaderLabel(
                text: "", iconImageData: png(for: person), tint: .neutral, url: peopleLink, groupId: group
            )
        }
        let count = event.attendees.count
        let text = "\(count) \(count == 1 ? "person" : "people") \u{00B7} \(event.count(.going)) going"
        labels.append(WidgetHeaderLabel(
            text: text, tint: event.hasOpenReplies ? .warning : .neutral, url: peopleLink, groupId: group
        ))
        if labels != headerLabels { headerLabels = labels }
    }

    /// A PNG of the person's avatar for a label segment (rendered once per person).
    private func png(for person: MeetEvent.Attendee) -> Data? {
        let key = MeetAvatar.key(name: person.name, email: person.email)
        if let cached = avatarPNG[key] { return cached }
        let renderer = ImageRenderer(content: MeetAvatarView(
            initials: MeetAvatar.initials(name: person.name, email: person.email), key: key, size: 18
        ).padding(1))
        renderer.scale = 2
        guard let cgImage = renderer.cgImage else { return nil }
        let data = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
        if let data { avatarPNG[key] = data }
        return data
    }
}

// MARK: - View

private struct PeopleView: View {
    let services: SessionServices

    @State private var state: MeetEventState?

    var body: some View {
        Group {
            switch state {
            case nil:
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            case .unlinked?:
                message(symbol: "person.2", title: "No guest list",
                        text: "Guests and their replies appear here for meetings created from your calendar.")
            case .failed(let command, let detail)?:
                errorState(command: command, message: detail)
            case .loaded(let event)?:
                if event.attendees.isEmpty {
                    message(symbol: "person.2", title: "No guest list", text: "This event has no guests.")
                } else {
                    PeopleList(event: event)
                }
            }
        }
        .task {
            while !Task.isCancelled {
                state = await MeetEventLoader.load(shell: services.shell, storage: services.storage)
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    private func message(symbol: String, title: String, text: String) -> some View {
        VStack(spacing: DT.s12) {
            Image(systemName: symbol)
                .font(.system(size: 22))
                .foregroundStyle(.secondary)
                .frame(width: 46, height: 46)
                .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(DT.chipFill))
            Text(title).font(.system(size: DT.f13, weight: .semibold))
            Text(text)
                .font(.system(size: DT.f11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 300)
        }
        .padding(DT.s24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorState(command: String, message: String) -> some View {
        VStack(alignment: .leading, spacing: DT.s8) {
            Label("Couldn\u{2019}t load the guests", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: DT.f13, weight: .semibold))
                .foregroundStyle(DT.amber)
            Text(message).font(.system(size: DT.f11)).foregroundStyle(.secondary).textSelection(.enabled)
            Text(command).font(.system(size: DT.f10, design: .monospaced)).foregroundStyle(.tertiary).textSelection(.enabled)
        }
        .padding(DT.s16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct PeopleList: View {
    let event: MeetEvent

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DT.s12) {
                summary
                ForEach(MeetRSVP.allCases, id: \.rawValue) { group in
                    let members = event.attendees.filter { MeetRSVP(status: $0.status) == group }
                    if !members.isEmpty { section(group, members) }
                }
            }
            .padding(.horizontal, DT.s16)
            .padding(.bottom, DT.s16)
            .padding(.top, DT.s4)
        }
    }

    private var summary: some View {
        HStack(spacing: DT.s12) {
            HStack(spacing: -8) {
                ForEach(Array(event.attendees.prefix(4).enumerated()), id: \.offset) { _, a in
                    MeetAvatarView(initials: MeetAvatar.initials(name: a.name, email: a.email),
                                   key: MeetAvatar.key(name: a.name, email: a.email), size: 30)
                }
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("\(event.attendees.count) \(event.attendees.count == 1 ? "person" : "people")")
                    .font(.system(size: 15, weight: .bold))
                Text(breakdown).font(.system(size: DT.f11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private var breakdown: String {
        var parts = ["\(event.count(.going)) going", "\(event.count(.maybe)) maybe", "\(event.count(.noReply)) no reply"]
        if event.count(.declined) > 0 { parts.append("\(event.count(.declined)) declined") }
        return parts.joined(separator: " \u{00B7} ")
    }

    private func section(_ group: MeetRSVP, _ members: [MeetEvent.Attendee]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(group.title.uppercased()) \u{00B7} \(members.count)")
                .font(.system(size: DT.f10, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(.tertiary)
                .padding(.bottom, DT.s4)
            VStack(spacing: 0) {
                ForEach(Array(members.enumerated()), id: \.offset) { index, person in
                    if index > 0 { Divider().opacity(0.35).padding(.leading, 42) }
                    row(person, group)
                }
            }
            .padding(.horizontal, DT.s8)
            .background(RoundedRectangle(cornerRadius: DT.rCard, style: .continuous).fill(DT.chipFill))
            .overlay(RoundedRectangle(cornerRadius: DT.rCard, style: .continuous).strokeBorder(DT.chipStroke, lineWidth: 0.5))
        }
    }

    private func row(_ person: MeetEvent.Attendee, _ group: MeetRSVP) -> some View {
        HStack(spacing: DT.s12) {
            MeetAvatarView(initials: MeetAvatar.initials(name: person.name, email: person.email),
                           key: MeetAvatar.key(name: person.name, email: person.email), size: 30)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(person.displayName).font(.system(size: DT.f12, weight: .semibold)).lineLimit(1)
                    if person.isOrganizer { chip("Organizer", tint: DT.systemAccent) }
                    if person.isCurrentUser { chip("You", tint: nil) }
                }
                if let email = person.email, person.name?.isEmpty == false {
                    Text(email).font(.system(size: DT.f11)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: group.symbol).foregroundStyle(group.color)
        }
        .padding(.vertical, 8)
    }

    private func chip(_ text: String, tint: Color?) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(tint ?? .secondary)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(Capsule().fill((tint ?? Color.primary).opacity(tint == nil ? 0.07 : 0.14)))
    }
}

@_cdecl("work42_widget_sdk_version")
public func work42_widget_sdk_version() -> Int32 { WidgetSDK.abiVersion }

@_cdecl("work42_widget_main")
public func work42_widget_main() -> UnsafeMutableRawPointer {
    nonisolated(unsafe) var result: UnsafeMutableRawPointer!
    MainActor.assumeIsolated {
        result = WidgetEntryPoint.register(PeopleWidget())
    }
    return result
}
