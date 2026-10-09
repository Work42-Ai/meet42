// Meet42Daemon.swift — daemonization + TCC re-key helper for meet42's
// long-lived modes (calendar `sync` daemon, `record`/`watch-mic` capture).
// (meet42-plugin-conversion, M1/s7).
//
// Ported from the flow42 `Record.swift` precedent: a two-step entry that keeps
// BOTH daemonization (setsid, so the daemon outlives the spawning shell) AND
// macOS TCC working for a CLI binary.
//
//   1. First call (no `--reexec`): we're a child of the spawning shell.
//      `setsid()` to become a session leader, then re-exec ourselves in place
//      with `--reexec` appended and macOS's "disclaim responsibility" spawn
//      attribute set (`POSIX_SPAWN_SETEXEC`, same pid). A plain `execve` is NOT
//      enough: macOS attributes privacy (TCC) requests to the *responsible
//      process*, which a child inherits from its parent, so without the
//      disclaim meet42 would read and ask for the permissions of whatever
//      launched it (Terminal, the Work42 app) under that app's name. Disclaimed,
//      it is its own principal: prompts say "meet42" and grants belong to its
//      code-sign identity. Set MEET42_NO_DISCLAIM=1 to fall back to a plain execve.
//   2. Second call (with `--reexec`): skip setsid (already done); request the
//      TCC-gated resources (Calendar/Mic/Screen) and run the long-lived loop.
//
// ⚠️ NOT build-verifiable: the TCC re-key only has an effect when the binary is
// signed with a persistent Developer ID and carries the embedded Info.plist
// usage descriptions (see scripts/build-meet42.sh). Under a plain `swift build`
// (ad-hoc signature) the re-exec runs but TCC grants won't persist across
// rebuilds — validate on a real signed build.

import Darwin
import Foundation

/// libSystem's `responsibility_spawnattrs_setdisclaim` (declared in <libproc/...> internals, exported by
/// libSystem). Marks a spawn so the new process is its own responsible process for privacy (TCC) purposes.
@_silgen_name("responsibility_spawnattrs_setdisclaim")
private func meet42_responsibility_spawnattrs_setdisclaim(
    _ attr: UnsafeMutablePointer<posix_spawnattr_t?>, _ disclaim: Int32
) -> Int32

public enum Meet42Daemon {

    /// Whether the current argv is already the re-exec phase.
    public static func isReexec(_ args: [String]) -> Bool {
        args.contains("--reexec")
    }

    /// Daemonize (step 1) + TCC re-key (execve with `--reexec`). On the first
    /// call this does not return (it execve's); on the re-exec call it returns
    /// immediately so the caller proceeds into its long-lived loop.
    ///
    /// - Parameter reexecArgv: the full argv to re-exec with — the verb prefix
    ///   + original args + `"--reexec"` (e.g. `["sync", "--daemon", "--reexec"]`).
    /// - Parameter isReexec: true when already in the re-exec phase (skips
    ///   setsid + execve).
    public static func daemonize(reexecArgv: [String], isReexec: Bool) {
        if !isReexec {
            // Detach from the parent's session so the daemon outlives the
            // spawning shell and any controlling tty.
            _ = setsid()
            chdir("/")
        }

        let skipReexec = ProcessInfo.processInfo.environment["MEET42_NO_REEXEC"] == "1"
        if !isReexec && !skipReexec {
            let exePath = currentExecutablePath()
            let cArgs = ([exePath] + reexecArgv).map { strdup($0) }
            defer { cArgs.forEach { free($0) } }
            var argvPtrs: [UnsafeMutablePointer<CChar>?] = cArgs + [nil]
            let env = ProcessInfo.processInfo.environment
            let cEnv = env.map { strdup("\($0.key)=\($0.value)") }
            defer { cEnv.forEach { free($0) } }
            var envPtrs: [UnsafeMutablePointer<CChar>?] = cEnv + [nil]

            // 1. Re-exec as meet42's OWN permission principal (see `execDisclaimed`). Does not return on success.
            if ProcessInfo.processInfo.environment["MEET42_NO_DISCLAIM"] != "1" {
                argvPtrs.withUnsafeMutableBufferPointer { argvBuf in
                    envPtrs.withUnsafeMutableBufferPointer { envBuf in
                        execDisclaimed(exePath, argvBuf.baseAddress, envBuf.baseAddress)
                    }
                }
                FileHandle.standardError.write(Data(
                    "[meet42:daemon] disclaimed re-exec failed (\(String(cString: strerror(errno)))) — falling back to a plain execve\n".utf8
                ))
            }
            // 2. Plain execve. macOS then still attributes permissions to whatever launched us.
            _ = argvPtrs.withUnsafeMutableBufferPointer { argvBuf in
                envPtrs.withUnsafeMutableBufferPointer { envBuf in
                    execve(exePath, argvBuf.baseAddress, envBuf.baseAddress)
                }
            }
            // execve only returns on failure — fall through and run anyway
            // (TCC may not re-key, but the loop still runs).
            FileHandle.standardError.write(Data(
                "[meet42:daemon] execve failed (\(String(cString: strerror(errno)))) — continuing without re-exec\n".utf8
            ))
        }
    }

    /// Replaces this process with `path`, in place (same pid, same open files) like `execve`, but with macOS's
    /// "disclaim responsibility" spawn attribute set.
    ///
    /// Why: macOS decides which app a permission request belongs to from the process's *responsible process*,
    /// which a child inherits from its parent. A bare `execve` therefore leaves meet42 reporting and asking
    /// for the permissions of whatever launched it (Terminal, or the Work42 app), under that app's name.
    /// Disclaiming makes the new image its own responsible process, so the prompt says "meet42" and the grant
    /// belongs to meet42's signature. `POSIX_SPAWN_SETEXEC` keeps the "this process becomes the daemon"
    /// behaviour the callers rely on. The function only returns when the exec failed (errno is set).
    private static func execDisclaimed(
        _ path: String,
        _ argv: UnsafePointer<UnsafeMutablePointer<CChar>?>?,
        _ envp: UnsafePointer<UnsafeMutablePointer<CChar>?>?
    ) {
        var attr: posix_spawnattr_t? = nil
        guard posix_spawnattr_init(&attr) == 0 else { return }
        defer { posix_spawnattr_destroy(&attr) }
        guard posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETEXEC)) == 0 else { return }
        guard meet42_responsibility_spawnattrs_setdisclaim(&attr, 1) == 0 else { return }
        var pid: pid_t = 0
        // With POSIX_SPAWN_SETEXEC this does not return on success.
        let rc = posix_spawn(&pid, path, nil, &attr, argv.map { UnsafeMutablePointer(mutating: $0) }, envp.map { UnsafeMutablePointer(mutating: $0) })
        errno = rc
    }

    /// Absolute path to the running executable (for the execve self-call).
    public static func currentExecutablePath() -> String {
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        var buf = [CChar](repeating: 0, count: Int(size))
        guard _NSGetExecutablePath(&buf, &size) == 0 else {
            return CommandLine.arguments.first ?? "meet42"
        }
        let raw = buf.withUnsafeBufferPointer { ptr in
            ptr.baseAddress.map { String(cString: $0) } ?? ""
        }
        return (raw as NSString).resolvingSymlinksInPath
    }
}
