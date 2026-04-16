#!/usr/bin/env swift
// Usage: run from repo root — `swift Scripts/generate-icon.swift`. Relative paths assume cwd = repo root.
//
// Composites an SF Symbol onto a vertical-gradient rounded square, emits the
// full 10-entry AppIcon.iconset/ contract, then runs `iconutil -c icns` to
// produce Resources/AppIcon.icns. Single-file Swift script with zero third-
// party deps (AppKit + CoreGraphics only).
//
// Source pattern: 06-RESEARCH.md §Code Examples Pattern 1 (lines 226-308)
// + Pattern 2 (lines 312-329) iconset filename ↔ pixel-size contract.
// + Pitfall 2 fix: explicit exit(Int32(task.terminationStatus)) gate after
//   iconutil so silent partial-icns failures (wrong pixel size, missing PNG)
//   do not pass.
//
// Tunables — see CONTEXT ICON-02, ICON-03 (locked decisions).
//   - symbolName: SF Symbol name. Swap here to retune the icon.
//   - accentTop / accentBottom: vertical-gradient endpoints (sky → deep blue,
//     macOS-native accent-blue family).
//
// Geometry constants (locked):
//   - cornerRadius = size * 0.2237  (community squircle approximation; Pitfall 4)
//   - symbolPointSize = size * 0.55, weight = .medium, tint white

import AppKit
import CoreGraphics

// --- Tunables (ICON-02, ICON-03) ---
let symbolName = "note.text"
let accentTop = NSColor(calibratedRed: 0.20, green: 0.55, blue: 0.98, alpha: 1.0)   // sky blue
let accentBottom = NSColor(calibratedRed: 0.10, green: 0.35, blue: 0.88, alpha: 1.0) // deep blue

// --- Render one size ---
func renderIcon(size: Int) -> Data? {
    let canvas = NSSize(width: size, height: size)
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 32
    ) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // Rounded-square background — ~22.37% for the macOS squircle approximation
    // (see Pitfall 4 in 06-RESEARCH.md). Apple's true shape is a continuous-
    // curvature Bézier, but a plain cornerRadius of ~0.2237 × side is
    // visually acceptable for a personal app and matches what most OSS
    // projects use.
    let rect = NSRect(origin: .zero, size: canvas)
    let radius = CGFloat(size) * 0.2237
    let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    path.addClip()
    if let gradient = NSGradient(colors: [accentTop, accentBottom]) {
        gradient.draw(in: rect, angle: -90)  // vertical top→bottom
    }

    // SF Symbol rendering
    let symbolPoint = CGFloat(size) * 0.55  // occupy ~55% of the canvas
    let config = NSImage.SymbolConfiguration(pointSize: symbolPoint, weight: .medium)
    guard let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
        .withSymbolConfiguration(config) else {
        NSGraphicsContext.restoreGraphicsState()
        return nil
    }
    // Tint the symbol white — use a template-style render via NSImage tinting.
    let symRect = NSRect(x: (CGFloat(size) - symbol.size.width) / 2,
                         y: (CGFloat(size) - symbol.size.height) / 2,
                         width: symbol.size.width, height: symbol.size.height)
    NSColor.white.set()
    symbol.draw(in: symRect, from: .zero, operation: .sourceOver, fraction: 1.0)

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

// --- Write the full iconset (see Pattern 2 below for filename contract) ---
let iconset = URL(fileURLWithPath: "Resources/AppIcon.iconset")
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

// Pairs of (filename, pixelSize) — matches the macOS iconset contract exactly.
// NOTE: pixel size differs from the point size in the filename
// (e.g. icon_16x16@2x.png MUST be 32×32 px). Misnaming → silent iconutil
// failure (Pitfall 2).
let pairs: [(String, Int)] = [
    ("icon_16x16.png", 16),   ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),   ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),("icon_512x512@2x.png", 1024),
]
for (name, px) in pairs {
    guard let data = renderIcon(size: px) else {
        print("failed \(name)"); exit(1)
    }
    do {
        try data.write(to: iconset.appendingPathComponent(name))
    } catch {
        print("write failed \(name): \(error)"); exit(1)
    }
}

// --- Convert to .icns ---
let task = Process()
task.launchPath = "/usr/bin/iconutil"
task.arguments = ["-c", "icns", "-o", "Resources/AppIcon.icns", iconset.path]
task.launch()
task.waitUntilExit()

// DELTA vs RESEARCH.md Pattern 1: explicit non-zero exit gate so silent
// partial-icns failures (Pitfall 2) do not pass. Pattern 1 omits this check.
if task.terminationStatus != 0 {
    print("iconutil failed with exit code \(task.terminationStatus)")
    exit(Int32(task.terminationStatus))
}

print("Generated Resources/AppIcon.icns from \(symbolName) (\(pairs.count) sizes)")
