import XCTest
@testable import Tesstats

private final class PushURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (Int, String)
    nonisolated(unsafe) private static var handlers: [String: Handler] = [:]
    private static let lock = NSLock()

    static func register(host: String, handler: @escaping Handler) {
        lock.lock(); defer { lock.unlock() }
        handlers[host] = handler
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            Self.lock.lock()
            let handler = Self.handlers[request.url!.host!]
            Self.lock.unlock()
            let (status, body) = try handler!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                           httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

final class PushServiceTests: XCTestCase {
    func testPlainOKRegistrationAndNtfyHealthSucceedThroughProxy() async throws {
        let push = service { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Basic dXNlcjpwYXNz")
            XCTAssertEqual(request.value(forHTTPHeaderField: "CF-Access-Client-Id"), "client")
            XCTAssertEqual(request.value(forHTTPHeaderField: "CF-Access-Client-Secret"), "secret")
            switch request.url!.path {
            case "/push/register":
                XCTAssertEqual(request.httpMethod, "POST")
                return (200, "ok")
            case "/push/healthz":
                XCTAssertEqual(request.httpMethod, "GET")
                return (200, #"{"ok":true,"apnsConfigured":false,"ntfyConfigured":true,"mqttConnected":true,"apnsEnvironment":"sandbox"}"#)
            default:
                XCTFail("Unexpected endpoint")
                return (404, "not found")
            }
        }
        try await push.register(token: "0123456789abcdef", preferences: NotificationPreferences())
    }

    func testWebhookOnlyHealthWorksForReleaseBuilds() throws {
        try health(#"{"ok":true,"apnsConfigured":false,"webhookConfigured":true,"mqttConnected":true}"#)
            .validate(requiresProductionAPNs: true)
    }

    func testOlderAPNsServerWithoutNewChannelFieldsRemainsCompatible() throws {
        try health(#"{"ok":true,"apnsConfigured":true,"mqttConnected":true,"apnsEnvironment":"production"}"#)
            .validate(requiresProductionAPNs: true)
    }

    func testReleaseRequiresProductionAPNsEvenWithAdditionalChannels() throws {
        let value = try health(#"{"ok":true,"apnsConfigured":true,"ntfyConfigured":true,"mqttConnected":true,"apnsEnvironment":"sandbox"}"#)
        try value.validate(requiresProductionAPNs: false)
        XCTAssertThrowsError(try value.validate(requiresProductionAPNs: true)) { error in
            guard case let PushServiceError.rejected(status, message) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(status, 503)
            XCTAssertEqual(message, L("TestFlight requires production APNs on the push server."))
        }
    }

    func testMissingChannelAndMQTTProduceActionableErrors() throws {
        let cases: [(String, String.LocalizationValue)] = [
            (#"{"ok":true,"apnsConfigured":false,"mqttConnected":true}"#, "No notification channel is configured on the push server."),
            (#"{"ok":true,"apnsConfigured":true}"#, "Update the push server to verify background delivery."),
            (#"{"ok":true,"apnsConfigured":false,"ntfyConfigured":true,"mqttConnected":false}"#, "The push server is disconnected from TeslaMate MQTT.")
        ]
        for (json, message) in cases {
            XCTAssertThrowsError(try health(json).validate(requiresProductionAPNs: true)) { error in
                guard case let PushServiceError.rejected(status, actualMessage) = error else {
                    return XCTFail("Unexpected error: \(error)")
                }
                XCTAssertEqual(status, 503)
                XCTAssertEqual(actualMessage, L(message))
            }
        }
    }

    func testInvalidHealthBodiesAreRejectedAfterSuccessfulRegistration() async {
        for body in ["ok", "<html>Login</html>", #"{"ok":true}"#,
                     #"{"ok":false,"apnsConfigured":true,"mqttConnected":true}"#] {
            let push = service { request in
                (200, request.httpMethod == "POST" ? "ok" : body)
            }
            do {
                try await push.register(token: "0123456789abcdef", preferences: NotificationPreferences())
                XCTFail("Invalid health response accepted")
            } catch {
                guard case PushServiceError.invalidResponse = error else {
                    XCTFail("Unexpected error: \(error)"); continue
                }
            }
        }
    }

    func testHealthHTTPFailurePreservesStatusAndServerMessage() async {
        let push = service { request in
            request.httpMethod == "POST" ? (200, "ok") : (503, "proxy unavailable")
        }
        do {
            try await push.register(token: "0123456789abcdef", preferences: NotificationPreferences())
            XCTFail("Unavailable health endpoint accepted")
        } catch {
            guard case let PushServiceError.rejected(status, message) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(status, 503)
            XCTAssertEqual(message, "proxy unavailable")
        }
    }

    func testRegistrationFailureDoesNotQueryHealth() async {
        let push = service { request in
            XCTAssertEqual(request.httpMethod, "POST")
            return (401, "unauthorized")
        }
        do {
            try await push.register(token: "0123456789abcdef", preferences: NotificationPreferences())
            XCTFail("Unauthorized registration accepted")
        } catch {
            guard case let PushServiceError.rejected(status, _) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(status, 401)
        }
    }

    private func health(_ json: String) throws -> PushServiceHealth {
        try JSONDecoder().decode(PushServiceHealth.self, from: Data(json.utf8))
    }

    private func service(handler: @escaping PushURLProtocol.Handler) -> PushService {
        let host = "push-\(UUID().uuidString.lowercased()).invalid"
        PushURLProtocol.register(host: host, handler: handler)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PushURLProtocol.self]
        return PushService(baseURL: " https://\(host)/push/\n", secret: "shared-secret",
                           trust: .init(allowSelfSigned: false, pinnedPublicKeySHA256: nil),
                           basicAuth: .init(user: "user", pass: "pass"),
                           cloudflareAccess: .init(clientID: "client", clientSecret: "secret"),
                           session: URLSession(configuration: config))
    }
}
