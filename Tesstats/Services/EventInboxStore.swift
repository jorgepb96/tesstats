import Foundation

@MainActor
@Observable
final class EventInboxStore {
    private let defaults: UserDefaults
    private let key: String
    private(set) var items: [EventInboxItem] = []

    init(defaults: UserDefaults = .standard, key: String = "tesstats.event.inbox") {
        self.defaults = defaults
        self.key = key
        load()
    }

    func add(category: EventInboxCategory, title: String, body: String, symbol: String = "bell", chargeRoute: ChargeNotificationRoute? = nil) {
        let item = EventInboxItem(id: UUID(), date: Date(), category: category, title: title, body: body, symbol: symbol, chargeRoute: chargeRoute)
        items.insert(item, at: 0)
        if items.count > 200 { items.removeLast(items.count - 200) }
        persist()
    }

    func seedWelcomeIfNeeded() {
        guard items.isEmpty else { return }
        add(category: .tesstats,
            title: L("Welcome to Tesstats"),
            body: L("Vehicle events generated on this device will appear here."),
            symbol: "sparkles")
    }

    func clear() {
        items = []
        defaults.removeObject(forKey: key)
    }

    func grouped(category: EventInboxCategory? = nil, calendar: Calendar = .current) -> [DailyHistoryGroup<EventInboxItem>] {
        let filtered = category.map { cat in items.filter { $0.category == cat } } ?? items
        return DailyHistoryGrouper.group(filtered, calendar: calendar, date: \.date) { day in
            if calendar.isDateInToday(day) { return L("Today") }
            if calendar.isDateInYesterday(day) { return L("Yesterday") }
            return AppDate.mediumDate(day)
        } detail: { bucket in
            L("\(bucket.count) events")
        }
    }

    private func load() {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([EventInboxItem].self, from: data)
        else { return }
        items = decoded.sorted { $0.date > $1.date }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(items) {
            defaults.set(data, forKey: key)
        }
    }
}
