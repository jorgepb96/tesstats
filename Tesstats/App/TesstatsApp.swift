import SwiftUI
#if os(iOS)
import UIKit
import UserNotifications
#endif

@main
struct TesstatsApp: App {
    #if os(iOS)
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #elseif os(macOS)
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var macDelegate
    #endif
    @State private var env = AppEnvironment()

    var body: some Scene {
        WindowGroup(id: "main") {
            RootContainerView()
                .environment(env)
                .lowercaseKeyboardStart()
                .macTextScale()
        }
        #if os(macOS)
        .defaultSize(width: 1080, height: 760)
        #endif

        #if os(macOS)
        // Menu-bar presence: Tesstats keeps running in the background (live MQTT + notifications)
        // even after the window is closed, with battery/charge status always in the menu bar.
        MenuBarExtra {
            MenuBarContent(env: env)
                .environment(\.locale, LanguageManager.locale)
                .environment(\.calendar, LanguageManager.calendar)
        } label: {
            MenuBarLabel(env: env)
        }
        .menuBarExtraStyle(.window)
        #endif
    }
}

#if os(iOS)
/// Minimal app delegate to receive the APNs device token for the optional push service.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    /// Set by AppEnvironment; called when iOS hands us a device token.
    nonisolated(unsafe) static var onToken: ((String) -> Void)?
    nonisolated(unsafe) static var onRegistrationFailure: ((String) -> Void)?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // iOS suppresses banners while an app is in the foreground unless a notification-center
        // delegate explicitly opts in. Keep the same visible behaviour in and out of the app.
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        AppDelegate.onToken?(token)
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        print("Remote notifications unavailable: \(error.localizedDescription)")
        AppDelegate.onRegistrationFailure?(error.localizedDescription)
    }

    // Completion-handler variants on purpose: the `async` forms let Swift call UIKit's completion
    // handler from whatever executor the task ended on. UIKit asserts that handler runs on the
    // main thread (it refreshes the app snapshot), so tapping a notification crashed the launch.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        var route: ChargeNotificationRoute?
        if let carID = info["carId"] as? Int, carID > 0,
           let chargeID = info["chargeId"] as? Int, chargeID > 0 {
            route = ChargeNotificationRoute(carID: carID, chargeID: chargeID)
        }
        let done = UncheckedSendable(value: completionHandler)
        Task { @MainActor [route] in
            if let route { NotificationNavigation.shared.charge = route }
            done.value()
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let done = UncheckedSendable(value: completionHandler)
        Task { @MainActor in done.value([.banner, .list, .sound, .badge]) }
    }

    private struct UncheckedSendable<Value>: @unchecked Sendable { let value: Value }
}
#endif

/// Decides between onboarding and the main tab UI, and shows a brief branded splash.
struct RootContainerView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.scenePhase) private var scenePhase
    @State private var showSplash = true
    @State private var notificationNavigation = NotificationNavigation.shared

    var body: some View {
        // Keep the global accent in sync with the user's choice. Reading the hex here makes the
        // root observe it, and running before the children render guarantees the rebuilt subtree
        // (keyed on the accent below) re-resolves every static `Brand.crimson` reference.
        let config = env.settings.config
        let _ = Brand.setAccent(config.accentColorHex)

        return ZStack {
            Brand.background.ignoresSafeArea()

            Group {
                if env.settings.isConfigured {
                    #if os(macOS)
                    MacRootView()
                    #else
                    RootTabView()
                    #endif
                } else {
                    OnboardingView()
                }
            }
            // Rebuild the tree on language OR accent change so static color reads re-resolve.
            .id("\(config.languageCode)|\(config.accentColorHex)")
            .opacity(showSplash ? 0 : 1)

            if showSplash {
                SplashView()
                    .transition(.opacity)
            }
        }
        .preferredColorScheme(config.appearance.colorScheme)
        // Dates, weekday names and chart axis labels are formatted from the environment
        // locale, not from the string table — without this they keep the device language
        // and leak through an app the user switched to another language.
        .environment(\.locale, LanguageManager.locale)
        .environment(\.calendar, LanguageManager.calendar)
        .tint(Brand.action)
        .sheet(item: $notificationNavigation.charge) { route in
            ChargeNotificationView(route: route).environment(env)
        }
        .task(id: "\(scenePhase == .active)|\(env.live.resolvedCarID ?? -1)") {
            guard scenePhase == .active, let carID = env.live.resolvedCarID else { return }
            while !Task.isCancelled {
                await env.history.syncRecent(carID: carID)
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
            }
        }
        .task {
            env.bootstrap()
            // Just long enough for the logo to register; the app used to hold the splash for
            // 1.1 s on top of a 0.5 s fade, which read as a slow launch.
            try? await Task.sleep(for: .seconds(0.35))
            withAnimation(.easeOut(duration: 0.25)) { showSplash = false }
        }
        .onChange(of: scenePhase) { _, phase in
            // iOS suspends background work, so reconnect on foreground and release on background.
            // On macOS the app keeps running in the menu bar, so the live connection stays up.
            #if os(iOS)
            switch phase {
            case .active where env.settings.isConfigured:
                env.live.start()
                Task { await env.notifications.refreshAuthorizationStatus() }
                // APNs tokens and network reachability can change between launches. Re-run
                // the idempotent registration on every foreground transition so a temporary
                // server/APNs failure does not leave background alerts permanently disabled.
                env.enablePushIfNeeded()
            case .background:
                env.driverBluetooth.stop()
                // Do not tear MQTT down ourselves. iOS will suspend the process when needed,
                // but while it grants a short background execution window the existing socket
                // can still observe a transition and schedule a local notification. Guaranteed
                // closed-app delivery remains the job of the optional APNs bridge.
            default:
                break
            }
            #endif
        }
    }
}

private struct SplashView: View {
    @State private var glow = false
    var body: some View {
        ZStack {
            Brand.background.ignoresSafeArea()
            VStack(spacing: 18) {
                LogoMark(width: 220)
                    .shadow(color: Brand.crimson.opacity(glow ? 0.7 : 0.2), radius: glow ? 26 : 8)
                    .scaleEffect(glow ? 1.0 : 0.96)
                Text("Tesstats")
                    .font(.title.weight(.semibold))
                    .foregroundStyle(Brand.textPrimary)
                    .tracking(2)
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) { glow = true }
        }
    }
}
