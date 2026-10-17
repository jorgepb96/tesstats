import SwiftUI

struct DashboardView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var refreshing = false
    @State private var showSettings = false
    @State private var showInbox = false
    @State private var showDriverDisplay = false
    @State private var drivingSuggestionDismissed = false
    @State private var tutorialStep = 0
    @State private var showTutorial = false
    @AppStorage("tesstats.dashboard.tutorial.completed") private var tutorialCompleted = false

    private var units: Units { Units(config: env.settings.config) }
    private var carID: Int { env.live.resolvedCarID ?? 1 }

    /// Rebuilt only when the history changes. Read three times per body pass, and the live
    /// MQTT feed re-evaluates that body several times a second.
    @State private var insights = DashboardInsights(lastDrive: nil, efficiency30dWhPerKm: nil, activity48h: [])

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                DemoDataBanner(isDemo: env.settings.config.demoMode) { showSettings = true }
                ZStack {
                    Brand.background.ignoresSafeArea()
                    content
                    if showTutorial { tutorialOverlay }
                }
            }
            .navigationTitle("")
            .toolbarTitleDisplayModeInline()
            .toolbar { toolbarContent }
            .settingsSheet(isPresented: $showSettings)
            .sheet(isPresented: $showInbox) {
                NotificationInboxView()   // brings its own NavigationStack
            }
            .driverDisplayCover(isPresented: $showDriverDisplay)
        }
        .compactNavigationBackButton()
        .task(id: carID) { await env.history.loadIfNeeded(carID: carID) }
        .task(id: env.history.revision) {
            let drives = env.history.drives
            let charges = env.history.charges
            let fresh = await Task.detached(priority: .userInitiated) {
                DashboardInsightEngine.insights(drives: drives, charges: charges)
            }.value
            guard !Task.isCancelled else { return }
            insights = fresh
        }
        .onChange(of: env.live.currentState?.isDriving == true) { _, driving in
            if !driving { drivingSuggestionDismissed = false }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let state = env.live.currentState {
            GeometryReader { proxy in
                let contentWidth = max(0, proxy.size.width - Metrics.screenPadding * 2)
                ScrollView {
                    dashboardGrid(state, width: contentWidth)
                        .frame(width: contentWidth, alignment: .topLeading)
                        .padding(.horizontal, Metrics.screenPadding)
                        .padding(.top, 8)
                }
                .scrollContentBackground(.hidden)
                .bottomScrollClearance()
                .refreshable { await refresh() }
            }
            .onAppear {
                let startScreen = ProcessInfo.processInfo.environment["TESSTATS_START_SCREEN"]
                if startScreen == "driver" {
                    showDriverDisplay = true
                } else if startScreen == "settings" {
                    showSettings = true
                }
                if !tutorialCompleted && ProcessInfo.processInfo.environment["TESSTATS_SKIP_TUTORIAL"] != "1" {
                    showTutorial = true
                }
            }
        } else {
            waitingState
        }
    }

    @ViewBuilder
    private func dashboardGrid(_ state: VehicleState, width: CGFloat) -> some View {
        let cards = SectionLayout.visible(DashboardCard.self, layout: env.settings.config.layout(for: .summary))
        if width >= 720 {
            let indexed = Array(cards.enumerated())
            HStack(alignment: .top, spacing: Metrics.cardSpacing) {
                LazyVStack(spacing: Metrics.cardSpacing) {
                    #if os(iOS)
                    driverDisplayEntry(state)
                    #endif
                    ForEach(indexed.filter { $0.offset.isMultiple(of: 2) == false }, id: \.element) { _, card in
                        cardView(card, state: state)
                    }
                }
                LazyVStack(spacing: Metrics.cardSpacing) {
                    ForEach(indexed.filter { $0.offset.isMultiple(of: 2) }, id: \.element) { _, card in
                        cardView(card, state: state)
                    }
                }
            }
        } else {
            LazyVStack(spacing: Metrics.cardSpacing) {
                #if os(iOS)
                driverDisplayEntry(state)
                #endif
                ForEach(cards) { card in cardView(card, state: state) }
                Color.clear.frame(height: 8)
            }
        }
    }

    @ViewBuilder
    private var waitingState: some View {
        switch env.live.status {
        case .connecting:
            LoadingStateView(label: L("Connecting to TeslaMate…"))
        case .failed(let message):
            ErrorStateView(message: message) { env.live.restart() }
        case .notConfigured:
            EmptyStateView(systemImage: "server.rack",
                           title: L("Not connected"),
                           message: L("Set up your TeslaMate server in Settings, or try demo mode."),
                           actionTitle: L("Enable demo mode")) { env.enableDemoMode() }
        default:
            EmptyStateView(systemImage: "antenna.radiowaves.left.and.right",
                           title: L("Waiting for data"),
                           message: env.settings.config.usesAPIPolling
                               ? L("Connected — waiting for TeslaMateApi to report your car.")
                               : L("Connected — waiting for the first MQTT messages from your car."))
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        #if os(iOS)
        ToolbarItem(placement: .leadingBar) { ConnectionStatusMenu() }
        ToolbarItem(placement: .principal) { ToolbarLogo() }
        #endif
        ToolbarItemGroup(placement: .trailingBar) {
            #if os(iOS)
            Button { showDriverDisplay = true } label: { Image(systemName: "steeringwheel") }
                .tint(Brand.action)
                .accessibilityLabel(L("Open driver display"))
                .accessibilityIdentifier("open-driver-display")
            #endif
            ArrangeSectionButton(section: .summary, blockType: DashboardCard.self)
            RefreshButton(isRefreshing: refreshing) { Task { await refresh() } }
            #if os(iOS)
            Button {
                showInbox = true
            } label: {
                Image(systemName: "bell")
            }
            .tint(Brand.action)
            .accessibilityLabel(L("Notifications"))
            .accessibilityIdentifier("open-notifications")
            SettingsGearButton(isPresented: $showSettings)
            #endif
        }
    }

    private func driverDisplayEntry(_ state: VehicleState) -> some View {
        let suggested = state.isDriving && env.settings.config.driverDisplay.suggestWhenDriving && !drivingSuggestionDismissed
        return HStack(spacing: 14) {
            Image(systemName: "steeringwheel")
                .font(.title2.weight(.medium)).foregroundStyle(.white)
                .frame(width: 48, height: 48).background(Brand.action, in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(suggested ? L("Driving detected") : L("Driver display"))
                    .font(.headline.weight(.semibold)).foregroundStyle(Brand.textPrimary)
                Text(L("Speed, energy and route information at a glance."))
                    .font(.caption).foregroundStyle(Brand.textSecondary).lineLimit(2)
            }
            Spacer(minLength: 8)
            if suggested {
                Button { drivingSuggestionDismissed = true } label: {
                    Image(systemName: "xmark").frame(width: 36, height: 36)
                }
                .buttonStyle(.plain).foregroundStyle(Brand.textTertiary)
                .accessibilityLabel(L("Dismiss"))
            }
            Button { showDriverDisplay = true } label: {
                Image(systemName: "arrow.up.right")
                    .font(.headline.weight(.bold)).foregroundStyle(.white)
                    .frame(width: 44, height: 44).background(Brand.action, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L("Open driver display"))
            .accessibilityIdentifier("driver-display-card-open")
        }
        .padding(14)
        .background(suggested ? Brand.action.opacity(0.12) : Brand.surface,
                    in: RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Metrics.cardRadius).strokeBorder(suggested ? Brand.action.opacity(0.5) : Brand.hairline))
    }

    private func dashboardQuickStats(_ state: VehicleState) -> some View {
        HStack(spacing: 12) {
            UnitStatTile(title: L("Efficiency 30d"),
                         value: units.consumption(whPerKm: insights.efficiency30dWhPerKm),
                         systemImage: "leaf.fill", tint: Brand.driving) { UnitToggle.consumption(env) }
            StatTile(title: L("Range"),
                     value: units.range(km: state.range(for: units.range)),
                     systemImage: "road.lanes")
            StatTile(title: L("Odometer"),
                     value: units.distance(km: state.odometer, digits: 0),
                     systemImage: "gauge")
        }
        .card()
    }

    @ViewBuilder
    private func cardView(_ card: DashboardCard, state: VehicleState) -> some View {
        switch card {
        case .overview:
            HeroMapCard(state: state, units: units)
                .accessibilityIdentifier("dashboard-map-hero")
        case .quickStats: dashboardQuickStats(state)
        case .lastDrive: if let last = insights.lastDrive { LastDriveDashboardCard(drive: last, units: units) }
        case .activity: ActivityTimelineView(segments: insights.activity48h)
        case .battery: BatterySummaryCard(state: state, units: units)
        case .charging: if state.isCharging { ChargingCard(state: state, units: units) }
        case .driving: if state.isDriving { DrivingCard(state: state, units: units) }
        case .sentry: if state.sentryBannerActive { SentryInferredCard(state: state, units: units) }
        case .climate: ClimateCard(state: state, units: units)
        case .security: SecurityCard(state: state)
        case .tpms: TPMSCard(state: state, units: units)
        case .location: LocationCard(state: state, units: units)
        case .route: if state.activeRouteDestination != nil { RouteCard(state: state, units: units) }
        case .vehicle: VehicleInfoCard(info: env.history.carInfo, state: state, units: units)
        case .software: SoftwareCard(state: state)
        }
    }

    private func refresh() async {
        refreshing = true
        env.live.restart()
        if let id = env.live.resolvedCarID { await env.history.refresh(carID: id) }
        try? await Task.sleep(for: .seconds(1.0))
        refreshing = false
    }

    private var tutorialOverlay: some View {
        let steps = tutorialSteps
        return ZStack {
            Color.black.opacity(0.72).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Image(systemName: steps[tutorialStep].icon)
                        .font(.title)
                        .foregroundStyle(.white)
                        .frame(width: 58, height: 58)
                        .background(Brand.crimson.opacity(0.35), in: Circle())
                    Spacer()
                    Text("\(tutorialStep + 1) / \(steps.count)")
                        .font(.headline)
                        .foregroundStyle(.white.opacity(0.58))
                }
                Text(steps[tutorialStep].title)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.white)
                Text(steps[tutorialStep].body)
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.72))
                HStack {
                    Button(L("Skip tutorial")) { finishTutorial() }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.62))
                    Spacer()
                    Button(tutorialStep == steps.count - 1 ? L("Done") : L("Next")) {
                        if tutorialStep == steps.count - 1 {
                            finishTutorial()
                        } else {
                            withAnimation(.snappy) { tutorialStep += 1 }
                        }
                    }
                    .font(.headline.weight(.bold))
                    .buttonStyle(.borderedProminent)
                    .tint(Brand.action)
                }
            }
            .padding(24)
            .background(Brand.surface, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 28).strokeBorder(Brand.hairline, lineWidth: 1))
            .padding(28)
        }
    }

    private func finishTutorial() {
        tutorialCompleted = true
        withAnimation(.snappy) { showTutorial = false }
    }

    private var tutorialSteps: [(title: String, body: String, icon: String)] {
        [
            (L("This is your dashboard"), L("Battery, range and location now start from a live map-first overview."), "hand.wave.fill"),
            (L("Recent activity"), L("The 48-hour timeline highlights driving and charging without sending commands to the car."), "clock.arrow.circlepath"),
            (L("Read-only insights"), L("Trips, charges, parking and notifications are derived from TeslaMate data."), "eye.fill")
        ]
    }
}

private struct LastDriveDashboardCard: View {
    let drive: DriveRecord
    let units: Units

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(L("Last trip"), systemImage: "road.lanes")
            VStack(alignment: .leading, spacing: 7) {
                Text(drive.originName)
                    .font(.headline.weight(.bold))
                    .fixedSize(horizontal: false, vertical: true)
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Image(systemName: "arrow.turn.down.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Brand.action)
                    Text(drive.destinationName)
                        .font(.headline.weight(.bold))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("\(units.distance(km: drive.distanceKm)) · \(units.duration(minutes: drive.durationMin))")
                    .font(.subheadline)
                    .foregroundStyle(Brand.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .card()
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("dashboard-last-trip-card")
    }
}

enum DashboardCard: String, Codable, SectionBlock {
    // Default order: what the car is doing now, then where it is, then reference info.
    case overview, quickStats, lastDrive, activity
    case battery, charging, driving, route, location, climate, security, sentry, tpms, vehicle, software

    var title: String {
        switch self {
        case .overview: L("Current")
        case .quickStats: L("Stats")
        case .lastDrive: L("Last trip")
        case .activity: L("Last 48h")
        case .battery: L("Battery")
        case .charging: L("Charging")
        case .driving: L("Driving")
        case .sentry: L("Sentry")
        case .climate: L("Climate")
        case .security: L("Security")
        case .tpms: L("Tire pressure")
        case .location: L("Location")
        case .route: L("Active route")
        case .vehicle: L("Vehicle")
        case .software: L("Software")
        }
    }
    var icon: String {
        switch self {
        case .overview: "map.fill"
        case .quickStats: "gauge.with.dots.needle.67percent"
        case .lastDrive: "road.lanes"
        case .activity: "clock.arrow.circlepath"
        case .battery: "battery.100percent"
        case .charging: "bolt.fill"
        case .driving: "steeringwheel"
        case .sentry: "video.fill"
        case .climate: "thermometer.medium"
        case .security: "lock.shield"
        case .tpms: "gauge.with.dots.needle.bottom.50percent"
        case .location: "mappin.and.ellipse"
        case .route: "arrow.triangle.turn.up.right.diamond"
        case .vehicle: "car.fill"
        case .software: "cpu"
        }
    }

    var blurb: String {
        switch self {
        case .overview: L("Battery, range and location now start from a live map-first overview.")
        case .quickStats: L("Battery, range and charging at a glance.")
        case .lastDrive: L("Your drives, newest first, grouped by day.")
        case .activity: L("Recent activity")
        case .battery: L("Charge, usable capacity and range right now.")
        case .charging: L("Live power, time to full and limit while charging.")
        case .driving: L("Speed, power and consumption while driving.")
        case .route: L("Destination, ETA and arrival charge.")
        case .location: L("Where the car is parked, on a map.")
        case .climate: L("Inside and outside temperature.")
        case .security: L("Locks, windows, doors and trunks.")
        case .sentry: L("Sentry banner detected on the car's screen.")
        case .tpms: L("Pressure for each tyre.")
        case .vehicle: L("Model, VIN, colour and wheels.")
        case .software: L("Installed firmware and pending updates.")
        }
    }

    /// Resolve a saved order into a complete, valid card list (appends any new cards).
    static func resolved(_ raw: [String]) -> [DashboardCard] {
        SectionLayout.resolved(DashboardCard.self, layout: SectionLayoutState(order: raw))
    }
}

extension View {
    /// Inline toolbar title on iOS (so the centered logo sits in the bar); no-op elsewhere.
    @ViewBuilder
    func toolbarTitleDisplayModeInline() -> some View {
        #if os(iOS)
        self.navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }
}
