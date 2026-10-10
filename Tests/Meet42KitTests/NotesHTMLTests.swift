import Testing
@testable import Meet42Kit

@Suite struct NotesHTMLTests {

    @Test func keepsAllowedFormatting() throws {
        let html = try #require(NotesHTML.sanitize(
            #"<p>Hi <b>all</b>, see <a href="https://example.com/doc">the doc</a></p><ol><li>One</li><li>Two</li></ol>"#
        ))
        #expect(html.contains("<b>all</b>"))
        #expect(html.contains(#"<a href="https://example.com/doc">the doc</a>"#))
        #expect(html.contains("<ol><li>One</li><li>Two</li></ol>"))
    }

    @Test func removesScriptsStylesImagesAndHandlers() throws {
        let html = try #require(NotesHTML.sanitize(
            #"<p onclick="evil()" style="color:red">Hello</p><script>alert(1)</script><style>p{}</style><img src="https://x/y.png" onerror="alert(1)"><iframe src="https://x"></iframe>"#
        ))
        #expect(html.contains("<p>") && html.contains("Hello"))
        for bad in ["script", "alert", "<style", "<img", "onerror", "onclick", "style=", "iframe"] {
            #expect(!html.lowercased().contains(bad), "kept \(bad): \(html)")
        }
    }

    @Test func dropsLinksWithUnsafeSchemesButKeepsTheirText() throws {
        let html = try #require(NotesHTML.sanitize(
            #"<a href="javascript:alert(1)">click</a> <a href="mailto:a@b.co">mail</a> <a href="file:///etc/passwd">file</a>"#
        ))
        #expect(!html.contains("javascript"))
        #expect(!html.contains("file:"))
        #expect(html.contains("click"))
        #expect(html.contains(#"<a href="mailto:a@b.co">mail</a>"#))
    }

    @Test func escapesPlainTextAndKeepsLineBreaks() throws {
        let html = try #require(NotesHTML.sanitize("Agenda:\n1 < 2 & 3 > 2\r\nBye"))
        #expect(html == "Agenda:<br>1 &lt; 2 &amp; 3 &gt; 2<br>Bye")
    }

    @Test func emptyNotesProduceNothing() {
        #expect(NotesHTML.sanitize(nil) == nil)
        #expect(NotesHTML.sanitize("  \n ") == nil)
    }
}
