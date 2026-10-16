import SwiftUI

struct NotificationInboxView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var filter: InboxFilter = .all

    private var groups: [DailyHistoryGroup<EventInboxItem>] {
        env.inbox.grouped(category: filter.category)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Brand.background.ignoresSafeArea()
                VStack(spacing: 16) {
                    filterBar
                    list
                }
                .padding(.horizontal, Metrics.screenPadding)
                .padding(.top, 8)
            }
            .navigationTitle(L("Notifications"))
            .toolbarTitleDisplayModeInline()
            .toolbar {
                ToolbarItemGroup(placement: .trailingBar) {
                    Button(role: .destructive) { env.inbox.clear() } label: {
                        Image(systemName: "trash")
                    }
                    .tint(Brand.action)
                    .accessibilityLabel(L("Delete everything"))
                    .accessibilityIdentifier("clear-notifications")

                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                    }
                    .tint(Brand.action)
                    .accessibilityLabel(L("Close"))
                    .accessibilityIdentifier("close-notifications")
                }
            }
        }
    }

    private var filterBar: some View {
        HStack(spacing: 4) {
            ForEach(InboxFilter.allCases) { option in
                let active = option == filter
                Text(option.label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(active ? .white : Brand.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(active ? Brand.crimson : Color.clear, in: Capsule())
                    .contentShape(Rectangle())
                    .onTapGesture { withAnimation(.snappy) { filter = option } }
            }
        }
        .padding(4)
        .background(Brand.elevatedSurface, in: Capsule())
        .overlay(Capsule().strokeBorder(Brand.hairline, lineWidth: 1))
    }

    @ViewBuilder
    private var list: some View {
        if groups.isEmpty {
            EmptyStateView(systemImage: "bell", title: L("No notifications"), message: L("Vehicle events generated on this device will appear here."))
        } else {
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(groups) { group in
                        HistoryDayHeader(title: group.title, detail: group.detail)
                        ForEach(group.items) { item in
                            EventInboxRow(item: item)
                                .onTapGesture {
                                    if let route = item.chargeRoute {
                                        dismiss()
                                        Task { @MainActor in
                                            try? await Task.sleep(for: .milliseconds(400))
                                            NotificationNavigation.shared.charge = route
                                        }
                                    }
                                }
                        }
                    }
                    Color.clear.frame(height: 8)
                }
            }
            .scrollContentBackground(.hidden)
            .bottomScrollClearance()
        }
    }
}

private enum InboxFilter: String, CaseIterable, Identifiable {
    case all, vehicle, tesstats
    var id: String { rawValue }
    var label: String {
        switch self {
        case .all: L("All")
        case .vehicle: L("Vehicle")
        case .tesstats: L("Tesstats")
        }
    }
    var category: EventInboxCategory? {
        switch self {
        case .all: nil
        case .vehicle: .vehicle
        case .tesstats: .tesstats
        }
    }
}

private struct EventInboxRow: View {
    let item: EventInboxItem

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: item.symbol)
                .font(.title3.weight(.semibold))
                .foregroundStyle(color)
                .frame(width: 34, height: 34)
                .background(color.opacity(0.16), in: Circle())
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(item.title)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(Brand.textPrimary)
                    Spacer()
                    Text(AppDate.shortTime(item.date))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Brand.textTertiary)
                }
                Text(item.body)
                    .font(.subheadline)
                    .foregroundStyle(Brand.textSecondary)
                    .lineLimit(3)
                Chip(text: item.category.label, color: color)
            }
        }
        .card()
    }

    private var color: Color {
        item.category == .vehicle ? Brand.driving : Brand.crimson
    }
}
