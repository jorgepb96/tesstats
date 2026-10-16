import SwiftUI

/// Share trips and charges as CSV / JSON / GPX via the system share sheet. Read-only data
/// leaves the device only when the user explicitly taps Share.
struct ExportSheet: View {
    let drives: [DriveRecord]
    let charges: [ChargeRecord]

    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var format: ExportFormat = .csv

    var body: some View {
        NavigationStack {
            ZStack {
                Brand.background.ignoresSafeArea()
                Form {
                    Section {
                        Picker(L("Format"), selection: $format) {
                            ForEach(ExportFormat.allCases) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.segmented)
                    } header: {
                        Text(L("File format"))
                    } footer: {
                        Text(format == .gpx
                             ? L("GPX exports trip tracks and charge locations for mapping tools.")
                             : L("CSV opens in any spreadsheet; JSON keeps the full structured data."))
                    }

                    Section {
                        shareRow(L("Trips"), count: drives.count, systemImage: "map",
                                 url: ExportService.drivesFile(drives, format: format, tags: env.tripTags.tags))
                        shareRow(L("Charging"), count: charges.count, systemImage: "bolt.fill",
                                 url: ExportService.chargesFile(charges, format: format,
                                     pricing: ChargePricing(config: env.settings.config),
                                     currencyCode: env.settings.config.currencyCode))
                    } header: {
                        Text(L("Export"))
                    }
                }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
            }
            .navigationTitle(L("Export data"))
            .navigationBarTitleDisplayModeInlineIfAvailable()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("Done")) { dismiss() }
                }
            }
        }
        .tint(Brand.action)
    }

    @ViewBuilder
    private func shareRow(_ title: String, count: Int, systemImage: String, url: URL?) -> some View {
        if let url, count > 0 {
            ShareLink(item: url) {
                HStack {
                    Label(title, systemImage: systemImage).foregroundStyle(Brand.textPrimary)
                    Spacer()
                    Text("\(count)").foregroundStyle(Brand.textTertiary)
                    Image(systemName: "square.and.arrow.up").foregroundStyle(Brand.crimson)
                }
            }
        } else {
            HStack {
                Label(title, systemImage: systemImage).foregroundStyle(Brand.textTertiary)
                Spacer()
                Text(L("Nothing to export")).font(.caption).foregroundStyle(Brand.textTertiary)
            }
        }
    }
}
