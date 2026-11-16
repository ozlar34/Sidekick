/// `FormattingToolbarView` — the formatting toolbar and its popover. It only shows the active styles and calls
/// the closures it is given (`EditorPaneView` wires them to `NoteTextView.perform(_:)`); the edits themselves are the
/// editor view's format commands (`NoteTextView+Format.swift`).

import AppKit
import SwiftUI

/// Formatting toolbar shown under the title. Buttons call `perform` (provided by EditorPaneView), which hands the
/// command to the editor view; the active styles come from the editor view's format state.
struct FormattingToolbarView: View {
    /// Inline styles the toolbar shows as active (bold, italic, code, strikethrough, underline).
    internal enum InlineKind { case bold, italic, code, strikethrough, underline }

    /// Block kind of the caret's line that the popover shows as active. A line is exactly one of these or none;
    /// headings have their own value (`activeHeadingLevel`).
    internal enum LinePrefix { case bullet, numbered, checklist, blockquote }

    let perform: (NoteFormatCommand) -> Void
    /// Heading level (1-3) of the caret's line, or nil for a line that is not a heading.
    var activeHeadingLevel: Int? = nil
    /// Block kind of the caret's line, or nil for plain lines.
    var activeLinePrefix: LinePrefix? = nil
    /// Inline styles active at the caret or on the whole selection (armed styles included).
    var activeInlineKinds: Set<InlineKind> = []

    /// Apple Notes-style: a single "Aa" trigger collapses every formatting
    /// control behind one popover. Inline buttons (B/I/U/S) and paragraph
    /// styles (Heading / Subheading / Body / Bulleted / Numbered / Quote)
    /// live inside `FormattingPopoverView`. Inline code (⌘⌥C) and Link (⌘K)
    /// remain reachable via the Format menu / shortcuts but aren't surfaced
    /// in the popover — Apple Notes itself doesn't either.
    @State private var popoverShown = false

    var body: some View {
        HStack(spacing: 2) {
            FormatPopoverTrigger(isOpen: $popoverShown)
                .popover(isPresented: $popoverShown, arrowEdge: .bottom) {
                    FormattingPopoverView(
                        perform: perform,
                        activeHeadingLevel: activeHeadingLevel,
                        activeLinePrefix: activeLinePrefix,
                        activeInlineKinds: activeInlineKinds,
                        dismiss: { popoverShown = false }
                    )
                }

            // Apple Notes places the checklist button immediately right of
            // the "Aa" trigger — single tap, no popover. ⌘⇧L parity (D-S-02
            // explicit modifier mask via the menu equivalent in AppDelegate).
            FormatButton(
                systemName: "checklist",
                tooltip: "Checklist (⌘⇧L)",
                accessibilityLabel: "Checklist",
                isActive: activeLinePrefix == .checklist
            ) { perform(.checklist) }

            Spacer()
        }
    }
}

/// Single toolbar button — 28×28 hit target with rounded-rect background that
/// shows hover (subtle gray) and active (accent-tinted) states. Plain button
/// style so the background is fully under our control; borderless was leaving
/// the button feeling dead with no hover affordance, which hurt discoverability.
private struct FormatButton: View {
    let systemName: String
    let tooltip: String
    let accessibilityLabel: String
    let isActive: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(backgroundColor)
                        .animation(.easeOut(duration: 0.12), value: isHovered)
                )
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help(tooltip)
        .accessibilityLabel(accessibilityLabel)
        .onHover { isHovered = $0 }
    }

    private var backgroundColor: Color {
        if isActive { return Color.accentColor.opacity(0.18) }
        if isHovered { return Color.primary.opacity(0.07) }
        return .clear
    }
}

/// "Aa" trigger button — the only control that lives on the toolbar bar
/// itself. Clicking it opens the formatting popover. Visual treatment
/// mirrors `FormatButton` (28pt height, 6pt corner, hover background) so
/// the toolbar reads as one button family — the only difference is the
/// glyph: a styled "Aa" text mark instead of an SF Symbol, matching Apple
/// Notes' custom mark.
private struct FormatPopoverTrigger: View {
    @Binding var isOpen: Bool

    @State private var isHovered = false

    var body: some View {
        Button(action: { isOpen.toggle() }) {
            Text("Aa")
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 36, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(backgroundColor)
                        .animation(.easeOut(duration: 0.12), value: isHovered)
                )
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help("Formatting")
        .accessibilityLabel("Formatting")
        .onHover { isHovered = $0 }
    }

    private var backgroundColor: Color {
        if isOpen { return Color.accentColor.opacity(0.18) }
        if isHovered { return Color.primary.opacity(0.07) }
        return .clear
    }
}

/// Apple Notes-style formatting panel. Two regions:
///   • Inline row: B / I / U / S — tapping toggles the style and closes the popover.
///   • Paragraph styles: Heading / Subheading / Body / Bulleted List /
///     Numbered List / Block Quote. Tap applies and CLOSES the popover —
///     these are mutually exclusive picks, not stackable toggles. Heading
///     levels show a leading checkmark when the caret's line matches; list
///     types currently never show a checkmark (active-state line-prefix
///     tracking is a follow-up — Apple Notes also doesn't track these
///     visually for non-heading rows).
///
/// Heading 3 is intentionally absent from the popover (parity with Apple
/// Notes' two-level Title/Heading-Subheading scheme — Title lives in its
/// own field above the toolbar, so the popover starts at H1). The ⌘⌥3
/// shortcut still fires `formatHeading3` via AppDelegate; this hides H3
/// from the visual surface only.
private struct FormattingPopoverView: View {
    let perform: (NoteFormatCommand) -> Void
    let activeHeadingLevel: Int?
    let activeLinePrefix: FormattingToolbarView.LinePrefix?
    let activeInlineKinds: Set<FormattingToolbarView.InlineKind>
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Inline row — popover dismisses after each tap so it doesn't
            // hide the text the user just formatted. Multi-format stacking
            // is still possible via repeated keyboard shortcuts (⌘B / ⌘I /
            // ⌘U / ⌘⇧X) which don't open the popover.
            HStack(spacing: 2) {
                FormatButton(
                    systemName: "bold",
                    tooltip: "Bold (⌘B)",
                    accessibilityLabel: "Bold",
                    isActive: activeInlineKinds.contains(.bold)
                ) { perform(.bold); dismiss() }

                FormatButton(
                    systemName: "italic",
                    tooltip: "Italic (⌘I)",
                    accessibilityLabel: "Italic",
                    isActive: activeInlineKinds.contains(.italic)
                ) { perform(.italic); dismiss() }

                FormatButton(
                    systemName: "underline",
                    tooltip: "Underline (⌘U)",
                    accessibilityLabel: "Underline",
                    isActive: activeInlineKinds.contains(.underline)
                ) { perform(.underline); dismiss() }

                FormatButton(
                    systemName: "strikethrough",
                    tooltip: "Strikethrough (⌘⇧X)",
                    accessibilityLabel: "Strikethrough",
                    isActive: activeInlineKinds.contains(.strikethrough)
                ) { perform(.strikethrough); dismiss() }
            }
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .padding(.bottom, 6)

            Divider()

            // Paragraph styles — single pick, dismisses popover after tap.
            VStack(spacing: 2) {
                ParagraphStyleRow(
                    label: "Heading",
                    labelFont: .system(size: 17, weight: .semibold),
                    isActive: activeHeadingLevel == 1
                ) { perform(.heading(1)); dismiss() }

                ParagraphStyleRow(
                    label: "Subheading",
                    labelFont: .system(size: 15, weight: .semibold),
                    isActive: activeHeadingLevel == 2
                ) { perform(.heading(2)); dismiss() }

                ParagraphStyleRow(
                    label: "Body",
                    labelFont: .system(size: 13, weight: .regular),
                    isActive: activeHeadingLevel == nil
                ) { perform(.heading(nil)); dismiss() }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 6)

            Divider()

            // List + quote types — visual marker baked into the row label
            // so the user sees what the prefix will look like.
            VStack(spacing: 2) {
                ParagraphStyleRow(
                    label: "•  Bulleted List",
                    labelFont: .system(size: 13, weight: .regular),
                    isActive: activeLinePrefix == .bullet
                ) { perform(.bullet); dismiss() }

                ParagraphStyleRow(
                    label: "1.  Numbered List",
                    labelFont: .system(size: 13, weight: .regular),
                    isActive: activeLinePrefix == .numbered
                ) { perform(.numbered); dismiss() }

                ParagraphStyleRow(
                    label: "❘  Block Quote",
                    labelFont: .system(size: 13, weight: .regular),
                    isActive: activeLinePrefix == .blockquote
                ) { perform(.quote); dismiss() }

                ParagraphStyleRow(
                    label: "□  Checklist",
                    labelFont: .system(size: 13, weight: .regular),
                    isActive: activeLinePrefix == .checklist
                ) { perform(.checklist); dismiss() }

                // One-shot insert — no toggle-off path (a thematic break has
                // no "active" state to highlight; clicking always emits one).
                ParagraphStyleRow(
                    label: "—  Horizontal Rule",
                    labelFont: .system(size: 13, weight: .regular),
                    isActive: false
                ) { perform(.rule); dismiss() }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 6)
        }
        .frame(width: 240)
    }
}

/// Single row in the paragraph-styles list. Leading 12pt slot reserved
/// for a checkmark (rendered always, opacity-toggled by `isActive`) so
/// active and inactive rows share a baseline — text doesn't shift when
/// the active state moves between rows.
private struct ParagraphStyleRow: View {
    let label: String
    let labelFont: Font
    let isActive: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.accentColor)
                    .opacity(isActive ? 1 : 0)
                    .frame(width: 12)
                Text(label)
                    .font(labelFont)
                    .foregroundColor(.primary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(isHovered ? Color.primary.opacity(0.07) : .clear)
                    .animation(.easeOut(duration: 0.12), value: isHovered)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
