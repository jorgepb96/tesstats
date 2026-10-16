import Foundation

// The `allCases` order of each enum below is the out-of-the-box layout, ordered for someone
// who opens the app to answer "how is my car / how much did it cost", with the enthusiast
// blocks further down. Anyone can reorder or hide them from the section's ▦ button.

enum TripsBlock: String, SectionBlock {
    case filters, totals, list, map

    var title: String {
        switch self {
        case .filters: L("Search & filters")
        case .totals: L("Totals")
        case .list: L("Trip list")
        case .map: L("Route map")
        }
    }
    var icon: String {
        switch self {
        case .filters: "line.3.horizontal.decrease.circle"
        case .totals: "sum"
        case .list: "list.bullet"
        case .map: "map"
        }
    }
    var blurb: String {
        switch self {
        case .filters: L("Search, tag filter and date range.")
        case .totals: L("Energy, efficiency and trip count for the current filter.")
        case .list: L("Your drives, newest first, grouped by day.")
        case .map: L("All filtered drives drawn on one map.")
        }
    }
}

enum ChargingBlock: String, SectionBlock {
    case filters, monthlyCost, totals, list, map, places

    var title: String {
        switch self {
        case .filters: L("Search & filters")
        case .monthlyCost: L("Monthly charging cost")
        case .totals: L("Totals")
        case .list: L("Session list")
        case .map: L("Charging map")
        case .places: L("Costs & places")
        }
    }
    var icon: String {
        switch self {
        case .filters: "line.3.horizontal.decrease.circle"
        case .monthlyCost: "chart.bar.xaxis"
        case .totals: "sum"
        case .list: "list.bullet"
        case .map: "map"
        case .places: "eurosign"
        }
    }
    var blurb: String {
        switch self {
        case .filters: L("Search, charger type and date range.")
        case .monthlyCost: L("Monthly costs by location and date range.")
        case .totals: L("Energy, cost and AC/DC split for the current filter.")
        case .list: L("Your charging sessions, newest first.")
        case .map: L("Where you charged, on one map.")
        case .places: L("Shortcut to per-location costs and prices.")
        }
    }
}

enum BatteryBlock: String, SectionBlock {
    case current, timeline, health, degradation, efficiency, updates

    var title: String {
        switch self {
        case .current: L("Current")
        case .timeline: L("Battery over time")
        case .health: L("Battery health")
        case .degradation: L("Degradation")
        case .efficiency: L("Efficiency & totals")
        case .updates: L("Software updates")
        }
    }
    var icon: String {
        switch self {
        case .current: "battery.100percent"
        case .timeline: "waveform.path.ecg"
        case .health: "cross.case"
        case .degradation: "chart.line.downtrend.xyaxis"
        case .efficiency: "leaf.fill"
        case .updates: "cpu"
        }
    }
    var blurb: String {
        switch self {
        case .current: L("Charge, usable capacity and range right now.")
        case .timeline: L("State of charge over the last days.")
        case .health: L("Capacity now versus when new.")
        case .degradation: L("Max range trend across months.")
        case .efficiency: L("Lifetime efficiency and charging totals.")
        case .updates: L("Firmware versions installed over time.")
        }
    }
}

enum StatsBlock: String, SectionBlock {
    case filters, comparison, cost, trends, charging, usage, heatmap, records, temperature, drain, eco

    var title: String {
        switch self {
        case .filters: L("Date range")
        case .comparison: L("Month comparison")
        case .cost: L("Cost")
        case .trends: L("Trends over time")
        case .charging: L("Where you charge")
        case .usage: L("When you drive")
        case .heatmap: L("Activity")
        case .records: L("Records")
        case .temperature: L("Consumption vs temperature")
        case .drain: L("Phantom drain")
        case .eco: L("Environmental impact")
        }
    }
    var icon: String {
        switch self {
        case .filters: "line.3.horizontal.decrease.circle"
        case .comparison: "arrow.left.arrow.right"
        case .cost: "creditcard"
        case .trends: "chart.line.uptrend.xyaxis"
        case .charging: "bolt.badge.clock"
        case .usage: "clock.arrow.circlepath"
        case .heatmap: "square.grid.3x3"
        case .records: "trophy"
        case .temperature: "thermometer.medium"
        case .drain: "drop"
        case .eco: "leaf"
        }
    }
    var blurb: String {
        switch self {
        case .filters: L("Filter trips, charges and statistics to a specific period.")
        case .comparison: L("This month against last month.")
        case .cost: L("What charging costs you, per 100 km and projected.")
        case .trends: L("Distance, energy and cost month by month.")
        case .charging: L("Sessions and spend per location.")
        case .usage: L("Which weekdays and hours you drive.")
        case .heatmap: L("A calendar of driving activity.")
        case .records: L("Longest trip, top speed, biggest charge…")
        case .temperature: L("How cold weather changes consumption.")
        case .drain: L("Standby battery loss while parked.")
        case .eco: L("CO₂ and petrol avoided versus a combustion car.")
        }
    }
}

enum ParkingBlock: String, SectionBlock {
    case filters, map, totals, live, list

    var title: String {
        switch self {
        case .filters: L("Date range")
        case .map: L("Parking map")
        case .totals: L("Totals")
        case .live: L("Current")
        case .list: L("Parking")
        }
    }

    var icon: String {
        switch self {
        case .filters: "line.3.horizontal.decrease.circle"
        case .map: "map"
        case .totals: "sum"
        case .live: "parkingsign.circle"
        case .list: "list.bullet"
        }
    }

    var blurb: String {
        switch self {
        case .filters: L("Filter trips, charges and statistics to a specific period.")
        case .map: L("Parking locations for the selected period.")
        case .totals: L("Time, energy, range and parked cost.")
        case .live: L("The current parking session when available.")
        case .list: L("Parking sessions grouped by day.")
        }
    }
}
