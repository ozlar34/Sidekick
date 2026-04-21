/// Josefin Sans font routing + registration for Sidekick.
///
/// Josefin Sans ships with Sidekick as bundled TTF (`Resources/Fonts/*.ttf`,
/// copied into `.app/Contents/Resources/Fonts/` by build-and-run.sh). The
/// .app's Info.plist sets `ATSApplicationFontsPath = Fonts` so AppKit
/// registers the fonts at launch. `register()` below is a belt-and-suspenders
/// path for `swift run` dev builds where Info.plist is not present.
///
/// Code spans (inline + fenced) intentionally stay on
/// NSFont.monospacedSystemFont — Josefin Sans is not a programming font and
/// using it for code would hurt legibility.
import AppKit
import CoreText
import SwiftUI

enum SidekickFont {
    static let family = "Josefin Sans"

    /// Programmatic font registration — safety net for non-bundle runs.
    /// Looks in Bundle.main's `Fonts` resource directory first (the path
    /// ATSApplicationFontsPath also uses), then falls back to
    /// `<project>/Resources/Fonts` relative to the executable (dev runs).
    static func register() {
        let candidates: [URL] = {
            var urls: [URL] = []
            if let fontsDir = Bundle.main.url(forResource: "Fonts", withExtension: nil) {
                urls.append(fontsDir)
            }
            // Dev fallback: `.build/debug/Sidekick` → project root → Resources/Fonts
            let execDir = (Bundle.main.executableURL ?? Bundle.main.bundleURL).deletingLastPathComponent()
            let devCandidate = execDir
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Resources/Fonts")
            urls.append(devCandidate)
            return urls
        }()

        for dir in candidates {
            guard let contents = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil
            ) else { continue }
            for url in contents {
                let ext = url.pathExtension.lowercased()
                guard ext == "ttf" || ext == "otf" else { continue }
                CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
            }
        }
    }

    /// NSFont lookup by weight + italic trait with system fallback.
    /// Used by MarkdownTextStorage, HybridEditorView, and any other AppKit
    /// caller that needs an explicit NSFont.
    static func ns(size: CGFloat, weight: NSFont.Weight = .regular, italic: Bool = false) -> NSFont {
        let fm = NSFontManager.shared
        var traits: NSFontTraitMask = []
        if italic { traits.insert(.italicFontMask) }
        let fmWeight = nsFontManagerWeight(for: weight)
        if let f = fm.font(withFamily: family, traits: traits, weight: fmWeight, size: size) {
            return f
        }
        // Fallback preserves the shape of the requested face so the UI still
        // reads as Regular/Bold/Italic even when Josefin Sans isn't loaded
        // (e.g. before register() runs or inside unit tests).
        let sysTraits: NSFontDescriptor.SymbolicTraits = italic ? [.italic] : []
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        if sysTraits.isEmpty { return base }
        let desc = base.fontDescriptor.withSymbolicTraits(sysTraits)
        return NSFont(descriptor: desc, size: size) ?? base
    }

    /// NSFontManager weight scale (0-15). Apple documents 5=Regular,
    /// 6=Medium, 8=SemiBold, 9=Bold; the rest follow the standard spread.
    private static func nsFontManagerWeight(for weight: NSFont.Weight) -> Int {
        switch weight {
        case .ultraLight: return 1
        case .thin:       return 2
        case .light:      return 3
        case .regular:    return 5
        case .medium:     return 6
        case .semibold:   return 8
        case .bold:       return 9
        case .heavy:      return 10
        case .black:      return 11
        default:          return 5
        }
    }
}

extension Font {
    /// SwiftUI Font.custom using the PostScript name for the exact Josefin Sans
    /// cut, since Josefin ships with mixed PostScript naming
    /// (`JosefinSans-Thin`, `JosefinSansRoman-Regular`, `JosefinSansItalic-*`)
    /// that Font.custom won't resolve by family name + weight alone.
    static func josefin(size: CGFloat, weight: Font.Weight = .regular, italic: Bool = false) -> Font {
        .custom(josefinPostScriptName(for: weight, italic: italic), size: size)
    }
}

private func josefinPostScriptName(for weight: Font.Weight, italic: Bool) -> String {
    switch (weight, italic) {
    case (.thin, false):     return "JosefinSans-Thin"
    case (.thin, true):      return "JosefinSans-ThinItalic"
    case (.light, false):    return "JosefinSansRoman-Light"
    case (.light, true):     return "JosefinSansItalic-Light"
    case (.medium, false):   return "JosefinSansRoman-Medium"
    case (.medium, true):    return "JosefinSansItalic-Medium"
    case (.semibold, false): return "JosefinSansRoman-SemiBold"
    case (.semibold, true):  return "JosefinSansItalic-SemiBold"
    case (.bold, false):     return "JosefinSansRoman-Bold"
    case (.bold, true):      return "JosefinSansItalic-Bold"
    case (_, false):         return "JosefinSansRoman-Regular"
    case (_, true):          return "JosefinSansItalic-Regular"
    }
}
