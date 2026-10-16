import AppIntents
import Foundation

// Siri / Shortcuts read-only queries. App Intents run inside the app process, so they read
// the most recent values from the offline cache (snapshots + charges) that the live pipeline
// persists. Honest about being read-only — they only report, never command the car.

@MainActor
enum IntentData {
    private static func latest() -> (name: String, state: VehicleState)? {
        let settings = SettingsStore()
        let snaps = CacheStore().loadAllSnapshots()
        guard !snaps.isEmpty else { return nil }
        let chosen = settings.config.selectedCarID.flatMap { id in snaps.first { $0.carID == id } } ?? snaps.first
        guard let snap = chosen else { return nil }
        return (snap.displayName ?? "Tesla", snap)
    }

    private static func units() -> Units { Units(config: SettingsStore().config) }

    static func batteryLine() -> String {
        guard let (name, s) = latest(), let level = s.batteryLevel else {
            return L("No recent data from your Tesla yet. Open Tesstats to connect.")
        }
        let u = units()
        let range = u.range(km: s.range(for: u.range))
        if s.isCharging, let limit = s.chargeLimitSoc {
            return L("\(name) is at \(level)%, charging to \(limit)%. About \(range) of range.")
        }
        return L("\(name) is at \(level)%, about \(range) of range.")
    }

    static func rangeLine() -> String {
        guard let (name, s) = latest() else {
            return L("No recent data from your Tesla yet. Open Tesstats to connect.")
        }
        let u = units()
        let range = u.range(km: s.range(for: u.range))
        return L("\(name) has about \(range) of range at \(s.batteryLevel ?? 0)%.")
    }

    static func monthCostLine() -> String {
        let settings = SettingsStore()
        let cache = CacheStore()
        let snaps = cache.loadAllSnapshots()
        let carID = settings.config.selectedCarID ?? snaps.first?.carID ?? 1
        let charges = cache.loadCharges(carID: carID)
        let cal = Calendar.current
        guard let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: Date())) else {
            return L("No charging data yet.")
        }
        let month = charges.filter { $0.startDate >= monthStart }
        guard !month.isEmpty else { return L("No charging sessions recorded this month.") }
        let pricing = ChargePricing(config: settings.config)
        let energy = month.reduce(0) { $0 + $1.energyAddedKwh }
        let cost = month.reduce(0) { $0 + pricing.cost(for: $1) }
        let u = units()
        return L("You've spent \(u.money(cost)) charging across \(month.count) sessions this month (\(u.energy(kwh: energy, digits: 0))).")
    }
}

// MARK: - Intents

struct BatteryStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Check Tesla battery"
    static let description = IntentDescription("Reports your Tesla's current battery level and range.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: IntentDialog(stringLiteral: IntentData.batteryLine()))
    }
}

struct RangeStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Check Tesla range"
    static let description = IntentDescription("Reports your Tesla's estimated range.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: IntentDialog(stringLiteral: IntentData.rangeLine()))
    }
}

struct MonthChargingCostIntent: AppIntent {
    static let title: LocalizedStringResource = "Tesla charging cost this month"
    static let description = IntentDescription("Reports how much you've spent charging this month.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: IntentDialog(stringLiteral: IntentData.monthCostLine()))
    }
}

// MARK: - Shortcuts phrases

struct TesstatsShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: BatteryStatusIntent(),
            phrases: [
                "What's my battery in \(.applicationName)",
                "Check my \(.applicationName) battery",
                "How much charge does my car have in \(.applicationName)"
            ],
            shortTitle: "Battery level",
            systemImageName: "battery.100percent")
        AppShortcut(
            intent: RangeStatusIntent(),
            phrases: [
                "What's my range in \(.applicationName)",
                "How far can my car go in \(.applicationName)"
            ],
            shortTitle: "Range",
            systemImageName: "gauge.with.dots.needle.50percent")
        AppShortcut(
            intent: MonthChargingCostIntent(),
            phrases: [
                "How much did I spend charging in \(.applicationName)",
                "My \(.applicationName) charging cost this month"
            ],
            shortTitle: "Charging cost",
            systemImageName: "creditcard")
    }
}
