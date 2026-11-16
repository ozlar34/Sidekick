import Foundation

/// Fixed corpus for the markdown-in / markdown-out seam. Extend by appending to `synthetic`
/// (shapes of real notes; never paste private note content) or by adding a file to
/// `Scripts/debug-harness/fixtures/`. Every entry is also run with CRLF line endings and with
/// the final newline removed, see `all`.
enum Corpus {
    struct Entry { let name: String; let text: String }

    static let synthetic: [Entry] = [
        .init(name: "empty", text: ""),
        .init(name: "only-newlines", text: "\n\n\n"),
        .init(name: "single-line-no-newline", text: "just one line"),
        .init(name: "title-and-paragraphs", text: "# Weekly sync\n\nFirst paragraph with **bold** text.\nSecond line right below.\n\n## Agenda\n\nSomething __else__ here.\n"),
        .init(name: "all-heading-levels", text: "# one\n## two\n### three\n#### four\n##### five\n###### six\n####### seven is text\n"),
        .init(name: "heading-spacing", text: "#   wide gap\n#\ttab\n#\n# \n#nospace\n  # indented\n"),
        .init(name: "bold-forms", text: "**a** __b__ **a****b** ** not bold** **not bold ** ***x*** __ __ a**b**c\n"),
        .init(name: "escapes", text: "\\*literal\\* snake_case \\_ \\\\ \\# trailing\\\n\\# not a heading\n\\\\# also text\n"),
        .init(name: "unsupported-literals", text: "- bullet\n* star bullet\n1. numbered\n- [ ] todo\n- [x] done\n> quote\n---\n***\n![img](x.png)\n<div>html</div>\n[^1]: footnote\n[ref]: http://example.com\nSetext\n======\n"),
        .init(name: "code-fence", text: "```swift\n# comment\nlet x = **y**\n```\nafter\n"),
        .init(name: "table", text: "| a | b |\n|---|---|\n| **1** | 2 |\n"),
        .init(name: "code-blocks", text: "intro\n```swift\n# comment\nlet x = **y** // `z`\n- not a bullet\n```\n~~~py info\n```\nstill code\n~~~\n````\nshort ``` inside\n`````\n```\n\n  indented\n\n```   \nafter\n"),
        .init(name: "code-block-edges", text: "```\n```\n```\n\n```\n```c++ x\nunclosed at the end\n"),
        .init(name: "unclosed-fence-is-text", text: "```swift\n# heading\n**bold**\n- item\n"),
        .init(name: "tables", text: "| a | b |\n|---|---|\n| **1** | `2` |\n\n|x|y|z|\n| :-- | :-: | --: |\n|1|\n| [l](http://x.y) | a \\| b | https://a.b |\nafter\n"),
        .init(name: "table-near-misses", text: "| a | b |\n| c | d |\n|---|\n| a |\n|--|\n| a | b |\n|---|-x-|\n a | b\n--|--\n|\n|-|\n"),
        .init(name: "urls-and-links", text: "see https://example.com/a_b_c and [label](http://x.y/__z__) now\n"),
        .init(name: "unicode", text: "# Caf\u{e9} e\u{301} \u{1F44D}\u{1F3FD} \u{4E2D}\u{6587}\n**\u{1F600}** \u{FEFF}bom-ish\n"),
        .init(name: "line-blocks-default-spelling", text: "- bullet **bold**\n1. first\n2. second\n- [ ] todo\n- [x] done\n> quote *it*\n---\nafter\n"),
        .init(name: "line-blocks-other-spelling", text: "* star\n  * indented star\n\t- tab indented\n1) paren\n  7) later\n* [X] big X\n- [x]\u{20}\n> \n***\n___\n-----\n  ---  \n"),
        .init(name: "line-blocks-near-misses", text: "-\n*\n-x\n1.x\n1 . x\n>x\n+ plus\n- [] no\n- [ ]x\n- [y] no\n--\n* * *\n- - -\n___ x\n"),
        .init(name: "marks-all", text: "*it* _it_ ~~gone~~ <u>under</u> `code` [t](http://x.y/z) **b *i* b** ***bi*** __b _i_ b__\n"),
        .init(name: "marks-nested", text: "<u>**bold under**</u> ~~*it strike*~~ [**b**](u) **[l](u)** `**not bold**` *a **b** c* **a *b* c**\n"),
        .init(name: "marks-near-misses", text: "*unclosed _unclosed ~~unclosed <u>unclosed `unclosed [unclosed](\n* a* *a * snake_case_name a*b*c <u></u> ~~ ~~ [](x) ``\n"),
        .init(name: "pills", text: "see https://example.com/a_b_c now\nhttp://a.b, (https://c.d/e) https://f.g.\n[https://x.y](https://x.y) [x](https://x.y) https://x.y/**z**\nxhttps://not.pill ftp://no.pill https://\n"),
        .init(name: "image-and-escapes", text: "![alt](pic.png) \\[ \\] \\` \\~ \\< \\: https\\://x.y \\- \\> \\1.\n\\- not bullet\n\\> not quote\n\\---\n\\1. not numbered\n"),
        .init(name: "marks-in-blocks", text: "# *it* head ~~s~~\n- [ ] `code` and [l](u)\n1. <u>u</u> https://a.b\n> **q** _q_\n"),
        .init(name: "whitespace-edges", text: "trailing spaces   \n\ttabbed\n   \n"),
        .init(name: "lone-cr", text: "a\rb\r\nc\r"),
        .init(name: "mixed-endings", text: "a\r\nb\nc\r\n\nd"),
        .init(name: "trailing-blank-lines", text: "x\n\n\n"),
        .init(name: "long-line", text: String(repeating: "word **w** ", count: 2000) + "\n"),
    ]

    /// Existing fixtures of the debug harness (real-shaped, no private content).
    static func fixtures() -> [Entry] {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Scripts/debug-harness/fixtures")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.sorted() ?? []
        return names.filter { $0.hasSuffix(".md") }.compactMap { name in
            guard let data = try? Data(contentsOf: dir.appendingPathComponent(name)),
                  let text = String(data: data, encoding: .utf8) else { return nil }
            return Entry(name: "fixture/\(name)", text: text)
        }
    }

    /// Base entries plus a CRLF variant and a no-final-newline variant of each.
    static var all: [Entry] {
        var out: [Entry] = []
        for e in synthetic + fixtures() {
            out.append(e)
            out.append(.init(name: e.name + " [crlf]", text: e.text.replacingOccurrences(of: "\n", with: "\r\n")))
            if e.text.hasSuffix("\n") {
                out.append(.init(name: e.name + " [no-final-newline]", text: String(e.text.dropLast())))
            }
        }
        return out
    }
}
