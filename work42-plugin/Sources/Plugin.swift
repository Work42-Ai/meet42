// Plugin.swift — meet42's compiled onCreate session hook.
//
// A plugin hooks dylib links only Work42PluginKit, so it cannot reach the calendar model directly — and by
// design it must not: all privileged calendar work lives in the standalone `meet42` CLI. The hook shells
// `meet42 link-session` to tie the new session to its calendar event.
//
// The session keeps only the calendar event id: `meeting/event_id` is seeded declaratively from
// session-types/event.json's `args` (SessionMint's generic arg->storage path) before onCreate ever runs, and
// the widgets and the agent read the event live through `meet42 show <event_id> --json`. There is no
// meeting.json. This hook only consumes that same `event_id` from `context.params`.
//
// onCreate fires only on a genuinely new session insert (SessionMint.finishMint's `guard inserted else
// { return }`), never on a re-mint — so the link runs exactly once per event session.

import Foundation
import Work42PluginKit

final class Meet42Hooks: Work42SessionHooks {
    func onCreate(_ context: SessionCreateContext) async throws {
        // Ad-hoc event (no calendar event_id): nothing to link — the
        // session just opens with empty states.
        guard case .string(let eventId)? = context.params["event_id"],
              !eventId.isEmpty else { return }

        // The session keeps only the calendar event id (session storage `meeting/event_id`, seeded from the
        // `event_id` arg); widgets and the agent read the event live through `meet42 show`. This hook just
        // links the new session back to its calendar event so `meet42 now --json`
        // surfaces a non-nil `sessionId`/`sessionDir` for this event, and so calendar sync keeps the event
        // even if it is later deleted. This is
        // the dedup hook: both the detection pill's YES path and the T-15
        // reconciler go through onCreate, so both link via this single write.
        // `--session-dir` lets a LATER detection resolve this session's
        // worktree directory (there is no other way to look up an arbitrary
        // session's directory by id), so the detection agent's YES path can
        // `meet42 record start --session-dir <dir>` into it. Fire-and-forget:
        // a failed link means the NEXT detection creates a second session
        // (accepted risk, not a fatal error for the session itself).
        let linkCommand = "meet42 link-session \(shellQuote(eventId)) \(shellQuote(context.sessionId))"
            + " --session-dir \(shellQuote(context.worktreePath))"
        _ = try? await context.shell.run(command: linkCommand)
    }
}

/// POSIX single-quote shell escaping for a value interpolated into a
/// `/bin/sh -c` command line (`WidgetCommandRunner`, the host's shell backend)
/// — wraps in single quotes, escaping an embedded `'` as `'\''`.
private nonisolated func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

// MARK: - Plugin entry-point ABI

// The two @_cdecl symbols the app's dlopen/dlsym loader expects (mirrors every
// widget's work42_widget_main/work42_widget_sdk_version pair).

@_cdecl("work42_plugin_sdk_version")
public func work42_plugin_sdk_version() -> Int32 { WidgetSDK.abiVersion }

@_cdecl("work42_plugin_main")
public func work42_plugin_main() -> UnsafeMutableRawPointer {
    nonisolated(unsafe) var result: UnsafeMutableRawPointer!
    MainActor.assumeIsolated {
        result = PluginEntryPoint.register(Meet42Hooks())
    }
    return result
}
