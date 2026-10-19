import Foundation

struct DiagLine: Identifiable, Sendable {
    let id = UUID()
    var ok: Bool
    var message: String
}

struct ConnectionDiagnostics: Sendable {
    var mqtt: [DiagLine] = []
    var api: [DiagLine] = []
    var finished = false
}

/// Validates MQTT, the history API and (in API-only mode) the live status endpoint
/// independently and returns human-readable diagnostics (TLS OK, auth OK, topics received…).
struct ConnectionTester: Sendable {

    func testMQTT(config: MQTTClient.Config, topicRoot: String) async -> [DiagLine] {
        var lines: [DiagLine] = []
        let client = MQTTClient(config: config)
        let topics = ["\(topicRoot)/+/display_name", "\(topicRoot)/+/state"]
        do {
            try await client.connect(topics: topics)
            lines.append(DiagLine(ok: true, message: L("TLS handshake succeeded")))
            lines.append(DiagLine(ok: true, message: L("MQTT broker accepted credentials")))
            if let msg = await firstMessage(client.publishes, timeout: 5) {
                lines.append(DiagLine(ok: true, message: L("Received topic: \(msg.topic)")))
            } else {
                lines.append(DiagLine(ok: false, message: L("Connected, but no TeslaMate topics arrived in 5s. Check the topic namespace.")))
            }
            await client.disconnect()
        } catch {
            lines.append(DiagLine(ok: false, message: error.localizedDescription))
        }
        return lines
    }

    func testAPI(config: HistoryAPIService.Config) async -> [DiagLine] {
        var lines: [DiagLine] = []
        guard !config.baseURL.isEmpty else {
            return [DiagLine(ok: false, message: L("No history API URL configured (optional)."))]
        }
        let service = HistoryAPIService(config: config)
        do {
            let cars = try await service.fetchCars()
            lines.append(DiagLine(ok: true, message: L("TLS + HTTP reachable")))
            if config.basicAuth != nil {
                lines.append(DiagLine(ok: true, message: L("Basic Auth accepted")))
            }
            if config.cloudflareAccess != nil {
                lines.append(DiagLine(ok: true, message: L("Cloudflare Access service token accepted")))
            }
            lines.append(DiagLine(ok: true, message: L("Found \(cars.count) car(s) via TeslaMateApi")))
        } catch {
            lines.append(DiagLine(ok: false, message: (error as? APIError)?.errorDescription ?? error.localizedDescription))
        }
        return lines
    }

    /// API-only mode: the live values come from `/status`, which needs TeslaMateApi's own
    /// MQTT connection, so check that endpoint and not just the history routes.
    func testLiveStatus(config: HistoryAPIService.Config) async -> [DiagLine] {
        guard !config.baseURL.isEmpty else {
            return [DiagLine(ok: false, message: L("API-only mode needs the TeslaMateApi URL."))]
        }
        let service = HistoryAPIService(config: config)
        do {
            guard let car = try await service.fetchCars().first else {
                return [DiagLine(ok: false, message: L("TeslaMateApi returned no cars, so there is no live status to read."))]
            }
            guard let status = try await service.fetchLiveStatus(carID: car.id) else {
                return [DiagLine(ok: false, message: L("Live status reachable, but TeslaMateApi has no data for this car yet. Check its MQTT settings (MQTT_HOST)."))]
            }
            var state = VehicleState(carID: car.id)
            status.apply(to: &state)
            let level = state.batteryLevel.map { "\($0) %" } ?? "—"
            return [DiagLine(ok: true, message: String(format: L("Live status OK: %@ · %@ · battery %@"),
                                                       car.title, (state.state ?? .unknown).label, level))]
        } catch {
            return [DiagLine(ok: false, message: (error as? APIError)?.errorDescription ?? error.localizedDescription)]
        }
    }

    private func firstMessage(_ stream: AsyncStream<MQTTPublish>, timeout: TimeInterval) async -> MQTTPublish? {
        await withTaskGroup(of: MQTTPublish?.self) { group in
            group.addTask {
                for await m in stream { return m }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(timeout))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}
