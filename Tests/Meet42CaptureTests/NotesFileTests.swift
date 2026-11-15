// NotesFileTests.swift — `meet42 notes write`: a note sent from another device lands in annotations.md whole.

import Foundation
import Testing
@testable import Meet42Capture

@Suite("NotesFile")
struct NotesFileTests {

    private func folder() throws -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("meet42-notes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    private func payload(_ text: String) -> String { Data(text.utf8).base64EncodedString() }

    private func read(_ dir: String) -> String? {
        try? String(contentsOfFile: (dir as NSString).appendingPathComponent(NotesFile.fileName), encoding: .utf8)
    }

    @Test("text, including line breaks, quotes and non-ASCII, is written exactly")
    func roundTrip() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let note = "Call Ada re: \"Q3\" — $5k; `plan`\n\n- one\n- two (caf\u{00E9}) ✅\n"
        let bytes = try NotesFile.write(base64: payload(note), dir: dir)
        #expect(read(dir) == note)
        #expect(bytes == note.utf8.count)
    }

    @Test("a second write replaces the first, and an empty payload clears the notes")
    func replaces() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try NotesFile.write(base64: payload("first, and longer than the second"), dir: dir)
        try NotesFile.write(base64: payload("second"), dir: dir)
        #expect(read(dir) == "second")
        #expect(try NotesFile.write(base64: "", dir: dir) == 0)
        #expect(read(dir) == "")
    }

    @Test("nothing but annotations.md is left in the folder (the write is atomic, with no temp file kept)")
    func leavesNoTemp() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try NotesFile.write(base64: payload("note"), dir: dir)
        try NotesFile.write(base64: payload("note 2"), dir: dir)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir) == [NotesFile.fileName])
    }

    @Test("a folder that does not exist, or is a file, is refused and nothing is made")
    func badFolder() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let missing = (dir as NSString).appendingPathComponent("nope")
        #expect(throws: NotesFile.WriteError.notADirectory(missing)) { try NotesFile.write(base64: payload("x"), dir: missing) }
        #expect(!FileManager.default.fileExists(atPath: missing))

        let file = (dir as NSString).appendingPathComponent("a-file")
        FileManager.default.createFile(atPath: file, contents: Data())
        #expect(throws: NotesFile.WriteError.notADirectory(file)) { try NotesFile.write(base64: payload("x"), dir: file) }
    }

    @Test("a payload that is not base64, not text or too large is refused and the notes are left as they were")
    func badPayload() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try NotesFile.write(base64: payload("keep me"), dir: dir)

        #expect(throws: NotesFile.WriteError.notBase64) { try NotesFile.write(base64: "not base64 !!", dir: dir) }
        #expect(throws: NotesFile.WriteError.notText) { try NotesFile.write(base64: Data([0xFF, 0xFE, 0xFD]).base64EncodedString(), dir: dir) }
        let big = Data(repeating: 0x61, count: NotesFile.maxBytes + 1).base64EncodedString()
        #expect(throws: NotesFile.WriteError.tooLarge(NotesFile.maxBytes + 1)) { try NotesFile.write(base64: big, dir: dir) }
        #expect(read(dir) == "keep me")
    }

    @Test("a note of exactly the most is accepted")
    func atTheLimit() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let full = Data(repeating: 0x61, count: NotesFile.maxBytes).base64EncodedString()
        #expect(try NotesFile.write(base64: full, dir: dir) == NotesFile.maxBytes)
    }
}
