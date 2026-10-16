#if os(macOS)
import SwiftUI

/// macOS-native navigation: a stable sidebar (logo + sections) with the content in the detail
/// pane. Replaces the iOS tab bar, which on macOS rendered as an unstable top segmented control.
struct MacRootView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var selection: AppTab = .summary
    @State private var showSettings = false

    private let sections: [AppTab] = [.summary, .trips, .charging, .battery, .parking, .stats]

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 300)
        } detail: {
            detail
                .frame(minWidth: 660, minHeight: 540)
        }
        .sheet(isPresented: $showSettings) {
            NavigationStack { SettingsView(presentedAsSheet: true) }
                .frame(width: 600, height: 680)
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            LogoMark(width: 142, color: Brand.signature)
                .frame(maxWidth: .infinity)
                .padding(.top, 28)
                .padding(.bottom, 22)

            List(selection: $selection) {
                ForEach(sections, id: \.self) { tab in
                    Label(tab.title, systemImage: tab.icon)
                        .font(.headline)
                        .padding(.vertical, 7)
                        .tag(tab)
                }
            }
            .listStyle(.sidebar)
            .environment(\.defaultMinListRowHeight, 40)
            .tint(Brand.action)

            sidebarFooter
        }
        .background(Brand.background)
    }

    private var sidebarFooter: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider().overlay(Brand.hairline)
            HStack(spacing: 8) {
                ConnectionDot(status: env.live.status)
                Text(env.live.status.label).font(.callout).foregroundStyle(Brand.textSecondary).lineLimit(1)
                Spacer()
                if env.settings.config.demoMode {
                    Text("Demo").font(.caption.weight(.semibold)).foregroundStyle(Brand.driving)
                }
            }
            Button {
                showSettings = true
            } label: {
                Label(L("Settings"), systemImage: "gearshape")
                    .font(.title3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .padding(.vertical, 4)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Brand.textPrimary)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .summary: DashboardView()
        case .trips: TripsView()
        case .charging: ChargesView()
        case .parking: ParkingView()
        case .battery: BatteryView()
        case .stats: StatsView()
        }
    }
}
#endif
