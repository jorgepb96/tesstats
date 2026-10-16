import SwiftUI

// MARK: - Adaptive Liquid Glass
//
// Liquid Glass (iOS/iPadOS/macOS 26+) lives ONLY on the navigation layer — tab bar,
// toolbars, sheets, floating controls. Dense reading content sits on solid surfaces.
//
// `adaptiveGlass` resolves to:
//   • Solid surface         when Reduce Transparency or Increase Contrast is on (a11y),
//   • Real `.glassEffect`   on OS 26+,
//   • `.ultraThinMaterial`  as the elegant fallback on older OSes.

struct AdaptiveGlass<S: Shape>: ViewModifier {
    let shape: S
    let tint: Color?
    let interactive: Bool

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        if reduceTransparency || contrast == .increased {
            content
                .background(Brand.elevatedSurface, in: shape)
                .overlay(shape.stroke(Brand.hairline, lineWidth: 1))
        } else if #available(iOS 26.0, macOS 26.0, *) {
            content.glassEffect(resolvedGlass, in: shape)
        } else {
            content
                .background(.ultraThinMaterial, in: shape)
                .overlay(shape.stroke(Brand.hairline, lineWidth: 1))
        }
    }

    @available(iOS 26.0, macOS 26.0, *)
    private var resolvedGlass: Glass {
        var glass: Glass = .regular
        if let tint { glass = glass.tint(tint) }
        if interactive { glass = glass.interactive() }
        return glass
    }
}

extension View {
    /// Apply Liquid Glass (capsule) with graceful fallbacks.
    func adaptiveGlass(tint: Color? = nil, interactive: Bool = false) -> some View {
        modifier(AdaptiveGlass(shape: Capsule(), tint: tint, interactive: interactive))
    }

    /// Apply Liquid Glass clipped to a custom shape.
    func adaptiveGlass(in shape: some Shape, tint: Color? = nil, interactive: Bool = false) -> some View {
        modifier(AdaptiveGlass(shape: shape, tint: tint, interactive: interactive))
    }
}

// MARK: - Glass container (morphing group)

/// Groups nearby glass elements so they blend/morph coherently. On older OSes it is a passthrough.
struct AdaptiveGlassContainer<Content: View>: View {
    var spacing: CGFloat = 16
    @ViewBuilder var content: Content

    var body: some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

// MARK: - Glass buttons

private struct GlassProminentButton: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        if #available(iOS 26.0, macOS 26.0, *), !reduceTransparency {
            content.buttonStyle(.glassProminent).tint(Brand.action)
        } else {
            content.buttonStyle(.borderedProminent).tint(Brand.action)
        }
    }
}

private struct GlassButton: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        if #available(iOS 26.0, macOS 26.0, *), !reduceTransparency {
            content.buttonStyle(.glass)
        } else {
            content.buttonStyle(.bordered).tint(Brand.textSecondary)
        }
    }
}

extension View {
    /// Prominent crimson call-to-action button, glass on OS 26+.
    func glassProminentButtonStyle() -> some View { modifier(GlassProminentButton()) }
    /// Secondary glass button, glass on OS 26+.
    func glassButtonStyle() -> some View { modifier(GlassButton()) }
}
