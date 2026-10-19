import Foundation

enum APIError: Error, LocalizedError {
    case notConfigured
    case badURL
    case unauthorized
    case cloudflareAccess
    case http(Int)
    case insecure
    case underlying(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: L("No history API (TeslaMateApi) URL configured.")
        case .badURL: L("The API URL is invalid.")
        case .unauthorized: L("Authentication failed (check Basic Auth or Cloudflare Access credentials).")
        case .cloudflareAccess: L("Cloudflare Access blocked the request. Turn on Cloudflare Access in Settings and check the service token's Client ID and Client Secret.")
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
/// instance over HTTPS. Basic Auth (reverse proxy) and a Cloudflare Access service token are
/// sent as explicit headers, only over TLS. Decoding is lenient so version differences
/// degrade gracefully.
final class HistoryAPIService: Sendable {
    struct Config: Sendable {
        var baseURL: String
        var basicAuth: BasicAuth?
        var cloudflareAccess: CloudflareAccessToken?
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
        // Never attach credentials to a plaintext request.
        if isTLS || config.allowInsecure {
            if let basic = config.basicAuth {
                req.setValue(basic.headerValue, forHTTPHeaderField: "Authorization")
            }
            for (name, value) in config.cloudflareAccess?.headers ?? [] {
                req.setValue(value, forHTTPHeaderField: name)
            }
        }
        return req
    }

    /// Performs the request and returns the body with its HTTP status (200 if not HTTP).
    private func send(path: String) async throws -> (Data, Int) {
        let req = try request(path: path)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw APIError.underlying(error.localizedDescription)
        }
        let http = response as? HTTPURLResponse
        if let http, Self.isCloudflareAccessLogin(http) { throw APIError.cloudflareAccess }
        return (data, http?.statusCode ?? 200)
    }

    /// Cloudflare Access answers a request without a valid service token by redirecting it to
    /// its login page. URLSession follows the redirect, so the login HTML arrives as a 200 from
    /// `<team>.cloudflareaccess.com` and would otherwise surface as a baffling decoding error.
    static func isCloudflareAccessLogin(_ response: HTTPURLResponse) -> Bool {
        var urls = [response.url]
        if (300...399).contains(response.statusCode),
           let location = response.value(forHTTPHeaderField: "Location") {
            urls.append(URL(string: location, relativeTo: response.url)?.absoluteURL)
        }
        return urls.contains { url in
            guard let url else { return false }
            let host = url.host?.lowercased() ?? ""
            return host == "cloudflareaccess.com" || host.hasSuffix(".cloudflareaccess.com")
                || url.path.hasPrefix("/cdn-cgi/access/")
        }
    }

    private func fetch<T: Decodable>(_ type: T.Type, path: String) async throws -> T {
        let (data, status) = try await send(path: path)
        switch status {
        case 200...299: break
        case 401, 403: throw APIError.unauthorized
        default: throw APIError.http(status)
        }
        return try decode(T.self, from: data)
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
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

    /// Live snapshot from `/status`, which TeslaMateApi serves from its own MQTT subscription.
    /// Returns nil while TeslaMateApi has not received any topic for this car yet.
    func fetchLiveStatus(carID: Int) async throws -> LiveStatusDTO? {
        let (data, status) = try await send(path: "/v1/cars/\(carID)/status")
        let serverError = (try? JSONDecoder().decode(APIErrorBody.self, from: data))?.error
        switch status {
        case 200...299: break
        case 401, 403: throw APIError.unauthorized
        case 404: throw APIError.underlying(L("TeslaMateApi has no live status endpoint at this URL. Check the base URL or update TeslaMateApi."))
        case 501: throw APIError.underlying(L("TeslaMateApi runs with MQTT disabled (DISABLE_MQTT=true), so it cannot provide live status."))
        default:
            if serverError?.localizedCaseInsensitiveContains("mqtt") == true {
                throw APIError.underlying(L("TeslaMateApi is not connected to its MQTT broker, so it cannot provide live status."))
            }
            throw APIError.http(status)
        }
        if let serverError {
            // HTTP 200 + error: "no info on this car ID" just means no topic has arrived yet.
            if serverError.localizedCaseInsensitiveContains("no info") { return nil }
            throw APIError.underlying(serverError)
        }
        return try decode(LiveStatusEnvelope.self, from: data).data
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
