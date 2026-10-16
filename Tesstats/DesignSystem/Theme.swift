import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: - Color hex helpers

extension Color {
    /// Create a color from a 24-bit RGB hex value, e.g. `Color(hex: 0xB30333)`.
    init(hex: UInt32, alpha: Double = 1) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: alpha)
    }

    /// Create a color from a hex string such as `"B30333"` or `"#B30333"`.
    init(hex string: String) {
        self.init(hex: Brand.parseHex(string))
    }
}

/// A color that resolves to its `light` or `dark` value based on the active interface style,
/// so it updates automatically when the app toggles between light and dark appearance.
func adaptiveColor(light: UInt32, dark: UInt32, lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) -> Color {
    #if canImport(UIKit)
    return Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(rgb: dark, alpha: darkAlpha)
            : UIColor(rgb: light, alpha: lightAlpha)
    })
    #elseif canImport(AppKit)
    return Color(nsColor: NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return isDark
            ? NSColor(rgb: dark, alpha: darkAlpha)
            : NSColor(rgb: light, alpha: lightAlpha)
    })
    #else
    return Color(hex: dark, alpha: darkAlpha)
    #endif
}

#if canImport(UIKit)
private extension UIColor {
    convenience init(rgb: UInt32, alpha: CGFloat = 1) {
        self.init(red: CGFloat((rgb >> 16) & 0xFF) / 255,
                  green: CGFloat((rgb >> 8) & 0xFF) / 255,
                  blue: CGFloat(rgb & 0xFF) / 255,
                  alpha: alpha)
    }
}
#elseif canImport(AppKit)
private extension NSColor {
    convenience init(rgb: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
                  green: CGFloat((rgb >> 8) & 0xFF) / 255,
                  blue: CGFloat(rgb & 0xFF) / 255,
                  alpha: alpha)
    }
}
#endif

// MARK: - Brand palette

/// Central, minimal, premium palette. Adapts between a pure-black dark theme and a clean
/// light theme; the accent color is user-selectable at runtime (default Tesla blue `#3E6AE1`).
enum Brand {

    // MARK: Accent (user-selectable)

    /// Current accent as a 24-bit RGB value. Updated from the user's setting via `setAccent`.
    /// Single-writer (main actor, on a settings change) and read during rendering.
    nonisolated(unsafe) static var accent: UInt32 = 0x3E6AE1

    /// Every decorative/action color resolves from the same user-selected accent. The legacy
    /// `crimson` names remain as aliases so existing call sites also follow the selection.
    static var action: Color { Color(hex: accent) }
    static var actionBright: Color { Color(hex: Self.scale(accent, 1.22)) }
    static var signature: Color { Color(hex: accent) }
    static var crimson: Color { Color(hex: accent) }
    static var crimsonBright: Color { Color(hex: Self.scale(accent, 1.22)) }
    static var crimsonDim: Color { Color(hex: Self.scale(accent, 0.60)) }

    /// Point the whole UI at a new accent color. Pair with a view-tree rebuild (the root keys
    /// its `.id` on the accent hex) so static `Brand.crimson` reads re-resolve everywhere.
    static func setAccent(_ hexString: String) { accent = parseHex(hexString) }

    // MARK: Surfaces (adaptive light/dark)

    /// App canvas — pure black in dark, near-white in light.
    static let background = adaptiveColor(light: 0xF3F3F1, dark: 0x101113)
    /// Card surface for dense reading content (never glass).
    static let surface = adaptiveColor(light: 0xFFFFFF, dark: 0x1B1C1F)
    static let elevatedSurface = adaptiveColor(light: 0xE8E8E5, dark: 0x25262A)
    static let hairline = adaptiveColor(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.10, darkAlpha: 0.08)

    static let textPrimary = adaptiveColor(light: 0x000000, dark: 0xFFFFFF)
    static let textSecondary = adaptiveColor(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.62, darkAlpha: 0.64)
    static let textTertiary = adaptiveColor(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.42, darkAlpha: 0.40)

    // Semantic status colors (kept restrained, the accent stays the hero).
    static let online = Color(hex: 0x35C759)
    static var charging: Color { crimson }
    static var driving: Color { action }
    static let asleep = Color(hex: 0x8E8E93)
    static let offline = Color(hex: 0x5A5A60)
    static let warning = Color(hex: 0xFF9F0A)
    static let danger = Color(hex: 0xFF453A)

    // MARK: Hex helpers

    /// Parse `"B30333"` / `"#B30333"` into a 24-bit RGB value (0 on failure).
    static func parseHex(_ string: String) -> UInt32 {
        var s = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        return UInt32(s, radix: 16) ?? 0
    }

    /// Scale each RGB channel by `factor` (clamped to 0…255) to derive bright/dim accent shades.
    static func scale(_ rgb: UInt32, _ factor: Double) -> UInt32 {
        func ch(_ shift: UInt32) -> UInt32 {
            let v = Double((rgb >> shift) & 0xFF) * factor
            return UInt32(min(255, max(0, v.rounded())))
        }
        return (ch(16) << 16) | (ch(8) << 8) | ch(0)
    }
}

// MARK: - Spacing & radii

enum Metrics {
    static let cardRadius: CGFloat = 18
    static let tightRadius: CGFloat = 12
    static let cardPadding: CGFloat = 18
    static let screenPadding: CGFloat = 16
    static let cardSpacing: CGFloat = 14
}
