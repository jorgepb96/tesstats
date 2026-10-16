import Foundation

struct ChargeNotificationRoute: Codable, Hashable, Identifiable, Sendable {
    let carID: Int
    let chargeID: Int
    var id: String { "\(carID):\(chargeID)" }
}

@MainActor @Observable final class NotificationNavigation {
    static let shared = NotificationNavigation()
    var charge: ChargeNotificationRoute?
}

/// Deduplicates completed sessions by server/vehicle and location. A first sync establishes
/// a baseline, rather than notifying about years of historical sessions.
struct ChargeCostReminderState: Codable {
    var initialized = false
    var seenCharges: Set<Int> = []
    var knownLocations: Set<String> = []

    mutating func inspect(_ charges: [ChargeRecord], prices: [String: Double], now: Date = Date()) -> [ChargeRecord] {
        let completed = charges.filter { $0.endDate != nil }
            .sorted { $0.startDate < $1.startDate }
        var reminders: [ChargeRecord] = []
        for charge in completed {
            let location = charge.locationName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !location.isEmpty, charge.geofence != nil || charge.address != nil else { continue }
            let newCharge = seenCharges.insert(charge.id).inserted
            let newLocation = knownLocations.insert(location.lowercased()).inserted
            guard initialized, newCharge, newLocation,
                  let end = charge.endDate, end <= now, now.timeIntervalSince(end) < 7 * 86400,
                  charge.energyAddedKwh > 0,
                  !(charge.cost.map { $0.isFinite && $0 > 0 } ?? false),
                  !prices.keys.contains(where: { $0.caseInsensitiveCompare(location) == .orderedSame }) else { continue }
            reminders.append(charge)
        }
        initialized = true
        return reminders
    }
}
