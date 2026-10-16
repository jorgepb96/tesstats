#if os(iOS)
import Foundation
import WatchConnectivity

/// Mirrors the read-only vehicle snapshot to Apple Watch. Application context preserves the
/// latest value for offline launch; an interactive message updates the visible Watch app with
/// low latency. The Watch may request a refresh but can never send a vehicle command.
@MainActor
final class WatchBridge: NSObject, WCSessionDelegate, @unchecked Sendable {
    static let shared = WatchBridge()
    private var refreshHandler: (@MainActor @Sendable () -> Void)?

    func setRefreshHandler(_ handler: @escaping @MainActor @Sendable () -> Void) {
        refreshHandler = handler
    }

    func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    func push(_ snapshot: WidgetSnapshot) {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated,
              session.isPaired, session.isWatchAppInstalled,
              let data = try? JSONEncoder().encode(snapshot) else { return }
        // Application context replaces the previous value — always the freshest state.
        try? session.updateApplicationContext(["snapshot": data])
        if session.isReachable {
            // A closure created in this @MainActor type inherits actor isolation. WCSession
            // invokes its error handler on an NSOperationQueue, which caused the Swift 6
            // runtime dispatch assertion seen in the production crash logs. A nil handler is
            // sufficient because application context already preserves this same snapshot.
            session.sendMessage(["snapshot": data], replyHandler: nil, errorHandler: nil)
        }
    }

    private func refreshRequested() {
        refreshHandler?()
    }

    // MARK: WCSessionDelegate

    nonisolated func session(_ session: WCSession,
                             activationDidCompleteWith activationState: WCSessionActivationState,
                             error: Error?) {}

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        // Re-activate after a watch switch so the new watch keeps receiving updates.
        session.activate()
    }

    nonisolated func session(_ session: WCSession,
                             didReceiveMessage message: [String: Any],
                             replyHandler: @escaping ([String: Any]) -> Void) {
        guard message["request"] as? String == "snapshot" else {
            replyHandler([:])
            return
        }
        // Reply immediately with the persisted latest value, then ask the live pipeline to
        // refresh retained MQTT state. A fresher snapshot follows through `push(_:)`.
        replyHandler(session.applicationContext)
        Task { @MainActor in
            WatchBridge.shared.refreshRequested()
        }
    }

    nonisolated func session(_ session: WCSession,
                             didReceiveUserInfo userInfo: [String: Any]) {
        guard userInfo["request"] as? String == "snapshot" else { return }
        Task { @MainActor in
            WatchBridge.shared.refreshRequested()
        }
    }
}
#endif
