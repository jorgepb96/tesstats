import WidgetKit
import SwiftUI

// Home-screen and lock-screen widget showing the car's battery, range and charge status from
// the App Group snapshot the app keeps fresh. Read-only.

struct StatusEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
}

struct StatusProvider: TimelineProvider {
    func placeholder(in context: Context) -> StatusEntry {
        StatusEntry(date: Date(), snapshot: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (StatusEntry) -> Void) {
        completion(StatusEntry(date: Date(), snapshot: WidgetSharedStore().load() ?? .placeholder))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<StatusEntry>) -> Void) {
        let snap = WidgetSharedStore().load() ?? .placeholder
        // The app pushes immediate reloads via WidgetCenter; this is just a safety refresh.
        let next = Calendar.current.date(byAdding: .minute, value: 15, to: Date()) ?? Date().addingTimeInterval(900)
        completion(Timeline(entries: [StatusEntry(date: Date(), snapshot: snap)], policy: .after(next)))
    }
}

struct TesstatsStatusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "TesstatsStatusWidget", provider: StatusProvider()) { entry in
            StatusWidgetView(entry: entry)
                .environment(\.locale, entry.snapshot.interfaceLocale)
        }
        .configurationDisplayName("Tesstats")
        .description(Text("Battery, range and charging at a glance."))
        .supportedFamilies([.systemSmall, .systemMedium,
                            .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

// MARK: - Status colors (mirrors the app's CarState palette)

private func stateColor(_ raw: String) -> Color {
    switch raw {
    case "online": Brand.online
    case "charging": Brand.charging
    case "driving": Brand.driving
    case "asleep", "suspended": Brand.asleep
    case "updating", "start": Brand.warning
    default: Brand.offline
    }
}

private func stateSymbol(_ raw: String) -> String {
    switch raw {
    case "online": "checkmark.circle.fill"
    case "charging": "bolt.fill"
    case "driving": "steeringwheel"
    case "asleep", "suspended": "moon.zzz.fill"
    case "updating": "arrow.down.circle.fill"
    default: "powersleep"
    }
}

// MARK: - Views

struct StatusWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: StatusEntry

    private var snap: WidgetSnapshot { entry.snapshot }

    var body: some View {
        content
            .containerBackground(for: .widget) {
                (family == .systemSmall || family == .systemMedium) ? Brand.background : Color.clear
            }
    }

    @ViewBuilder
    private var content: some View {
        switch family {
        case .systemMedium: medium
        case .accessoryCircular: circular
        case .accessoryRectangular: rectangular
        case .accessoryInline: inline
        default: small
        }
    }

    // Home screen — small
    private var small: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 5) {
                Image(systemName: stateSymbol(snap.stateRaw)).font(.caption2.weight(.bold))
                    .foregroundStyle(stateColor(snap.stateRaw))
                Text(snap.carName).font(.caption2.weight(.semibold)).foregroundStyle(Brand.textSecondary).lineLimit(1)
                Spacer()
            }
            Spacer(minLength: 4)
            Text(snap.batteryString)
                .font(.system(size: 40, weight: .bold, design: .rounded))
                .foregroundStyle(snap.isCharging ? Brand.crimson : Brand.textPrimary)
                .minimumScaleFactor(0.6).lineLimit(1)
            ProgressView(value: Double(snap.batteryLevel), total: 100)
                .tint(snap.isCharging ? Brand.crimson : Brand.online)
            Spacer(minLength: 4)
            HStack(spacing: 4) {
                Image(systemName: "road.lanes").font(.caption2).foregroundStyle(Brand.textTertiary)
                Text(snap.rangeString()).font(.caption.weight(.medium)).foregroundStyle(Brand.textSecondary)
                Spacer()
                if snap.isCharging {
                    Text(snap.powerString).font(.caption2.weight(.semibold)).foregroundStyle(Brand.crimson)
                }
            }
        }
        .padding(2)
    }

    // Home screen — medium
    private var medium: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 5) {
                    Image(systemName: stateSymbol(snap.stateRaw)).font(.caption.weight(.bold))
                        .foregroundStyle(stateColor(snap.stateRaw))
                    Text(snap.carName).font(.caption.weight(.semibold)).foregroundStyle(Brand.textSecondary).lineLimit(1)
                }
                Text(snap.batteryString)
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .foregroundStyle(snap.isCharging ? Brand.crimson : Brand.textPrimary)
                ProgressView(value: Double(snap.batteryLevel), total: 100)
                    .tint(snap.isCharging ? Brand.crimson : Brand.online)
                Text(snap.rangeString()).font(.caption).foregroundStyle(Brand.textSecondary)
            }
            Divider().overlay(Brand.hairline)
            VStack(alignment: .leading, spacing: 8) {
                if snap.isCharging {
                    metric("bolt.fill", Text("Charging status"), snap.powerString, Brand.crimson)
                    metric("clock", Text("Time to full"), WidgetSnapshot.timeString(hours: snap.timeToFullHours, languageCode: snap.languageCode), Brand.textPrimary)
                    if let limit = snap.chargeLimitSoc {
                        metric("target", Text("Limit"), "\(limit)%", Brand.textPrimary)
                    }
                } else {
                    if let title = snap.lastTripTitle {
                        metric("map", Text("Last trip"), title, Brand.textPrimary)
                        metric("road.lanes", Text("Distance"), snap.distanceString(snap.lastTripDistanceKm), Brand.textSecondary)
                    }
                    if let odo = snap.odometerKm {
                        metric("gauge.with.dots.needle.bottom.50percent", Text("Odometer"), snap.distanceString(odo, digits: 0), Brand.textSecondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(2)
    }

    private func metric(_ icon: String, _ label: Text, _ value: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 9)).foregroundStyle(Brand.textTertiary)
                label.font(.system(size: 9)).foregroundStyle(Brand.textTertiary).lineLimit(1)
            }
            Text(value).font(.caption.weight(.semibold)).foregroundStyle(tint).lineLimit(1).minimumScaleFactor(0.7)
        }
    }

    // Lock screen — circular gauge
    private var circular: some View {
        Gauge(value: Double(snap.batteryLevel), in: 0...100) {
            Image(systemName: snap.isCharging ? "bolt.fill" : "minus.plus.batteryblock")
        } currentValueLabel: {
            Text("\(snap.batteryLevel)")
        }
        .gaugeStyle(.accessoryCircular)
    }

    // Lock screen — rectangular
    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: stateSymbol(snap.stateRaw)).font(.caption2)
                Text(snap.carName).font(.caption.weight(.semibold)).lineLimit(1)
            }
            Text("\(snap.batteryString) · \(snap.rangeString())").font(.caption2)
            if snap.isCharging {
                Text(verbatim: "\(snap.powerString) · \(WidgetSnapshot.timeString(hours: snap.timeToFullHours, languageCode: snap.languageCode))")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    // Lock screen — inline
    private var inline: some View {
        HStack(spacing: 3) {
            Image(systemName: snap.isCharging ? "bolt.fill" : "battery.50percent")
            Text(verbatim: "\(snap.batteryString) · \(snap.rangeString())")
        }
    }
}
