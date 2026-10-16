import Foundation
import WatchConnectivity

/// Receives the iPhone's persisted snapshot and low-latency updates. On every foreground
/// activation it asks the phone for a fresh read-only snapshot; no vehicle command is exposed.
@MainActor
@Observable
final class WatchSnapshotStore: NSObject, WCSessionDelegate, @unchecked Sendable {
    private(set) var snapshot: WidgetSnapshot?
    private(set) var isPhoneReachable = false

    override init() {
        super.init()
        #if DEBUG
        if ProcessInfo.processInfo.environment["TESSTATS_DEMO"] == "1" {
            snapshot = .placeholder
            return
        }
        #endif
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
        decode(session.receivedApplicationContext)
        isPhoneReachable = session.isReachable
    }

    private func decode(_ context: [String: Any]) {
        decode(data: context["snapshot"] as? Data)
    }

    private func decode(data: Data?) {
        guard let data,
              let snap = try? JSONDecoder().decode(WidgetSnapshot.self, from: data) else { return }
        snapshot = snap
    }

    func refresh() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        decode(session.receivedApplicationContext)
        isPhoneReachable = session.isReachable
        guard session.activationState == .activated else { return }
        if session.isReachable {
            let replyHandler: @Sendable ([String: Any]) -> Void = { [weak self] reply in
                let data = reply["snapshot"] as? Data
                Task { @MainActor in self?.decode(data: data) }
            }
            // WCSession callbacks arrive on its own operation queue. Supplying an empty closure
            // from this @MainActor method makes Swift 6 assert the wrong executor at runtime.
            session.sendMessage(["request": "snapshot"],
                                replyHandler: replyHandler,
                                errorHandler: nil)
        } else {
            // Queue one refresh hint for the phone. watchOS delivers it opportunistically and
            // the resulting application context replaces, rather than accumulates, snapshots.
            session.transferUserInfo(["request": "snapshot"])
        }
    }

    // MARK: WCSessionDelegate

    nonisolated func session(_ session: WCSession,
                             activationDidCompleteWith activationState: WCSessionActivationState,
                             error: Error?) {
        let data = session.receivedApplicationContext["snapshot"] as? Data
        let reachable = session.isReachable
        Task { @MainActor in
            self.decode(data: data)
            self.isPhoneReachable = reachable
            if activationState == .activated { self.refresh() }
        }
    }

    nonisolated func session(_ session: WCSession,
                             didReceiveApplicationContext applicationContext: [String: Any]) {
        let data = applicationContext["snapshot"] as? Data
        Task { @MainActor in self.decode(data: data) }
    }

    nonisolated func session(_ session: WCSession,
                             didReceiveMessage message: [String: Any]) {
        let data = message["snapshot"] as? Data
        Task { @MainActor in self.decode(data: data) }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor in
            self.isPhoneReachable = reachable
            if reachable { self.refresh() }
        }
    }
}
