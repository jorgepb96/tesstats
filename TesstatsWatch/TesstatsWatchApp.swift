import SwiftUI

/// Watch companion app: a read-only glance at the car — battery, range, state and
/// charging progress. Data arrives from the iPhone app over WatchConnectivity
/// (application context), so it shows the last state even when the phone is away.
@main
struct TesstatsWatchApp: App {
    @State private var store = WatchSnapshotStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            WatchStatusView()
                .environment(store)
                .task { store.refresh() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { store.refresh() }
                }
        }
    }
}
