// PinnedArtifact.swift — shared by the Meeting brief and Summary widgets (copied into each widget's Sources by
// scripts/sync-shared.sh, because every widget compiles on its own).
//
// A widget that always shows ONE session artifact full size: it resolves the artifact's loopback URL with
// `ArtifactRuntime.url(sessionId:artifactId:)`, renders it with `WebSectionView` from `WebAppCatalog.artifact(url:)`
// (the same pieces the built-in Artifacts widget uses), and reloads when the agent rewrites the artifact's
// `index.html`. Links inside the page go to Work42's Open Link intent (`WebSectionView` does that itself).

import Foundation
import Observation
import SwiftUI
import Work42UI
import Work42PluginKit

// MARK: - File watcher

/// Polls one file's modification time and size once a second and bumps `version` when either changes (or the
/// file appears), so a SwiftUI body that reads `version` re-runs.
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
        path = nil
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

// MARK: - Locating an artifact on disk

enum PinnedArtifactLocator {

    /// `<session dir>/artifacts/<id>/index.html`. The session dir is the one `work42 artifact set` registered with
    /// the artifact server, else the session's worktree (what the widgets register themselves). Nil when neither
    /// is known.
    static func indexPath(sessionId: String?, worktreePath: String?, artifactId: String) -> String? {
        let directory = sessionId.flatMap { ArtifactRuntime.directory(forSessionId: $0) } ?? worktreePath
        guard let directory, !directory.isEmpty else { return nil }
        return ((directory as NSString).appendingPathComponent("artifacts") as NSString)
            .appendingPathComponent("\(artifactId)/index.html")
    }

    static func exists(sessionId: String?, worktreePath: String?, artifactId: String) -> Bool {
        guard let path = indexPath(sessionId: sessionId, worktreePath: worktreePath, artifactId: artifactId) else { return false }
        return FileManager.default.fileExists(atPath: path)
    }

    /// Makes the session known to the artifact server, as the built-in Artifacts widget's session is, so its URL
    /// resolves even before the agent has written anything.
    static func register(sessionId: String?, worktreePath: String?) {
        guard let sessionId, let worktreePath, ArtifactRuntime.directory(forSessionId: sessionId) == nil else { return }
        try? ArtifactRuntime.register(sessionId: sessionId, directory: worktreePath)
    }
}

// MARK: - The view

struct PinnedArtifactView: View {
    let services: SessionServices
    let artifactId: String
    let emptyTitle: String
    let emptyMessage: String
    let symbol: String

    @State private var watcher = WidgetFileWatcher()
    @State private var retryNonce = 0
    @State private var watchedPath = ""

    var body: some View {
        let _ = watcher.version
        let _ = retryNonce
        let present = PinnedArtifactLocator.exists(
            sessionId: services.sessionId, worktreePath: services.worktreePath, artifactId: artifactId
        )
        return Group {
            if !present {
                message(symbol: symbol, title: emptyTitle, text: emptyMessage, retry: false)
            } else if let sessionId = services.sessionId,
                      let base = ArtifactRuntime.url(sessionId: sessionId, artifactId: artifactId),
                      let url = URL(string: base.absoluteString + "?r=\(watcher.version)") {
                WebSectionView(spec: WebAppCatalog.artifact(url: url))
            } else {
                message(
                    symbol: "bolt.horizontal.circle", title: "Can\u{2019}t reach the artifact server",
                    text: "Work42\u{2019}s local artifact server isn\u{2019}t answering yet.", retry: true
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            PinnedArtifactLocator.register(sessionId: services.sessionId, worktreePath: services.worktreePath)
            // Keep the watcher on the artifact's current location (the session may be registered a moment later).
            while !Task.isCancelled {
                if let path = PinnedArtifactLocator.indexPath(
                    sessionId: services.sessionId, worktreePath: services.worktreePath, artifactId: artifactId
                ), path != watchedPath {
                    watchedPath = path
                    watcher.watch(path)
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .onDisappear { watcher.stop(); watchedPath = "" }
    }

    private func message(symbol: String, title: String, text: String, retry: Bool) -> some View {
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
                .frame(maxWidth: 280)
            if retry {
                Button("Retry") { retryNonce += 1 }
                    .glassSubtleCapsule(tint: DT.systemAccent)
            }
        }
        .padding(DT.s24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
