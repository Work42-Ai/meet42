// Meet42Trace.swift — the pipeline trace log, one logger for every widget of the plugin.
//
// Appends one JSON line per event to ~/.work42/meet42/trace.jsonl (`meet42 trace` reads it). Best-effort: it never throws and
// never blocks. An extension has no environment of the person's shell, so the two switches that were environment variables are
// `services.storage` keys under the `meet42` namespace now: `meet42/trace` (`"0"` turns the log off, anything else leaves it on)
// and `meet42/perf` (`"1"` turns the per-update timing lines on). A widget or agent calls `configure` when it starts.

import Foundation
import Work42PluginKit

nonisolated enum Meet42Trace {

    nonisolated(unsafe) private static var traceEnabled = true
    nonisolated(unsafe) private static var perfOn = false

    /// Whether the per-update timing lines are on (`meet42/perf`).
    static var perfEnabled: Bool { perfOn }

    /// Reads the two switches from storage. A storage that cannot be read (the Home surface) leaves the defaults: trace on,
    /// timing off.
    static func configure(storage: any WidgetStorageService) async {
        let trace = try? await storage.get(namespace: "meet42", key: "trace")
        let perf = try? await storage.get(namespace: "meet42", key: "perf")
        apply(trace: trace, perf: perf)
    }

    static func apply(trace: WidgetJSONValue?, perf: WidgetJSONValue?) {
        traceEnabled = !isOff(trace)
        perfOn = isOn(perf)
    }

    private static func isOff(_ value: WidgetJSONValue?) -> Bool {
        switch value {
        case .string(let text)?: return ["0", "false", "no", "off"].contains(text.lowercased())
        case .bool(let flag)?: return !flag
        default: return false
        }
    }

    private static func isOn(_ value: WidgetJSONValue?) -> Bool {
        switch value {
        case .string(let text)?: return !["", "0", "false", "no", "off"].contains(text.lowercased())
        case .bool(let flag)?: return flag
        default: return false
        }
    }

    /// A pill call the host refused. Not every host can draw an extension's pill (it throws "has no pill version"), and the
    /// recording must not depend on it: the callers carry on without the pill and this says so in the trace.
    static func pillFailed(_ action: String, sessionId: String?, _ error: any Error) {
        log("pill", "\(action)-failed", ["sessionId": sessionId ?? "", "error": String(describing: error)])
    }

    static func log(_ src: String, _ evt: String, _ fields: [String: Any] = [:]) {
        guard traceEnabled else { return }
        var row = fields
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        row["ts"] = formatter.string(from: Date())
        row["pid"] = Int(getpid())
        row["src"] = src
        row["evt"] = evt
        guard let data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]),
              var line = String(data: data, encoding: .utf8) else { return }
        line += "\n"
        let root = RealHome.meet42Folder.path
        let path = (root as NSString).appendingPathComponent("trace.jsonl")
        // Rotate past 5 MB.
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
           let size = attrs[.size] as? Int, size > 5 * 1024 * 1024 {
            rename(path, path + ".1")
        }
        try? FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true, attributes: nil)
        // O_APPEND|O_CREAT|O_WRONLY: atomic across processes for small writes.
        let descriptor = open(path, O_APPEND | O_CREAT | O_WRONLY, 0o644)
        guard descriptor >= 0 else { return }
        line.withCString { _ = write(descriptor, $0, strlen($0)) }
        close(descriptor)
    }
}
