import Foundation

enum APIError: Error, LocalizedError {
    case notConfigured
    case badURL
    case unauthorized
    case http(Int)
    case insecure
    case underlying(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: L("No history API (TeslaMateApi) URL configured.")
        case .badURL: L("The API URL is invalid.")
        case .unauthorized: L("Authentication failed (check Basic Auth credentials).")
        case .http(let code): String(format: L("Server responded with HTTP %@."), String(code))
        case .insecure: L("Refusing to send credentials over an unencrypted connection.")
        case .underlying(let m): m
        }
    }
}

/// URLSession delegate that applies the TLS trust policy (Let's Encrypt / custom CA / pinning).
private final class APITrustDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    let trust: TrustConfig
    init(trust: TrustConfig) { self.trust = trust }

    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        if TrustEvaluator.evaluate(serverTrust, config: trust) {
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}

/// Reads TeslaMate history (drives, charges, cars, live status) from a TeslaMateApi
/// instance over HTTPS. Basic Auth (reverse proxy) is sent as an explicit header, only
/// over TLS. Decoding is lenient so version differences degrade gracefully.
final class HistoryAPIService: Sendable {
    struct Config: Sendable {
        var baseURL: String
        var basicAuth: BasicAuth?
        var trust: TrustConfig
        var allowInsecure: Bool
    }

    private let config: Config
    private let session: URLSession

    init(config: Config, session: URLSession? = nil) {
        self.config = config
        if let session {
            self.session = session
            return
        }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 20
        cfg.waitsForConnectivity = false
        self.session = URLSession(configuration: cfg,
                                  delegate: APITrustDelegate(trust: config.trust),
                                  delegateQueue: nil)
    }

    private var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }

    private func request(path: String) throws -> URLRequest {
        let base = config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { throw APIError.notConfigured }
        let lower = base.lowercased()
        let isTLS = lower.hasPrefix("https://")
        if !isTLS && !config.allowInsecure { throw APIError.insecure }
        guard let url = URL(string: base + path) else { throw APIError.badURL }
        var req = URLRequest(url: url)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let basic = config.basicAuth {
            // Never attach credentials to a plaintext request.
            if isTLS || config.allowInsecure {
                req.setValue(basic.headerValue, forHTTPHeaderField: "Authorization")
            }
        }
        return req
    }

    private func fetch<T: Decodable>(_ type: T.Type, path: String) async throws -> T {
        let req = try request(path: path)
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw APIError.underlying(error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse {
            switch http.statusCode {
            case 200...299: break
            case 401, 403: throw APIError.unauthorized
            default: throw APIError.http(http.statusCode)
            }
        }
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw APIError.underlying(String(format: L("Decoding failed: %@"), error.localizedDescription))
        }
    }

    // MARK: - Endpoints

    func fetchCars() async throws -> [CarSummary] {
        let env = try await fetch(CarsEnvelope.self, path: "/v1/cars")
        return (env.data?.cars ?? []).compactMap { $0.toDomain() }
    }

    func fetchCarInfo(carID: Int) async throws -> CarInfo? {
        let env = try await fetch(CarsEnvelope.self, path: "/v1/cars")
        return (env.data?.cars ?? []).compactMap { $0.toInfo() }.first { $0.id == carID }
    }

    private let pageLimit = 100   // TeslaMateApi returns up to 100 rows per page

    /// Download drives, stopping pagination as soon as a page overlaps `cached` (incremental
    /// sync — past drives never change). With an empty cache this is a plain full fetch.
    /// Early-stop only engages when the server paginates newest-first; otherwise all pages
    /// are fetched as before. The result is fetched-over-cached, newest first.
    func fetchDrives(carID: Int, mergingWith cached: [DriveRecord] = []) async throws -> [DriveRecord] {
        let newestCachedID = cached.map(\.id).max()
        var all: [DriveRecord] = []
        var seenIDs = Set<Int>()
        var page = 1
        var canStopEarly = newestCachedID != nil
        while true {
            try Task.checkCancellation()
            let env = try await fetch(DrivesEnvelope.self, path: "/v1/cars/\(carID)/drives?page=\(page)&show=\(pageLimit)")
            let batch = env.data?.drives ?? []
            let records = batch.enumerated().compactMap {
                $0.element.toDomain(index: (page - 1) * pageLimit + $0.offset, units: env.data?.units)
            }
            if batch.count >= pageLimit, !records.contains(where: { !seenIDs.contains($0.id) }) {
                throw APIError.underlying(L("The history API repeated a page. Please check the server's pagination."))
            }
            seenIDs.formUnion(records.map(\.id))
            all.append(contentsOf: records)
            if page == 1 {
                let dates = batch.compactMap { $0.startDate.flatMap(VehicleState.parseDate) }
                canStopEarly = canStopEarly && HistorySync.isNewestFirst(dates: dates)
            }
            if batch.count < pageLimit { break }
            if canStopEarly,
               HistorySync.reachedCachedHistory(batchIDs: batch.compactMap(\.driveId), newestCachedID: newestCachedID) {
                break
            }
            page += 1
        }
        return HistorySync.merge(fetched: all, cached: cached) { $0.startDate }
    }

    /// Charges counterpart of `fetchDrives(carID:mergingWith:)` — same early-stop rules.
    func fetchCharges(carID: Int, mergingWith cached: [ChargeRecord] = []) async throws -> [ChargeRecord] {
        let newestCachedID = cached.map(\.id).max()
        var all: [ChargeRecord] = []
        var seenIDs = Set<Int>()
        var page = 1
        var canStopEarly = newestCachedID != nil
        while true {
            try Task.checkCancellation()
            let env = try await fetch(ChargesEnvelope.self, path: "/v1/cars/\(carID)/charges?page=\(page)&show=\(pageLimit)")
            let batch = env.data?.charges ?? []
            let records = batch.enumerated().compactMap {
                $0.element.toDomain(index: (page - 1) * pageLimit + $0.offset, units: env.data?.units)
            }
            if batch.count >= pageLimit, !records.contains(where: { !seenIDs.contains($0.id) }) {
                throw APIError.underlying(L("The history API repeated a page. Please check the server's pagination."))
            }
            seenIDs.formUnion(records.map(\.id))
            all.append(contentsOf: records)
            if page == 1 {
                let dates = batch.compactMap { $0.startDate.flatMap(VehicleState.parseDate) }
                canStopEarly = canStopEarly && HistorySync.isNewestFirst(dates: dates)
            }
            if batch.count < pageLimit { break }
            if canStopEarly,
               HistorySync.reachedCachedHistory(batchIDs: batch.compactMap(\.chargeId), newestCachedID: newestCachedID) {
                break
            }
            page += 1
        }
        return HistorySync.merge(fetched: all, cached: cached) { $0.startDate }
    }

    /// Real per-point GPS trace for a single drive, used to draw the route from the actual
    /// recorded positions (no text geocoding). Returns an empty trace if the deployment doesn't
    /// expose `drive_details` or the drive has no positions.
    func fetchDriveDetails(carID: Int, driveID: Int) async throws -> DriveTrace {
        let env = try await fetch(DriveDetailsEnvelope.self, path: "/v1/cars/\(carID)/drives/\(driveID)")
        let points = env.data?.drive?.driveDetails ?? []
        let located = points.filter { $0.coordinate != nil }
        let path = located.compactMap { $0.coordinate }
        // Elevation aligned 1:1 with the path; only meaningful when present on every point.
        let elevations = located.map { $0.elevation }
        let elevationProfile = elevations.allSatisfy { $0 != nil } ? elevations.compactMap { $0 } : []
        return DriveTrace(path: path, elevationProfile: elevationProfile)
    }

    /// Per-point charge curve (kW vs SoC) for a single session. Older / minimal TeslaMateApi
    /// deployments may not expose `charge_details`; callers fall back to the modeled curve.
    func fetchChargeCurve(carID: Int, chargeID: Int) async throws -> [ChargeCurvePoint] {
        let env = try await fetch(ChargeDetailEnvelope.self, path: "/v1/cars/\(carID)/charges/\(chargeID)")
        return (env.data?.charge?.chargeDetails ?? [])
            .compactMap { $0.toDomain() }
            .sorted { $0.date < $1.date }
    }

    /// Official battery-health snapshot (current vs new capacity & range, health %). Returns nil
    /// when the deployment doesn't expose `/battery-health` or has insufficient data.
    func fetchBatteryHealth(carID: Int) async throws -> BatteryHealthSummary? {
        let env = try await fetch(BatteryHealthEnvelope.self, path: "/v1/cars/\(carID)/battery-health")
        let isMiles = (env.data?.units?.unitOfLength ?? "km").lowercased().hasPrefix("mi")
        return env.data?.batteryHealth?.toDomain(lengthIsMiles: isMiles)
    }

    /// Firmware update history (newest first). Empty when the deployment doesn't expose `/updates`.
    func fetchUpdates(carID: Int) async throws -> [SoftwareUpdate] {
        let env = try await fetch(UpdatesEnvelope.self, path: "/v1/cars/\(carID)/updates")
        return (env.data?.updates ?? []).enumerated()
            .compactMap { $0.element.toDomain(index: $0.offset) }
            .sorted { $0.startDate > $1.startDate }
    }
}
