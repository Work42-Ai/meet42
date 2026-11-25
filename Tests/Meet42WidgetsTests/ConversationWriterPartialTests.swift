// ConversationWriterPartialTests.swift — partial transcript lines (WOR-892).

import Foundation
import Testing
import Work42PluginKit
@testable import Meet42PluginWidgets

@Suite("ConversationWriter partial lines")
struct ConversationWriterPartialTests {
    @Test("a partial line lives beside the conversation and the final line replaces it")
    func partialIsReplacedByFinal() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("meet42-partial-\(UUID().uuidString)", isDirectory: true)
        let conversationFile = dir.appendingPathComponent("conversation.jsonl")
        let writer = ConversationWriter(file: conversationFile)
        let partialFile = dir.appendingPathComponent(ConversationWriter.partialFileName)

        writer.setPartial(TranscriptSegment(start: 0, end: 1, text: "hello wor", source: .microphone, isPartial: true))
        let rows = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: partialFile)) as? [[String: Any]])
        #expect(rows.count == 1)
        #expect(rows.first?["text"] as? String == "hello wor")
        #expect(rows.first?["lineId"] as? String == "partial-You")
        #expect(!FileManager.default.fileExists(atPath: conversationFile.path))

        writer.append(TranscriptSegment(start: 0, end: 2, text: "hello world", source: .microphone))
        #expect(!FileManager.default.fileExists(atPath: partialFile.path))
        let conversation = try String(contentsOf: conversationFile, encoding: .utf8)
        #expect(conversation.contains("hello world"))
        #expect(!conversation.contains("\"hello wor\""))
    }

    @Test("each side keeps its own partial line")
    func partialsPerSource() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("meet42-partial-\(UUID().uuidString)", isDirectory: true)
        let writer = ConversationWriter(file: dir.appendingPathComponent("conversation.jsonl"))
        writer.setPartial(TranscriptSegment(start: 0, end: 1, text: "mine", source: .microphone, isPartial: true))
        writer.setPartial(TranscriptSegment(start: 0, end: 1, text: "theirs", source: .systemAudio, isPartial: true))
        writer.clearPartial(for: .microphone)
        let rows = try #require(JSONSerialization.jsonObject(
            with: Data(contentsOf: dir.appendingPathComponent(ConversationWriter.partialFileName))) as? [[String: Any]])
        #expect(rows.map { $0["text"] as? String } == ["theirs"])
        writer.clearAllPartials()
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent(ConversationWriter.partialFileName).path))
    }
}
