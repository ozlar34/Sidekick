# Horizontal Rule Behavior — Research & Spec for Sidekick

**Date:** 2026-05-27
**Author:** /deep-research (Opus synth over 3 Haiku Explore agents)
**Purpose:** Spec how an HR / thematic break (`---`) should behave in Sidekick. Companion document for the `fix/hr-dashes-only` branch — used as a checklist when comparing current implementation against conventions.

---

## TL;DR

1. **CommonMark is the only authoritative source.** It gives deterministic rules for what *is* an HR — character set, count, line shape, and the setext-heading tie-break. We honour it.
2. **Editor caret/selection/deletion behavior around HRs is essentially undocumented in public sources.** No editor (Bear, Typora, iA Writer, Ulysses, Obsidian, Notion, Craft) publishes specs for these dimensions [1][2]. The spec below is derived from first principles + observed bug reports, not from authoritative documentation.
3. **The convention that mature hybrid editors converge on** — visible in screenshots, GIFs, and bug reports rather than docs — is: HR renders as a single thin hairline replacing the dash text; the caret behaves as if the HR is one indivisible "block" that the caret skips across rather than landing on.
4. **Sidekick's existing decisions match this implicit convention.** The two design choices encoded in this branch's tests — *"HR lines are uninhabitable, caret snaps to nearest neighbor in direction of motion"* and *"HR rendering survives note-switch round trip"* — are both consistent with how Bear, Typora, and Obsidian Live Preview behave in practice.
5. **The real risks are well-known bug patterns** (Obsidian's spaced-syntax invisible-on-load bug, Bear's setext-heading-vs-HR confusion, missing-padding-on-reload, "HR after tag" rendering failures), and Sidekick should test against each one explicitly.

---

## 1. What CommonMark requires (deterministic, non-negotiable)

CommonMark §4.1 *Thematic breaks* [3]:

| Rule | Detail |
|---|---|
| Character set | `-`, `_`, or `*` — all three are HR markers |
| Minimum count | **3 of the same character** (no mixing across kinds) |
| Internal whitespace | Spaces/tabs between characters are allowed: `- - -` is a valid HR |
| Leading whitespace | Up to **3 spaces** of indent. 4+ → code block, not HR |
| Trailing whitespace | Allowed |
| Other characters | None permitted on the line |
| Blank line above | **Not required** by spec — an HR can interrupt a paragraph directly |
| Setext-heading tie-break | When `paragraph-text\n---` is ambiguous, **setext H2 wins** [3]. This is deterministic in CommonMark, not editor-specific. |

GFM (GitHub Flavored Markdown) is a strict superset of CommonMark with **no thematic-break-specific extensions or divergences** [4].

**Implication for Sidekick:**
- The parser MUST accept `---`, `***`, `___`, with internal spaces, and with 0–3 leading spaces.
- The parser MUST NOT accept mixed-character lines (`---***`) as HRs.
- The parser MUST resolve `text\n---` (no blank line above) as setext H2, not HR. Sidekick currently treats this as HR — see comparison work, this may be a spec deviation worth confirming or correcting.

---

## 2. Visual rendering — what mature editors do

| Editor | Rendering | Source-text visible? | Notes |
|---|---|---|---|
| Bear | Visual line separator | No — replaced by hairline | [5] |
| Typora | Thin line (CSS-customizable) | No — `---` replaced by `<hr>` | [6] |
| iA Writer | `<hr>` on export, hairline in editor | Configurable | [7] |
| Ulysses | Scene break / hairline depending on style | No | [8] |
| Obsidian (Live Preview) | Thin line, full content width | No when cursor is off the line | Padding differs Live vs Reading [9][10] |
| Obsidian (Reading mode) | Thin line, tighter padding | N/A | [9] |
| Notion | Thin gray line, auto-width | No — block becomes `/divider` | [11] |
| Craft | **4 semantic styles**: strong (`=--`), regular (`---`), dotted (`.--`), light (`..-`) | No | Only editor offering visual variants [12] |
| Apple Notes | **No HR support at all** | N/A | Users use images/Unicode workarounds [13] |

**The Bear/Typora/Obsidian convention is the dominant one** for hybrid markdown editors:
- HR renders as a thin hairline that spans the content area.
- The source `---` text is hidden when the caret is not on the HR line.
- When the caret enters the HR line (in editors that allow it), the dashes become visible again.

Padding/spacing around the HR is the most commonly reported inconsistency [9].

**Implication for Sidekick:** the existing model (HR is an attributed run that renders as a hairline glyph and remains the literal `---` characters in storage) matches the Bear/Typora pattern. The question of whether dashes should *reveal* when the caret is on the HR line is a UX call — but since Sidekick has chosen to make HR lines uninhabitable, this question is moot in the current design.

---

## 3. Creation triggers — what mature editors do

| Editor | Accepts | Notes |
|---|---|---|
| Bear | `---` on its own line | **Bear bug history:** `---` directly after text was sometimes promoted to setext heading, sometimes to HR — Bear later required a blank line above to disambiguate [14] |
| Typora | `---` or `***` + Enter | Live-converts to hairline |
| Obsidian | `---` or `***` on its own line | Spaced syntax `- - -` has caused invisible-on-load bugs [10][15] |
| Notion | `---` + Enter OR `/divider` slash command | Becomes a `/divider` block, source dashes discarded |
| iA Writer | `***`, `---`, `___` (spaces optional) | Per CommonMark |
| Craft | `=--`, `---`, `.--`, `..-` markdown shortcuts | 4 semantic variants |

**No editor publicly documents an undo escape hatch for accidental HR creation.** All presumably rely on standard Cmd+Z; Backspace-after-auto-promotion behavior is not specified anywhere I could find.

**Implication for Sidekick:**
- Accept `---`, `***`, `___` (and internal-space variants per CommonMark).
- Decide explicitly: does typing the 3rd dash auto-convert mid-line, or only on Enter? The existing test `test_typingThirdDash_caretStaysWithinFreshlyConvertedHR` suggests Sidekick converts mid-line, on the third dash. This is more aggressive than Typora's "Enter to confirm" model but consistent with Bear.
- Decide explicitly: what's the undo path? Cmd+Z should restore the literal dashes. Backspace immediately after auto-promotion is the most natural escape hatch but is not standardized across editors.

---

## 4. Caret, selection, and deletion — the documentation gap

**This is the most important finding of this research:** public documentation across all major markdown editors is **silent** on:
- Where the caret lands on an HR line
- How arrow keys traverse an HR
- Triple-click / drag-select behavior on HRs
- Backspace from the line after, Delete from the line before
- Copy/paste shape of HRs

The agent that searched specifically for this returned essentially no usable citations [2]. The behavior has clearly not become a "convention worth documenting" — likely because the conventions emerged through screenshots and bug reports, not specs.

**What we can infer from bug reports + editor behavior visible in demos:**

### Caret
- **Bear, Typora, Obsidian Live Preview** all visually skip the caret across the HR — Up/Down arrow does not pause on an HR line in any demo I could find. The behavior is observed, not documented.
- **Notion** treats the divider as a full block — Up/Down moves to the block above/below, and the divider itself can be "selected" as a block via cmd-shift-click but the text caret does not live inside it.

### Selection
- **Notion** allows block-level selection of dividers; deletion removes the whole block.
- For text-stream editors (Bear, Typora, Obsidian, Sidekick), no public source describes triple-click or Cmd+A behavior on HRs.

### Deletion
- **Notion**: Backspace on a divider deletes the whole block, like any other block [11].
- **Bear**: bug history suggests Backspace from line-after merges, but specific behavior undocumented [14].
- No editor publicly specifies whether Backspace-from-after-HR deletes the HR or merges the line into it.

### Copy/paste
- Universally undocumented. No public source addresses whether copy-of-region-with-HR pastes as `---` text or as a fresh HR block.

**Implication for Sidekick:** because there is no canonical convention to copy, Sidekick has to make principled choices. The existing choices (HR uninhabitable + snap to neighbor in direction of motion) are defensible and internally consistent. They should be documented as Sidekick design decisions rather than as conformance to a standard, because no standard exists.

---

## 5. Known bug patterns (avoid these explicitly)

From scraping Obsidian forums, GitHub issues, and Bear community threads:

1. **Spaced-syntax invisible-on-load** (Obsidian, fixed v1.8.8): `- - -` was rendered invisible due to inherited list-styling CSS (`text-indent: -583px`). Round-trip serialization that produces spaced syntax can break rendering on reload. [15]

2. **HR-after-tag rendering failure** (Obsidian): a tag on the previous line followed immediately by `---` on the next line fails to render the HR. Inline-format proximity can break HR detection. [16]

3. **Setext-heading ambiguity** (Bear): `---` directly after a non-blank line was promoted to setext H2 in some cases and HR in others, causing user confusion. Bear later enforced "blank line above" for HR. [14]

4. **Padding inconsistency between modes** (Obsidian Live Preview vs Reading): HR spacing differs by mode, breaking visual continuity when toggling. [9]

5. **HR-vanishes-on-reload** — implicit pattern: the canonical shape of this bug is "HR renders on first display, dashes survive but hairline is gone after note switch / file reload." Sidekick already has a regression test for this: `ThematicBreakSurvivesNoteSwitchTests.swift`. The root cause in such bugs is usually that the post-load reparse doesn't re-stamp the HR attribute on the dash run. Worth treating as a permanent test obligation, not a one-time fix.

6. **HR inside list item / blockquote** — multiple editors handle this inconsistently. CommonMark allows it under conditions, but UX varies. Sidekick should explicitly decide (and test) what happens when `---` appears inside a list item.

7. **HR auto-creates mid-list / mid-table** — typing `---` inside a list or table sometimes promotes to HR unintentionally. The trigger should be context-aware.

8. **Cursor traps on rendered blocks** (general, observed in Joplin, DEVONthink, Cursor IDE): when a block renders to something that the OS text engine doesn't have a sane cursor position for, the caret can become "trapped." Sidekick's "HR lines are uninhabitable" rule sidesteps this entirely by never letting the caret land on the HR in the first place — a strong design choice.

---

## 6. Recommended Sidekick HR behavior spec

Each rule below is either (a) sourced from CommonMark, (b) sourced from observed convention, or (c) a principled Sidekick design choice where no convention exists.

### Parsing
- **R1** (CommonMark): accept `---`, `***`, `___`, internal-space variants, and 0–3 leading spaces.
- **R2** (CommonMark): reject mixed-character HR lines (`---***`, `-*-`).
- **R3** (CommonMark): resolve `paragraph-text\n---` (no blank line above) as **setext H2**, not HR.
- **R4** (CommonMark, currently relevant on this branch): The branch is named `fix/hr-dashes-only` — the parser changes suggest tightening HR detection to only the `-` character variant, or only the unambiguous dash-only shape. Verify the parser changes do not violate R1 (must still accept `***` and `___`) unless Sidekick is intentionally narrowing to a "dashes-only" UX — in which case this is a design choice that should be called out explicitly in the spec.

### Visual rendering
- **R5** (convention): render HR as a thin hairline replacing the dash run when not selected.
- **R6** (Sidekick choice): keep the literal `---` characters in storage. The hairline is an attributed-render layer, not a block-replacement.
- **R7** (Sidekick choice, currently enforced): the HR attribute must be re-stamped after every external storage push (note switch, file reload). Regression-tested by `ThematicBreakSurvivesNoteSwitchTests`.

### Creation
- **R8** (Sidekick choice): typing the third dash on an otherwise-empty line auto-promotes to HR. Regression-tested by `test_typingThirdDash_caretStaysWithinFreshlyConvertedHR`.
- **R9** (Sidekick choice, recommend): provide undo escape via Cmd+Z — must restore literal dashes, not delete them outright.

### Caret behavior
- **R10** (Sidekick choice, currently enforced): HR lines are **uninhabitable**. Any caret landing on an HR line snaps to the nearest neighbor.
- **R11** (Sidekick choice, currently enforced): snap direction follows motion — forward (target > previous) snaps to line below HR; backward snaps to line above. Regression-tested by `CaretSkipsAcrossHRTests`.
- **R12** (Sidekick choice, currently enforced): edge cases — HR at doc start snaps below only; HR at doc end snaps above only; HR-is-entire-doc means no snap (caret has nowhere to go).

### Selection
- **R13** (Sidekick choice, currently enforced): range selections that *span* an HR are NOT snapped — the user is explicitly selecting a region that includes the HR, and that intent should be honoured. Tested by `test_rangeSelectionAcrossHR_notSnapped`.
- **R14** (recommend, no current test): Cmd+A across a document with HRs should include them in the selection. (Mirror of R13.)

### Deletion
- **R15** (recommend, untested): Backspace from the line immediately after an HR should delete the HR cleanly, not "merge" the following line into the HR. Test gap.
- **R16** (recommend, untested): Delete (forward) from the line immediately before an HR — same: removes the HR. Test gap.
- **R17** (recommend, untested): a selection-delete that spans an HR removes it atomically along with its surrounding newlines, without leaving orphan blank lines. Test gap.

### Copy/paste
- **R18** (recommend, untested): copy of a region containing an HR yields literal `---` text on the clipboard (since storage is dash text). Paste produces the same dashes, which then re-parse as an HR if the surrounding context still qualifies. Test gap.

### Bug-pattern guards
- **R19** (recommend, untested): typing `---` mid-list-item or mid-table should NOT auto-promote to HR. Context-aware trigger. Test gap.
- **R20** (recommend, partially tested): HR rendering must survive: (a) note switch ✓ tested, (b) file reload from disk — gap, (c) undo across editor focus loss — gap.

---

## 7. Comparison-checklist for current Sidekick state

When we move to the comparison phase, walk through each rule R1–R20 against:
- `Sources/Sidekick/MarkdownInlineParser.swift` — R1, R2, R3, R4
- `Sources/Sidekick/HybridEditorView.swift` (caret snap logic, external-push branch) — R7, R10, R11, R12, R13
- `Sources/Sidekick/FormattingToolbarView.swift` — likely R8/R9 surface (toolbar HR insert)
- `Tests/SidekickTests/Regressions/*` — coverage map for R7, R10–R13
- **Gaps to file**: R15, R16, R17, R18, R19, R20(b), R20(c) all have no current regression coverage based on the file inventory.

---

## Sources

[1] HR editor-behavior research, agent 2 summary: "No public source documents triple-click selection, drag-select, or Shift+Down behavior with HRs … none publish their cursor/selection/deletion specifications publicly."
[2] Same — confirmed gap across Bear, Typora, iA Writer, Ulysses, Obsidian, Notion, Craft, Apple Notes.
[3] CommonMark spec, §4.1 Thematic breaks — https://spec.commonmark.org/0.30/
[4] GitHub Flavored Markdown spec — https://github.github.com/gfm/
[5] Bear FAQ: Markdown Support — https://bear.app/faq/how-to-use-markdown-in-bear/
[6] Typora Markdown Reference — https://support.typora.io/Markdown-Reference/
[7] iA Writer Markdown Guide — https://ia.net/writer/support/basics/markdown-guide
[8] Markdown Guide: Bear — https://www.markdownguide.org/tools/bear/
[9] Obsidian Forum: Horizontal Rule Spacing Inconsistent — https://forum.obsidian.md/t/horizontal-rule-spacing-inconsistent-between-live-preview-and-reading-modes/71878
[10] Obsidian Forum: Horizontal Line with `---` does not show on load in LP — https://forum.obsidian.md/t/horizontal-line-with-does-not-show-on-load-in-lp/95865
[11] Notion Help: Columns, Headings, and Dividers — https://www.notion.com/help/columns-headings-and-dividers
[12] Craft Markdown Shortcuts — https://support.craft.do/hc/en-us/articles/360019555597-Markdown-Style-Shortcuts
[13] Apple Community: Horizontal Rules in Notes — https://discussions.apple.com/thread/250476048
[14] Bear Community: Unexpected HR Behavior — https://community.bear.app/t/unexpected-hr-behavior/411
[15] Same as [10] — root cause was inherited list-styling CSS (`text-indent: -583px`), fixed in Obsidian v1.8.8.
[16] Obsidian Forum: Horizontal rule after a tag — https://forum.obsidian.md/t/horizontal-rule-after-a-tag/31938
