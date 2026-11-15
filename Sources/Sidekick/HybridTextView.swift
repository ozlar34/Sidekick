/// `HybridTextView` — the NSTextView subclass behind `HybridEditorView`.
///
/// This file holds the class declaration, its stored state, and the frame-
/// height floor / observer lifecycle. Behavior is split across extensions:
///   * `HybridTextView+Mouse.swift`         — click routing (checklist toggle,
///     link-label drag-select, post-click caret relocation).
///   * `HybridTextView+Typing.swift`        — `insertText` armed-format wrap
///     plus the two HR quick-insert triggers.
///   * `HybridTextView+CaretSnapping.swift` — pure "where should this caret
///     go" helpers for every managed region (HR, checklist gap, link chip).
///   * `HybridTextView+CaretMovement.swift` — `correctedCaretTarget` plus the
///     `setSelectedRanges` / plain-arrow overrides that consume those helpers.
///   * `HybridTextView+SelectionExtension.swift` — the shift-arrow
///     `move…AndModifySelection` overrides and their anchor/edge tracking.

import AppKit
import SwiftUI

/// NSTextView subclass that floors its frame height at the enclosing scroll
/// view's clip-view height. Without this, a short note's text view ends at
/// content height, leaving a "dead zone" below — clicks in that empty area
/// fall outside the text view's frame and never reach it. With the floor in
/// place, NSTextView's built-in "click below the last glyph → caret at end
/// of document" behavior covers the empty area for free, no mouseDown
/// override required.
///
/// Two paths feed the height update:
///   1. setConstrainedFrameSize — invoked by the layout manager after every
///      text edit. Flooring `desiredSize.height` at clip-view height makes
///      every layout-driven resize respect the floor.
///   2. clipFrameChanged — invoked when the scroll view (and thus the clip
///      view) resizes, e.g. window resize. Layout doesn't re-fire on a
///      height-only resize, so we re-floor explicitly here.
///
/// `widthTracksTextView` + `autoresizingMask = .width` continue to handle
/// width tracking; we only own the vertical floor.
/// Note: not `final` so test files can subclass with a local UndoManager
/// (windowless NSTextViews have no undoManager via the responder chain).
/// See `TestableHybridTextView` in ArmedInlineFormatTests.swift. Production
/// code never subclasses HybridTextView — there is exactly one instance
/// created in `HybridEditorView.makeNSView`.
class HybridTextView: NSTextView {
    // MARK: - Armed inline-format state (quick-260523-29t)
    //
    // "Hide markers on empty selection" UX: Cmd+B with caret-only selection
    // does NOT write `****` into the body; it arms the next-typed character's
    // style. State lives on the text view (the unique focused-editor source
    // of truth) and is mirrored upward through the weak `hybridController`
    // back-pointer so the toolbar can OR arming into its `isActive` highlight.
    //
    // Design Note (clear-on-consumption vs persist-until-cancel):
    //   The locked decisions hedged between these two behaviors. We CLEAR on
    //   consumption because the user-visible behavior is identical: after the
    //   first typed char, the caret sits between char and suffix — i.e. INSIDE
    //   an existing inline pair. The toolbar's `findAnyEnclosingInlinePair`
    //   path keeps the button highlighted as long as the caret stays inside.
    //   Subsequent typed chars naturally extend the pair via vanilla NSTextView
    //   insertion. On caret-move-out the inline-pair detector reports
    //   "not in a pair" and the button de-highlights. Strictly less state to
    //   track; revisit only if real UAT proves the simpler version feels wrong.

    /// Set of armed inline kinds. Empty when no Cmd+B/I/U/etc has been
    /// pressed with an empty selection (the default state).
    var armedInlineKinds: Set<FormattingToolbarView.InlineKind> = []

    /// Order of arming (innermost / first-armed → outermost / last-armed).
    /// Drives `composeArmedWrap`'s reading-order output. Kept in lockstep
    /// with `armedInlineKinds` by `FormattingToolbarView.armedInlineKindsAfterArm`.
    var armedInlineKindsOrder: [FormattingToolbarView.InlineKind] = []

    /// Weak back-pointer to the controller so the text view can republish
    /// arming changes upward. Set once in `HybridEditorView.makeNSView` right
    /// after `controller.textView = textView`. Weak to avoid the retain cycle
    /// (controller owns view-lifetime; we don't want the text view to keep
    /// the controller alive past its scope).
    weak var hybridController: HybridEditorController?

    /// One-shot flag — set to true immediately before a programmatic
    /// `setSelectedRange` call that participates in consumption-on-type, so
    /// the selection-change cancel branch in `setSelectedRanges` skips clearing
    /// the armed set on THAT specific call. AppKit fires selection-change as
    /// a side-effect of `replaceCharacters` + `setSelectedRange`, which would
    /// otherwise clear the armed set BEFORE consumption finishes.
    // Internal (not private): set in HybridTextView+Typing.swift, consumed in
    // HybridTextView+CaretMovement.swift.
    var suppressArmedClearOnNextSelectionChange: Bool = false

    /// Republish armed kinds upward. Coalesced (skip write when value
    /// unchanged) for the same SwiftUI re-render reason as the other
    /// HybridEditorController publishers.
    func republishArmedKinds() {
        guard let c = hybridController else { return }
        if c.armedInlineKinds != armedInlineKinds {
            c.armedInlineKinds = armedInlineKinds
        }
    }

    // MARK: - Selection-extension chain state
    //
    // Stored (so they cannot live in an extension); read and written by the
    // modify-selection overrides in HybridTextView+SelectionExtension.swift.

    /// Fixed anchor of an in-progress `moveLeftAndModifySelection`/
    /// `moveRightAndModifySelection` extension chain.
    ///
    /// AppKit's public API doesn't expose which end of `selectedRange()` is
    /// the anchor and which is the moving edge: `NSRange(location: 5,
    /// length: 3)` produced by anchoring at 5 and extending right to 8 is
    /// indistinguishable, after the fact, from the same range produced by
    /// anchoring at 8 and extending left to 5. `selectionAffinity` doesn't
    /// help either — it only disambiguates which line an insertion point
    /// belongs to at a wrapped line boundary, not which edge of a range
    /// selection is the anchor. So the anchor is tracked here instead of
    /// reconstructed: `extensionAnchorAndEdge(for:)` (re)confirms it to the
    /// current caret location every time a NEW extension starts from a
    /// zero-length selection — mirroring AppKit's own convention that a
    /// fresh shift-arrow press anchors wherever the caret currently sits —
    /// and otherwise leaves it untouched across a chain of subsequent
    /// shift-arrow presses (including ones this override defers straight to
    /// `super` for) so the anchor never drifts mid-chain. Any operation that
    /// collapses the selection back to zero length (a plain arrow key, a
    /// click, typing) is picked up automatically the next time either
    /// override runs, since `extensionAnchorAndEdge(for:)` always re-derives
    /// a fresh anchor when `current.length == 0`.
    var selectionExtensionAnchor: Int?

    /// Whether the CURRENT extension chain has already had a step corrected
    /// by this override (as opposed to every step so far being deferred to
    /// `super`). See outcome 3 in `stepExtension(anchor:naive:edge:direction:)`'s
    /// doc comment (HybridTextView+SelectionExtension.swift) for why, once
    /// true, every subsequent step in the
    /// chain must also be self-computed
    /// rather than handed back to `super` — empirically, `super` does not
    /// reliably resume extending from OUR tracked anchor after this override
    /// has called `setSelectedRange` with a non-native range. Reset to
    /// `false` whenever a new chain starts (mirrors `selectionExtensionAnchor`,
    /// and lives here rather than as a third case inside
    /// `extensionAnchorAndEdge(for:)` only because that function has no
    /// other reason to mutate state — resetting both together, right where
    /// "new chain" is detected, keeps the two invariants co-located).
    var selectionExtensionOwnedByOverride = false

    override func setConstrainedFrameSize(_ desiredSize: NSSize) {
        var size = desiredSize
        if let clipHeight = enclosingScrollView?.contentView.bounds.height {
            size.height = max(size.height, clipHeight)
        }
        super.setConstrainedFrameSize(size)
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        guard let clipView = enclosingScrollView?.contentView else { return }
        // Remove first to avoid stacking observers if the view re-mounts
        // (e.g. SwiftUI tearing down and recreating the NSViewRepresentable).
        NotificationCenter.default.removeObserver(
            self, name: NSView.frameDidChangeNotification, object: clipView
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(clipFrameChanged),
            name: NSView.frameDidChangeNotification, object: clipView
        )
        clipView.postsFrameChangedNotifications = true
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func clipFrameChanged() {
        guard let lm = layoutManager, let tc = textContainer else { return }
        lm.ensureLayout(for: tc)
        let used = lm.usedRect(for: tc)
        let clipHeight = enclosingScrollView?.contentView.bounds.height ?? used.height
        let insetY = textContainerInset.height * 2
        let target = max(used.height + insetY, clipHeight)
        if abs(frame.height - target) > 0.5 {
            var f = frame
            f.size.height = target
            frame = f
        }
    }
}
