## Tests/SidekickTests/Support

`KeystrokeRunner` is a windowless TextKit harness that drives
`HybridEditorView.Coordinator` end-to-end. The stack assembly mirrors the
pattern in `EditorInteractionTests.makeStack` but uses `HybridTextView` so
the F-07 `insertText` override and armed-inline consumption-on-type are
also exercised. Used by `TranscriptRunnerTests` (smoke), `InvariantFuzzTests`
(Layer 2 fuzzer), and `Regressions/*Tests` (keystroke-driven regression
guards).

## Adding a new transcript test

```swift
@MainActor final class MyFeatureTests: XCTestCase {
    func test_someBehavior() {
        let runner = KeystrokeRunner(
            initialBody: "hello",
            initialSelection: NSRange(location: 5, length: 0)
        )
        runner.type(" world")
        runner.key(.enter)
        runner.assertBody("hello world\n")
        runner.assertSelection(NSRange(location: 12, length: 0))
    }
}
```

Use `runner.type(_:)` for printable input (routed through
`HybridTextView.insertText`), `runner.key(_:)` for special keys (routed
through `coordinator.textView(_:doCommandBy:)` with default-NSTextView
fallthrough when the Coordinator declines), and `runner.select(_:)` to
move the caret programmatically (also fires the selection-change
notification so armed-inline cancel logic runs).

## Extracting a fuzzer finding

When `InvariantFuzzTests` fails, the message ends with a
`Replayable transcript:` block. Copy that block verbatim into a new file
`Tests/SidekickTests/Regressions/FuzzerFinding_seed{N}.swift`, wrap it in
a test method, add the assertion(s) that reproduce the violated invariant,
and (if the underlying bug isn't being fixed yet) mark `XCTExpectFailure`
so the suite stays green.

## Tuning the fuzzer

The tunables block sits at the top of
`Tests/SidekickTests/Fuzz/InvariantFuzzTests.swift`. Defaults: 200 seeds ×
30 steps each, measured runtime ~0.6s on M1 with a 10s budget guard. To
make it faster: lower `seedCount` or `maxStepsPerSeed`. To make it thorough
for an overnight run: raise `seedCount` to 5000 (the budget guard will
trip and tell you to relax the assertion).

## Why no NSWindow

The stack assembly mirrors `EditorInteractionTests.makeStack`. AppKit's
NSTextView works without a window for the delegate/storage/layout paths
we test (delegate dispatch, text mutation, attribute application, parser
re-runs). UI rendering and gesture paths are NOT covered by this harness
— use SwiftUI previews / interactive runs for those.
