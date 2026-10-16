import SwiftUI

struct ChargeNotificationView: View {
    let route: ChargeNotificationRoute
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var charge: ChargeRecord?
    @State private var failed = false

    var body: some View {
        NavigationStack {
            Group {
                if let charge {
                    ChargeDetailView(charge: charge, units: Units(config: env.settings.config),
                                     explicitCarID: route.carID, promptForPrice: true)
                } else if failed {
                    ContentUnavailableView(L("Charge unavailable"), systemImage: "bolt.slash",
                                           description: Text(L("Check your connection and selected server, then try again.")))
                } else { ProgressView() }
            }
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L("Done")) { dismiss() } } }
        }
        .task {
            do {
                let api = HistoryAPIService(config: env.settings.makeAPIConfig())
                charge = try await api.fetchCharges(carID: route.carID).first { $0.id == route.chargeID }
                failed = charge == nil
            } catch { failed = true }
        }
    }
}
