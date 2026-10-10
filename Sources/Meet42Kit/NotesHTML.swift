// NotesHTML.swift — turns a calendar event's notes into HTML that is safe to render.
//
// Invite descriptions are untrusted text, and many arrive as raw HTML (Google, some Outlook bodies). The
// widgets render them through a markdown/HTML viewer, so this keeps only a small allow-list of formatting
// tags and drops everything else: scripts, styles, images, iframes, event-handler attributes, inline CSS and
// any link that is not http, https or mailto. Plain text is escaped and keeps its line breaks.

import Foundation

public nonisolated enum NotesHTML {

    /// Tags whose markup is kept. Anything else is removed and only its text survives.
    private static let allowedTags: Set<String> = [
        "p", "br", "b", "strong", "i", "em", "u", "ul", "ol", "li",
        "h1", "h2", "h3", "h4", "h5", "h6", "blockquote", "code", "pre",
        "table", "thead", "tbody", "tr", "th", "td", "a",
    ]

    /// Elements removed together with everything inside them.
    private static let droppedWithContent: Set<String> = [
        "script", "style", "head", "title", "iframe", "object", "embed", "noscript", "template", "svg",
    ]

    private static let allowedLinkSchemes: Set<String> = ["http", "https", "mailto"]

    /// Sanitised HTML for `notes`, or nil when there is nothing to show.
    public static func sanitize(_ notes: String?) -> String? {
        guard let notes, !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        guard looksLikeHTML(notes) else { return escapedWithBreaks(notes) }
        guard let document = try? XMLDocument(xmlString: notes, options: [.documentTidyHTML]),
              let body = try? document.nodes(forXPath: "//body").first else {
            return escapedWithBreaks(notes)
        }
        let html = (body.children ?? []).map(render).joined().trimmingCharacters(in: .whitespacesAndNewlines)
        return html.isEmpty ? nil : html
    }

    // MARK: - Rendering

    private static func render(_ node: XMLNode) -> String {
        switch node.kind {
        case .text:
            return escape(node.stringValue ?? "")
        case .element:
            guard let element = node as? XMLElement, let rawName = element.name else { return "" }
            let name = rawName.lowercased()
            if droppedWithContent.contains(name) { return "" }
            let inner = (element.children ?? []).map(render).joined()
            guard allowedTags.contains(name) else { return inner }
            if name == "br" { return "<br>" }
            if name == "a" {
                guard let href = safeHref(element.attribute(forName: "href")?.stringValue) else { return inner }
                return "<a href=\"\(escape(href))\">\(inner)</a>"
            }
            return "<\(name)>\(inner)</\(name)>"
        default:
            return ""
        }
    }

    /// The link target when its scheme is allowed, otherwise nil (the link text is kept, the link is not).
    private static func safeHref(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              allowedLinkSchemes.contains(scheme) else { return nil }
        return trimmed
    }

    // MARK: - Plain text

    private static func looksLikeHTML(_ text: String) -> Bool {
        text.range(of: #"<\s*/?\s*[a-zA-Z!][^>]*>"#, options: .regularExpression) != nil
    }

    private static func escapedWithBreaks(_ text: String) -> String {
        escape(text)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\n", with: "<br>")
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
