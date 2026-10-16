import SwiftUI

struct DriverBluetoothSettingsSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDelete = false
    @State private var showVehicleRemovalInstructions = false

    private var service: DriverBluetoothTelemetryService { env.driverBluetooth }

    var body: some View {
        NavigationStack {
            Form {
                telemetryModeSection
                DriverDisplayConfigurationSections()
                vehicleSection
                securitySection
                actionsSection
            }
            .scrollContentBackground(.hidden)
            .background(Brand.background)
            .navigationTitle(L("Driver display"))
            .navigationBarTitleDisplayModeInlineIfAvailable()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("Done")) { dismiss() }
                        .accessibilityIdentifier("driver-bluetooth-done")
                }
            }
        }
        .presentationDetents([.large])
        .task { await service.prepare(carID: env.live.resolvedCarID) }
        .interactiveDismissDisabled(service.pairingState == .awaitingVehicleApproval)
        .alert(L("Remove pairing?"), isPresented: $confirmDelete) {
            Button(L("Cancel"), role: .cancel) {}
            Button(L("Remove from this iPhone"), role: .destructive) {
                service.deletePairing()
                showVehicleRemovalInstructions = true
            }
        } message: {
            Text(L("The private key will be destroyed immediately. Tesstats will no longer be able to authenticate with this vehicle."))
        }
        .alert(L("Finish removal in the vehicle"), isPresented: $showVehicleRemovalInstructions) {
            Button(L("Understood"), role: .cancel) {}
        } message: {
            Text(L("For complete cleanup, open Controls › Locks on the Tesla screen and remove the read-only key that was added for this iPhone."))
        }
    }

    private var telemetryModeSection: some View {
        Section {
            Picker(L("Telemetry source"), selection: telemetryModeBinding) {
                ForEach(DriverTelemetryMode.allCases) { mode in
                    Image(systemName: mode.icon)
                        .accessibilityLabel(mode.label)
                        .tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("driver-telemetry-mode-sheet")

            Label(env.settings.config.driverDisplay.telemetryMode.detail,
                  systemImage: env.settings.config.driverDisplay.telemetryMode.icon)
                .font(.footnote)
                .foregroundStyle(Brand.textSecondary)
        } header: {
            Text(L("Telemetry source"))
        }
    }

    private var telemetryModeBinding: Binding<DriverTelemetryMode> {
        Binding(
            get: { env.settings.config.driverDisplay.telemetryMode },
            set: { mode in
                env.settings.config.driverDisplay.telemetryMode = mode
                env.settings.save()
            }
        )
    }

    private var vehicleSection: some View {
        Section {
            if let identity = service.identity {
                HStack(spacing: 12) {
                    Image(systemName: "car.side.fill")
                        .font(.title3)
                        .foregroundStyle(Brand.action)
                        .frame(width: 38, height: 38)
                        .background(Brand.action.opacity(0.12), in: Circle())
                    VStack(alignment: .leading, spacing: 3) {
                        Text(identity.displayName).font(.headline)
                        Text(identity.maskedVIN)
                            .font(.caption.monospaced())
                            .foregroundStyle(Brand.textSecondary)
                    }
                    Spacer()
                    bluetoothStatusBadge
                }
                if !identity.isInitiallySupported {
                    Label(L("Direct Bluetooth is currently available for Model 3 and Model Y."),
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote).foregroundStyle(Brand.warning)
                }
            } else {
                Label(pairingMessage, systemImage: "car.side")
                    .font(.footnote).foregroundStyle(Brand.textSecondary)
            }
        } header: {
            Text(L("Selected vehicle"))
        }
    }

    private var securitySection: some View {
        Section {
            Label(L("The vehicle grants a Vehicle Monitor key: it can read driving data but cannot authorize changes to the car."),
                  systemImage: "lock.shield.fill")
            Label(L("The private key is hardware-protected on this iPhone and is never sent to TeslaMate, Tesla servers or any other device."),
                  systemImage: "iphone.gen3")
            Label(L("Bluetooth runs only while Driver Copilot is visible and disconnects in the background."),
                  systemImage: "eye.fill")
        } header: {
            Text(L("Read-only security"))
        }
        .font(.footnote)
        .foregroundStyle(Brand.textSecondary)
    }

    @ViewBuilder
    private var actionsSection: some View {
        Section {
            switch service.pairingState {
            case .unpaired, .failed:
                Button {
                    service.pair()
                } label: {
                    Label(L("Pair read-only Bluetooth"), systemImage: "link.badge.plus")
                }
                .disabled(!service.canPair)
                .accessibilityIdentifier("driver-bluetooth-pair")

            case .connecting:
                HStack {
                    ProgressView().controlSize(.small)
                    Text(L("Finding the selected vehicle…"))
                }
                Button(L("Cancel"), role: .cancel) { service.cancelPairing() }

            case .awaitingVehicleApproval:
                VStack(alignment: .leading, spacing: 10) {
                    Label(L("Approve on the Tesla"), systemImage: "key.radiowaves.forward.fill")
                        .font(.headline).foregroundStyle(Brand.action)
                    Text(L("Place a key card on the center console, then confirm the request on the vehicle screen. Keep this sheet open."))
                        .font(.footnote).foregroundStyle(Brand.textSecondary)
                    ProgressView().frame(maxWidth: .infinity)
                }
                Button(L("Cancel pairing"), role: .cancel) { service.cancelPairing() }

            case .paired, .pairedDisabled:
                Toggle(isOn: Binding(get: { service.isEnabled },
                                     set: { service.setEnabled($0) })) {
                    Label(L("Use direct Bluetooth"), systemImage: "antenna.radiowaves.left.and.right")
                }
                .tint(Brand.action)
                .accessibilityIdentifier("driver-bluetooth-enabled")
                Button(role: .destructive) {
                    confirmDelete = true
                } label: {
                    Label(L("Remove pairing"), systemImage: "trash")
                }
                .accessibilityIdentifier("driver-bluetooth-delete")

            case .unavailable:
                EmptyView()
            }
        } header: {
            Text(L("Connection"))
        } footer: {
            if case .failed(let message) = service.pairingState {
                Text(message).foregroundStyle(Brand.danger)
            } else if service.pairingState.isPaired {
                Text(L("If Bluetooth is interrupted, Driver Copilot automatically continues with iPhone GPS and TeslaMate."))
            }
        }
    }

    private var bluetoothStatusBadge: some View {
        HStack(spacing: 5) {
            Circle().fill(statusColor).frame(width: 7, height: 7)
            Text(statusText).font(.caption.weight(.semibold))
        }
        .foregroundStyle(Brand.textSecondary)
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(Brand.elevatedSurface, in: Capsule())
        .accessibilityIdentifier("driver-bluetooth-status")
    }

    private var statusText: String {
        switch service.pairingState {
        case .unavailable: L("Unavailable")
        case .unpaired: L("Not paired")
        case .connecting: L("Connecting…")
        case .awaitingVehicleApproval: L("Waiting for approval")
        case .pairedDisabled: L("Disabled")
        case .paired:
            if env.settings.config.driverDisplay.telemetryMode == .iphoneAndTeslaMate {
                L("Bluetooth on standby")
            } else {
                switch service.connectionState {
                case .connected: L("Connected")
                case .scanning, .connecting, .authenticating: L("Reconnecting…")
                case .failed: L("Error")
                case .idle: L("Paired")
                }
            }
        case .failed: L("Error")
        }
    }

    private var statusColor: Color {
        switch service.pairingState {
        case .paired where service.connectionState.isConnected: Brand.online
        case .paired where env.settings.config.driverDisplay.telemetryMode != .iphoneAndTeslaMate:
            Brand.warning
        case .paired, .awaitingVehicleApproval, .connecting: Brand.action
        case .failed: Brand.danger
        default: Brand.textTertiary
        }
    }

    private var pairingMessage: String {
        switch service.pairingState {
        case .unavailable(let message), .failed(let message): message
        default: L("Vehicle information is loading…")
        }
    }
}
