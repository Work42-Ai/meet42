// NotesCommand.swift — `meet42 notes write --base64 <payload> [--dir <folder>] [--json]`.
//
// Replaces the session's My Notes file (`annotations.md`). A device that is not the Mac (the Work42 iPad app) saves notes through
// this verb; see NotesFile. `--dir` defaults to the current directory, which is the session folder when Work42 runs the command
// for a widget.

import Foundation
import Meet42Capture

@MainActor
enum NotesCommand {

    static func notes(args: [String]) {
        guard CLI.firstPositional(args) == "write" else {
            CLI.fail("usage: meet42 notes write --base64 <payload> [--dir <folder>] [--json]")
        }
        guard let payload = CLI.argValue(args, "--base64") else {
            CLI.fail("meet42 notes write: missing --base64 <payload> (an empty payload clears the notes)")
        }
        let dir = CLI.argValue(args, "--dir") ?? FileManager.default.currentDirectoryPath
        do {
            let bytes = try NotesFile.write(base64: payload, dir: dir)
            if CLI.wantsJSON(args) {
                CLI.emitJSON(["dir": dir, "bytes": String(bytes)])
            } else {
                print("wrote \(bytes) bytes to \(dir)/\(NotesFile.fileName)")
            }
        } catch {
            CLI.fail("meet42 notes write: \(error)")
        }
    }
}
