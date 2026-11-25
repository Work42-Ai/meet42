// AnnotationsWidget.swift — meet42's My Notes (annotations) widget.
//
// An editable notes tile whose content is `annotations.md` in the session folder, so it is part of the session and readable by
// the agent. The widget runs in the meet42 extension, which cannot touch the session folder itself: it reads, follows and
// writes the file through `services.files` (SDK 3.3.0), on the Mac and on an iPad alike.
//
// Two rules keep a person's typing safe: a change made elsewhere (the agent, another device) is taken in only while there is
// nothing unsaved here, and the text is kept when a save fails (the status says so and the next edit tries again).

import Foundation
import Observation
import SwiftUI
import Work42UI
import Work42PluginKit

/// The notes file's name inside the session folder.
private let annotationsFileName = "annotations.md"

// MARK: - AnnotationsWidget

@Observable
@MainActor
final class AnnotationsWidget: Work42Widget, Work42WidgetPill {

    let id = "annotations"
    let title = "Meet42 My Notes"
    let icon = "square.and.pencil"
    var linkIntents: [WidgetLinkIntentSpec] { [] }
    var minSize: WidgetMinSize { WidgetMinSize(width: 220, height: 160) }

    func makeView(services: SessionServices) -> AnyView {
        AnyView(AnnotationsView(services: services, compact: false))
    }

    // MARK: Work42WidgetPill

    func makePillView(services: SessionServices) -> AnyView? {
        AnyView(AnnotationsView(services: services, compact: true))
    }

    var pillMetadata: WidgetPillMetadata {
        WidgetPillMetadata(
            preferredSize: WidgetMinSize(width: 320, height: 220),
            title: title,
            icon: icon
        )
    }
}

// MARK: - NotesModel

/// My Notes over `SessionServices`: the notes are `annotations.md` in the session folder, read through `services.files`, followed
/// when they change, and saved by writing the file back through the same service. Everything here is plain logic, tested without
/// a view.
@MainActor
@Observable
final class NotesModel {

    enum SaveState: Equatable {
        case idle
        case saving
        case saved
        case failed(String)
    }

    /// The editor's text.
    var text = ""
    /// The notes as the session folder last held them (what was last read, or last saved).
    private(set) var savedText = ""
    private(set) var loaded = false
    /// Why the notes could not be read, when they could not.
    private(set) var failure: String?
    private(set) var saveState: SaveState = .idle

    /// How long after the last keystroke the notes are saved.
    var debounce: Duration = .milliseconds(500)

    private let services: SessionServices
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var saves = 0

    init(services: SessionServices) { self.services = services }

    var isDirty: Bool { text != savedText }

    /// Reads the file now and again whenever it changes, until the task is cancelled.
    func follow() async {
        await load()
        for await _ in services.files.watch(annotationsFileName) {
            await load()
        }
    }

    func load() async {
        do {
            let data = try await services.files.read(annotationsFileName)
            adopt(String(decoding: data, as: UTF8.self))
            failure = nil
        } catch let error as WidgetServiceError {
            // The file does not exist until the first note is written: that is the empty state, not a failure.
            if error.message.hasPrefix("no such file") {
                adopt("")
                failure = nil
            } else {
                failure = error.errorDescription ?? error.message
            }
        } catch {
            failure = error.localizedDescription
        }
        loaded = true
    }

    /// Takes in what the folder holds, unless there are unsaved edits here or a save is under way.
    private func adopt(_ stored: String) {
        guard !isDirty, saveState != .saving, stored != text else {
            if !isDirty { savedText = stored }
            return
        }
        text = stored
        savedText = stored
    }

    /// The editor's text changed: save it once typing pauses.
    func textChanged() {
        saveTask?.cancel()
        guard isDirty else { return }
        let wait = debounce
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled else { return }
            await self?.save()
        }
    }

    /// Saves now. A save that finishes after the person typed more leaves the newer text unsaved, and it is saved in turn.
    func save() async {
        saveTask?.cancel()
        let sending = text
        guard sending != savedText else { return }
        saves += 1
        let attempt = saves
        saveState = .saving
        do {
            try await services.files.write(annotationsFileName, data: Data(sending.utf8))
            guard attempt == saves else { return }   // a newer save has taken over
            savedText = sending
            saveState = .saved
            if isDirty { textChanged() }
        } catch {
            guard attempt == saves else { return }
            saveState = .failed((error as? WidgetServiceError)?.errorDescription ?? error.localizedDescription)
        }
    }
}

// MARK: - AnnotationsView

/// The editor: the tile (with its header) or the pill (the editor alone).
private struct AnnotationsView: View {

    @State private var model: NotesModel
    @FocusState private var isFocused: Bool
    let compact: Bool

    init(services: SessionServices, compact: Bool) {
        _model = State(initialValue: NotesModel(services: services))
        self.compact = compact
    }

    var body: some View {
        VStack(spacing: 0) {
            if !compact {
                header
                Divider().opacity(0.4)
            }
            content
        }
        .task { await model.follow() }
    }

    private var header: some View {
        HStack(spacing: DT.s8) {
            Image(systemName: "square.and.pencil")
                .font(.system(size: DT.f11, weight: .medium))
                .foregroundStyle(DT.textTertiary)
            Text("MY NOTES")
                .font(.system(size: DT.f9, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(DT.textTertiary)
            Spacer(minLength: 0)
            status
        }
        .padding(.horizontal, DT.s12)
        .padding(.vertical, DT.s8)
    }

    @ViewBuilder
    private var status: some View {
        switch model.saveState {
        case .idle: EmptyView()
        case .saving: Text("Saving\u{2026}").font(.system(size: DT.f9)).foregroundStyle(DT.textTertiary)
        case .saved: Text("Saved").font(.system(size: DT.f9)).foregroundStyle(DT.textTertiary)
        case .failed: Text("Not saved").font(.system(size: DT.f9, weight: .semibold)).foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private var content: some View {
        if let failure = model.failure, !model.loaded || model.text.isEmpty {
            Text(failure)
                .font(.system(size: DT.f12))
                .foregroundStyle(DT.textTertiary)
                .padding(DT.s16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            VStack(spacing: 0) {
                ZStack(alignment: .topLeading) {
                    if model.loaded && model.text.isEmpty && !isFocused {
                        Text(compact ? "Jot personal notes\u{2026}" : "Jot personal notes \u{2014} captured here and readable by the agent.")
                            .font(.system(size: compact ? DT.f12 : DT.f13))
                            .foregroundStyle(DT.textTertiary)
                            .allowsHitTesting(false)
                            .padding(.horizontal, compact ? DT.s12 : DT.s16)
                            .padding(.vertical, compact ? DT.s8 : DT.s12)
                    }
                    TextEditor(text: $model.text)
                        .focused($isFocused)
                        .font(.system(size: compact ? DT.f12 : DT.f13))
                        .foregroundStyle(.primary)
                        .scrollContentBackground(.hidden)
                        .background(Color.clear)
                        .padding(.horizontal, compact ? DT.s8 : DT.s12)
                        .padding(.vertical, compact ? DT.s4 : DT.s8)
                        .disabled(!model.loaded)
                        .onChange(of: model.text) { model.textChanged() }
                }
                if case .failed(let reason) = model.saveState {
                    Text(reason)
                        .font(.system(size: DT.f11))
                        .foregroundStyle(.red)
                        .padding(.horizontal, DT.s12)
                        .padding(.vertical, DT.s8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}
