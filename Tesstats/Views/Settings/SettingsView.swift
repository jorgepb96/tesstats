import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#endif

struct SettingsView: View {
    var isOnboarding = false
    var presentedAsSheet = false

    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    @State private var mqttPassword = ""
    @State private var basicAuthPassword = ""
    @State private var cloudflareAccessClientSecret = ""
    @State private var pushSecret = ""
    @State private var diagnostics: ConnectionDiagnostics?
    @State private var testing = false
    @State private var showInsecureConfirm = false
    @State private var savedToast = false
    @State private var section: SettingsSection = .connection

    // Data / profiles / backup
    @State private var showExportSheet = false
    @State private var showEncryptedExport = false
    @State private var showRestoreImporter = false
    @State private var restoreError: String?
    @State private var newProfileName = ""
    @State private var showAddProfile = false
    // Encrypted-backup import
    @State private var showImportPassword = false
    @State private var importPassword = ""
    @State private var pendingEncrypted: EncryptedBackup?
    // Storage / reset
    @State private var showClearCacheConfirm = false
    @State private var showEraseAllConfirm = false

    var body: some View {
        @Bindable var settings = env.settings
        @Bindable var notifications = env.notifications

        VStack(spacing: 0) {
            if !isOnboarding { settingsHeader }
            SettingsTabBar(selection: $section)
                .padding(.horizontal, Metrics.screenPadding)
                .padding(.top, isOnboarding ? 8 : 4)
                .padding(.bottom, 6)
            Form {
                switch section {
                case .connection:
                    serverSection($settings)
                    liveSourceSection($settings)
                    if !settings.config.usesAPIPolling {
                        mqttSection($settings)
                    }
                    apiSection($settings)
                    basicAuthSection($settings)
                    cloudflareAccessSection($settings)
                    securitySection($settings)
                    testSection
                case .preferences:
                    appearanceSection($settings)
                    preferencesSection($settings)
                    tariffSection($settings)
                    dashboardLayoutSection($settings)
                case .notifications:
                    notificationsSection($notifications)
                    sentrySignalSection
                    tpmsSection($notifications)
                    quietHoursSection($notifications)
                    liveActivitySection($settings)
                    pushSection($settings)
                case .data:
                    profilesSection
                    backupSection
                    exportSection
                    storageSection
                case .vehicle:
                    vehiclesSection($settings)
                    demoSection($settings)
                    aboutSection
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .bottomScrollClearance()
            .onChange(of: notifications.prefs) { _, _ in
                env.notifications.persist()
                env.enablePushIfNeeded()
            }
        }
        .background(Brand.background.ignoresSafeArea())
        .navigationTitle(L("Settings"))
        .tint(Brand.action)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(isOnboarding ? L("Save & Connect") : L("Save")) { save() }
                    .fontWeight(.semibold)
            }
            if isOnboarding {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("Cancel")) { dismiss() }
                }
            }
        }
        .onAppear {
            mqttPassword = env.settings.mqttPassword
            basicAuthPassword = env.settings.basicAuthPassword
            cloudflareAccessClientSecret = env.settings.cloudflareAccessClientSecret
            pushSecret = env.settings.pushSecret
        }
        .alert(L("Use an unencrypted connection?"), isPresented: $showInsecureConfirm) {
            Button(L("Cancel"), role: .cancel) { env.settings.config.allowInsecureTransport = false }
            Button(L("I understand the risk"), role: .destructive) {}
        } message: {
            Text(L("Credentials and data would travel in plain text. Only do this inside a trusted local network."))
        }
        .sheet(isPresented: $showExportSheet) {
            ExportSheet(drives: env.history.drives, charges: env.history.charges)
        }
        .sheet(isPresented: $showEncryptedExport) {
            EncryptedBackupSheet(makeBackup: { env.settings.makeBackup() })
        }
        .fileImporter(isPresented: $showRestoreImporter, allowedContentTypes: [.json]) { result in
            handleRestore(result)
        }
        .alert(L("Enter the backup password"), isPresented: $showImportPassword) {
            SecureField(L("Password"), text: $importPassword)
            Button(L("Restore")) { decryptAndRestore() }
            Button(L("Cancel"), role: .cancel) { importPassword = ""; pendingEncrypted = nil }
        } message: {
            Text(L("This backup is password-protected. Enter its password to restore."))
        }
        .alert(L("Save profile"), isPresented: $showAddProfile) {
            TextField(L("Name"), text: $newProfileName)
            Button(L("Save")) {
                let name = newProfileName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty { env.settings.saveCurrentAsProfile(name: name) }
            }
            Button(L("Cancel"), role: .cancel) {}
        } message: {
            Text(L("Save the current server configuration as a switchable profile."))
        }
        .alert(L("Clear cache?"), isPresented: $showClearCacheConfirm) {
            Button(L("Clear cache"), role: .destructive) {
                env.clearCache()
                withAnimation { savedToast = true }
                Task { try? await Task.sleep(for: .seconds(1.4)); withAnimation { savedToast = false } }
            }
            Button(L("Cancel"), role: .cancel) {}
        } message: {
            Text(L("Removes downloaded drives, charges and snapshots saved offline. They'll be downloaded again next time."))
        }
        .alert(L("Delete all data?"), isPresented: $showEraseAllConfirm) {
            Button(L("Delete everything"), role: .destructive) {
                dismiss()   // close the sheet first, then wipe so the return to onboarding is clean
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(0.15))
                    env.eraseAllData()
                }
            }
            Button(L("Cancel"), role: .cancel) {}
        } message: {
            Text(L("This erases your server, credentials, profiles, notifications and cache, and returns the app to the start. It can't be undone."))
        }
        .overlay(alignment: .bottom) { if savedToast { savedBanner } }
    }

    private func handleRestore(_ result: Result<URL, Error>) {
        restoreError = nil
        switch result {
        case .failure(let error):
            restoreError = error.localizedDescription
        case .success(let url):
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else {
                restoreError = L("That file isn't a valid Tesstats backup.")
                return
            }
            switch BackupImport.inspect(data) {
            case .plain(let backup):
                applyRestore(backup)
            case .encrypted(let enc):
                pendingEncrypted = enc
                showImportPassword = true   // ask for the password before decrypting
            case .invalid:
                restoreError = L("That file isn't a valid Tesstats backup.")
            }
        }
    }

    private func decryptAndRestore() {
        guard let enc = pendingEncrypted else { return }
        do {
            let data = try BackupCrypto.decrypt(enc, password: importPassword)
            guard let backup = ConfigBackup.decode(data) else {
                restoreError = L("That file isn't a valid Tesstats backup.")
                importPassword = ""; pendingEncrypted = nil
                return
            }
            applyRestore(backup)
        } catch {
            restoreError = error.localizedDescription
        }
        importPassword = ""
        pendingEncrypted = nil
    }

    private func applyRestore(_ backup: ConfigBackup) {
        env.settings.restore(backup)
        env.applyConfigChange()
        reloadSecretFields()
        withAnimation { savedToast = true }
        Task { try? await Task.sleep(for: .seconds(1.4)); withAnimation { savedToast = false } }
    }

    // MARK: - Sections

    private var settingsHeader: some View {
        VStack(spacing: 10) {
            LogoMark(width: 150)
                .shadow(color: Brand.crimson.opacity(0.25), radius: 12)
            ConnectionPill(status: env.live.status)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 10)
        .padding(.bottom, 2)
    }

    private func serverSection(_ settings: Bindable<SettingsStore>) -> some View {
        Section {
            LabeledTextField(title: L("Address (IP or domain)"),
                             text: settings.config.serverHost,
                             prompt: "teslamate.example.com",
                             keyboard: .URL)
        } header: {
            Text(L("Server"))
        } footer: {
            Text(L("Your reverse-proxy domain or the server's IP. Used as the default host."))
        }
    }

    private func liveSourceSection(_ settings: Bindable<SettingsStore>) -> some View {
        Section {
            Picker(L("Live data"), selection: settings.config.liveSource) {
                ForEach(LiveDataSource.allCases) { Text($0.label).tag($0) }
            }
            .accessibilityIdentifier("settings-live-source")
            if settings.config.liveSource.wrappedValue == .api {
                Picker(L("Refresh every"), selection: settings.config.apiPollingSeconds) {
                    ForEach(ServerConfig.apiPollingChoices, id: \.self) { seconds in
                        Text(String(format: L("%@ s"), String(seconds))).tag(seconds)
                    }
                }
            }
        } header: {
            Text(L("Connection mode"))
        } footer: {
            if settings.config.liveSource.wrappedValue == .api {
                Text(L("Simplest setup: only TeslaMateApi has to be reachable. Live values are refreshed periodically while the app is open, so speed, power and alerts lag behind. TeslaMateApi still needs its own MQTT connection to TeslaMate."))
            } else {
                Text(L("Recommended: MQTT pushes every change instantly (dashboard, driving view, Live Activity, alerts). TeslaMateApi adds trips, charges and battery history."))
            }
        }
    }

    private func mqttSection(_ settings: Bindable<SettingsStore>) -> some View {
        Section {
            LabeledTextField(title: L("MQTT host (name only)"), text: settings.config.mqttHost,
                             prompt: "teslamate.example.com", keyboard: .URL)
            HStack {
                Text(L("Port")).foregroundStyle(Brand.textSecondary)
                Spacer()
                TextField("8883", value: settings.config.mqttPort, format: .number)
                    .multilineTextAlignment(.trailing)
                    .keyboardTypeNumberPad()
                    .frame(width: 90)
            }
            Picker(L("Transport"), selection: settings.config.mqttTransport) {
                ForEach(MQTTTransport.allCases) { Text($0.label).tag($0) }
            }
            if settings.config.mqttTransport.wrappedValue == .websocket {
                LabeledTextField(title: L("WebSocket path"),
                                 text: settings.config.mqttWebsocketPath, prompt: "/mqtt")
            }
            LabeledTextField(title: L("Username"), text: settings.config.mqttUsername, prompt: "mqtt-user")
            SecureField(L("Password"), text: $mqttPassword)
            LabeledTextField(title: L("Topic namespace (optional)"),
                             text: settings.config.topicNamespace, prompt: "—")
        } header: {
            Text(L("MQTT (real-time)"))
        } footer: {
            Text(L("Always encrypted (mqtts/wss). Enter the host as a plain name — no https:// and no path (the app builds the URL). Read-only subscription."))
        }
    }

    private func basicAuthSection(_ settings: Bindable<SettingsStore>) -> some View {
        Section {
            Toggle(L("My server uses Basic Auth"), isOn: settings.config.usesBasicAuth)
                .tint(Brand.action)
            if settings.config.usesBasicAuth.wrappedValue {
                LabeledTextField(title: L("Username"), text: settings.config.basicAuthUsername, prompt: "user")
                SecureField(L("Password"), text: $basicAuthPassword)
            }
        } header: {
            Text(L("Reverse proxy Basic Auth"))
        } footer: {
            Text(L("Applied to the wss MQTT handshake and the history API. Sent only over TLS."))
        }
    }

    private func cloudflareAccessSection(_ settings: Bindable<SettingsStore>) -> some View {
        Section {
            Toggle(L("My server is behind Cloudflare Access"), isOn: settings.config.usesCloudflareAccess)
                .tint(Brand.action)
            if settings.config.usesCloudflareAccess.wrappedValue {
                LabeledTextField(title: L("Client ID"), text: settings.config.cloudflareAccessClientID,
                                 prompt: "xxxxxxxx.access", keyboard: .URL)
                SecureField(L("Client Secret"), text: $cloudflareAccessClientSecret)
            }
        } header: {
            Text(L("Cloudflare Access"))
        } footer: {
            Text(L("A service token from Cloudflare Zero Trust → Access → Service credentials. The Access application needs a Service Auth policy that includes it. Sent to the history API, the wss MQTT handshake and the push service, only over TLS."))
        }
    }

    private func apiSection(_ settings: Bindable<SettingsStore>) -> some View {
        Section {
            LabeledTextField(title: L("TeslaMateApi base URL"),
                             text: settings.config.apiBaseURL,
                             prompt: "https://teslamate.example.com/api", keyboard: .URL)
        } header: {
            Text(settings.config.liveSource.wrappedValue == .api ? L("TeslaMateApi (required)") : L("History API (recommended)"))
        } footer: {
            if settings.config.liveSource.wrappedValue == .api {
                Text(L("Required in API-only mode. A full URL — include https:// and the path (e.g. https://host/api). Provides live status plus drives, charges and battery history. Inherits Basic Auth."))
            } else {
                Text(L("Optional but recommended. Here it IS a full URL — include https:// and the path (e.g. https://host/api). Provides drives, charges and battery history. Inherits Basic Auth."))
            }
        }
    }

    private func securitySection(_ settings: Bindable<SettingsStore>) -> some View {
        Section {
            Toggle(L("Trust a custom / self-signed certificate"),
                   isOn: settings.config.trustCustomCertificate)
                .tint(Brand.action)
            LabeledTextField(title: L("Pinned public-key SHA-256 (optional)"),
                             text: settings.config.pinnedPublicKeySHA256, prompt: "base64…")
            Toggle(isOn: Binding(
                get: { settings.config.allowInsecureTransport.wrappedValue },
                set: { newValue in
                    settings.config.allowInsecureTransport.wrappedValue = newValue
                    if newValue { showInsecureConfirm = true }
                })) {
                    Label(L("Allow unencrypted (LAN only)"), systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Brand.warning)
                }
                .tint(Brand.warning)
        } header: {
            Text(L("Security & certificates"))
        } footer: {
            Text(L("Let's Encrypt works out of the box. For self-hosted certs, trust your CA or pin its key. TLS is required by default."))
        }
    }

    private var testSection: some View {
        Section {
            Button {
                runTest()
            } label: {
                HStack {
                    Label(L("Test connection"), systemImage: "checkmark.shield")
                    Spacer()
                    if testing { ProgressView().tint(Brand.action) }
                }
            }
            .accessibilityIdentifier("settings-driver-display")
            .disabled(testing)

            if let diagnostics {
                if !diagnostics.mqtt.isEmpty {
                    DiagnosticsView(title: L("MQTT"), lines: diagnostics.mqtt)
                }
                DiagnosticsView(title: L("History API"), lines: diagnostics.api)
            }
        } header: {
            Text(L("Diagnostics"))
        }
    }

    private func vehiclesSection(_ settings: Bindable<SettingsStore>) -> some View {
        Section {
            if env.live.cars.isEmpty {
                Text(L("No vehicles detected yet. Connect to discover them automatically."))
                    .font(.subheadline).foregroundStyle(Brand.textSecondary)
            } else {
                Picker(L("Active vehicle"), selection: Binding(
                    get: { env.live.resolvedCarID ?? env.live.cars.first?.id ?? 0 },
                    set: { env.live.selectCar($0) })) {
                        ForEach(env.live.cars) { car in
                            Text(car.title).tag(car.id)
                        }
                    }
            }
        } header: {
            Text(L("Vehicles"))
        }
    }

    private func appearanceSection(_ settings: Bindable<SettingsStore>) -> some View {
        Section {
            Picker(L("Theme"), selection: settings.config.appearance) {
                ForEach(AppAppearance.allCases) { Text($0.label).tag($0) }
            }
            .onChange(of: settings.config.appearance.wrappedValue) { _, _ in env.settings.save() }

            VStack(alignment: .leading, spacing: 12) {
                Text(L("Accent color")).foregroundStyle(Brand.textSecondary)
                accentSwatches(settings)
            }
            .padding(.vertical, 4)
        } header: {
            Text(L("Appearance"))
        } footer: {
            Text(L("Choose a light or dark theme and the accent color used across the app."))
        }
    }

    private func accentSwatches(_ settings: Bindable<SettingsStore>) -> some View {
        let selected = settings.config.accentColorHex.wrappedValue
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 5), spacing: 14) {
            ForEach(AccentPalette.options) { opt in
                let isSelected = selected.caseInsensitiveCompare(opt.hex) == .orderedSame
                Button {
                    Brand.setAccent(opt.hex)                                   // update accent before the rebuild
                    settings.config.accentColorHex.wrappedValue = opt.hex      // triggers the root re-render
                    settings.config.accentColorWasCustomized.wrappedValue = true
                    env.settings.save()
                    WidgetBridge.updateAccent(opt.hex)
                } label: {
                    Circle()
                        .fill(opt.color)
                        .frame(width: 32, height: 32)
                        .overlay(Image(systemName: "checkmark")
                            .font(.footnote.weight(.bold))
                            .foregroundStyle(.white)
                            .opacity(isSelected ? 1 : 0))
                        .overlay(Circle()
                            .strokeBorder(Brand.textPrimary, lineWidth: 2)
                            .padding(-3)
                            .opacity(isSelected ? 0.9 : 0))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(opt.name)
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            }
        }
    }

    private func preferencesSection(_ settings: Bindable<SettingsStore>) -> some View {
        Section {
            Picker(L("Language"), selection: Binding(
                get: { AppLanguage(rawValue: settings.config.languageCode.wrappedValue) ?? .system },
                set: { newValue in
                    settings.config.languageCode.wrappedValue = newValue.rawValue
                    env.settings.save()
                    LanguageManager.apply(newValue.rawValue)
                    WidgetBridge.updateLanguage(newValue.rawValue)
                })) {
                ForEach(AppLanguage.allCases) { Text($0.label).tag($0) }
            }
            Picker(L("Distance"), selection: settings.config.units) {
                ForEach(UnitsPreference.allCases) { Text($0.label).tag($0) }
            }
            Picker(L("Temperature"), selection: settings.config.temperatureUnit) {
                ForEach(TempUnit.allCases) { Text($0.label).tag($0) }
            }
            Picker(L("Range shown"), selection: settings.config.rangeKind) {
                ForEach(RangeKind.allCases) { Text($0.label).tag($0) }
            }
            LabeledTextField(title: L("Currency code"), text: settings.config.currencyCode, prompt: "EUR")
            HStack {
                Text(L("Fuel price / L")).foregroundStyle(Brand.textSecondary)
                Spacer()
                TextField("1.70", value: settings.config.fuelPricePerLiter, format: .number)
                    .multilineTextAlignment(.trailing).keyboardTypeDecimal().frame(width: 90)
            }
            HStack {
                Text(L("Comparison car L/100km")).foregroundStyle(Brand.textSecondary)
                Spacer()
                TextField("7.0", value: settings.config.fuelConsumptionLPer100km, format: .number)
                    .multilineTextAlignment(.trailing).keyboardTypeDecimal().frame(width: 90)
            }
            HStack {
                Text(L("Charge price / kWh")).foregroundStyle(Brand.textSecondary)
                Spacer()
                TextField("0.15", value: settings.config.chargePricePerKwh, format: .number)
                    .multilineTextAlignment(.trailing).keyboardTypeDecimal().frame(width: 90)
            }
        } header: {
            Text(L("Preferences"))
        } footer: {
            Text(L("Charge price is used to estimate cost and savings when TeslaMate has no recorded cost."))
        }
    }

    /// Time-of-use electricity tariff: price bands by time of day, applied to unpriced
    /// charging sessions (recorded costs and per-location overrides still win).
    private func tariffSection(_ settings: Bindable<SettingsStore>) -> some View {
        Section {
            Toggle(L("Time-of-use tariff"), isOn: settings.config.tariffEnabled)
                .tint(Brand.action)
            // Always reachable: a plan can be built before switching pricing over to it.
            NavigationLink {
                TariffPlansView()
            } label: {
                HStack {
                    Label(L("Tariff plans"), systemImage: "clock.badge.checkmark")
                        .foregroundStyle(Brand.textPrimary)
                    Spacer()
                    Text(activePlanLabel)
                        .font(.caption).foregroundStyle(Brand.textTertiary)
                }
            }
            HStack {
                Text(L("Default price")).foregroundStyle(Brand.textPrimary)
                Spacer()
                TextField("0.15", value: settings.config.chargePricePerKwh, format: .number)
                    .multilineTextAlignment(.trailing)
                    .keyboardTypeDecimal()
                    .frame(width: 80)
                Text(L("/kWh")).font(.caption).foregroundStyle(Brand.textTertiary)
            }
        } header: {
            Text(L("Electricity tariff"))
        } footer: {
            Text(L("A plan splits the day into price bands, so a charging session TeslaMate did not cost is priced by when it happened. Without a plan every session uses the default price."))
        }
    }

    private var activePlanLabel: String {
        guard let plan = env.settings.config.activeTariff else { return L("None") }
        return plan.name.isEmpty ? L("Untitled plan") : plan.name
    }

    /// Bridge a minutes-from-midnight Int to the hour-and-minute DatePicker.
    private func minuteOfDayBinding(_ minutes: Binding<Int>) -> Binding<Date> {
        Binding(
            get: {
                let m = ((minutes.wrappedValue % 1440) + 1440) % 1440
                return Calendar.current.date(bySettingHour: m / 60, minute: m % 60, second: 0, of: Date()) ?? Date()
            },
            set: { date in
                let c = Calendar.current.dateComponents([.hour, .minute], from: date)
                minutes.wrappedValue = (c.hour ?? 0) * 60 + (c.minute ?? 0)
            })
    }

    private func dashboardLayoutSection(_ settings: Bindable<SettingsStore>) -> some View {
        Section {
            ForEach(DashboardCard.resolved(settings.config.dashboardCardOrder.wrappedValue)) { card in
                HStack(spacing: 12) {
                    Image(systemName: card.icon).foregroundStyle(Brand.crimson).frame(width: 24)
                    Text(card.title).foregroundStyle(Brand.textPrimary)
                    Spacer()
                    Image(systemName: "line.3.horizontal").foregroundStyle(Brand.textTertiary)
                }
            }
            .onMove { from, to in
                var order = DashboardCard.resolved(env.settings.config.dashboardCardOrder)
                order.move(fromOffsets: from, toOffset: to)
                env.settings.config.dashboardCardOrder = order.map { $0.rawValue }
                env.settings.save()
            }
        } header: {
            HStack {
                Text(L("Home cards"))
                Spacer()
                #if os(iOS)
                EditButton().font(.caption.weight(.semibold)).tint(Brand.action)
                #endif
            }
        } footer: {
            Text(L("Drag to reorder the cards on the Summary screen. Cards only appear when their data is available (e.g. Charging while charging)."))
        }
    }

    private func notificationsSection(_ notifications: Bindable<NotificationEngine>) -> some View {
        Section {
            Toggle(L("Enable notifications"), isOn: notifications.prefs.enabled).tint(Brand.action)
            if notifications.prefs.enabled.wrappedValue {
                Button {
                    Task { await env.notifications.sendTestNotification() }
                } label: {
                    Label(L("Send test notification"), systemImage: "bell.badge.fill")
                }
                Label(
                    env.pushRegistrationState == .registered
                        ? L("Background alerts are connected through the push service.")
                        : L("Local monitoring stops when iOS suspends the app. Configure Immediate push below for reliable locked-screen alerts."),
                    systemImage: env.pushRegistrationState == .registered ? "checkmark.shield.fill" : "iphone.slash"
                )
                .font(.caption)
                .foregroundStyle(env.pushRegistrationState == .registered ? Brand.online : Brand.warning)
                #if os(iOS)
                if notifications.authorizationStatus.wrappedValue == .denied {
                    Button {
                        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                        UIApplication.shared.open(url)
                    } label: {
                        Label(L("Open notification settings"), systemImage: "gearshape.fill")
                    }
                }
                #endif
                Toggle(L("Charging started"), isOn: notifications.prefs.chargeStarted).tint(Brand.action)
                Toggle(L("Charging complete"), isOn: notifications.prefs.chargeComplete).tint(Brand.action)
                Toggle(L("Missing charging cost"), isOn: notifications.prefs.chargeCostMissing).tint(Brand.action)
                Toggle(L("Charge limit reached"), isOn: notifications.prefs.chargeTargetReached).tint(Brand.action)
                Toggle(L("Left unplugged"), isOn: notifications.prefs.leftUnplugged).tint(Brand.action)
                Toggle(L("Plugged in, not charging"), isOn: notifications.prefs.pluggedNotCharging).tint(Brand.action)
                Toggle(L("Open doors / unlocked"), isOn: notifications.prefs.openingsOrUnlocked).tint(Brand.action)
                Toggle(L("Software updates"), isOn: notifications.prefs.softwareUpdate).tint(Brand.action)
                Toggle(L("Geofence enter / exit"), isOn: notifications.prefs.geofence).tint(Brand.action)
                Toggle(L("Possible Sentry (inferred)"), isOn: notifications.prefs.sentryInferred).tint(Brand.action)
                Toggle(L("Sentry armed / disarmed"), isOn: notifications.prefs.sentryArmedAlerts).tint(Brand.action)
                Stepper(value: notifications.prefs.lowBatteryThreshold, in: 5...60, step: 5) {
                    Toggle(L("Low battery below \(notifications.prefs.lowBatteryThreshold.wrappedValue)%"),
                           isOn: notifications.prefs.lowBattery).tint(Brand.action)
                }
            }
        } header: {
            Text(L("Notifications"))
        } footer: {
            Text(L("The local test is scheduled 10 seconds later: lock the iPhone after tapping it to verify Lock Screen permission. Vehicle alerts need the optional push service below once iOS suspends the app."))
        }
    }

    /// Live view of the two MQTT signals the Sentry alert depends on, so users can verify
    /// their TeslaMate actually emits them (walk up to the car with Sentry armed and the
    /// screen-state row should flip to the Sentry banner).
    private var sentrySignalSection: some View {
        let state = env.live.currentState
        return Section {
            KeyValueRow(label: L("Sentry Mode"),
                        value: state?.sentryMode.map { $0 ? L("Armed") : L("Off") } ?? "—",
                        valueColor: state?.sentryMode == true ? Brand.online : Brand.textPrimary,
                        systemImage: "video.fill")
            KeyValueRow(label: L("Car screen state"),
                        value: screenStateLabel(state?.centerDisplayState),
                        valueColor: state?.centerDisplayState == 7 ? Brand.crimson : Brand.textPrimary,
                        systemImage: "display")
            KeyValueRow(label: L("Car"),
                        value: state?.state?.label ?? "—",
                        systemImage: "car")
        } header: {
            Text(L("Sentry signal (live)"))
        } footer: {
            Text(L("The Sentry alert fires when the screen state becomes “Sentry banner (7)”. To verify end-to-end: arm Sentry, keep this screen open, and walk up to the car — the row should flip within seconds. TeslaMate polls every ~30 s, so very brief banners can be missed; with the app closed, alerts need the push service or ntfy (see Data → README)."))
        }
    }

    /// Human label for TeslaMate's `center_display_state` values.
    private func screenStateLabel(_ raw: Int?) -> String {
        guard let raw else { return "—" }
        let name: String = switch raw {
        case 0: L("Off")
        case 2, 4: L("On")
        case 3: L("Charging screen")
        case 5: L("Charging (large)")
        case 6: L("Ready to unlock")
        case 7: L("Sentry banner")
        case 8: L("Dog Mode")
        case 9: L("Media")
        default: L("Unknown")
        }
        return "\(name) (\(raw))"
    }

    private func tpmsSection(_ notifications: Bindable<NotificationEngine>) -> some View {
        Section {
            Toggle(L("Low tire pressure alert"), isOn: notifications.prefs.tpmsLow).tint(Brand.action)
            if notifications.prefs.tpmsLow.wrappedValue {
                Picker(L("Unit"), selection: notifications.prefs.tpmsUnitIsPsi) {
                    Text("bar").tag(false)
                    Text("psi").tag(true)
                }
                .pickerStyle(.segmented)
                HStack {
                    Text(L("Alert below")).foregroundStyle(Brand.textSecondary)
                    Spacer()
                    TextField("2.4", value: Binding(
                        get: { notifications.prefs.tpmsThresholdDisplay.wrappedValue },
                        set: { notifications.prefs.tpmsThresholdDisplay.wrappedValue = $0 }),
                        format: .number)
                        .multilineTextAlignment(.trailing).keyboardTypeDecimal().frame(width: 80)
                    Text(notifications.prefs.tpmsUnitIsPsi.wrappedValue ? "psi" : "bar")
                        .foregroundStyle(Brand.textTertiary)
                }
            }
        } header: {
            Text(L("Tire pressure"))
        } footer: {
            Text(L("Notifies when any wheel drops below your threshold. TPMS readings arrive only while the car is awake."))
        }
    }

    private func quietHoursSection(_ notifications: Bindable<NotificationEngine>) -> some View {
        Section {
            Toggle(L("Quiet hours"), isOn: notifications.prefs.quietHoursEnabled).tint(Brand.action)
            if notifications.prefs.quietHoursEnabled.wrappedValue {
                DatePicker(L("From"), selection: Binding(
                    get: { Self.date(fromMinutes: notifications.prefs.quietStartMinutes.wrappedValue) },
                    set: { notifications.prefs.quietStartMinutes.wrappedValue = Self.minutes(from: $0) }),
                    displayedComponents: .hourAndMinute)
                DatePicker(L("To"), selection: Binding(
                    get: { Self.date(fromMinutes: notifications.prefs.quietEndMinutes.wrappedValue) },
                    set: { notifications.prefs.quietEndMinutes.wrappedValue = Self.minutes(from: $0) }),
                    displayedComponents: .hourAndMinute)
                Toggle(L("Sentry breaks through quiet hours"), isOn: notifications.prefs.sentryBypassQuietHours)
                    .tint(Brand.action)
            }
        } header: {
            Text(L("Do not disturb"))
        } footer: {
            Text(L("On-device alerts are silenced during this window (e.g. overnight). A possible Sentry event can still alert you — that 3 AM warning is usually the one you want."))
        }
    }

    private static func date(fromMinutes m: Int) -> Date {
        Calendar.current.date(bySettingHour: m / 60, minute: m % 60, second: 0, of: Date()) ?? Date()
    }
    private static func minutes(from date: Date) -> Int {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }

    // MARK: Data, profiles & backup

    private var profilesSection: some View {
        Section {
            if env.settings.profiles.isEmpty {
                Text(L("No saved profiles. Save your current server as a profile to switch between installs quickly."))
                    .font(.subheadline).foregroundStyle(Brand.textSecondary)
            } else {
                ForEach(env.settings.profiles) { profile in
                    Button {
                        env.settings.switchToProfile(profile.id)
                        env.applyConfigChange()
                        reloadSecretFields()
                    } label: {
                        HStack {
                            Image(systemName: env.settings.activeProfileID == profile.id ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(env.settings.activeProfileID == profile.id ? Brand.crimson : Brand.textTertiary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(profile.name).foregroundStyle(Brand.textPrimary)
                                Text(profile.config.serverHost.isEmpty ? profile.config.mqttHost : profile.config.serverHost)
                                    .font(.caption).foregroundStyle(Brand.textTertiary)
                            }
                            Spacer()
                        }
                    }
                    .tint(Brand.textPrimary)
                }
                .onDelete { idx in
                    idx.map { env.settings.profiles[$0].id }.forEach { env.settings.deleteProfile($0) }
                }
            }
            Button {
                newProfileName = env.settings.config.serverHost.isEmpty ? L("My server") : env.settings.config.serverHost
                showAddProfile = true
            } label: {
                Label(L("Save current as profile"), systemImage: "plus.circle")
            }
            .tint(Brand.action)
        } header: {
            Text(L("Server profiles"))
        } footer: {
            Text(L("Switch between multiple TeslaMate installations. Each profile keeps its own credentials in the Keychain."))
        }
    }

    private var backupSection: some View {
        Section {
            Button {
                showEncryptedExport = true
            } label: {
                Label(L("Export encrypted backup"), systemImage: "lock.doc")
            }
            .tint(Brand.action)
            Button {
                showRestoreImporter = true
            } label: {
                Label(L("Restore from backup file"), systemImage: "square.and.arrow.down")
            }
            .tint(Brand.action)
            if let restoreError {
                Text(restoreError).font(.caption).foregroundStyle(Brand.danger)
            }
        } header: {
            Text(L("Backup & restore"))
        } footer: {
            Text(L("The backup holds your server settings and credentials, locked with a password only you know — AES-256 encrypted. Keep the password safe: it can't be recovered."))
        }
    }

    private var exportSection: some View {
        Section {
            Button {
                showExportSheet = true
            } label: {
                Label(L("Export trips & charges"), systemImage: "tablecells")
            }
            .tint(Brand.action)
        } header: {
            Text(L("Export data"))
        } footer: {
            Text(L("Share your drives and charging sessions as CSV, JSON or GPX."))
        }
    }

    private var storageSection: some View {
        Section {
            Button {
                showClearCacheConfirm = true
            } label: {
                HStack {
                    Label(L("Clear cache"), systemImage: "internaldrive")
                    Spacer()
                    Text(cacheSizeText).font(.caption).foregroundStyle(Brand.textTertiary)
                }
            }
            .tint(Brand.action)
            Button(role: .destructive) {
                showEraseAllConfirm = true
            } label: {
                Label(L("Delete all data"), systemImage: "trash")
            }
        } header: {
            Text(L("Storage & reset"))
        } footer: {
            Text(L("“Clear cache” removes downloaded history saved offline. “Delete all data” also erases your server, credentials, profiles and preferences."))
        }
    }

    private var cacheSizeText: String {
        let bytes = env.cache.sizeBytes()
        guard bytes > 0 else { return "—" }
        return Int64(bytes).formatted(.byteCount(style: .file).locale(LanguageManager.locale))
    }

    private func reloadSecretFields() {
        mqttPassword = env.settings.mqttPassword
        basicAuthPassword = env.settings.basicAuthPassword
        cloudflareAccessClientSecret = env.settings.cloudflareAccessClientSecret
        pushSecret = env.settings.pushSecret
    }

    private func liveActivitySection(_ settings: Bindable<SettingsStore>) -> some View {
        Section {
            Toggle(isOn: settings.config.liveActivityEnabled) {
                Label(L("Charging Live Activity"), systemImage: "bolt.fill")
            }.tint(Brand.action)
            if settings.config.liveActivityEnabled.wrappedValue,
               settings.config.pushEnabled.wrappedValue {
                switch env.liveActivityPushRegistrationState {
                case .disabled:
                    Label(L("Background Live Activity updates will connect when charging starts."), systemImage: "bolt.badge.clock")
                        .foregroundStyle(Brand.textSecondary)
                case .registering:
                    Label(L("Registering Live Activity updates…"), systemImage: "arrow.triangle.2.circlepath")
                        .foregroundStyle(Brand.textSecondary)
                case .registered:
                    Label(L("Background Live Activity updates connected"), systemImage: "checkmark.circle.fill")
                        .foregroundStyle(Brand.online)
                case .failed:
                    VStack(alignment: .leading, spacing: 4) {
                        Label(L("Background Live Activity updates failed"), systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Brand.warning)
                        if let error = env.liveActivityPushRegistrationError {
                            Text(error).font(.caption).foregroundStyle(Brand.textSecondary)
                        }
                    }
                }
            }
        } header: {
            Text(L("Live Activity"))
        } footer: {
            Text(L("Shows charging progress on the Lock Screen and Dynamic Island. Reliable updates while Tesstats is suspended require Immediate push and the current push microservice."))
        }
    }

    private func pushSection(_ settings: Bindable<SettingsStore>) -> some View {
        Section {
            Toggle(isOn: settings.config.pushEnabled) {
                Label(L("Immediate push (app closed)"), systemImage: "bolt.horizontal.circle")
            }.tint(Brand.action)
            if settings.config.pushEnabled.wrappedValue {
                LabeledTextField(title: L("Push service URL"),
                                 text: settings.config.pushServiceURL,
                                 prompt: "https://push.example.com", keyboard: .URL)
                SecureField(L("Shared secret"), text: $pushSecret)
                if !settings.config.pushServiceURL.wrappedValue.isEmpty {
                    pushRegistrationStatus
                    if env.pushRegistrationState == .registered {
                        Button {
                            Task { await env.sendTestPush() }
                        } label: {
                            Label(L("Send remote test"), systemImage: "paperplane.fill")
                        }
                    }
                }
            }
        } header: {
            Text(L("Immediate push (optional)"))
        } footer: {
            Text(L("Native alerts and background Live Activity updates require APNs. For ntfy or webhook alerts, configure the server and subscribe in the receiving app; enabling Immediate push here is optional."))
        }
    }

    @ViewBuilder
    private var pushRegistrationStatus: some View {
        switch env.pushRegistrationState {
        case .disabled:
            Label(L("Save to register this iPhone"), systemImage: "iphone.badge.exclamationmark")
                .foregroundStyle(Brand.textSecondary)
        case .registering:
            Label(L("Registering with APNs…"), systemImage: "arrow.triangle.2.circlepath")
                .foregroundStyle(Brand.textSecondary)
        case .registered:
            Label(L("Push connected"), systemImage: "checkmark.circle.fill")
                .foregroundStyle(Brand.online)
        case .failed:
            VStack(alignment: .leading, spacing: 4) {
                Label(L("Push registration failed"), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Brand.warning)
                if let error = env.pushRegistrationError {
                    Text(error).font(.caption).foregroundStyle(Brand.textSecondary)
                }
            }
        }
    }

    private func demoSection(_ settings: Bindable<SettingsStore>) -> some View {
        Section {
            Toggle(isOn: settings.config.demoMode) {
                Label(L("Demo mode"), systemImage: "play.circle")
            }.tint(Brand.action)
        } footer: {
            Text(L("Explore the full UI with realistic sample data. No network is contacted."))
        }
    }

    private var aboutSection: some View {
        Section {
            KeyValueRow(label: L("Version"), value: appVersion)
            Link(destination: Self.supportURL) {
                HStack(spacing: 10) {
                    Image(systemName: "questionmark.circle")
                        .font(.subheadline).foregroundStyle(Brand.textTertiary)
                        .frame(width: 22, alignment: .center)
                    Text(L("Support")).font(.subheadline).foregroundStyle(Brand.textSecondary)
                    Spacer(minLength: 12)
                    Text("GitHub Issues").font(.subheadline.weight(.medium)).foregroundStyle(Brand.crimson)
                    Image(systemName: "arrow.up.right").font(.caption2).foregroundStyle(Brand.textTertiary)
                }
            }
            Link(destination: Self.sourceURL) {
                HStack(spacing: 10) {
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                        .font(.subheadline).foregroundStyle(Brand.textTertiary)
                        .frame(width: 22, alignment: .center)
                    Text(L("Source code")).font(.subheadline).foregroundStyle(Brand.textSecondary)
                    Spacer(minLength: 12)
                    Text("AGPL-3.0").font(.subheadline.weight(.medium)).foregroundStyle(Brand.crimson)
                    Image(systemName: "arrow.up.right").font(.caption2).foregroundStyle(Brand.textTertiary)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                aboutNote("eye", L("Read-only. Tesstats never sends vehicle-control commands."))
                aboutNote("video.slash", L("Sentry is inferred from the screen banner; clips live on the car's USB and aren't available via TeslaMate."))
                aboutNote("lock", L("TLS only · credentials in Keychain · no telemetry or trackers."))
                // TeslaMate's trademark policy requires this exact English sentence in the
                // About section, so it is deliberately not localized.
                aboutNote("exclamationmark.shield", "This project is an unofficial community tool and is not affiliated with, endorsed by, or supported by the official TeslaMate project.")
                aboutNote("info.circle", L("Not affiliated with Tesla, Inc. or the TeslaMate project. Tesla is a trademark of Tesla, Inc.; TeslaMate is a trademark of the TeslaMate project."))
            }
            .padding(.vertical, 4)
        } header: {
            Text(L("About"))
        }
    }

    /// Public issue tracker linked from the About screen.
    private static let supportURL = URL(string: "https://github.com/jorgepb96/tesstats/issues")!

    /// Public AGPL-3.0 source repository linked from the About screen.
    private static let sourceURL = URL(string: "https://github.com/jorgepb96/tesstats")!

    private func aboutNote(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).font(.caption).foregroundStyle(Brand.crimson).frame(width: 18)
            Text(text).font(.caption).foregroundStyle(Brand.textSecondary)
        }
    }

    private var savedBanner: some View {
        Label(L("Saved"), systemImage: "checkmark.circle.fill")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(Brand.online, in: Capsule())
            .padding(.bottom, 24)
            .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(v) (\(b))"
    }

    // MARK: - Actions

    private func commitSecrets() {
        env.settings.mqttPassword = mqttPassword
        env.settings.basicAuthPassword = basicAuthPassword
        env.settings.cloudflareAccessClientSecret = cloudflareAccessClientSecret
        env.settings.pushSecret = pushSecret
    }

    private func save() {
        commitSecrets()
        env.notifications.persist()
        if env.settings.activeProfileID != nil { env.settings.updateActiveProfile() }
        env.applyConfigChange()
        if isOnboarding || presentedAsSheet {
            dismiss()   // Save also closes the sheet — no separate Done button needed.
        } else {
            withAnimation { savedToast = true }
            Task { try? await Task.sleep(for: .seconds(1.4)); withAnimation { savedToast = false } }
        }
    }

    private func runTest() {
        commitSecrets()
        env.settings.save()
        testing = true
        diagnostics = nil
        Task {
            let apiConfig = env.settings.makeAPIConfig()
            if env.settings.config.usesAPIPolling {
                let api = await env.tester.testAPI(config: apiConfig)
                let live = await env.tester.testLiveStatus(config: apiConfig)
                diagnostics = ConnectionDiagnostics(mqtt: [], api: api + live, finished: true)
            } else {
                let mqtt = await env.tester.testMQTT(config: env.settings.makeMQTTConfig(),
                                                     topicRoot: env.settings.config.topicRoot)
                let api = await env.tester.testAPI(config: apiConfig)
                diagnostics = ConnectionDiagnostics(mqtt: mqtt, api: api, finished: true)
            }
            testing = false
        }
    }
}

// MARK: - Small helpers

private struct LabeledTextField: View {
    let title: String
    @Binding var text: String
    var prompt: String = ""
    var keyboard: PlatformKeyboard = .default

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(Brand.textTertiary)
            TextField(prompt, text: $text)
                .textFieldKeyboard(keyboard)
                .autocorrectionDisabled()
        }
    }
}

private struct DiagnosticsView: View {
    let title: String
    let lines: [DiagLine]
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(Brand.textTertiary)
            ForEach(lines) { line in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: line.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .foregroundStyle(line.ok ? Brand.online : Brand.danger)
                        .font(.caption)
                    Text(line.message).font(.caption).foregroundStyle(Brand.textSecondary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Settings sections (icon sub-tabs)

enum SettingsSection: String, CaseIterable, Identifiable {
    case connection, preferences, notifications, data, vehicle
    var id: String { rawValue }

    var icon: String {
        switch self {
        case .connection: "antenna.radiowaves.left.and.right"
        case .preferences: "slider.horizontal.3"
        case .notifications: "bell.badge"
        case .data: "square.and.arrow.up.on.square"
        case .vehicle: "car"
        }
    }
    var shortLabel: String {
        switch self {
        case .connection: L("Server")
        case .preferences: L("Prefs")
        case .notifications: L("Alerts")
        case .data: L("Data")
        case .vehicle: L("Info")
        }
    }
}

/// Icon sub-tab bar — icon only, with a short label that appears only when selected.
struct SettingsTabBar: View {
    @Binding var selection: SettingsSection

    var body: some View {
        AdaptiveGlassContainer(spacing: 6) {
            HStack(spacing: 8) {
                ForEach(SettingsSection.allCases) { sec in
                    let active = sec == selection
                    Button {
                        withAnimation(.snappy(duration: 0.25)) { selection = sec }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: sec.icon).font(.subheadline.weight(.semibold))
                            if active {
                                Text(sec.shortLabel).font(.caption.weight(.semibold)).fixedSize()
                            }
                        }
                        .frame(maxWidth: active ? .infinity : nil)
                        .padding(.vertical, 10)
                        .padding(.horizontal, active ? 12 : 13)
                        .foregroundStyle(active ? Color.white : Brand.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .adaptiveGlass(tint: active ? Brand.action : nil, interactive: true)
                    // An inactive tab is icon-only, so without this it has no accessible name.
                    .accessibilityLabel(sec.shortLabel)
                    .accessibilityIdentifier("settings-section-\(sec.rawValue)")
                    .accessibilityAddTraits(active ? [.isSelected] : [])
                }
            }
        }
    }
}
