// Widget.swift — meet42's My Notes (annotations) widget
// (meet42-plugin-conversion, s12).
//
// A faithful, identical-UI port of the app's AnnotationsWidgetView
// (`Sources/Work42App/Meetings/AnnotationsWidgetView.swift`) into a plugin
// widget that links ONLY Work42PluginKit + Work42UI. An editable notes tile
// whose content persists to `<dir>/annotations.md` inside the session dir so
// it is part of the session and readable by the agent.
//
// The original leaned on three app/Flow42Core symbols that a plugin widget
// can't import; each is replaced with a small self-contained equivalent:
//   - Flow42Core.AnnotationsStore (path/load/atomic-save) → local free
//     functions doing direct file I/O with a temp-file + rename atomic save.
//   - Flow42Core.SessionLatestFile (the atomic-write recipe)              → same.
//   - Work42App.FileWatcher (reload on external change)                   → a
//     local Timer-based mtime/size poller (WidgetFileWatcher).
//
// Behaviour (unchanged from the original):
//   - Load on appear; placeholder when the file is absent.
//   - Save on edit: debounced (~500 ms) atomic write so a concurrent reader
//     never sees a half-written file.
//   - Reload guard: external changes only reload when the tile is NOT focused
//     AND has no unsaved local edits.
//
// SESSION FILE (read + write): <dir>/annotations.md

import Foundation
import Observation
import SwiftUI
import Work42UI
import Work42PluginKit

// MARK: - Annotations file I/O (local AnnotationsStore replacement)

/// The notes file's name inside the session folder.
private let annotationsFileName = "annotations.md"

/// Absolute path to `annotations.md` inside the session dir.
private func annotationsPath(sessionDir: String) -> String {
    (sessionDir as NSString).appendingPathComponent(annotationsFileName)
}

/// Read the current annotations, or "" when the file is absent/unreadable.
private func loadAnnotations(sessionDir: String) -> String {
    (try? String(contentsOfFile: annotationsPath(sessionDir: sessionDir), encoding: .utf8)) ?? ""
}

/// Atomic write: temp file in the same dir + rename, so a concurrent watcher
/// reader never sees a half-written file (the `SessionLatestFile` recipe).
private func saveAnnotations(sessionDir: String, text: String) throws {
    try FileManager.default.createDirectory(
        atPath: sessionDir, withIntermediateDirectories: true
    )
    let dest = URL(fileURLWithPath: annotationsPath(sessionDir: sessionDir))
    try Data(text.utf8).write(to: dest, options: .atomic)
}

// MARK: - WidgetFileWatcher (local FileWatcher reimplementation)

/// Minimal self-contained replacement for `Work42App.FileWatcher`. Polls the
/// file's (mtime, size) signature every second and bumps `version` on change.
@Observable
@MainActor
final class WidgetFileWatcher {

    private(set) var version = 0

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var path: String?
    @ObservationIgnored private var lastSignature = ""

    func watch(_ path: String) {
        guard self.path != path else { return }
        self.path = path
        lastSignature = Self.signature(of: path)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.poll() }
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        guard let path else { return }
        let sig = Self.signature(of: path)
        guard sig != lastSignature else { return }
        lastSignature = sig
        version &+= 1
    }

    private static func signature(of path: String) -> String {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let size = (attrs?[.size] as? Int) ?? 0
        return "\(mtime)-\(size)"
    }
}

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
        #if os(macOS)
        AnyView(AnnotationsWidgetView(sessionDir: services.worktreePath ?? ""))
        #else
        // Not the Mac: the notes file is on the Mac, so it is read through `services.files`.
        AnyView(AnnotationsRemoteView(services: services))
        #endif
    }

    // MARK: Work42WidgetPill

    func makePillView(services: SessionServices) -> AnyView? {
        AnyView(AnnotationsPillView(sessionDir: services.worktreePath ?? ""))
    }

    var pillMetadata: WidgetPillMetadata {
        WidgetPillMetadata(
            preferredSize: WidgetMinSize(width: 320, height: 220),
            title: title,
            icon: icon
        )
    }
}

// MARK: - AnnotationsWidgetView (ported)

/// Editable personal annotations tile. Faithful port of the app view, with the
/// loading-state plumbing dropped (plugin widgets own their own chrome).
private struct AnnotationsWidgetView: View {

    let sessionDir: String

    @State private var text: String = ""
    @State private var isDirty: Bool = false
    @FocusState private var isFocused: Bool
    @State private var lastSavedText: String = ""
    @State private var watcher = WidgetFileWatcher()
    @State private var saveTimer: Timer? = nil

    var body: some View {
        VStack(spacing: 0) {
            headerRow
            Divider().opacity(0.4)
            editorArea
        }
        .onAppear {
            let path = annotationsPath(sessionDir: sessionDir)
            let contents = loadAnnotations(sessionDir: sessionDir)
            text          = contents
            lastSavedText = contents
            isDirty       = false
            watcher.watch(path)
        }
        .onChange(of: watcher.version) {
            // External change detected. Only reload if we have no local edits
            // and the editor is not focused — guarding against clobbering
            // in-flight user input.
            guard !isDirty, !isFocused else { return }
            let onDisk = loadAnnotations(sessionDir: sessionDir)
            guard onDisk != text else { return }
            text = onDisk
            lastSavedText = onDisk
        }
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack(spacing: DT.s8) {
            Image(systemName: "square.and.pencil")
                .font(.system(size: DT.f11, weight: .medium))
                .foregroundStyle(DT.textTertiary)
            Text("MY NOTES")
                .font(.system(size: DT.f9, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(DT.textTertiary)
            Spacer(minLength: 0)
            if isDirty {
                Text("Saving…")
                    .font(.system(size: DT.f9))
                    .foregroundStyle(DT.textTertiary)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, DT.s12)
        .padding(.vertical, DT.s8)
        .animation(.easeInOut(duration: 0.2), value: isDirty)
    }

    // MARK: - Editor

    private var editorArea: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty && !isFocused {
                placeholder
            }
            TextEditor(text: $text)
                .focused($isFocused)
                .font(.system(size: DT.f13))
                .foregroundStyle(.primary)
                .scrollContentBackground(.hidden)
                .background(Color.clear)
                .padding(.horizontal, DT.s12)
                .padding(.vertical, DT.s8)
                .onChange(of: text) { _, newValue in
                    isDirty = true
                    scheduleDebounce(text: newValue)
                }
        }
    }

    private var placeholder: some View {
        Text("Jot personal notes — captured here and readable by the agent.")
            .font(.system(size: DT.f13))
            .foregroundStyle(DT.textTertiary)
            .allowsHitTesting(false)
            .padding(.horizontal, DT.s16)
            .padding(.vertical, DT.s12)
    }

    // MARK: - Persistence

    /// Arms (or re-arms) the 500 ms debounce timer. Each keystroke resets
    /// the countdown; the file is only written once the user pauses.
    private func scheduleDebounce(text: String) {
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    commitToDisk(text: text)
                }
            }
        }
    }

    private func commitToDisk(text: String) {
        do {
            try saveAnnotations(sessionDir: sessionDir, text: text)
            lastSavedText = text
            isDirty = false
        } catch {
            fputs("[annotations] write failed: \(error)\n", stderr)
        }
    }
}

// MARK: - RemoteNotesModel (a device that is not the Mac)

/// My Notes on a device that is not the Mac: the notes are `annotations.md` in the session folder on the Mac. This reads that file
/// through `services.files`, follows its changes, and saves what the person types by asking the Mac to write it
/// (`meet42 notes write`), because a widget's file service is read-only. Everything here is plain logic over `SessionServices`, so
/// it is tested on the Mac; only the editor view is iOS-only.
///
/// Two rules keep a person's typing safe: a change made elsewhere is taken in only while there is nothing unsaved here, and the
/// text is kept when a save fails (the status says so and the next edit tries again).
@MainActor
@Observable
final class RemoteNotesModel {

    enum SaveState: Equatable {
        case idle
        case saving
        case saved
        case failed(String)
    }

    /// The editor's text.
    var text = ""
    /// The notes as the Mac last held them (what was last read, or last saved).
    private(set) var savedText = ""
    private(set) var loaded = false
    /// Why the notes could not be read, when they could not.
    private(set) var failure: String?
    private(set) var saveState: SaveState = .idle

    /// How long after the last keystroke the notes are saved.
    var debounce: Duration = .seconds(1)
    /// The most a note may be to send in one command: base64 characters (about 300 KB of text). Over it, the editor says so.
    static let maxPayload = 400_000

    private let services: SessionServices
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var saves = 0

    init(services: SessionServices) { self.services = services }

    var isDirty: Bool { text != savedText }

    /// Reads the file now and again whenever the Mac reports it changed, until the task is cancelled.
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

    /// Takes in what the Mac holds, unless there are unsaved edits here or a save is under way.
    private func adopt(_ remote: String) {
        guard !isDirty, saveState != .saving, remote != text else {
            if !isDirty { savedText = remote }
            return
        }
        text = remote
        savedText = remote
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
        let payload = Data(sending.utf8).base64EncodedString()
        guard payload.count <= Self.maxPayload else {
            saveState = .failed("This note is too long to save from the iPad. Shorten it, or save it on your Mac.")
            return
        }
        saves += 1
        let attempt = saves
        saveState = .saving
        do {
            let result = try await services.shell.run(command: "meet42 notes write --base64 '\(payload)'")
            guard attempt == saves else { return }   // a newer save has taken over
            guard result.exitCode == 0 else {
                let said = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                saveState = .failed(said.isEmpty ? "meet42 couldn't save the notes (exit \(result.exitCode))." : said)
                return
            }
            savedText = sending
            saveState = .saved
            if isDirty { textChanged() }
        } catch {
            guard attempt == saves else { return }
            let reason = (error as? WidgetServiceError)?.errorDescription ?? error.localizedDescription
            saveState = .failed(reason)
        }
    }
}

#if !os(macOS)
// MARK: - AnnotationsRemoteView (a device that is not the Mac)

private struct AnnotationsRemoteView: View {

    @State private var model: RemoteNotesModel
    @FocusState private var isFocused: Bool

    init(services: SessionServices) {
        _model = State(initialValue: RemoteNotesModel(services: services))
    }

    var body: some View {
        VStack(spacing: 0) {
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
            Divider().opacity(0.4)
            content
        }
        .task { await model.follow() }
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
                        Text("Jot personal notes \u{2014} captured here and readable by the agent.")
                            .font(.system(size: DT.f13))
                            .foregroundStyle(DT.textTertiary)
                            .allowsHitTesting(false)
                            .padding(.horizontal, DT.s16)
                            .padding(.vertical, DT.s12)
                    }
                    TextEditor(text: $model.text)
                        .focused($isFocused)
                        .font(.system(size: DT.f13))
                        .scrollContentBackground(.hidden)
                        .padding(.horizontal, DT.s12)
                        .padding(.vertical, DT.s8)
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
#endif

// MARK: - AnnotationsPillView (compact editor)

/// Compact pill rendering: the editor without the header chrome. Same
/// load/debounced-atomic-save persistence as the full widget.
private struct AnnotationsPillView: View {

    let sessionDir: String

    @State private var text: String = ""
    @State private var isDirty: Bool = false
    @FocusState private var isFocused: Bool
    @State private var watcher = WidgetFileWatcher()
    @State private var saveTimer: Timer? = nil

    var body: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty && !isFocused {
                Text("Jot personal notes…")
                    .font(.system(size: DT.f12))
                    .foregroundStyle(DT.textTertiary)
                    .allowsHitTesting(false)
                    .padding(.horizontal, DT.s12)
                    .padding(.vertical, DT.s8)
            }
            TextEditor(text: $text)
                .focused($isFocused)
                .font(.system(size: DT.f12))
                .foregroundStyle(.primary)
                .scrollContentBackground(.hidden)
                .background(Color.clear)
                .padding(.horizontal, DT.s8)
                .padding(.vertical, DT.s4)
                .onChange(of: text) { _, newValue in
                    isDirty = true
                    scheduleDebounce(text: newValue)
                }
        }
        .onAppear {
            let contents = loadAnnotations(sessionDir: sessionDir)
            text = contents
            isDirty = false
            watcher.watch(annotationsPath(sessionDir: sessionDir))
        }
        .onChange(of: watcher.version) {
            guard !isDirty, !isFocused else { return }
            let onDisk = loadAnnotations(sessionDir: sessionDir)
            guard onDisk != text else { return }
            text = onDisk
        }
    }

    private func scheduleDebounce(text: String) {
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    do {
                        try saveAnnotations(sessionDir: sessionDir, text: text)
                        isDirty = false
                    } catch {
                        fputs("[annotations] write failed: \(error)\n", stderr)
                    }
                }
            }
        }
    }
}

// MARK: - Hosting without the plugin loader

/// A new instance of this widget, for a host that builds widgets itself (the iPad app, through `Meet42Widgets`).
/// The plugin loader builds the same class through `work42_widget_main`.
public func meet42MakeWidget() -> any Work42Widget { AnnotationsWidget() }

// The plugin loader's entry points. Not part of the SwiftPM library build: every widget would export the same two
// C symbols, and a host that links several widgets has no use for them.
#if !MEET42_WIDGETS_LIBRARY
// MARK: - Widget entry-point ABI

@_cdecl("work42_widget_sdk_version")
public func work42_widget_sdk_version() -> Int32 { WidgetSDK.abiVersion }

@_cdecl("work42_widget_main")
public func work42_widget_main() -> UnsafeMutableRawPointer {
    nonisolated(unsafe) var result: UnsafeMutableRawPointer!
    MainActor.assumeIsolated {
        result = WidgetEntryPoint.register(AnnotationsWidget())
    }
    return result
}
#endif
