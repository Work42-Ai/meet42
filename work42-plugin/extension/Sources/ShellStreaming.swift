// ShellStreaming.swift — a long-lived `meet42` command, read line by line through Work42's shell service.
//
// `meet42 watch` never exits on its own: it prints one JSON line when a call app opens or closes the microphone. The extension
// cannot launch processes (it is sandboxed), so Work42 runs it (SDK 3.3.0 `shell.start`), streams its lines back, and stops it
// when the widget's or agent's scope ends.

import Foundation
import Work42PluginKit

/// Runs `command` as a long-lived process and hands each line it prints to `handle`, until it exits or the calling task is
/// cancelled (which stops it). Returns when it ends, so the caller can start it again.
@MainActor
func streamMeet42Lines(_ command: String, shell: any WidgetShellService, handle: (String) async -> Void) async {
    guard let process = try? await shell.start(command: command) else { return }
    await withTaskCancellationHandler {
        for await item in process.output {
            if Task.isCancelled { break }
            switch item {
            case .stdout(let line):
                let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { await handle(text) }
            case .stderr:
                break
            case .exited:
                return
            @unknown default:
                break
            }
        }
    } onCancel: {
        Task { await process.stop() }
    }
    await process.stop()
}
