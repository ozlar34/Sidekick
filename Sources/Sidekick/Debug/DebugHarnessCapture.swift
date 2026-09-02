import AppKit
import Foundation

/// Capture half of `DebugHarness`: pixel screenshots of the panel window and
/// the ink metric used to detect an unpainted editor.
extension DebugHarness {

    // MARK: - POST /screenshot

    /// Captures the panel's real window pixels (CoreGraphics window capture of
    /// our own window needs no Screen Recording permission). `region` is
    /// "panel" (default) or "editor" (cropped to the text view's frame).
    /// Returns pixel stats for the captured region so a driver can detect an
    /// unpainted editor without image tooling: `inkFraction` is the share of
    /// pixels that differ from the region's dominant color.
    func screenshot(_ json: [String: Any]) throws -> [String: Any] {
        guard let panel else { throw fail("no panel") }
        guard let path = json["path"] as? String else { throw fail("path required") }
        let region = json["region"] as? String ?? "panel"

        var cg: CGImage?
        var source = "window"
        cg = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(panel.windowNumber),
                                     [.boundsIgnoreFraming, .bestResolution])
        if cg == nil || cg!.width <= 1, let cv = panel.contentView,
           let rep = cv.bitmapImageRepForCachingDisplay(in: cv.bounds) {
            cv.cacheDisplay(in: cv.bounds, to: rep)
            cg = rep.cgImage
            source = "cacheDisplay"
        }
        guard var image = cg else { throw fail("capture failed") }

        let scale = CGFloat(image.width) / panel.frame.width
        var cropRect: NSRect? = nil
        if region == "editor", let tv = Self.findTextView(in: panel.contentView) {
            let inWin = tv.convert(tv.visibleRect, to: nil)   // bottom-left origin
            // Window pixels have a top-left origin.
            let px = NSRect(x: inWin.origin.x * scale,
                            y: (panel.frame.height - inWin.maxY) * scale,
                            width: inWin.width * scale,
                            height: inWin.height * scale)
            cropRect = px
            if let c = image.cropping(to: px) { image = c }
        }

        let rep = NSBitmapImageRep(cgImage: image)
        guard let png = rep.representation(using: .png, properties: [:]) else { throw fail("png encode failed") }
        try png.write(to: URL(fileURLWithPath: path))

        var out: [String: Any] = ["path": path, "width": image.width, "height": image.height,
                                  "source": source, "scale": scale]
        if let cropRect { out["cropPixels"] = rect(cropRect) }
        out.merge(Self.pixelStats(image)) { a, _ in a }
        return out
    }

    /// Dominant color + fraction of pixels that differ from it by more than a
    /// small tolerance. Empty editor ⇒ inkFraction ≈ 0.
    static func pixelStats(_ image: CGImage) -> [String: Any] {
        let w = image.width, h = image.height
        guard w > 0, h > 0 else { return [:] }
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return [:] }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        // Quantize to 4 bits per channel to find the dominant color.
        var hist: [UInt32: Int] = [:]
        let step = max(1, (w * h) / 200_000)
        var i = 0
        while i < w * h {
            let o = i * 4
            let key = UInt32(buf[o] >> 4) << 8 | UInt32(buf[o + 1] >> 4) << 4 | UInt32(buf[o + 2] >> 4)
            hist[key, default: 0] += 1
            i += step
        }
        guard let dom = hist.max(by: { $0.value < $1.value })?.key else { return [:] }
        let dr = Int((dom >> 8) & 0xF) << 4, dg = Int((dom >> 4) & 0xF) << 4, db = Int(dom & 0xF) << 4
        var ink = 0, total = 0
        i = 0
        while i < w * h {
            let o = i * 4
            let d = abs(Int(buf[o]) - dr) + abs(Int(buf[o + 1]) - dg) + abs(Int(buf[o + 2]) - db)
            if d > 60 { ink += 1 }
            total += 1
            i += step
        }
        return ["dominant": [dr, dg, db], "inkFraction": Double(ink) / Double(max(total, 1)), "sampled": total]
    }
}
