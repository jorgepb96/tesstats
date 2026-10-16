import SwiftUI

/// Settings embedded directly in Driver Mode. Keeping these sections beside the live display
/// avoids duplicating a second, easy-to-miss configuration entry in the app's general settings.
struct DriverDisplayConfigurationSections: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        @Bindable var settings = env.settings
        Group {
            Section(L("Appearance")) {
                Picker(L("Driver theme"), selection: $settings.config.driverDisplay.appearance) {
                    ForEach(DriverDisplayAppearance.allCases) { Text($0.label).tag($0) }
                }
                Picker(L("Speed size"), selection: $settings.config.driverDisplay.speedScale) {
                    ForEach(DriverSpeedScale.allCases) { Text($0.label).tag($0) }
                }
            }
            Section {
                ForEach(DriverDisplayModule.allCases) { module in
                    Toggle(isOn: visibilityBinding(module)) {
                        Label(module.label, systemImage: module.icon)
                    }
                    .tint(Brand.action)
                    .accessibilityIdentifier("driver-toggle-\(module.rawValue)")
                }
            } header: {
                Text(L("Modules"))
            }
            Section(L("Behaviour")) {
                Toggle(L("Suggest when driving"), isOn: $settings.config.driverDisplay.suggestWhenDriving).tint(Brand.action)
                Toggle(L("Keep screen awake"), isOn: $settings.config.driverDisplay.keepScreenAwake).tint(Brand.action)
            }
            Section {
                Toggle(L("Speed adjustment"), isOn: $settings.config.driverDisplay.iphoneSpeedAdjustmentEnabled)
                    .tint(Brand.action)
                    .accessibilityIdentifier("driver-speed-adjustment-enabled")
                if settings.config.driverDisplay.iphoneSpeedAdjustmentEnabled {
                    Stepper(value: $settings.config.driverDisplay.iphoneSpeedAdjustmentKmh,
                            in: -10...10, step: 1) {
                        LabeledContent(L("iPhone GPS correction"), value: speedAdjustmentLabel)
                    }
                    .accessibilityIdentifier("driver-speed-adjustment-value")
                }
            } header: {
                Text(L("Speedometer"))
            } footer: {
                Text(L("Adds this value only to the iPhone GPS speed. Bluetooth and Tesstats vehicle readings are never adjusted."))
            }
        }
        .onChange(of: settings.config.driverDisplay) { _, _ in env.settings.save() }
    }

    private var speedAdjustmentLabel: String {
        let value = Int(env.settings.config.driverDisplay.iphoneSpeedAdjustmentKmh.rounded())
        return "\(value > 0 ? "+" : "")\(value) km/h"
    }

    private func visibilityBinding(_ module: DriverDisplayModule) -> Binding<Bool> {
        Binding(
            get: { !env.settings.config.driverDisplay.hiddenModules.contains(module) },
            set: { visible in
                var hidden = env.settings.config.driverDisplay.hiddenModules
                if visible { hidden.removeAll { $0 == module } }
                else if !hidden.contains(module) { hidden.append(module) }
                env.settings.config.driverDisplay.hiddenModules = hidden
                env.settings.save()
            })
    }

}
