import Foundation

enum PushRegistrationState: Equatable, Sendable {
    case disabled
    case registering
    case registered
    case failed
}

struct PushServiceHealth: Decodable, Sendable {
    let ok: Bool
    let apnsConfigured: Bool
    let ntfyConfigured: Bool?
    let webhookConfigured: Bool?
    let mqttConnected: Bool?
    let apnsEnvironment: String?

    func validate(requiresProductionAPNs: Bool) throws {
        guard ok else { throw PushServiceError.invalidResponse }
        guard apnsConfigured || ntfyConfigured == true || webhookConfigured == true else {
            throw PushServiceError.rejected(status: 503, message: L("No notification channel is configured on the push server."))
        }
        guard let mqttConnected else {
            throw PushServiceError.rejected(status: 503, message: L("Update the push server to verify background delivery."))
        }
        guard mqttConnected else {
            throw PushServiceError.rejected(status: 503, message: L("The push server is disconnected from TeslaMate MQTT."))
        }
        if requiresProductionAPNs && apnsConfigured && apnsEnvironment != "production" {
            throw PushServiceError.rejected(status: 503, message: L("TestFlight requires production APNs on the push server."))
        }
    }
}

enum PushServiceError: LocalizedError, Sendable {
    case invalidURL
    case invalidResponse
    case rejected(status: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: "The push service URL must use HTTPS."
        case .invalidResponse: "The push service returned an invalid response."
        case let .rejected(status, message): "Push service error \(status): \(message)"
        }
    }
}

/// Registers this device's APNs token with the optional Tesstats push microservice,
/// so it can deliver immediate alerts (Sentry/security) when the app is closed.
/// No-op unless the user configures a push service URL in Settings.
final class PushService: Sendable {
    private let baseURL: String
    private let secret: String
    private let session: URLSession

    init(baseURL: String, secret: String, trust: TrustConfig, basicAuth: BasicAuth?,
         cloudflareAccess: CloudflareAccessToken? = nil, session: URLSession? = nil) {
        self.baseURL = baseURL
        self.secret = secret
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 15
        self.session = session ?? URLSession(configuration: cfg, delegate: PushTrustDelegate(trust: trust), delegateQueue: nil)
        self.basicAuth = basicAuth
        self.cloudflareAccess = cloudflareAccess
    }

    private let basicAuth: BasicAuth?
    private let cloudflareAccess: CloudflareAccessToken?

    /// The push service usually sits behind the same proxy as TeslaMate, so it gets the same
    /// credentials. Only ever called for https:// URLs.
    private func authorize(_ request: inout URLRequest) {
        if let basicAuth { request.setValue(basicAuth.headerValue, forHTTPHeaderField: "Authorization") }
        for (name, value) in cloudflareAccess?.headers ?? [] {
            request.setValue(value, forHTTPHeaderField: name)
        }
    }

    func register(token: String, preferences: NotificationPreferences, locationPrices: [String: Double] = [:]) async throws {
        let data = try JSONEncoder().encode(preferences)
        var preferencesObject = (try JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        preferencesObject["locationPrices"] = locationPrices
        try await post(path: "/register", body: [
            "token": token,
            "secret": secret,
            "preferences": preferencesObject
        ])
        // Token acceptance alone does not mean the bridge is receiving vehicle events.
        var request = URLRequest(url: try endpoint("/healthz"))
        authorize(&request)
        let (healthData, response) = try await session.data(for: request)
        try validateResponse(response, data: healthData)
        guard let health = try? JSONDecoder().decode(PushServiceHealth.self, from: healthData) else {
            throw PushServiceError.invalidResponse
        }
        #if DEBUG
        try health.validate(requiresProductionAPNs: false)
        #else
        try health.validate(requiresProductionAPNs: true)
        #endif
    }

    func registerLiveActivity(token: String, carID: Int, config: ServerConfig) async throws {
        try await post(path: "/register-live-activity", body: [
            "token": token,
            "secret": secret,
            "carId": carID,
            "isImperial": config.units == .imperial,
            "languageCode": LanguageManager.resolvedLanguageCode(config.languageCode),
            "accentColorHex": config.accentColorHex,
            "rangeKind": config.rangeKind.rawValue
        ])
    }

    func sendTest(title: String, message: String) async throws {
        try await post(path: "/test", body: [
            "secret": secret,
            "title": title,
            "message": message
        ])
    }

    private func endpoint(_ path: String) throws -> URL {
        var base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        guard !base.isEmpty, base.lowercased().hasPrefix("https://"),
              let url = URL(string: base + path) else { throw PushServiceError.invalidURL }
        return url
    }

    private func post(path: String, body: [String: Any]) async throws {
        var req = URLRequest(url: try endpoint(path))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        authorize(&req)
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: req)
        try validateResponse(response, data: data)
    }

    private func validateResponse(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw PushServiceError.invalidResponse }
        guard 200..<300 ~= http.statusCode else {
            let message = String(data: data, encoding: .utf8) ?? "unknown error"
            throw PushServiceError.rejected(status: http.statusCode, message: message)
        }
    }
}

private final class PushTrustDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    let trust: TrustConfig
    init(trust: TrustConfig) { self.trust = trust }
    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil); return
        }
        if TrustEvaluator.evaluate(serverTrust, config: trust) {
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}
