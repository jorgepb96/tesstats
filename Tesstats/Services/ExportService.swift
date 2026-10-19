import Foundation

// Read-only data portability: turn the locally-held history into CSV / JSON / GPX files
// the user can share via the system share sheet (`ShareLink`). Pure and side-effect free
// except for writing a temporary file the share sheet hands off.

enum ExportFormat: String, CaseIterable, Identifiable {
    case csv, json, gpx
    var id: String { rawValue }
    var label: String {
        switch self {
        case .csv: "CSV"
        case .json: "JSON"
        case .gpx: "GPX"
        }
    }
}

enum ExportService {

    nonisolated(unsafe) private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    // MARK: - Public entry points (return a temp file URL for ShareLink)

    /// `tags` carries the local trip labels (drive ID → tag) into CSV/JSON exports.
    static func drivesFile(_ drives: [DriveRecord], format: ExportFormat, tags: [Int: TripTag] = [:]) -> URL? {
        switch format {
        case .csv: write(drivesCSV(drives, tags: tags), name: "tesstats-trips.csv")
        case .json: write(drivesJSON(drives, tags: tags), name: "tesstats-trips.json")
        case .gpx: write(drivesGPX(drives), name: "tesstats-trips.gpx")
        }
    }

    static func chargesFile(_ charges: [ChargeRecord], format: ExportFormat,
                            pricing: ChargePricing, currencyCode: String) -> URL? {
        switch format {
        case .csv: write(chargesCSV(charges, pricing: pricing, currencyCode: currencyCode), name: "tesstats-charges.csv")
        case .json: write(chargesJSON(charges, pricing: pricing, currencyCode: currencyCode), name: "tesstats-charges.json")
        case .gpx: write(chargesGPX(charges, pricing: pricing, currencyCode: currencyCode), name: "tesstats-charges.gpx")
        }
    }

    static func driveGPXFile(_ drive: DriveRecord) -> URL? {
        write(drivesGPX([drive]), name: "tesstats-trip-\(drive.id).gpx")
    }

    static func backupFile(_ data: Data) -> URL? {
        writeData(data, name: "tesstats-backup.json")
    }

    /// Encrypted backup container (still JSON, so the .json importer accepts it).
    static func encryptedBackupFile(_ data: Data) -> URL? {
        writeData(data, name: "tesstats-backup-encrypted.json")
    }

    // MARK: - CSV

    static func drivesCSV(_ drives: [DriveRecord], tags: [Int: TripTag] = [:]) -> String {
        var rows = ["start,end,origin,destination,distance_km,duration_min,start_battery,end_battery,consumption_wh_km,avg_speed_kmh,max_speed_kmh,outside_temp_c,tag"]
        for d in drives {
            var f: [String] = []
            f.append(iso.string(from: d.startDate))
            f.append(d.endDate.map { iso.string(from: $0) } ?? "")
            f.append(esc(d.originName))
            f.append(esc(d.destinationName))
            f.append(num(d.distanceKm))
            f.append(String(d.durationMin))
            f.append(d.startBattery.map(String.init) ?? "")
            f.append(d.endBattery.map(String.init) ?? "")
            f.append(d.consumptionWhPerKm.map { num($0) } ?? "")
            f.append(d.avgSpeedKmh.map { num($0) } ?? "")
            f.append(d.maxSpeedKmh.map { num($0) } ?? "")
            f.append(d.outsideTempAvg.map { num($0) } ?? "")
            f.append(tags[d.id]?.rawValue ?? "")
            rows.append(f.joined(separator: ","))
        }
        return rows.joined(separator: "\n")
    }

    static func chargesCSV(_ charges: [ChargeRecord], pricing: ChargePricing, currencyCode: String) -> String {
        var rows = ["start,end,location,energy_kwh,cost,start_battery,end_battery,duration_min,avg_power_kw,fast_dc,latitude,longitude,id,address,geofence,energy_used_kwh,billed_energy_kwh,charging_efficiency,start_range_km,end_range_km,outside_temp_c,odometer_km,currency,recorded_cost,cost_source,cost_is_estimated,effective_price_per_kwh,pricing_timezone,tariff_name,tariff_details_json"]
        for c in charges {
            let details = ChargeExport(charge: c, pricing: pricing, currencyCode: currencyCode)
            let resolved = details.pricing
            var f: [String] = []
            f.append(iso.string(from: c.startDate))
            f.append(c.endDate.map { iso.string(from: $0) } ?? "")
            f.append(esc(c.locationName))
            f.append(num(c.energyAddedKwh))
            f.append(num(resolved.cost, 2))
            f.append(c.startBattery.map(String.init) ?? "")
            f.append(c.endBattery.map(String.init) ?? "")
            f.append(String(c.durationMin))
            f.append(c.avgPowerKw.map { num($0) } ?? "")
            f.append(c.isFastCharger ? "1" : "0")
            f.append(c.coord.map { num($0.latitude, 6) } ?? "")
            f.append(c.coord.map { num($0.longitude, 6) } ?? "")
            f.append(String(c.id))
            f.append(esc(c.address ?? ""))
            f.append(esc(c.geofence ?? ""))
            f.append(c.energyUsedKwh.map { num($0, 4) } ?? "")
            f.append(num(resolved.billedEnergyKwh, 4))
            f.append(c.chargingEfficiency.map { num($0, 6) } ?? "")
            f.append(c.startRangeKm.map { num($0) } ?? "")
            f.append(c.endRangeKm.map { num($0) } ?? "")
            f.append(c.outsideTempAvg.map { num($0) } ?? "")
            f.append(c.odometerKm.map { num($0) } ?? "")
            f.append(esc(currencyCode))
            f.append(c.cost.map { num($0, 2) } ?? "")
            f.append(resolved.source)
            f.append(resolved.isEstimated ? "1" : "0")
            f.append(resolved.effectivePricePerKwh.map { num($0, 6) } ?? "")
            f.append(esc(details.pricingTimeZone))
            f.append(esc(details.tariffPlan?.name ?? ""))
            f.append(esc(details.tariffPlan.map { prettyJSON($0) }
                         ?? details.legacyTariff.map { prettyJSON($0) } ?? ""))
            rows.append(f.joined(separator: ","))
        }
        return rows.joined(separator: "\n")
    }

    // MARK: - JSON

    /// Flatten the original record fields for compatibility, keeping its raw cost separately.
    /// Only pricing metadata is exported, never ServerConfig or connection credentials.
    private struct ChargeExport: Encodable {
        let charge: ChargeRecord
        let pricing: ChargePricing.Resolution
        let currencyCode: String
        let pricingTimeZone: String
        let tariffPlan: TariffPlan?
        let legacyTariff: TimeOfUseTariff?

        init(charge: ChargeRecord, pricing: ChargePricing, currencyCode: String) {
            self.charge = charge
            self.pricing = pricing.resolution(for: charge)
            self.currencyCode = currencyCode
            pricingTimeZone = Calendar.current.timeZone.identifier
            tariffPlan = self.pricing.source == "time_of_use" ? pricing.plan?.normalized() : nil
            legacyTariff = self.pricing.source == "time_of_use" && pricing.plan == nil ? pricing.tariff : nil
        }

        enum CodingKeys: String, CodingKey {
            case schemaVersion, cost, recordedCost, locationName, currencyCode, pricing
            case pricingTimeZone, tariffPlan, legacyTariff, chargingEfficiency
        }

        func encode(to encoder: Encoder) throws {
            try charge.encode(to: encoder)
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(2, forKey: .schemaVersion)
            try values.encode(pricing.cost, forKey: .cost)
            try values.encodeIfPresent(charge.cost, forKey: .recordedCost)
            try values.encode(charge.locationName, forKey: .locationName)
            try values.encode(currencyCode, forKey: .currencyCode)
            try values.encode(pricing, forKey: .pricing)
            try values.encode(pricingTimeZone, forKey: .pricingTimeZone)
            try values.encodeIfPresent(tariffPlan, forKey: .tariffPlan)
            try values.encodeIfPresent(legacyTariff, forKey: .legacyTariff)
            try values.encodeIfPresent(charge.chargingEfficiency, forKey: .chargingEfficiency)
        }
    }

    static func chargesJSON(_ charges: [ChargeRecord], pricing: ChargePricing, currencyCode: String) -> String {
        prettyJSON(charges.map { ChargeExport(charge: $0, pricing: pricing, currencyCode: currencyCode) })
    }

    /// A drive plus its local tag. Only used when tags exist, so untagged installs keep
    /// producing the original `[DriveRecord]` JSON shape.
    private struct TaggedDriveExport: Encodable {
        let drive: DriveRecord
        let tag: String?
    }

    static func drivesJSON(_ drives: [DriveRecord], tags: [Int: TripTag] = [:]) -> String {
        guard !tags.isEmpty else { return prettyJSON(drives) }
        return prettyJSON(drives.map { TaggedDriveExport(drive: $0, tag: tags[$0.id]?.rawValue) })
    }

    private static func prettyJSON<T: Encodable>(_ value: T) -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(value), let s = String(data: data, encoding: .utf8) else { return "[]" }
        return s
    }

    // MARK: - GPX

    static func drivesGPX(_ drives: [DriveRecord]) -> String {
        var x = gpxHeader()
        for d in drives {
            let pts = d.path.isEmpty ? [d.startCoord, d.endCoord].compactMap { $0 } : d.path
            guard !pts.isEmpty else { continue }
            x += "  <trk>\n    <name>\(xmlEsc(d.originName)) → \(xmlEsc(d.destinationName))</name>\n    <trkseg>\n"
            for p in pts {
                x += "      <trkpt lat=\"\(num(p.latitude, 6))\" lon=\"\(num(p.longitude, 6))\"></trkpt>\n"
            }
            x += "    </trkseg>\n  </trk>\n"
        }
        x += "</gpx>\n"
        return x
    }

    static func chargesGPX(_ charges: [ChargeRecord], pricing: ChargePricing, currencyCode: String) -> String {
        var x = gpxHeader()
        for c in charges {
            guard let coord = c.coord else { continue }
            let details = ChargeExport(charge: c, pricing: pricing, currencyCode: currencyCode)
            x += "  <wpt lat=\"\(num(coord.latitude, 6))\" lon=\"\(num(coord.longitude, 6))\">\n"
            x += "    <time>\(iso.string(from: c.startDate))</time>\n    <name>\(xmlEsc(c.locationName))</name>\n"
            x += "    <desc>\(xmlEsc("\(num(c.energyAddedKwh)) kWh; \(num(details.pricing.cost)) \(currencyCode); \(details.pricing.source)"))</desc>\n"
            x += "    <extensions><tesstats:charge>\(xmlEsc(prettyJSON(details)))</tesstats:charge></extensions>\n  </wpt>\n"
        }
        // GPX waypoints require coordinates. Preserve unlocated sessions as document metadata.
        let unlocated = charges.filter { $0.coord == nil }
        if !unlocated.isEmpty {
            x += "  <extensions><tesstats:unlocatedCharges>\(xmlEsc(chargesJSON(unlocated, pricing: pricing, currencyCode: currencyCode)))</tesstats:unlocatedCharges></extensions>\n"
        }
        x += "</gpx>\n"
        return x
    }

    private static func gpxHeader() -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="Tesstats" xmlns="http://www.topografix.com/GPX/1/1" xmlns:tesstats="https://drakonis96.github.io/tesstats/export/1">

        """
    }

    // MARK: - Helpers

    private static func write(_ contents: String, name: String) -> URL? {
        writeData(Data(contents.utf8), name: name)
    }

    private static func writeData(_ data: Data, name: String) -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do { try data.write(to: url, options: .atomic); return url } catch { return nil }
    }

    private static func num(_ value: Double, _ digits: Int = 2) -> String {
        String(format: "%.\(digits)f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    /// CSV field escaping (always uses '.' decimals via String(format:), locale-independent).
    private static func esc(_ field: String) -> String {
        if field.contains(",") || field.contains("\"") || field.contains("\n") || field.contains("\r") {
            return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return field
    }

    private static func xmlEsc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

// MARK: - Configuration backup / restore

/// Portable snapshot of the connection setup, including secrets, so a second device can be
/// configured by file or QR instead of retyping. Clearly flagged as containing credentials.
struct ConfigBackup: Codable, Sendable {
    var version = 1
    var config: ServerConfig
    var mqttPassword: String?
    var basicAuthPassword: String?
    var cloudflareAccessClientSecret: String?
    var pushSecret: String?

    func encoded() -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? enc.encode(self)) ?? Data()
    }

    static func decode(_ data: Data) -> ConfigBackup? {
        try? JSONDecoder().decode(ConfigBackup.self, from: data)
    }

    /// Encrypt this backup under a password, returning the container JSON to write to a file.
    func encryptedData(password: String) throws -> Data {
        try BackupCrypto.encrypt(encoded(), password: password).encoded()
    }
}

/// What an imported backup file turned out to be.
enum BackupImport {
    case plain(ConfigBackup)
    case encrypted(EncryptedBackup)
    case invalid

    /// Encrypted containers are checked first so a plaintext decode can't shadow them.
    static func inspect(_ data: Data) -> BackupImport {
        if let enc = EncryptedBackup.decode(data) { return .encrypted(enc) }
        if let plain = ConfigBackup.decode(data) { return .plain(plain) }
        return .invalid
    }
}
