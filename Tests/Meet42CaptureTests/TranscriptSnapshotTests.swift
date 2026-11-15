import Foundation
import Testing
@testable import Meet42Capture

/// `meet42 transcript` prints a `TranscriptSnapshot`: a recording's two transcript files, read verbatim and read-only.
@Suite struct TranscriptSnapshotTests {

    private func makeDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("transcript-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("reads conversation.jsonl and speakers.json verbatim")
    func readsBothFiles() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let conversation = "{\"text\":\"hello\"}\n{\"text\":\"world\"}\n"
        let speakers = "{\"Them 1\":{\"name\":\"Ada\",\"person_id\":\"ada@example.com\"}}"
        try conversation.write(to: dir.appendingPathComponent("conversation.jsonl"), atomically: true, encoding: .utf8)
        try speakers.write(to: dir.appendingPathComponent("speakers.json"), atomically: true, encoding: .utf8)

        let snapshot = try TranscriptSnapshot.read(dir: dir.path)

        #expect(snapshot.dir == dir.path)
        #expect(snapshot.conversation == conversation)
        #expect(snapshot.speakers == speakers)
    }

    @Test("a recording with no line yet has an empty conversation and no speakers")
    func missingFilesAreNotAnError() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let snapshot = try TranscriptSnapshot.read(dir: dir.path)

        #expect(snapshot.conversation == "")
        #expect(snapshot.speakers == nil)
    }

    @Test("a directory that does not exist, or a file, is an error")
    func notADirectory() throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("nope-\(UUID().uuidString)").path
        #expect(throws: TranscriptSnapshot.ReadError.notADirectory(missing)) {
            try TranscriptSnapshot.read(dir: missing)
        }

        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("a.txt")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        #expect(throws: TranscriptSnapshot.ReadError.notADirectory(file.path)) {
            try TranscriptSnapshot.read(dir: file.path)
        }
    }

    @Test("it reads only the two transcript files, whatever else the directory holds")
    func readsNothingElse() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "secret".write(to: dir.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        try "line\n".write(to: dir.appendingPathComponent("conversation.jsonl"), atomically: true, encoding: .utf8)

        let snapshot = try TranscriptSnapshot.read(dir: dir.path)
        let encoded = String(data: try JSONEncoder().encode(snapshot), encoding: .utf8) ?? ""

        #expect(!encoded.contains("secret"))
        #expect(snapshot.conversation == "line\n")
    }

    @Test("it round-trips through JSON, which is how the CLI prints it, with speakers absent when there are none")
    func roundTripsThroughJSON() throws {
        let snapshot = TranscriptSnapshot(dir: "/r/1", conversation: "a\n", speakers: nil)
        let data = try JSONEncoder().encode(snapshot)

        #expect(try JSONDecoder().decode(TranscriptSnapshot.self, from: data) == snapshot)
        #expect(!(String(data: data, encoding: .utf8) ?? "").contains("speakers"))
    }
}
