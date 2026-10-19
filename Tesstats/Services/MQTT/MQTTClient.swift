import Foundation
import Network
import Security

struct BasicAuth: Sendable, Equatable {
    let user: String
    let pass: String
    var headerValue: String { "Basic " + Data("\(user):\(pass)".utf8).base64EncodedString() }
}

/// Cloudflare Access service token (Zero Trust → Access → Service credentials). With both
/// headers present Access lets a non-browser client through instead of redirecting it to the
/// interactive login page.
struct CloudflareAccessToken: Sendable, Equatable {
    let clientID: String
    let clientSecret: String
    var headers: [(String, String)] {
        [("CF-Access-Client-Id", clientID), ("CF-Access-Client-Secret", clientSecret)]
    }
}

/// One-shot guard so a continuation is only resumed once even though the callback
/// may fire on a serial queue multiple times.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func run(_ block: () -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard !done else { return }
        done = true
        block()
    }
}

enum MQTTError: Error, LocalizedError {
    case connectionRefused(UInt8)
    case timeout
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .connectionRefused(let code): String(format: L("MQTT connection refused (code %@)"), String(code))
        case .timeout: L("MQTT connection timed out")
        case .transport(let m): m
        }
    }
}

/// A read-only MQTT 3.1.1 subscriber built directly on Network.framework.
/// Supports `mqtts` (TLS) and `wss` (WebSocket Secure, with optional Basic Auth and a
/// Cloudflare Access service token on the handshake), custom-CA trust and public-key pinning.
/// Emits published messages as an `AsyncStream`; the stream finishing signals a dropped
/// connection to the caller.
actor MQTTClient {
    struct Config: Sendable {
        var host: String
        var port: Int
        var transport: MQTTTransport
        var websocketPath: String
        var username: String?
        var password: String?
        var clientID: String
        var basicAuth: BasicAuth?
        var cloudflareAccess: CloudflareAccessToken?
        var trust: TrustConfig
        var keepAlive: UInt16 = 30
    }

    private let config: Config
    private let queue = DispatchQueue(label: "com.tesstats.mqtt")
    private let parser = MQTTByteParser()

    private var connection: NWConnection?
    private var receiveTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    private var connackContinuation: CheckedContinuation<UInt8, Error>?
    private var packetID: UInt16 = 0

    private let stream: AsyncStream<MQTTPublish>
    private let continuation: AsyncStream<MQTTPublish>.Continuation

    init(config: Config) {
        self.config = config
        (stream, continuation) = AsyncStream<MQTTPublish>.makeStream()
    }

    nonisolated var publishes: AsyncStream<MQTTPublish> { stream }

    // MARK: - Lifecycle

    func connect(topics: [String]) async throws {
        let connection = makeConnection()
        self.connection = connection
        try await waitUntilReady(connection)

        startReceiveLoop()
        try await sendData(MQTTEncoder.connect(
            clientID: config.clientID,
            username: config.username,
            password: config.password,
            keepAlive: config.keepAlive))

        let code = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<UInt8, Error>) in
            connackContinuation = cont
        }
        guard code == 0 else { throw MQTTError.connectionRefused(code) }

        if !topics.isEmpty {
            packetID &+= 1
            try await sendData(MQTTEncoder.subscribe(topics: topics, packetID: packetID))
        }
        startPing()
    }

    func disconnect() {
        pingTask?.cancel(); pingTask = nil
        receiveTask?.cancel(); receiveTask = nil
        if let connection {
            connection.send(content: MQTTEncoder.disconnect, completion: .contentProcessed { _ in })
            connection.cancel()
        }
        connection = nil
        continuation.finish()
        if let c = connackContinuation { connackContinuation = nil; c.resume(throwing: CancellationError()) }
    }

    // MARK: - Connection setup

    private func makeConnection() -> NWConnection {
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        let trust = config.trust
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, secTrustRef, complete in
            let secTrust = sec_trust_copy_ref(secTrustRef).takeRetainedValue()
            complete(TrustEvaluator.evaluate(secTrust, config: trust))
        }, queue)

        switch config.transport {
        case .tls:
            let params = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
            let endpoint = NWEndpoint.hostPort(
                host: NWEndpoint.Host(config.host),
                port: NWEndpoint.Port(rawValue: UInt16(config.port)) ?? 8883)
            return NWConnection(to: endpoint, using: params)

        case .websocket:
            let params = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
            let ws = NWProtocolWebSocket.Options()
            ws.autoReplyPing = true
            // MQTT-over-WebSocket uses the "mqtt" subprotocol.
            ws.setSubprotocols(["mqtt"])
            var headers: [(String, String)] = []
            if let basic = config.basicAuth { headers.append(("Authorization", basic.headerValue)) }
            if let access = config.cloudflareAccess { headers += access.headers }
            if !headers.isEmpty { ws.setAdditionalHeaders(headers) }
            params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
            let urlString = "wss://\(config.host):\(config.port)\(config.websocketPath)"
            let endpoint = NWEndpoint.url(URL(string: urlString)!)
            return NWConnection(to: endpoint, using: params)
        }
    }

    private func waitUntilReady(_ connection: NWConnection) async throws {
        let guardOnce = ResumeOnce()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guardOnce.run { cont.resume() }
                case .failed(let error), .waiting(let error):
                    guardOnce.run { cont.resume(throwing: error) }
                case .cancelled:
                    guardOnce.run { cont.resume(throwing: CancellationError()) }
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
        // Once ready, route later drops to stream termination so the caller can reconnect.
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                Task { await self?.handleDrop() }
            default:
                break
            }
        }
    }

    private func handleDrop() {
        continuation.finish()
        if let c = connackContinuation { connackContinuation = nil; c.resume(throwing: MQTTError.transport(L("Connection dropped"))) }
    }

    // MARK: - I/O

    private func sendData(_ data: Data) async throws {
        guard let connection else { throw MQTTError.transport(L("Not connected")) }
        let context: NWConnection.ContentContext
        if config.transport == .websocket {
            let meta = NWProtocolWebSocket.Metadata(opcode: .binary)
            context = NWConnection.ContentContext(identifier: "mqtt", metadata: [meta])
        } else {
            context = .defaultMessage
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: data, contentContext: context, isComplete: true,
                            completion: .contentProcessed { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            })
        }
    }

    private func startReceiveLoop() {
        receiveTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let result = await self.receiveOnce()
                switch result {
                case .data(let data):
                    await self.ingest(data)
                case .closed:
                    await self.handleDrop()
                    return
                }
            }
        }
    }

    private enum ReceiveResult { case data(Data); case closed }

    private func receiveOnce() async -> ReceiveResult {
        guard let connection else { return .closed }
        return await withCheckedContinuation { (cont: CheckedContinuation<ReceiveResult, Never>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { data, _, isComplete, error in
                if let data, !data.isEmpty {
                    cont.resume(returning: .data(data))
                } else if isComplete || error != nil {
                    cont.resume(returning: .closed)
                } else {
                    cont.resume(returning: .data(Data()))
                }
            }
        }
    }

    private func ingest(_ data: Data) async {
        parser.append(data)
        while let packet = parser.next() {
            await handle(packet)
        }
    }

    private func handle(_ packet: MQTTIncoming) async {
        switch packet {
        case .connack(_, let code):
            if let c = connackContinuation { connackContinuation = nil; c.resume(returning: code) }
        case .publish(let pub, let qos, let packetID):
            continuation.yield(pub)
            if qos == 1, let pid = packetID {
                try? await sendData(MQTTEncoder.puback(packetID: pid))
            }
        case .pingResp, .suback, .other:
            break
        }
    }

    private func startPing() {
        let interval = max(5, Int(config.keepAlive) - 5)
        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                if Task.isCancelled { return }
                await self?.sendPing()
            }
        }
    }

    private func sendPing() async {
        try? await sendData(MQTTEncoder.pingReq)
    }
}
