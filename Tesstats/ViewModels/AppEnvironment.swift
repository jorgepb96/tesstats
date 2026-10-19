import Foundation
#if os(iOS)
import UIKit
#endif

/// Dependency-injection container. Built once at app launch and passed down the view tree.
@MainActor
@Observable
final class AppEnvironment {
    let settings: SettingsStore
    let notifications: NotificationEngine
    let inbox: EventInboxStore
    let cache: CacheStore
    let live: VehicleLiveService
    let history: HistoryViewModel
    let driverBluetooth: DriverBluetoothTelemetryService
    let tripTags = TripTagStore()
    let tester = ConnectionTester()
    var pushRegistrationState: PushRegistrationState = .disabled
    var pushRegistrationError: String?
    var liveActivityPushRegistrationState: PushRegistrationState = .disabled
    var liveActivityPushRegistrationError: String?
    private var pushRegistrationTask: Task<Void, Never>?

    init() {
        let settings = SettingsStore()
        LanguageManager.apply(settings.config.languageCode)   // apply saved language before any UI
        Brand.setAccent(settings.config.accentColorHex)       // apply saved accent before any UI
        let inbox = EventInboxStore()
        let notifications = NotificationEngine(inbox: inbox)
        let cache = CacheStore()
        self.settings = settings
        self.inbox = inbox
        self.notifications = notifications
        self.cache = cache
        self.live = VehicleLiveService(settings: settings, notifications: notifications, cache: cache)
        self.history = HistoryViewModel(settings: settings, cache: cache)
        self.driverBluetooth = DriverBluetoothTelemetryService(settings: settings)
        tripTags.scope(to: settings.config.historySourceIdentity)
        self.history.onChargesLoaded = { [weak notifications, weak settings] charges, carID in
            guard let settings else { return }
            notifications?.processCharges(charges, carID: carID, server: settings.config.apiBaseURL,
                                          prices: settings.config.chargePricePerKwhByLocation)
        }
    }

    /// Start the live pipeline and ask for notification permission once configured.
    func bootstrap() {
        // Launch-time affordance for previews/UI verification: `TESSTATS_DEMO=1`.
        // In-memory only (not persisted) so it never overwrites a real saved configuration.
        let isPreview = ProcessInfo.processInfo.environment["TESSTATS_DEMO"] == "1"
        if isPreview, !settings.config.demoMode {
            settings.config = .demo
        }
        if isPreview { applyPreviewOverrides() }
        let injected = applyEnvOverridesIfPresent()
        tripTags.scope(to: settings.config.historySourceIdentity)
        #if os(iOS)
        WatchBridge.shared.setRefreshHandler { [weak self] in
            self?.refreshWatchData()
        }
        WatchBridge.shared.activate()   // keep the paired watch fed with live snapshots
        #endif
        guard settings.isConfigured else { return }
        live.start()
        inbox.seedWelcomeIfNeeded()
        if !isPreview && !injected {
            Task { await notifications.requestAuthorization() }
        }
        enablePushIfNeeded()
    }

    #if os(iOS)
    /// Refresh both the lightweight MQTT state and the optional battery-health summary for
    /// the vehicle selected on iPhone. History loading is incremental and deduplicated.
    private func refreshWatchData() {
        live.refreshForWatch()
        guard let carID = live.resolvedCarID ?? settings.config.selectedCarID else { return }
        Task { await history.loadIfNeeded(carID: carID) }
    }
    #endif

    /// Deterministic, in-memory presentation variants used by UI tests and curated screenshots.
    /// These values are intentionally ignored outside demo launches and are never persisted.
    private func applyPreviewOverrides() {
        let env = ProcessInfo.processInfo.environment
        var config = settings.config
        if let language = env["TESSTATS_LANGUAGE"] { config.languageCode = language }
        if let appearance = env["TESSTATS_APPEARANCE"].flatMap(AppAppearance.init(rawValue:)) {
            config.appearance = appearance
        }
        if let appearance = env["TESSTATS_DRIVER_APPEARANCE"].flatMap(DriverDisplayAppearance.init(rawValue:)) {
            config.driverDisplay.appearance = appearance
        }

        if let hidden = env["TESSTATS_DRIVER_HIDDEN_MODULES"] {
            config.driverDisplay.hiddenModules = hidden.split(separator: ",")
                .compactMap { DriverDisplayModule(rawValue: String($0)) }
        }
        settings.config = config
        LanguageManager.apply(config.languageCode)
        Brand.setAccent(config.accentColorHex)
    }

    /// Wire up the optional push service: register for APNs and forward the token.
    func enablePushIfNeeded() {
        #if os(iOS)
        pushRegistrationTask?.cancel()
        guard settings.config.pushEnabled, !settings.config.pushServiceURL.isEmpty else {
            AppDelegate.onToken = nil
            AppDelegate.onRegistrationFailure = nil
            WidgetBridge.liveActivityPushTokenHandler = nil
            pushRegistrationState = .disabled
            pushRegistrationError = nil
            liveActivityPushRegistrationState = .disabled
            liveActivityPushRegistrationError = nil
            return
        }
        let url = settings.config.pushServiceURL
        let secret = settings.pushSecret
        let trust = settings.trustConfig
        let basic = settings.basicAuth
        let cloudflare = settings.cloudflareAccess
        AppDelegate.onToken = { [weak self] token in
            let service = PushService(baseURL: url, secret: secret, trust: trust, basicAuth: basic,
                                      cloudflareAccess: cloudflare)
            self?.pushRegistrationTask?.cancel()
            self?.pushRegistrationTask = Task { @MainActor [weak self] in
                for attempt in 0..<4 {
                guard !Task.isCancelled else { return }
                self?.pushRegistrationState = .registering
                self?.pushRegistrationError = nil
                do {
                    try await service.register(token: token, preferences: self?.notifications.prefs ?? NotificationPreferences(),
                                               locationPrices: self?.settings.config.chargePricePerKwhByLocation ?? [:])
                    guard !Task.isCancelled else { return }
                    self?.pushRegistrationState = .registered
                    return
                } catch {
                    guard !Task.isCancelled else { return }
                    self?.pushRegistrationState = .failed
                    self?.pushRegistrationError = error.localizedDescription
                }
                do { try await Task.sleep(for: .seconds(2 << attempt)) } catch { return }
                }
            }
        }
        AppDelegate.onRegistrationFailure = { [weak self] message in
            Task { @MainActor in
                self?.pushRegistrationState = .failed
                self?.pushRegistrationError = message
            }
        }
        WidgetBridge.liveActivityPushTokenHandler = { [weak self] token, carID in
            guard let self else { return }
            self.liveActivityPushRegistrationState = .registering
            self.liveActivityPushRegistrationError = nil
            let currentConfig = self.settings.config
            let currentService = PushService(baseURL: currentConfig.pushServiceURL,
                                             secret: self.settings.pushSecret,
                                             trust: self.settings.trustConfig,
                                             basicAuth: self.settings.basicAuth,
                                             cloudflareAccess: self.settings.cloudflareAccess)
            Task { @MainActor in
                do {
                    try await currentService.registerLiveActivity(token: token, carID: carID, config: currentConfig)
                    self.liveActivityPushRegistrationState = .registered
                } catch {
                    self.liveActivityPushRegistrationState = .failed
                    self.liveActivityPushRegistrationError = error.localizedDescription
                }
            }
        }
        pushRegistrationState = .registering
        pushRegistrationError = nil
        Task { @MainActor in
            await notifications.requestAuthorization()
            guard notifications.authorized else {
                pushRegistrationState = .failed
                pushRegistrationError = L("Notification permission is disabled in iOS Settings.")
                return
            }
            UIApplication.shared.registerForRemoteNotifications()
            WidgetBridge.reregisterLiveActivityPushTokens()
        }
        #endif
    }

    func sendTestPush() async {
        guard settings.config.pushEnabled, !settings.config.pushServiceURL.isEmpty else { return }
        let service = PushService(baseURL: settings.config.pushServiceURL,
                                  secret: settings.pushSecret,
                                  trust: settings.trustConfig,
                                  basicAuth: settings.basicAuth,
                                  cloudflareAccess: settings.cloudflareAccess)
        do {
            try await service.sendTest(
                title: L("Test notification"),
                message: L("Remote notifications are working even when Tesstats is closed.")
            )
            pushRegistrationError = nil
        } catch {
            pushRegistrationState = .failed
            pushRegistrationError = error.localizedDescription
        }
    }

    /// Test affordance: inject a real server configuration from launch env vars so the live
    /// connection can be verified end-to-end without filling the form by hand. Returns true
    /// if env config was applied. Secrets go to the Keychain like the normal flow.
    private func applyEnvOverridesIfPresent() -> Bool {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["TESSTATS_MQTT_HOST"], !host.isEmpty else { return false }
        var c = ServerConfig()
        c.demoMode = false
        c.serverHost = host
        c.mqttHost = host
        c.mqttPort = Int(env["TESSTATS_MQTT_PORT"] ?? "443") ?? 443
        c.mqttTransport = (env["TESSTATS_MQTT_TRANSPORT"] == "tls") ? .tls : .websocket
        c.mqttWebsocketPath = env["TESSTATS_WS_PATH"] ?? "/"
        c.mqttUsername = env["TESSTATS_MQTT_USER"] ?? ""
        c.apiBaseURL = env["TESSTATS_API_URL"] ?? ""
        if let basicUser = env["TESSTATS_BASIC_USER"], !basicUser.isEmpty {
            c.usesBasicAuth = true
            c.basicAuthUsername = basicUser
        }
        if let accessID = env["TESSTATS_CF_ACCESS_CLIENT_ID"], !accessID.isEmpty {
            c.usesCloudflareAccess = true
            c.cloudflareAccessClientID = accessID
        }
        settings.config = c
        settings.mqttPassword = env["TESSTATS_MQTT_PASS"] ?? ""
        settings.basicAuthPassword = env["TESSTATS_BASIC_PASS"] ?? ""
        settings.cloudflareAccessClientSecret = env["TESSTATS_CF_ACCESS_CLIENT_SECRET"] ?? ""
        if env["TESSTATS_PERSIST"] == "1" { settings.save() }
        return true
    }

    /// Persist edited configuration and reconnect with the new settings.
    func applyConfigChange() {
        settings.save()
        tripTags.scope(to: settings.config.historySourceIdentity)
        history.reset()
        live.restart()
        if let carID = settings.config.selectedCarID {
            Task { await history.loadIfNeeded(carID: carID) }
        }
        Task { await notifications.requestAuthorization() }
        enablePushIfNeeded()
        if !settings.config.liveActivityEnabled { WidgetBridge.stopLiveActivities() }
    }

    func enableDemoMode() {
        settings.config = .demo
        settings.save()
        tripTags.scope(to: settings.config.historySourceIdentity)
        history.reset()
        live.restart()
    }

    /// Clear only the offline cache (downloaded history + snapshots). Configuration is kept.
    func clearCache() {
        cache.clearAll()
        history.reset()
    }

    /// Full reset: wipe configuration, every Keychain secret, profiles, notifications and cache.
    /// Afterwards `isConfigured` is false, so the app returns to onboarding.
    func eraseAllData() {
        live.stop()
        driverBluetooth.eraseAll()
        settings.eraseAll()
        notifications.resetToDefaults()
        inbox.clear()
        cache.clearAll()
        history.reset()
        tripTags.clear()
        WidgetBridge.clearAll()
        live.restart()
    }
}
