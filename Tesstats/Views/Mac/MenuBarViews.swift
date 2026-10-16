#if os(macOS)
import SwiftUI
import AppKit
import UserNotifications

/// macOS app delegate: keeps Tesstats running in the menu bar after the window is closed, and
/// shows notification banners even while the app is frontmost.
final class MacAppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
    }

    /// Closing the window doesn't quit — the app lives on in the menu bar (background).
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}

/// The status-bar label: battery % (with a charging bolt) or a placeholder until data arrives.
struct MenuBarLabel: View {
    let env: AppEnvironment

    var body: some View {
        if let s = env.live.currentState, let level = s.batteryLevel {
            Label("\(level)%", systemImage: s.isCharging ? "bolt.fill" : batterySymbol(level))
        } else {
            Image(systemName: "bolt.car")
        }
    }

    private func batterySymbol(_ level: Int) -> String {
        switch level {
        case ..<13: "battery.0percent"
        case ..<38: "battery.25percent"
        case ..<63: "battery.50percent"
        case ..<88: "battery.75percent"
        default: "battery.100percent"
        }
    }
}

/// The dropdown shown when the menu-bar item is clicked: live status + open/quit actions.
struct MenuBarContent: View {
    let env: AppEnvironment
    @Environment(\.openWindow) private var openWindow

    private var units: Units { Units(config: env.settings.config) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                ConnectionDot(status: env.live.status)
                Text(env.live.currentState?.displayName ?? "Tesstats")
                    .font(.headline).foregroundStyle(Brand.textPrimary).lineLimit(1)
                Spacer()
                Text(env.live.status.label).font(.caption).foregroundStyle(Brand.textSecondary)
            }
            Divider().overlay(Brand.hairline)

            if let s = env.live.currentState {
                HStack(spacing: 16) {
                    ring(level: s.batteryLevel ?? 0, charging: s.isCharging)
                    VStack(alignment: .leading, spacing: 6) {
                        row("road.lanes", units.range(km: s.range(for: units.range)))
                        if s.isCharging {
                            row("bolt.fill", units.power(kw: s.chargerPower))
                            row("clock", units.duration(hours: s.timeToFullCharge))
                        } else if let odo = s.odometer {
                            row("gauge.with.dots.needle.bottom.50percent", units.distance(km: odo, digits: 0))
                        }
                    }
                    Spacer()
                }
            } else {
                Text(L("Waiting for the first data from your car…"))
                    .font(.subheadline).foregroundStyle(Brand.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .center).padding(.vertical, 10)
            }

            Divider().overlay(Brand.hairline)
            HStack {
                Button(L("Open window")) {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
                Spacer()
                Button(L("Quit Tesstats")) { NSApp.terminate(nil) }
            }
            .buttonStyle(.plain)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(Brand.crimson)
        }
        .padding(16)
        .frame(width: 300)
        .background(Brand.surface)
    }

    private func ring(level: Int, charging: Bool) -> some View {
        ZStack {
            Circle().stroke(Brand.elevatedSurface, lineWidth: 7)
            Circle().trim(from: 0, to: CGFloat(level) / 100)
                .stroke(charging ? Brand.crimson : Brand.online,
                        style: StrokeStyle(lineWidth: 7, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(level)%").font(.system(size: 16, weight: .bold, design: .rounded)).foregroundStyle(Brand.textPrimary)
        }
        .frame(width: 62, height: 62)
    }

    private func row(_ icon: String, _ value: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon).font(.caption).foregroundStyle(Brand.textTertiary).frame(width: 16)
            Text(value).font(.subheadline.weight(.medium)).foregroundStyle(Brand.textPrimary)
        }
    }
}
#endif
