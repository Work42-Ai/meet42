// NotesFile.swift — the session's My Notes file, written from a device that is not the Mac.
//
// `meet42 notes write --base64 <payload> [--dir <folder>]` replaces `annotations.md` in a session folder (default: the current
// directory, which is the session folder when the Mac's Work42 runs the command for a widget). The Annotations widget on the
// Mac writes this file itself; a device that is not the Mac (the Work42 iPad app) asks the Mac to, through this verb, because a
// widget's file service is read-only. The text travels base64-encoded: the link refuses shell metacharacters in a command, and
// a note is free text.
//
// Only this one fixed file name is ever written, so a `--dir` can't be used to overwrite anything else.

import Foundation

public enum NotesFile {

    /// The notes file in a session folder (`annotations.md`).
    public static let fileName = "annotations.md"

    /// The most a note may be, in bytes. A note is text a person types; this only stops a runaway payload.
    public static let maxBytes = 1_000_000

    public enum WriteError: Error, Equatable, CustomStringConvertible {
        case notADirectory(String)
        case notBase64
        case notText
        case tooLarge(Int)
        case writeFailed(String)

        public var description: String {
            switch self {
            case .notADirectory(let dir): return "'\(dir)' is not a directory"
            case .notBase64: return "the payload is not base64"
            case .notText: return "the payload is not UTF-8 text"
            case .tooLarge(let bytes): return "the note is \(bytes) bytes; the most is \(NotesFile.maxBytes)"
            case .writeFailed(let reason): return "could not write \(NotesFile.fileName): \(reason)"
            }
        }
    }

    /// The text a base64 payload holds. An empty payload is an empty note.
    public static func decode(base64: String) throws -> String {
        guard let data = Data(base64Encoded: base64) else { throw WriteError.notBase64 }
        guard data.count <= maxBytes else { throw WriteError.tooLarge(data.count) }
        guard let text = String(data: data, encoding: .utf8) else { throw WriteError.notText }
        return text
    }

    /// Replaces `<dir>/annotations.md` with the decoded text, all at once (a reader never sees half a note), and returns how many
    /// bytes it holds. `dir` must already exist.
    @discardableResult
    public static func write(base64: String, dir: String) throws -> Int {
        let text = try decode(base64: base64)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw WriteError.notADirectory(dir)
        }
        let file = URL(fileURLWithPath: dir, isDirectory: true).appendingPathComponent(fileName)
        let data = Data(text.utf8)
        do {
            try data.write(to: file, options: .atomic)
        } catch {
            throw WriteError.writeFailed(error.localizedDescription)
        }
        return data.count
    }
}
