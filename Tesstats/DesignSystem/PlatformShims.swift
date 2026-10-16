import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

enum PlatformClipboard {
    @MainActor
    static func copy(_ text: String) {
        #if os(iOS)
        UIPasteboard.general.string = text
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}

/// Cross-platform keyboard hints. `keyboardType` is iOS/iPadOS-only, so these become
/// no-ops on macOS, keeping the shared SwiftUI code building everywhere.
enum PlatformKeyboard {
    case `default`, URL, numberPad, decimal, email
}

extension ToolbarItemPlacement {
    /// Leading toolbar slot that compiles on both iOS and macOS (`topBarLeading` is iOS-only).
    static var leadingBar: ToolbarItemPlacement {
        #if os(iOS)
        .topBarLeading
        #else
        .navigation
        #endif
    }
    /// Trailing toolbar slot that compiles on both iOS and macOS.
    static var trailingBar: ToolbarItemPlacement {
        #if os(iOS)
        .topBarTrailing
        #else
        .primaryAction
        #endif
    }
}

extension View {
    /// Use the system's adaptive tab presentation. On iOS 26 the standard tab bar is Liquid
    /// Glass and can move out of the way while someone scrolls; older systems retain their
    /// native tab/sidebar appearance.
    @ViewBuilder
    func tesstatsTabBarBehavior() -> some View {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            self
                .tabViewStyle(.sidebarAdaptable)
                .tabBarMinimizeBehavior(.onScrollDown)
        } else {
            self.tabViewStyle(.sidebarAdaptable)
        }
        #else
        self
        #endif
    }

    /// Keep the final row/card visibly clear of floating navigation chrome. This is additional
    /// breathing room on top of the safe-area inset that the system TabView manages.
    func bottomScrollClearance(_ amount: CGFloat = 24) -> some View {
        contentMargins(.bottom, amount, for: .scrollContent)
    }

    /// Present the mounted driver surface using the most immersive presentation each platform
    /// provides. macOS deliberately uses a sheet because `fullScreenCover` is iOS-only.
    @ViewBuilder
    func driverDisplayCover(isPresented: Binding<Bool>) -> some View {
        #if os(iOS)
        self.fullScreenCover(isPresented: isPresented) { DriverDisplayView() }
        #else
        self.sheet(isPresented: isPresented) { DriverDisplayView().frame(minWidth: 900, minHeight: 560) }
        #endif
    }

    /// Maps embedded in cards are previews; present their fully interactive counterpart using
    /// the largest idiomatic surface available on each platform.
    @ViewBuilder
    func expandedMapCover<Content: View>(isPresented: Binding<Bool>,
                                         @ViewBuilder content: @escaping () -> Content) -> some View {
        #if os(iOS)
        self.fullScreenCover(isPresented: isPresented, content: content)
        #else
        self.sheet(isPresented: isPresented) {
            content().frame(minWidth: 760, minHeight: 560)
        }
        #endif
    }

    /// The driver surface owns every available pixel on a mounted iPhone or iPad.
    @ViewBuilder
    func driverSystemChromeHidden() -> some View {
        #if os(iOS)
        self.statusBarHidden(true).persistentSystemOverlays(.hidden)
        #else
        self
        #endif
    }

    /// Navigation details use the compact chevron-only back affordance on iOS.
    @ViewBuilder
    func compactNavigationBackButton() -> some View {
        #if os(iOS)
        self.toolbarRole(.editor)
        #else
        self
        #endif
    }

    @ViewBuilder
    func textFieldKeyboard(_ kind: PlatformKeyboard) -> some View {
        #if os(iOS)
        switch kind {
        case .default: self
        case .URL: self.keyboardType(.URL).textInputAutocapitalization(.never)
        case .numberPad: self.keyboardType(.numberPad)
        case .decimal: self.keyboardType(.decimalPad)
        case .email: self.keyboardType(.emailAddress).textInputAutocapitalization(.never)
        }
        #else
        self
        #endif
    }

    @ViewBuilder
    func keyboardTypeNumberPad() -> some View {
        #if os(iOS)
        self.keyboardType(.numberPad)
        #else
        self
        #endif
    }

    @ViewBuilder
    func keyboardTypeDecimal() -> some View {
        #if os(iOS)
        self.keyboardType(.decimalPad)
        #else
        self
        #endif
    }

    /// Inline navigation title on iOS (used by detail screens); no-op elsewhere.
    @ViewBuilder
    func navigationBarTitleDisplayModeInlineIfAvailable() -> some View {
        #if os(iOS)
        self.navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }

    /// Make text fields in this subtree start the keyboard in lowercase (no auto-capitalization).
    /// Applied near the root so it propagates to every field, including sheets. No-op on macOS.
    @ViewBuilder
    func lowercaseKeyboardStart() -> some View {
        #if os(iOS)
        self.textInputAutocapitalization(.never)
        #else
        self
        #endif
    }

    /// Bump up text on macOS — the iOS semantic font sizes are too small for a desktop display.
    @ViewBuilder
    func macTextScale() -> some View {
        #if os(macOS)
        self.dynamicTypeSize(.xLarge)
        #else
        self
        #endif
    }
}
