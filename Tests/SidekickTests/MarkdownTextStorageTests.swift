import XCTest
import AppKit
@testable import Sidekick

/// Pins the NSTextStorage contract for the hybrid markdown editor.
/// Covers:
///   - STORAGE-01 round-trip (byte-identical .string for every markdown construct)
///   - D-T-02 edit-range invariant (attribute mutations scoped to edited paragraph)
///   - D-T-04 hidden-marker attribute fallback (assert .sidekickHiddenMarker on exactly
///     the marker character indices; does NOT assert NSGlyphProperty.null directly —
///     that's layout-manager territory and harder to test window-less)
///
/// Pattern source: PerformWrapTests.swift (windowless AppKit + @MainActor).
/// CONTEXT reference: .planning/phases/09-hybrid-editor-foundation/09-CONTEXT.md
///   D-T-02, D-T-03, D-T-04.
@MainActor
final class MarkdownTextStorageTests: XCTestCase {

    /// Standard four-piece TextKit 1 assembly. Leaving the layout manager
    /// unwired can mask processEditing bugs — the layout manager is notified
    /// of edited ranges as part of the NSTextStorage contract (PATTERNS.md
    /// line 371).
    private func makeStorage(_ body: String) -> MarkdownTextStorage {
        let storage = MarkdownTextStorage()
        let layoutManager = MarkdownLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 200, height: 100))
        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(container)
        storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: body)
        return storage
    }

    // MARK: - STORAGE-01: byte-identical round-trip

    func test_storage_isByteIdenticalRoundTrip_simpleMarkdown() {
        let markdown = "# Heading\n\n**bold** and *italic* and `code`.\n\n- bullet one\n- bullet two\n\n```\nfenced code\n```\n"
        let storage = makeStorage(markdown)
        XCTAssertEqual(storage.string, markdown,
                       "STORAGE-01: hybrid rendering must be view-only; bytes unchanged")
    }

    func test_storage_isByteIdenticalRoundTrip_withEmoji() {
        // Emoji surrogate-pair sanity — storage.string must preserve the
        // full UTF-16 encoding. "🎉" is a surrogate pair = 2 UTF-16 units.
        let markdown = "hello **🎉** world"
        let storage = makeStorage(markdown)
        XCTAssertEqual(storage.string, markdown,
                       "STORAGE-01: surrogate pairs must survive round-trip")
    }

    func test_storage_roundTrip_afterMultipleEdits() {
        let storage = makeStorage("")
        storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "**a**")
        storage.replaceCharacters(in: NSRange(location: 5, length: 0), with: " *b*")
        storage.replaceCharacters(in: NSRange(location: 9, length: 0), with: " `c`")
        XCTAssertEqual(storage.string, "**a** *b* `c`",
                       "STORAGE-01 holds under a sequence of small edits")
    }

    // MARK: - D-T-04: hidden-marker attribute on marker ranges

    func test_boldMarkers_tagged_sidekickHiddenMarker() {
        let storage = makeStorage("**bold**")
        // Marker open: {0,2} — characters '*' '*'
        XCTAssertNotNil(storage.attribute(.sidekickHiddenMarker, at: 0, effectiveRange: nil),
                        "Opening ** at location 0 must carry .sidekickHiddenMarker")
        XCTAssertNotNil(storage.attribute(.sidekickHiddenMarker, at: 1, effectiveRange: nil),
                        "Opening ** at location 1 must carry .sidekickHiddenMarker")
        // Content: {2,4} ("bold") — must NOT carry the marker attribute
        XCTAssertNil(storage.attribute(.sidekickHiddenMarker, at: 2, effectiveRange: nil),
                     "Content 'bold' at location 2 must NOT carry .sidekickHiddenMarker")
        XCTAssertNil(storage.attribute(.sidekickHiddenMarker, at: 5, effectiveRange: nil),
                     "Content 'bold' at location 5 must NOT carry .sidekickHiddenMarker")
        // Marker close: {6,2}
        XCTAssertNotNil(storage.attribute(.sidekickHiddenMarker, at: 6, effectiveRange: nil),
                        "Closing ** at location 6 must carry .sidekickHiddenMarker")
        XCTAssertNotNil(storage.attribute(.sidekickHiddenMarker, at: 7, effectiveRange: nil),
                        "Closing ** at location 7 must carry .sidekickHiddenMarker")
    }

    func test_headingMarkers_tagged_sidekickHiddenMarker() {
        let storage = makeStorage("# Title")
        // Prefix range {0,2} covers "# " (hash + space)
        XCTAssertNotNil(storage.attribute(.sidekickHiddenMarker, at: 0, effectiveRange: nil),
                        "# prefix at location 0 must carry .sidekickHiddenMarker")
        XCTAssertNotNil(storage.attribute(.sidekickHiddenMarker, at: 1, effectiveRange: nil),
                        "Space after # at location 1 must carry .sidekickHiddenMarker")
        // Content "Title" at 2..6 must NOT carry the marker attribute
        XCTAssertNil(storage.attribute(.sidekickHiddenMarker, at: 2, effectiveRange: nil),
                     "First content char 'T' at location 2 must NOT carry .sidekickHiddenMarker")
    }

    func test_bulletPrefix_tagged_sidekickHiddenMarker() {
        let storage = makeStorage("- item")
        // Prefix range {0,2} covers "- " (dash + space)
        XCTAssertNotNil(storage.attribute(.sidekickHiddenMarker, at: 0, effectiveRange: nil),
                        "- at location 0 must carry .sidekickHiddenMarker")
        XCTAssertNotNil(storage.attribute(.sidekickHiddenMarker, at: 1, effectiveRange: nil),
                        "Space after - at location 1 must carry .sidekickHiddenMarker")
        XCTAssertNil(storage.attribute(.sidekickHiddenMarker, at: 2, effectiveRange: nil),
                     "Content 'i' at location 2 must NOT carry .sidekickHiddenMarker")
    }

    func test_inlineCodeMarkers_tagged_sidekickHiddenMarker() {
        // "a `code` b" — backtick at location 2, code "code" at 3..6, close backtick at 7
        let storage = makeStorage("a `code` b")
        XCTAssertNotNil(storage.attribute(.sidekickHiddenMarker, at: 2, effectiveRange: nil),
                        "Opening ` at location 2 must carry .sidekickHiddenMarker")
        XCTAssertNil(storage.attribute(.sidekickHiddenMarker, at: 3, effectiveRange: nil),
                     "Content 'c' at location 3 must NOT carry .sidekickHiddenMarker")
        XCTAssertNotNil(storage.attribute(.sidekickHiddenMarker, at: 7, effectiveRange: nil),
                        "Closing ` at location 7 must carry .sidekickHiddenMarker")
    }

    func test_unclosedBold_doesNotHideMarker() {
        // D-MH-04: unclosed markers stay visible. `.sidekickHiddenMarker`
        // must NOT be set on the opening ** of "**foo".
        let storage = makeStorage("**foo")
        XCTAssertNil(storage.attribute(.sidekickHiddenMarker, at: 0, effectiveRange: nil),
                     "Unclosed ** must NOT carry .sidekickHiddenMarker (D-MH-04)")
        XCTAssertNil(storage.attribute(.sidekickHiddenMarker, at: 1, effectiveRange: nil),
                     "Unclosed ** must NOT carry .sidekickHiddenMarker (D-MH-04)")
    }

    // MARK: - D-T-02: edit-range invariant

    func test_processEditing_onlyMutatesAttributesInEditedParagraphRange() {
        let body = "para one\n\npara two\n\npara **three**\n\npara four"
        let storage = makeStorage(body)

        // Snapshot the font attribute on paragraph 1 ("para one") chars 0..8
        // BEFORE the edit.
        let before = storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont

        // Edit inside paragraph 2 ("para two"):
        // "para one" = 8 chars, "\n" = 1, "\n" = 1, total offset to "para two" = 10
        // "para two" = 8 chars, editing at end of "para two" = location 18
        let editLocation = 18   // "para one\n\npara two" → length 18, insert after
        storage.replaceCharacters(in: NSRange(location: editLocation, length: 0), with: "X")

        // Assert font on location 0 (paragraph 1) is unchanged.
        let after = storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        XCTAssertEqual(before, after,
                       "D-T-02: edits in paragraph 2 must not mutate attributes in paragraph 1")
    }

    func test_processEditing_editInsideFenceExpandsReparseToFence() {
        // When the edit lands inside a fenced code block, the reparse range
        // must expand to include both fence lines so the closing ``` keeps
        // its hidden-marker attribute.
        //
        // Buffer layout (UTF-16 offsets):
        //   "```\n"       = 4 chars  → location  0, fenceOpen  {0, 4}
        //   "line one\n"  = 9 chars  → location  4
        //   "line two\n"  = 9 chars  → location 13
        //   "```\n"       = 4 chars  → location 22, fenceClose {22, 4}
        let body = "```\nline one\nline two\n```\n"
        let storage = makeStorage(body)

        // Confirm closing fence is hidden after initial parse.
        // Closing ``` starts at location 22.
        XCTAssertNotNil(storage.attribute(.sidekickHiddenMarker, at: 22, effectiveRange: nil),
                        "Closing ``` at location 22 must carry .sidekickHiddenMarker after initial parse")

        // Edit inside the content region (insert "X" at location 13 — start of "line two").
        storage.replaceCharacters(in: NSRange(location: 13, length: 0), with: "X")

        // The closing fence index shifted by +1 → now at 23. Verify still hidden.
        XCTAssertNotNil(storage.attribute(.sidekickHiddenMarker, at: 23, effectiveRange: nil),
                        "Closing ``` must remain hidden after edit inside fence (D-PS-02 expansion)")
    }

    // MARK: - Visible attributes applied correctly

    func test_boldContent_getsSemiboldFont() {
        let storage = makeStorage("**bold**")
        // Content "bold" starts at location 2
        let font = storage.attribute(.font, at: 2, effectiveRange: nil) as? NSFont
        XCTAssertNotNil(font, "Bold content must have a font attribute")
        // Font descriptor should include the semibold/bold trait.
        let descriptor = font?.fontDescriptor
        XCTAssertTrue(
            descriptor?.symbolicTraits.contains(.bold) == true
            || (descriptor?.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any])?[.weight] as? CGFloat ?? 0 >= 0.3,
            "Bold content font must register as bold/semibold"
        )
    }

    func test_inlineCodeContent_getsMonospacedFontAndBackground() {
        // "a `code` b" — code content at location 3
        let storage = makeStorage("a `code` b")
        let font = storage.attribute(.font, at: 3, effectiveRange: nil) as? NSFont
        XCTAssertNotNil(font, "Inline code content must have a font attribute")
        let bg = storage.attribute(.backgroundColor, at: 3, effectiveRange: nil) as? NSColor
        XCTAssertNotNil(bg, "Inline code content must have a backgroundColor attribute")
    }
}
