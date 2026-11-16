// TranscriptSnapshot.swift — the two files of a recording that a transcript view shows, read verbatim.
//
// `meet42 transcript --dir <dir> --json` prints one of these. The Recording widget reads the same files straight from
// disk on the Mac; a device that is not the Mac (the Work42 iPad app) asks the Mac for them through this verb, because a
// recording's directory (~/.work42/meet42/recordings/<id>/) is outside the session folder that a widget may read.
//
// Read-only, and only these two fixed file names, so passing any directory reads nothing else.

import Foundation

public struct TranscriptSnapshot: Codable, Equatable, Sendable {

    /// The recording directory that was read.
    public let dir: String

    /// `conversation.jsonl`, verbatim. Empty until the first line is written.
    public let conversation: String

    /// `speakers.json`, verbatim. Nil until the end-of-meeting attribution writes it.
    public let speakers: String?

    public enum ReadError: Error, Equatable, CustomStringConvertible {
        case notADirectory(String)

        public var description: String {
            switch self {
            case .notADirectory(let dir): return "'\(dir)' is not a directory"
            }
        }
    }

    /// Reads `<dir>/conversation.jsonl` and `<dir>/speakers.json`. A missing file is not an error (a recording that has not
    /// produced a line yet has neither); a `dir` that does not exist, or is a file, is.
    public static func read(dir: String) throws -> TranscriptSnapshot {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ReadError.notADirectory(dir)
        }
        let conversation = (try? String(contentsOfFile: conversationPath(sessionDir: dir), encoding: .utf8)) ?? ""
        let speakers = try? String(contentsOfFile: speakersPath(sessionDir: dir), encoding: .utf8)
        return TranscriptSnapshot(dir: dir, conversation: conversation, speakers: speakers)
    }
}
