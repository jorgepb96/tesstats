import Foundation

enum AppLanguage: String, CaseIterable, Identifiable, Codable {
    case system = ""
    case spanish = "es"
    case english = "en"
    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: L("System")
        case .spanish: "Español"
        case .english: "English"
        }
    }
}

/// Runtime language override. Because the modern `String(localized:)` API bypasses the
/// old Bundle swizzle, every localized string in the app goes through `L(_:)`, which
/// resolves against the currently selected language bundle — so switching is instant.
///
/// Strings are only half the picture: dates, weekday names, chart axis labels and numbers are
/// formatted from a `Locale`, not from the string table. `locale` mirrors the selected language
/// so those surfaces switch with it instead of staying on the device language (which used to
/// leave e.g. Spanish weekday labels inside an otherwise English app).
enum LanguageManager {
    nonisolated(unsafe) static var bundle: Bundle?
    /// Locale matching the selected language — `.current` while following the system.
    nonisolated(unsafe) static private(set) var locale: Locale = .current
    /// Calendar carrying `locale`, so month/weekday symbols follow the selected language.
    nonisolated(unsafe) static private(set) var calendar: Calendar = .current

    static func apply(_ code: String) {
        let effectiveCode = resolvedLanguageCode(code)
        bundle = Bundle.main.path(forResource: effectiveCode, ofType: "lproj").flatMap(Bundle.init(path:))
        locale = Locale(identifier: effectiveCode)
        var cal = Calendar.current
        cal.locale = locale
        calendar = cal
        if code.isEmpty {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set([effectiveCode], forKey: "AppleLanguages")
        }
    }

    /// Tesstats intentionally supports a two-language policy: Spanish devices use Spanish;
    /// every other system language uses the English source language. An explicit in-app
    /// override wins, while unknown/corrupt persisted values safely fall back to English.
    static func resolvedLanguageCode(
        _ code: String,
        preferredLanguages: [String] = Locale.preferredLanguages
    ) -> String {
        let requested = code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !requested.isEmpty {
            return requested == "es" || requested.hasPrefix("es-") ? "es" : "en"
        }
        let system = preferredLanguages.first?.lowercased() ?? "en"
        return system == "es" || system.hasPrefix("es-") ? "es" : "en"
    }

    static func resolvedLocale(
        _ code: String,
        preferredLanguages: [String] = Locale.preferredLanguages
    ) -> Locale {
        Locale(identifier: resolvedLanguageCode(code, preferredLanguages: preferredLanguages))
    }
}

/// Localize a string against the user-selected language (falls back to the system bundle).
func L(_ key: String.LocalizationValue) -> String {
    String(localized: key, bundle: LanguageManager.bundle ?? .main)
}
