import SwiftUI

/// Five focused destinations. Secondary information lives with the screen it describes
/// instead of being duplicated in a catch-all "More" hierarchy.
struct RootTabView: View {
    @State private var selection: AppTab

    init() {
        let raw = ProcessInfo.processInfo.environment["TESSTATS_TAB"] ?? ""
        _selection = State(initialValue: AppTab(rawValue: raw) ?? .summary)
    }

    var body: some View {
        tabs
            .tesstatsTabBarBehavior()
    }

    private var tabs: some View {
        TabView(selection: $selection) {
            Tab(value: AppTab.summary) {
                DashboardView()
            } label: {
                tabLabel(.summary)
            }
            Tab(value: AppTab.trips) {
                TripsView()
            } label: {
                tabLabel(.trips)
            }
            Tab(value: AppTab.charging) {
                ChargesView()
            } label: {
                tabLabel(.charging)
            }
            Tab(value: AppTab.battery) {
                BatteryView()
            } label: {
                tabLabel(.battery)
            }
            Tab(value: AppTab.stats) {
                StatsView()
            } label: {
                tabLabel(.stats)
            }
        }
        .tint(Brand.action)
        .compactNavigationBackButton()
    }

    private func tabLabel(_ tab: AppTab) -> some View {
        Label(tab.title, systemImage: tab.icon)
            .accessibilityIdentifier("primary-tab-\(tab.rawValue)")
    }
}

enum AppTab: String, Hashable, CaseIterable {
    case summary, trips, charging, parking, battery, stats

    var title: String {
        switch self {
        case .summary: L("Summary")
        case .trips: L("Trips")
        case .charging: L("Charging")
        case .parking: L("Parking")
        case .battery: L("Battery")
        case .stats: L("Stats")
        }
    }
    var icon: String {
        switch self {
        case .summary: "gauge.with.dots.needle.67percent"
        case .trips: "map"
        case .charging: "bolt.fill"
        case .parking: "parkingsign"
        case .battery: "battery.100percent"
        case .stats: "chart.bar.xaxis"
        }
    }
}
