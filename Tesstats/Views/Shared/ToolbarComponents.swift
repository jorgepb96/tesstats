import SwiftUI

/// The colored connection dot shown top-left on every screen. Tapping opens a menu with the
/// live status and (when more than one car) a vehicle picker — identical to the Summary screen.
struct ConnectionStatusMenu: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        Menu {
            Text(env.live.status.label)
            if env.live.cars.count > 1 {
                Divider()
                ForEach(env.live.cars) { car in
                    Button { env.live.selectCar(car.id) } label: {
                        Label(car.title, systemImage: env.live.resolvedCarID == car.id ? "checkmark" : "car")
                    }
                }
            }
        } label: {
            ConnectionDot(status: env.live.status)
        }
    }
}

/// Settings gear shown next to the refresh button on every screen.
struct SettingsGearButton: View {
    @Binding var isPresented: Bool
    var body: some View {
        Button { isPresented = true } label: { Image(systemName: "gearshape") }
            .tint(Brand.action)
            .accessibilityLabel(L("Settings"))
            .accessibilityIdentifier("Settings")
    }
}

extension View {
    /// Present Settings as a sheet (the destination of every screen's gear button).
    func settingsSheet(isPresented: Binding<Bool>) -> some View {
        sheet(isPresented: isPresented) {
            NavigationStack { SettingsView(presentedAsSheet: true) }
        }
    }
}
