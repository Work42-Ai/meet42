// TranscriptTail.swift — incremental reader for the recording's conversation.jsonl (WOR-235).
//
// The Recording tile used to re-read and re-parse the whole file on the main thread every time
// the file watcher fired, and mint fresh row ids on each pass, so a long meeting (thousands of
// lines) made the whole app stutter. `TranscriptTail` reads only what was appended since the
// last poll, parses it off the main thread, and publishes the new lines.
//
// Two ways the file changes under us, both handled:
//   • APPEND — the engine appends one JSON line at a time (`ConversationLog.append`). We read
//     `[offset, EOF)`, keep a torn trailing line buffered until its newline arrives, and emit
//     only complete lines.
//   • REWRITE — diarization back-patches `speakerLabel` by atomically replacing the whole file
//     (`ConversationLog.rewriteSpeakerLabels`). The replacement is a NEW file (new inode), usually
//     larger, so "size grew" alone would silently miss relabelled lines. We watch the file
//     identity as well as the size; on a change (or if the file shrank) we re-read from the
//     start and replace the published lines. Row ids are stable (`lineId`), so SwiftUI updates
//     the rows in place rather than rebuilding them.

import Foundation
import Observation

/// What one poll found.
private struct TailUpdate: Sendable {
    var lines: [RecordingLine]
    /// True when `lines` is the whole file (it was replaced, shrank or vanished), not a suffix.
    var replacesAll: Bool
}

/// Owns the read position. An actor so file I/O and JSON parsing run off the main thread.
private actor TranscriptTailReader {
    private let path: String
    /// First byte not yet read.
    private var offset: UInt64 = 0
    /// Bytes read but not yet part of a complete line (a torn trailing line).
    private var carry = Data()
    /// The file's identity (inode) when last read, to notice an atomic replacement.
    private var fileID: UInt64?

    init(path: String) { self.path = path }

    private func reset() {
        offset = 0
        carry = Data()
        fileID = nil
    }

    func poll() -> TailUpdate? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = (attrs[.size] as? NSNumber)?.uint64Value else {
            // The file is gone. If we had shown lines, they go too.
            guard fileID != nil else { return nil }
            reset()
            return TailUpdate(lines: [], replacesAll: true)
        }
        let id = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value

        var replacesAll = false
        if let known = fileID, known != id || size < offset {
            reset()
            replacesAll = true
        }
        fileID = id
        guard size > offset else {
            return replacesAll ? TailUpdate(lines: [], replacesAll: true) : nil
        }

        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return nil }
        defer { try? handle.close() }
        try? handle.seek(toOffset: offset)
        guard let chunk = try? handle.read(upToCount: Int(size - offset)), !chunk.isEmpty else { return nil }

        // Absolute file offset where `carry` begins, so each line can be given a position-based id.
        var lineOffset = Int(offset) - carry.count
        offset += UInt64(chunk.count)
        carry.append(chunk)

        var lines: [RecordingLine] = []
        var start = carry.startIndex
        while let newline = carry[start...].firstIndex(of: 0x0A) {
            if let line = Self.parse(carry[start..<newline], offset: lineOffset) { lines.append(line) }
            lineOffset += carry.distance(from: start, to: newline) + 1
            start = carry.index(after: newline)
        }
        carry = Data(carry[start...])

        // A writer that skipped the final newline: a COMPLETE json object is unambiguous (a torn
        // one is never valid json), so emit it now instead of waiting for a newline that may
        // never come. The newline that arrives later is then just an empty line.
        if !carry.isEmpty, let line = Self.parse(carry, offset: lineOffset) {
            lines.append(line)
            carry = Data()
        }

        if lines.isEmpty && !replacesAll { return nil }
        return TailUpdate(lines: lines, replacesAll: replacesAll)
    }

    private static func parse(_ bytes: Data, offset: Int) -> RecordingLine? {
        guard !bytes.isEmpty, let text = String(data: bytes, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return RecordingLine(jsonString: text, byteOffset: offset)
    }
}

/// The transcript so far, kept current by polling the file twice a second.
@Observable
@MainActor
final class TranscriptTail {

    private(set) var lines: [RecordingLine] = []

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var path: String?

    /// Start following `path`. Following the same path again is a no-op.
    func start(path: String) {
        guard self.path != path else { return }
        stop()
        self.path = path
        lines = []
        let reader = TranscriptTailReader(path: path)
        task = Task { [weak self] in
            while !Task.isCancelled {
                if let update = await reader.poll() { self?.apply(update) }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        path = nil
    }

    private func apply(_ update: TailUpdate) {
        if update.replacesAll {
            lines = update.lines
        } else if !update.lines.isEmpty {
            lines.append(contentsOf: update.lines)
        }
        if Self.perfLogging {
            FileHandle.standardError.write(Data(
                "[perf] TranscriptTail +\(update.lines.count) parsed\(update.replacesAll ? " (replace)" : ""), \(lines.count) total\n".utf8
            ))
        }
    }

    private static let perfLogging: Bool = {
        guard let value = ProcessInfo.processInfo.environment["WORK42_PERF"]?.lowercased() else { return false }
        return !["", "0", "false", "no", "off"].contains(value)
    }()
}
