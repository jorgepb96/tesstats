import SwiftUI

// MARK: - Plan list

/// Manage the named time-of-use plans and pick which one prices charges.
struct TariffPlansView: View {
    @Environment(AppEnvironment.self) private var env

    private var plans: [TariffPlan] { env.settings.config.tariffPlans }

    var body: some View {
        ZStack {
            Brand.background.ignoresSafeArea()
            Form {
                Section {
                    if plans.isEmpty {
                        Text(L("No tariff plans yet. Add one to price charges by time of day."))
                            .font(.subheadline).foregroundStyle(Brand.textSecondary)
                    }
                    ForEach(plans) { plan in
                        NavigationLink {
                            TariffPlanDetailView(planID: plan.id)
                        } label: {
                            planRow(plan)
                        }
                    }
                    .onDelete(perform: delete)
                    Button {
                        addPlan()
                    } label: {
                        Label(L("Add plan"), systemImage: "plus.circle.fill")
                    }
                    .tint(Brand.action)
                } header: {
                    Text(L("Plans"))
                } footer: {
                    Text(L("Tap a plan to edit its bands. The selected plan prices any charging session TeslaMate did not record a cost for. Swipe to delete."))
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
        .navigationTitle(L("Tariff plans"))
        .navigationBarTitleDisplayModeInlineIfAvailable()
        .onAppear {
            // Bring a pre-plan band list into the new editor rather than stranding it.
            var config = env.settings.config
            config.migrateLegacyTariffIfNeeded()
            if config != env.settings.config {
                env.settings.config = config
                env.settings.save()
            }
        }
    }

    private func planRow(_ plan: TariffPlan) -> some View {
        HStack(spacing: 10) {
            // A bare .onTapGesture here swallowed the row's tap, so the plan could never be
            // opened. A borderless Button keeps its own hit area inside the NavigationLink.
            Button {
                select(plan)
            } label: {
                Image(systemName: isActive(plan) ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isActive(plan) ? Brand.crimson : Brand.textTertiary)
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(isActive(plan) ? L("Selected plan") : L("Use this plan"))
            VStack(alignment: .leading, spacing: 2) {
                Text(plan.name.isEmpty ? L("Untitled plan") : plan.name)
                    .foregroundStyle(Brand.textPrimary)
                Text(L("\(plan.bands.count) bands"))
                    .font(.caption).foregroundStyle(Brand.textTertiary)
            }
        }
    }

    private func isActive(_ plan: TariffPlan) -> Bool {
        env.settings.config.activeTariffPlanID == plan.id.uuidString
    }

    private func select(_ plan: TariffPlan) {
        env.settings.config.activeTariffPlanID = isActive(plan) ? "" : plan.id.uuidString
        env.settings.save()
    }

    private func addPlan() {
        // A new plan starts as one all-day band; adding more splits the day automatically.
        let plan = TariffPlan(name: L("New plan"),
                              bands: [TariffBand(kind: .flat, startMinute: 0, endMinute: 0,
                                                 buyPricePerKwh: env.settings.config.chargePricePerKwh)])
            .normalized()
        env.settings.config.tariffPlans.append(plan)
        if env.settings.config.activeTariffPlanID.isEmpty {
            env.settings.config.activeTariffPlanID = plan.id.uuidString
        }
        env.settings.save()
    }

    private func delete(_ offsets: IndexSet) {
        let removed = offsets.map { plans[$0].id.uuidString }
        env.settings.config.tariffPlans.remove(atOffsets: offsets)
        if removed.contains(env.settings.config.activeTariffPlanID) {
            env.settings.config.activeTariffPlanID = ""
        }
        env.settings.save()
    }
}

// MARK: - Plan detail

/// Editor for one plan. Only each band's START time is editable — ends are derived so the
/// bands always tile a full 24 h however many the user adds.
struct TariffPlanDetailView: View {
    let planID: UUID
    @Environment(AppEnvironment.self) private var env

    private var plan: TariffPlan {
        env.settings.config.tariffPlans.first { $0.id == planID } ?? TariffPlan()
    }

    var body: some View {
        ZStack {
            Brand.background.ignoresSafeArea()
            Form {
                Section(L("Plan")) {
                    TextField(L("Plan name"), text: nameBinding)
                        .foregroundStyle(Brand.textPrimary)
                }

                Section {
                    ForEach(plan.bands) { band in
                        bandRow(band)
                    }
                    .onDelete(perform: deleteBands)
                    Button {
                        addBand()
                    } label: {
                        Label(L("Add band"), systemImage: "plus.circle.fill")
                    }
                    .tint(Brand.action)
                    .disabled(plan.bands.count >= 48)
                } header: {
                    Text(L("Price bands"))
                } footer: {
                    Text(L("Set when each band starts — the app closes the day automatically, so the bands always add up to 24 hours. Leave the sell price empty to match the buy price. Swipe a band to delete it."))
                }

                if !plan.bands.isEmpty {
                    Section(L("Day coverage")) {
                        TariffDayBar(bands: plan.normalized().bands)
                            .frame(height: 26)
                            .padding(.vertical, 4)
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
        .navigationTitle(plan.name.isEmpty ? L("Plan") : plan.name)
        .navigationBarTitleDisplayModeInlineIfAvailable()
    }

    @ViewBuilder
    private func bandRow(_ band: TariffBand) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("", selection: kindBinding(band)) {
                    ForEach(TariffBandKind.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .tint(color(for: band.kind))
                Spacer()
                Text(L("\(timeLabel(band.startMinute)) – \(timeLabel(band.endMinute))"))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Brand.textTertiary)
                    .monospacedDigit()
            }
            HStack(spacing: 8) {
                Text(L("Starts")).font(.caption).foregroundStyle(Brand.textSecondary)
                DatePicker("", selection: startBinding(band), displayedComponents: .hourAndMinute)
                    .labelsHidden().fixedSize()
                Spacer()
            }
            HStack(spacing: 8) {
                priceField(L("Buy"), value: buyBinding(band), placeholder: "0.10")
                priceField(L("Sell"), value: sellBinding(band), placeholder: L("same"))
            }
        }
        .padding(.vertical, 2)
    }

    private func priceField(_ label: String, value: Binding<Double?>, placeholder: String) -> some View {
        HStack(spacing: 4) {
            Text(label).font(.caption).foregroundStyle(Brand.textSecondary)
            TextField(placeholder, value: value, format: .number)
                .multilineTextAlignment(.trailing)
                .keyboardTypeDecimal()
                .frame(width: 64)
            Text(L("/kWh")).font(.caption2).foregroundStyle(Brand.textTertiary)
        }
    }

    // MARK: Bindings — every write re-normalizes so the day stays fully covered.

    private var nameBinding: Binding<String> {
        Binding(get: { plan.name },
                set: { new in
                    guard let idx = index else { return }
                    env.settings.config.tariffPlans[idx].name = new
                    env.settings.save()
                })
    }

    private var index: Int? { env.settings.config.tariffPlans.firstIndex { $0.id == planID } }

    private func update(_ change: (inout TariffPlan) -> Void) {
        guard let idx = index else { return }
        var p = env.settings.config.tariffPlans[idx]
        change(&p)
        env.settings.config.tariffPlans[idx] = p.normalized()
        env.settings.save()
    }

    private func kindBinding(_ band: TariffBand) -> Binding<TariffBandKind> {
        Binding(get: { band.kind },
                set: { new in update { p in if let i = p.bands.firstIndex(where: { $0.id == band.id }) { p.bands[i].kind = new } } })
    }

    private func startBinding(_ band: TariffBand) -> Binding<Date> {
        Binding(
            get: {
                let m = ((band.startMinute % 1440) + 1440) % 1440
                return Calendar.current.date(bySettingHour: m / 60, minute: m % 60, second: 0, of: Date()) ?? Date()
            },
            set: { date in
                let c = Calendar.current.dateComponents([.hour, .minute], from: date)
                let minutes = (c.hour ?? 0) * 60 + (c.minute ?? 0)
                update { p in if let i = p.bands.firstIndex(where: { $0.id == band.id }) { p.bands[i].startMinute = minutes } }
            })
    }

    private func buyBinding(_ band: TariffBand) -> Binding<Double?> {
        Binding(get: { band.buyPricePerKwh },
                set: { new in update { p in if let i = p.bands.firstIndex(where: { $0.id == band.id }) { p.bands[i].buyPricePerKwh = new ?? 0 } } })
    }

    private func sellBinding(_ band: TariffBand) -> Binding<Double?> {
        Binding(get: { band.sellPricePerKwh },
                set: { new in update { p in if let i = p.bands.firstIndex(where: { $0.id == band.id }) { p.bands[i].sellPricePerKwh = new } } })
    }

    private func addBand() {
        update { p in
            let start = p.suggestedStartForNewBand()
            let price = p.bands.first?.buyPricePerKwh ?? env.settings.config.chargePricePerKwh
            p.bands.append(TariffBand(kind: .flat, startMinute: start, endMinute: start, buyPricePerKwh: price))
        }
    }

    private func deleteBands(_ offsets: IndexSet) {
        update { p in p.bands.remove(atOffsets: offsets) }
    }

    private func timeLabel(_ minute: Int) -> String {
        let m = ((minute % 1440) + 1440) % 1440
        let date = Calendar.current.date(bySettingHour: m / 60, minute: m % 60, second: 0, of: Date()) ?? Date()
        return AppDate.shortTime(date)
    }

    private func color(for kind: TariffBandKind) -> Color {
        switch kind {
        case .valley: Brand.online
        case .flat: Brand.driving
        case .peak: Brand.danger
        }
    }
}

// MARK: - Coverage bar

/// Proportional 24 h strip, so it is obvious at a glance that the bands tile the whole day.
struct TariffDayBar: View {
    let bands: [TariffBand]

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 1) {
                ForEach(bands) { band in
                    color(for: band.kind)
                        .frame(width: max(2, geo.size.width * CGFloat(band.durationMinutes) / 1440))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 5))
        }
        .accessibilityLabel(L("Bands covering the 24 hour day"))
    }

    private func color(for kind: TariffBandKind) -> Color {
        switch kind {
        case .valley: Brand.online
        case .flat: Brand.driving
        case .peak: Brand.danger
        }
    }
}
