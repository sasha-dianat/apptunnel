// Skin.swift — palette and drawing primitives shared by every view.
// Extracted verbatim from main.swift; no behaviour change.

import AppKit

// MARK: - Skin

enum Skin {
    static let metalHi   = NSColor(srgbRed: 0.40, green: 0.40, blue: 0.47, alpha: 1)
    static let metal     = NSColor(srgbRed: 0.235, green: 0.235, blue: 0.275, alpha: 1)
    static let metalLo   = NSColor(srgbRed: 0.145, green: 0.145, blue: 0.180, alpha: 1)
    static let metalDeep = NSColor(srgbRed: 0.055, green: 0.055, blue: 0.075, alpha: 1)
    static let green     = NSColor(srgbRed: 0.000, green: 1.000, blue: 0.298, alpha: 1)
    static let greenMid  = NSColor(srgbRed: 0.000, green: 0.720, blue: 0.220, alpha: 1)
    static let greenDim  = NSColor(srgbRed: 0.000, green: 0.380, blue: 0.130, alpha: 1)
    static let amber     = NSColor(srgbRed: 1.000, green: 0.780, blue: 0.150, alpha: 1)
    static let red       = NSColor(srgbRed: 1.000, green: 0.290, blue: 0.170, alpha: 1)
    static let label     = NSColor(srgbRed: 0.66, green: 0.66, blue: 0.74, alpha: 1)
    static let lcd       = NSColor(srgbRed: 0.02, green: 0.03, blue: 0.02, alpha: 1)

    static func mono(_ s: CGFloat, _ bold: Bool = false) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: s, weight: bold ? .bold : .regular)
    }
}

func bevel(_ r: NSRect, sunken: Bool = false) {
    let hi = sunken ? Skin.metalDeep : Skin.metalHi
    let lo = sunken ? Skin.metalHi : Skin.metalDeep
    hi.setFill()
    NSRect(x: r.minX, y: r.maxY - 1, width: r.width, height: 1).fill()
    NSRect(x: r.minX, y: r.minY, width: 1, height: r.height).fill()
    lo.setFill()
    NSRect(x: r.minX, y: r.minY, width: r.width, height: 1).fill()
    NSRect(x: r.maxX - 1, y: r.minY, width: 1, height: r.height).fill()
}

func text(_ s: String, _ p: NSPoint, _ f: NSFont, _ c: NSColor, glow: CGFloat = 0) {
    var a: [NSAttributedString.Key: Any] = [.font: f, .foregroundColor: c]
    if glow > 0 {
        let sh = NSShadow()
        sh.shadowColor = c.withAlphaComponent(glow)
        sh.shadowBlurRadius = 5
        sh.shadowOffset = .zero
        a[.shadow] = sh
    }
    (s as NSString).draw(at: p, withAttributes: a)
}

func width(_ s: String, _ f: NSFont) -> CGFloat {
    (s as NSString).size(withAttributes: [.font: f]).width
}

/// Frame-rate independent easing toward a target.
func ease(_ cur: inout CGFloat, _ target: CGFloat, _ rate: CGFloat = 0.22) {
    cur += (target - cur) * rate
    if abs(target - cur) < 0.0005 { cur = target }
}

/// Render determinism.
///
/// The analyser drives its bars from `CGFloat.random`, so two snapshots of the
/// SAME binary never matched and a pixel-hash regression check was meaningless.
/// In snapshot modes this switches to a seeded sequence, which makes render
/// tests able to catch a real change instead of just noise.
enum Render {
    static var deterministic = false
    private static var seed: UInt64 = 0x9E3779B97F4A7C15

    /// Uniform in 0..<hi. Seeded and repeatable when `deterministic` is set.
    static func rand(_ hi: CGFloat) -> CGFloat {
        if !deterministic { return CGFloat.random(in: 0..<max(hi, 0.000001)) }
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        let unit = CGFloat((seed >> 33) % 1_000_000) / 1_000_000.0
        return unit * hi
    }

    /// Restart the sequence so every snapshot begins from the same point.
    static func reseed() { seed = 0x9E3779B97F4A7C15 }
}
