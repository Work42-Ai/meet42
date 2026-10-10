// Widget.swift — meet42's Event details widget.
//
// Reads the calendar event live through `meet42 show <event_id> --json` (the id is the session's
// `meeting/event_id`), so it works without any file in the session and reflects edits made in the calendar.
// An ad-hoc event session (no calendar event) shows a clean "Not linked" state.
//
//   • Card: calendar colour bar, source and status chips, title, absolute time, the meeting link with its provider
//     and a copy button, the location, the guest list (a summary with an RSVP bar, then the guests grouped by
//     reply: Going, Maybe, No reply, Declined) and the description (the notes as sanitised HTML, rendered by the
//     SDK markdown viewer).
//   • Header labels (every tab), both opening this widget: the time ("Starts in N min" → "Live · N min left" →
//     "Ended h:mm") and the guests, as first names only: "Yan, Ethan, Enmo and 4 more" (amber while anyone is
//     tentative, pending or unknown).
//   • Action: **Join** (the provider's brand colour) from 15 minutes before the start to the end; it opens the
//     meeting link with the operating system.
//
// The shared decoder, avatars and helpers live in work42-plugin/shared/MeetEvent.swift.

import AppKit
import Foundation
import Observation
import SwiftUI
import Work42UI
import Work42PluginKit

private let eventLink = URL(string: "meet42://widget/event-details")!

// MARK: - Widget

@Observable
@MainActor
final class EventDetailsWidget: Work42Widget, Work42WidgetBackground {

    let id = "event-details"
    let title = "Event details"
    let icon = "calendar"
    var linkIntents: [WidgetLinkIntentSpec] {
        [WidgetLinkIntentSpec(matchers: [.regex(#"^meet42://widget/event-details$"#)], perform: { _ in })]
    }
    var minSize: WidgetMinSize { WidgetMinSize(width: 300, height: 260) }

    /// The linked event, kept current by a poll that starts on activation (drives the Join action).
    private(set) var event: MeetEvent?
    @ObservationIgnored private var pollTask: Task<Void, Never>?

    func activate(services: SessionServices) {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                if case .loaded(let loaded) = await MeetEventLoader.load(shell: services.shell, storage: services.storage) {
                    self?.event = loaded
                } else {
                    self?.event = nil
                }
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    func deactivate() {
        pollTask?.cancel()
        pollTask = nil
        event = nil
    }

    func makeView(services: SessionServices) -> AnyView {
        AnyView(EventDetailsView(services: services))
    }

    func makeBackgroundAgent() -> any WidgetBackgroundAgent { EventDetailsLabelAgent() }

    // MARK: Join

    /// Join shows from 15 minutes before the start until the end, for an event that has a meeting link.
    private func joinURL(now: Date = Date()) -> URL? {
        guard let event, let link = event.meetingURL, let url = URL(string: link) else { return nil }
        return now >= event.startsAt.addingTimeInterval(-15 * 60) && now <= event.endsAt ? url : nil
    }

    var intents: [WidgetIntentSpec] {
        [
            WidgetIntentSpec(
                name: "join",
                title: "Join",
                icon: "video.fill",
                brandColorHex: MeetProvider.detect(event?.meetingURL)?.brandHex,
                keywords: ["meeting", "call", "zoom", "meet", "teams"],
                placement: [.actionArea, .palette],
                actionAreaStyle: .labeled,
                isEnabled: { [weak self] in self?.joinURL() != nil },
                livePeriodicTick: 30,
                perform: { [weak self] in
                    if let url = self?.joinURL() { NSWorkspace.shared.open(url) }
                }
            ),
        ]
    }
}

// MARK: - Label agent (one per session)

@Observable
@MainActor
final class EventDetailsLabelAgent: WidgetBackgroundAgent {

    private(set) var headerLabels: [WidgetHeaderLabel] = []

    @ObservationIgnored private var task: Task<Void, Never>?

    func start(services: WidgetBackgroundServices) {
        task?.cancel()
        task = Task { [weak self] in
            var event: MeetEvent?
            var lastLoad = Date.distantPast
            while !Task.isCancelled {
                if Date().timeIntervalSince(lastLoad) >= 60 {
                    if case .loaded(let loaded) = await MeetEventLoader.load(shell: services.shell, storage: services.storage) {
                        event = loaded
                    } else {
                        event = nil
                    }
                    lastLoad = Date()
                }
                self?.update(event)
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private func update(_ event: MeetEvent?) {
        var labels: [WidgetHeaderLabel] = []
        if let event, let item = MeetTimeLabel.label(for: event) {
            labels.append(WidgetHeaderLabel(text: item.text, systemIcon: "clock", tint: item.tint, url: eventLink))
        }
        if let event, let text = Self.guestsText(event.attendees) {
            labels.append(WidgetHeaderLabel(text: text, tint: event.hasOpenReplies ? .warning : .neutral, url: eventLink))
        }
        if labels != headerLabels { headerLabels = labels }
    }
}

extension EventDetailsLabelAgent {

    /// "Yan, Ethan, Enmo and 4 more": first names only. Up to 4 guests are all named ("Yan, Ethan, Enmo and Ana");
    /// beyond that the first 3 are named and the rest are counted. nil when there are no guests.
    static func guestsText(_ attendees: [MeetEvent.Attendee]) -> String? {
        let names = attendees.map(firstName)
        switch names.count {
        case 0: return nil
        case 1: return names[0]
        case 2...4: return names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
        default: return names.prefix(3).joined(separator: ", ") + " and \(names.count - 3) more"
        }
    }

    /// The first word of the name, else the part of the email before the "@".
    private static func firstName(_ person: MeetEvent.Attendee) -> String {
        let full = person.displayName
        let word = full.split(separator: " ").first.map(String.init) ?? full
        return word.split(separator: "@").first.map(String.init) ?? word
    }
}

// MARK: - View

private struct EventDetailsView: View {
    let services: SessionServices

    @State private var state: MeetEventState?
    @State private var descriptionExpanded = false

    var body: some View {
        Group {
            switch state {
            case nil:
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            case .unlinked?:
                emptyState
            case .failed(let command, let message)?:
                errorState(command: command, message: message)
            case .loaded(let event)?:
                EventCard(event: event, descriptionExpanded: $descriptionExpanded)
            }
        }
        .task {
            while !Task.isCancelled {
                state = await MeetEventLoader.load(shell: services.shell, storage: services.storage)
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: DT.s12) {
            Image(systemName: "calendar")
                .font(.system(size: 22))
                .foregroundStyle(.secondary)
                .frame(width: 46, height: 46)
                .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(DT.chipFill))
            Text("Not linked to a calendar event").font(.system(size: DT.f13, weight: .semibold))
            Text("Time, meeting link, location and guests appear here for meetings created from your calendar.")
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
            Label("Couldn\u{2019}t load the event", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: DT.f13, weight: .semibold))
                .foregroundStyle(DT.amber)
            Text(message).font(.system(size: DT.f11)).foregroundStyle(.secondary).textSelection(.enabled)
            Text(command).font(.system(size: DT.f10, design: .monospaced)).foregroundStyle(.tertiary).textSelection(.enabled)
        }
        .padding(DT.s16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct EventCard: View {
    let event: MeetEvent
    @Binding var descriptionExpanded: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DT.s12) {
                header
                if let link = event.meetingURL, let provider = MeetProvider.detect(link) { meetingLink(link, provider) }
                if let location = event.location?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !location.isEmpty, location != event.meetingURL { locationRow(location) }
                if !event.attendees.isEmpty { guests }
                if let html = event.notesHTML, !html.isEmpty { description(html) }
            }
            .padding(.horizontal, DT.s16)
            .padding(.bottom, DT.s16)
        }
    }

    // MARK: Header

    private var accent: Color { color(hex: event.calendarColor) ?? DT.systemAccent }

    private var header: some View {
        HStack(alignment: .top, spacing: DT.s12) {
            RoundedRectangle(cornerRadius: 2).fill(accent).frame(width: 4)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    chip("\(MeetProvider.sourceName(event.source))\(event.calendarTitle.map { " \u{00B7} \($0)" } ?? "")", tint: nil)
                    if let status = statusChip { chip(status.text, tint: status.tint) }
                }
                Text(event.title.isEmpty ? "(Untitled)" : event.title)
                    .font(.system(size: 21, weight: .bold))
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: DT.s8) {
                    Image(systemName: "clock").font(.system(size: DT.f11)).foregroundStyle(.secondary)
                    Text(timeText).font(.system(size: DT.f12))
                }
            }
        }
        .padding(.top, DT.s4)
    }

    private var statusChip: (text: String, tint: Color)? {
        switch event.status {
        case "confirmed": return ("Confirmed", DT.green)
        case "tentative": return ("Tentative", DT.amber)
        case "canceled": return ("Canceled", DT.red)
        default: return nil
        }
    }

    private var timeText: String {
        let day = DateFormatter()
        day.dateFormat = "EEE, MMM d"
        if event.allDay { return "\(day.string(from: event.startsAt)) \u{00B7} All day" }
        let time = DateFormatter()
        time.dateFormat = "h:mm"
        let end = DateFormatter()
        end.dateFormat = "h:mm a"
        return "\(day.string(from: event.startsAt)) \u{00B7} \(time.string(from: event.startsAt)) \u{2013} \(end.string(from: event.endsAt))"
    }

    // MARK: Cards

    private func meetingLink(_ link: String, _ provider: MeetProvider) -> some View {
        card {
            HStack(spacing: DT.s12) {
                Image(systemName: "video.fill")
                    .foregroundStyle(provider.brandHex.flatMap { color(hex: $0) } ?? DT.systemAccent)
                VStack(alignment: .leading, spacing: 1) {
                    Text(provider.name).font(.system(size: DT.f12, weight: .semibold))
                    Text(link.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: ""))
                        .font(.system(size: DT.f11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 0)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(link, forType: .string)
                } label: { Image(systemName: "doc.on.doc") }
                    .glassIconButton()
                    .help("Copy link")
            }
        }
    }

    private func locationRow(_ location: String) -> some View {
        card {
            HStack(spacing: DT.s12) {
                Image(systemName: "mappin.and.ellipse").foregroundStyle(.secondary)
                Text(location).font(.system(size: DT.f12)).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
        }
    }

    private var guests: some View {
        VStack(alignment: .leading, spacing: DT.s8) {
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
                    Text(guestBreakdown).font(.system(size: DT.f11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            rsvpBar
            ForEach(MeetRSVP.allCases, id: \.rawValue) { group in
                let members = event.attendees.filter { MeetRSVP(status: $0.status) == group }
                if !members.isEmpty { guestGroup(group, members) }
            }
        }
    }

    /// "4 going · 1 maybe · 1 no reply · organized by Ana Silva" (declined only when someone declined).
    private var guestBreakdown: String {
        var parts = ["\(event.count(.going)) going", "\(event.count(.maybe)) maybe", "\(event.count(.noReply)) no reply"]
        if event.count(.declined) > 0 { parts.append("\(event.count(.declined)) declined") }
        if let organizer = event.organizer, !organizer.isEmpty { parts.append("organized by \(organizer)") }
        return parts.joined(separator: " \u{00B7} ")
    }

    private func guestGroup(_ group: MeetRSVP, _ members: [MeetEvent.Attendee]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(group.title.uppercased()) \u{00B7} \(members.count)")
                .font(.system(size: DT.f10, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(.tertiary)
                .padding(.bottom, DT.s4)
            VStack(spacing: 0) {
                ForEach(Array(members.enumerated()), id: \.offset) { index, person in
                    if index > 0 { Divider().opacity(0.35).padding(.leading, 42) }
                    guestRow(person, group)
                }
            }
            .padding(.horizontal, DT.s8)
            .background(RoundedRectangle(cornerRadius: DT.rCard, style: .continuous).fill(DT.chipFill))
            .overlay(RoundedRectangle(cornerRadius: DT.rCard, style: .continuous).strokeBorder(DT.chipStroke, lineWidth: 0.5))
        }
    }

    private func guestRow(_ person: MeetEvent.Attendee, _ group: MeetRSVP) -> some View {
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

    private var rsvpBar: some View {
        let parts: [(Int, Color)] = [(event.count(.going), DT.green), (event.count(.maybe), DT.amber),
                                     (event.count(.noReply), DT.textTertiary), (event.count(.declined), DT.red)]
        return HStack(spacing: 2) {
            ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                if part.0 > 0 { RoundedRectangle(cornerRadius: 3).fill(part.1).frame(height: 6).layoutPriority(Double(part.0)) }
            }
        }
    }

    private func description(_ html: String) -> some View {
        card {
            VStack(alignment: .leading, spacing: DT.s8) {
                Label("Description", systemImage: "doc.text")
                    .font(.system(size: DT.f11, weight: .semibold)).foregroundStyle(.secondary)
                MarkdownPreview(text: html, autoHeight: true)
                    .frame(maxHeight: descriptionExpanded ? nil : 170, alignment: .top)
                    .clipped()
                Button(descriptionExpanded ? "Show less" : "Show more") { descriptionExpanded.toggle() }
                    .buttonStyle(.plain)
                    .font(.system(size: DT.f11))
                    .foregroundStyle(DT.systemAccent)
            }
        }
    }

    // MARK: Pieces

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(DT.s12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: DT.rCard, style: .continuous).fill(DT.chipFill))
            .overlay(RoundedRectangle(cornerRadius: DT.rCard, style: .continuous).strokeBorder(DT.chipStroke, lineWidth: 0.5))
    }

    private func chip(_ text: String, tint: Color?) -> some View {
        Text(text)
            .font(.system(size: DT.f10, weight: .semibold))
            .foregroundStyle(tint ?? .secondary)
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(Capsule().fill((tint ?? Color.primary).opacity(tint == nil ? 0.06 : 0.14)))
    }

    private func color(hex: String?) -> Color? {
        guard var hex, hex.hasPrefix("#") else { return nil }
        hex.removeFirst()
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        return Color(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }
}

@_cdecl("work42_widget_sdk_version")
public func work42_widget_sdk_version() -> Int32 { WidgetSDK.abiVersion }

@_cdecl("work42_widget_main")
public func work42_widget_main() -> UnsafeMutableRawPointer {
    nonisolated(unsafe) var result: UnsafeMutableRawPointer!
    MainActor.assumeIsolated {
        result = WidgetEntryPoint.register(EventDetailsWidget())
    }
    return result
}
