// TranscriptCommand.swift — `meet42 transcript --dir <dir> [--json]`.
//
// Prints a recording's conversation.jsonl and speakers.json, read-only. The Recording widget on a device that is not
// the Mac (the Work42 iPad app) calls this through the Mac, because a recording's directory is outside the session
// folder a widget may read. With --json the output is one object: {"dir","conversation","speakers"} (`speakers` is
// absent until the end-of-meeting attribution writes it). Without --json it prints conversation.jsonl as it is.

import Foundation
import Meet42Capture

@MainActor
enum TranscriptCommand {

    static func transcript(args: [String]) {
        guard let dir = CLI.argValue(args, "--dir") else {
            CLI.fail("meet42 transcript: missing --dir <recording dir>")
        }
        let snapshot: TranscriptSnapshot
        do {
            snapshot = try TranscriptSnapshot.read(dir: dir)
        } catch {
            CLI.fail("meet42 transcript: \(error)")
        }
        if CLI.wantsJSON(args) {
            CLI.emitJSON(snapshot)
        } else {
            print(snapshot.conversation, terminator: "")
        }
    }
}
