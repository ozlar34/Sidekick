import XCTest
import AppKit
@testable import Sidekick

/// Deterministic textual snapshot of an `NSAttributedString`. Emitted as a
/// line-per-attribute-run summary with attribute keys sorted alphabetically
/// and values normalized to stable forms (system-color names, font postscript
/// names, paragraph-style key fields only when they differ from default).
///
/// Captures the styling surface where view-layer bugs live: marker glyph
/// substitution (via the substring on each run), font traits (bold/italic/
/// mono), foreground / background color, paragraph alignment + line height,
/// strikethrough / underline, link URLs, and Sidekick's custom marker
/// attributes (`sidekickHiddenMarker`, `sidekickBulletMarker`,
/// `sidekickChecklistMarker`, `sidekickNumberedMarker`, `sidekickLinkChip`,
/// `sidekickThematicBreak`).
///
/// Baselines live under `Tests/SidekickTests/__Snapshots__/<TestClass>/
/// <testMethod>.<name>.snap`. Re-record with `SIDEKICK_RECORD_SNAPSHOTS=1`.
enum AttributeSnapshot {

    static func serialize(_ str: NSAttributedString) -> String {
        var lines: [String] = ["SNAPSHOT v1 length=\(str.length)"]
        let full = NSRange(location: 0, length: str.length)
        str.enumerateAttributes(in: full, options: []) { attrs, range, _ in
            let substring = (str.string as NSString).substring(with: range)
            let escaped = escape(substring)
            let attrSummary = formatAttributes(attrs)
            let start = range.location
            let end = range.location + range.length
            lines.append("[\(start),\(end)) \"\(escaped)\" \(attrSummary)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Escape

    private static func escape(_ s: String) -> String {
        var out = ""
        for c in s {
            switch c {
            case "\\": out.append("\\\\")
            case "\"": out.append("\\\"")
            case "\n": out.append("\\n")
            case "\t": out.append("\\t")
            case "\r": out.append("\\r")
            default:   out.append(c)
            }
        }
        return out
    }

    // MARK: - Attribute formatting

    private static func formatAttributes(_ attrs: [NSAttributedString.Key: Any]) -> String {
        var parts: [(String, String)] = []
        for (key, value) in attrs {
            parts.append((key.rawValue, formatValue(key: key, value: value)))
        }
        parts.sort { $0.0 < $1.0 }
        return parts.map { "\($0.0)=\($0.1)" }.joined(separator: " ")
    }

    private static func formatValue(key: NSAttributedString.Key, value: Any) -> String {
        switch key {
        case .font:
            if let f = value as? NSFont { return formatFont(f) }
        case .foregroundColor, .backgroundColor,
             .strokeColor, .underlineColor, .strikethroughColor:
            if let c = value as? NSColor { return formatColor(c) }
        case .paragraphStyle:
            if let p = value as? NSParagraphStyle { return formatParagraphStyle(p) }
        case .link:
            if let url = value as? URL { return "\"\(url.absoluteString)\"" }
            if let s = value as? String { return "\"\(s)\"" }
        case .underlineStyle, .strikethroughStyle:
            if let i = value as? Int { return "\(i)" }
            if let n = value as? NSNumber { return n.stringValue }
        default:
            // Custom `.sidekick*` keys and anything else.
            if let b = value as? Bool { return b ? "true" : "false" }
            if let n = value as? NSNumber { return n.stringValue }
            if let s = value as? String { return "\"\(s)\"" }
        }
        return "\(value)"
    }

    // MARK: - Font

    private static func formatFont(_ f: NSFont) -> String {
        let traits = f.fontDescriptor.symbolicTraits
        var traitLabels: [String] = []
        if traits.contains(.bold)        { traitLabels.append("bold") }
        if traits.contains(.italic)      { traitLabels.append("italic") }
        if traits.contains(.monoSpace)   { traitLabels.append("mono") }
        if traits.contains(.condensed)   { traitLabels.append("condensed") }
        if traits.contains(.expanded)    { traitLabels.append("expanded") }
        let traitStr = traitLabels.sorted().joined(separator: ",")
        let ps = f.fontDescriptor.postscriptName ?? f.fontName
        return "{name=\(ps),pt=\(f.pointSize),traits=[\(traitStr)]}"
    }

    // MARK: - Color

    /// AppKit returns the same singleton for `.textColor`, `.linkColor`, etc.
    /// every call, so identity (`===`) yields a stable, appearance-agnostic
    /// name. Fall back to sRGB hex for colors created via
    /// `init(red:green:blue:alpha:)` or similar.
    private static let namedColors: [(String, NSColor)] = [
        ("textColor",                 .textColor),
        ("linkColor",                 .linkColor),
        ("labelColor",                .labelColor),
        ("secondaryLabelColor",       .secondaryLabelColor),
        ("tertiaryLabelColor",        .tertiaryLabelColor),
        ("quaternaryLabelColor",      .quaternaryLabelColor),
        ("placeholderTextColor",      .placeholderTextColor),
        ("disabledControlTextColor",  .disabledControlTextColor),
        ("controlAccentColor",        .controlAccentColor),
        ("controlBackgroundColor",    .controlBackgroundColor),
        ("textBackgroundColor",       .textBackgroundColor),
        ("selectedTextBackgroundColor", .selectedTextBackgroundColor),
        ("clear",                     .clear),
        ("white",                     .white),
        ("black",                     .black),
    ]

    private static func formatColor(_ c: NSColor) -> String {
        for (name, ref) in namedColors {
            if c === ref { return "system:\(name)" }
        }
        if let s = c.usingColorSpace(.sRGB) {
            return String(
                format: "#%02X%02X%02X%02X",
                Int(round(s.redComponent   * 255)),
                Int(round(s.greenComponent * 255)),
                Int(round(s.blueComponent  * 255)),
                Int(round(s.alphaComponent * 255))
            )
        }
        return c.description
    }

    // MARK: - Paragraph style

    /// Emit only the fields that differ from `NSParagraphStyle.default` so
    /// snapshots stay compact. Ordered fields are always written in the same
    /// sequence so diffs are stable.
    private static func formatParagraphStyle(_ p: NSParagraphStyle) -> String {
        let d = NSParagraphStyle.default
        var parts: [String] = []
        if p.alignment              != d.alignment              { parts.append("align=\(alignmentName(p.alignment))") }
        if p.lineHeightMultiple     != d.lineHeightMultiple     { parts.append("lineHeightMultiple=\(p.lineHeightMultiple)") }
        if p.lineSpacing            != d.lineSpacing            { parts.append("lineSpacing=\(p.lineSpacing)") }
        if p.paragraphSpacing       != d.paragraphSpacing       { parts.append("paragraphSpacing=\(p.paragraphSpacing)") }
        if p.paragraphSpacingBefore != d.paragraphSpacingBefore { parts.append("paragraphSpacingBefore=\(p.paragraphSpacingBefore)") }
        if p.firstLineHeadIndent    != d.firstLineHeadIndent    { parts.append("firstLineHeadIndent=\(p.firstLineHeadIndent)") }
        if p.headIndent             != d.headIndent             { parts.append("headIndent=\(p.headIndent)") }
        if p.tailIndent             != d.tailIndent             { parts.append("tailIndent=\(p.tailIndent)") }
        if p.minimumLineHeight      != d.minimumLineHeight      { parts.append("minimumLineHeight=\(p.minimumLineHeight)") }
        if p.maximumLineHeight      != d.maximumLineHeight      { parts.append("maximumLineHeight=\(p.maximumLineHeight)") }
        return "{\(parts.joined(separator: ","))}"
    }

    private static func alignmentName(_ a: NSTextAlignment) -> String {
        switch a {
        case .left:      return "left"
        case .right:     return "right"
        case .center:    return "center"
        case .justified: return "justified"
        case .natural:   return "natural"
        @unknown default: return "raw\(a.rawValue)"
        }
    }
}

// MARK: - Assertion helper + record mode

/// Assert that the supplied snapshot string matches the baseline at
/// `__Snapshots__/<TestClass>/<testMethod>.<name>.snap`. Re-record baselines
/// by setting `SIDEKICK_RECORD_SNAPSHOTS=1` for the test run.
///
/// `name` distinguishes multiple snapshots taken within one test method
/// (e.g., `"after-bold"`, `"after-paste"`).
@MainActor
func assertAttributeSnapshot(_ snapshot: String,
                             named name: String,
                             testCase: XCTestCase,
                             file: StaticString = #file,
                             line: UInt = #line)
{
    let testFileURL = URL(fileURLWithPath: "\(file)")
    let snapshotDir = snapshotsDirectory(forTestFile: testFileURL)
        .appendingPathComponent(testCase.snapshotClassName)
    let snapshotURL = snapshotDir
        .appendingPathComponent("\(testCase.snapshotMethodName).\(name).snap")

    let record = ProcessInfo.processInfo
        .environment["SIDEKICK_RECORD_SNAPSHOTS"] == "1"

    if record {
        do {
            try FileManager.default.createDirectory(
                at: snapshotDir,
                withIntermediateDirectories: true
            )
            try snapshot.write(to: snapshotURL, atomically: true, encoding: .utf8)
        } catch {
            XCTFail("Failed to write snapshot \(snapshotURL.path): \(error)",
                    file: file, line: line)
        }
        return
    }

    guard FileManager.default.fileExists(atPath: snapshotURL.path) else {
        XCTFail("""
            No baseline snapshot at \(snapshotURL.path).
            Re-run with SIDEKICK_RECORD_SNAPSHOTS=1 to record one.
            """, file: file, line: line)
        return
    }

    do {
        let existing = try String(contentsOf: snapshotURL, encoding: .utf8)
        if existing != snapshot {
            XCTFail("""
                Snapshot \(name) mismatch.
                Baseline (\(snapshotURL.path)):
                \(existing)
                ----- vs actual -----
                \(snapshot)
                Re-record with SIDEKICK_RECORD_SNAPSHOTS=1 if intentional.
                """, file: file, line: line)
        }
    } catch {
        XCTFail("Failed to read snapshot \(snapshotURL.path): \(error)",
                file: file, line: line)
    }
}

// MARK: - Snapshot directory resolution

/// Walk up from the test source file looking for the `SidekickTests`
/// directory; `__Snapshots__` is the sibling created next to it. Survives
/// the test bundle's working dir (which is `.build/...`) because `#file`
/// resolves to the source path captured at compile time.
private func snapshotsDirectory(forTestFile testFileURL: URL) -> URL {
    var url = testFileURL.deletingLastPathComponent()
    while url.path != "/" {
        if url.lastPathComponent == "SidekickTests" {
            return url.appendingPathComponent("__Snapshots__")
        }
        url = url.deletingLastPathComponent()
    }
    return testFileURL.deletingLastPathComponent()
        .appendingPathComponent("__Snapshots__")
}

private extension XCTestCase {
    /// Type name of the test class (e.g. "HostedEditorSnapshotTests").
    var snapshotClassName: String { String(describing: type(of: self)) }

    /// Strip ObjC bridge wrapper from `XCTestCase.name`. Stored form is
    /// "-[ClassName methodName]" — return just `methodName`.
    var snapshotMethodName: String {
        let raw = self.name
        if let space = raw.firstIndex(of: " ") {
            let after = raw.index(after: space)
            var trimmed = String(raw[after...])
            if trimmed.hasSuffix("]") { trimmed.removeLast() }
            return trimmed
        }
        return raw
    }
}
