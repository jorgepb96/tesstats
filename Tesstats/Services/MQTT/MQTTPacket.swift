import Foundation

// Minimal, dependency-free MQTT 3.1.1 wire-format encoder + streaming decoder.
// Only the subset needed for a read-only TeslaMate subscriber: CONNECT, SUBSCRIBE,
// PUBACK, PINGREQ, DISCONNECT (outbound) and CONNACK, SUBACK, PUBLISH, PINGRESP (inbound).

struct MQTTPublish: Sendable, Equatable {
    let topic: String
    let payload: String
}

enum MQTTIncoming: Sendable {
    case connack(accepted: Bool, code: UInt8)
    case suback
    case publish(MQTTPublish, qos: UInt8, packetID: UInt16?)
    case pingResp
    case other(type: UInt8)
}

enum MQTTEncoder {
    /// Encode the MQTT "remaining length" as a variable-length integer.
    static func remainingLength(_ length: Int) -> [UInt8] {
        var value = length
        var bytes = [UInt8]()
        repeat {
            var digit = UInt8(value % 128)
            value /= 128
            if value > 0 { digit |= 0x80 }
            bytes.append(digit)
        } while value > 0
        return bytes
    }

    private static func string(_ s: String) -> [UInt8] {
        let utf8 = Array(s.utf8)
        let len = UInt16(utf8.count)
        return [UInt8(len >> 8), UInt8(len & 0xFF)] + utf8
    }

    static func connect(clientID: String, username: String?, password: String?, keepAlive: UInt16) -> Data {
        var variableHeader = string("MQTT")          // protocol name
        variableHeader.append(0x04)                  // protocol level 4 (3.1.1)

        var flags: UInt8 = 0x02                       // clean session
        if username != nil { flags |= 0x80 }
        if password != nil { flags |= 0x40 }
        variableHeader.append(flags)
        variableHeader.append(UInt8(keepAlive >> 8))
        variableHeader.append(UInt8(keepAlive & 0xFF))

        var payload = string(clientID)
        if let username { payload += string(username) }
        if let password { payload += string(password) }

        let body = variableHeader + payload
        return Data([0x10] + remainingLength(body.count) + body)
    }

    static func subscribe(topics: [String], packetID: UInt16, qos: UInt8 = 0) -> Data {
        var body: [UInt8] = [UInt8(packetID >> 8), UInt8(packetID & 0xFF)]
        for topic in topics {
            body += string(topic)
            body.append(qos)
        }
        return Data([0x82] + remainingLength(body.count) + body)   // 0x82 = SUBSCRIBE w/ required flags
    }

    static func puback(packetID: UInt16) -> Data {
        Data([0x40, 0x02, UInt8(packetID >> 8), UInt8(packetID & 0xFF)])
    }

    static let pingReq = Data([0xC0, 0x00])
    static let disconnect = Data([0xE0, 0x00])
}

/// Stateful byte parser that reassembles MQTT control packets from a TCP/WebSocket stream.
final class MQTTByteParser {
    private var buffer = [UInt8]()

    func append(_ data: Data) { buffer.append(contentsOf: data) }

    /// Returns the next complete packet, or nil if more bytes are needed.
    func next() -> MQTTIncoming? {
        guard buffer.count >= 2 else { return nil }
        let header = buffer[0]
        let type = header >> 4

        // Decode remaining length varint.
        var multiplier = 1
        var length = 0
        var index = 1
        while true {
            guard index < buffer.count else { return nil }   // need more bytes
            let digit = buffer[index]
            length += Int(digit & 0x7F) * multiplier
            index += 1
            if digit & 0x80 == 0 { break }
            multiplier *= 128
            if multiplier > 128 * 128 * 128 { // malformed
                buffer.removeAll()
                return nil
            }
        }

        let total = index + length
        guard buffer.count >= total else { return nil }       // packet not fully arrived

        let packetFlags = header & 0x0F
        let variable = Array(buffer[index..<total])
        buffer.removeFirst(total)                              // consume

        switch type {
        case 2: // CONNACK
            let code = variable.count >= 2 ? variable[1] : 0xFF
            return .connack(accepted: code == 0, code: code)
        case 9: // SUBACK
            return .suback
        case 3: // PUBLISH
            return parsePublish(flags: packetFlags, variable: variable)
        case 13: // PINGRESP
            return .pingResp
        default:
            return .other(type: type)
        }
    }

    private func parsePublish(flags: UInt8, variable: [UInt8]) -> MQTTIncoming? {
        let qos = (flags >> 1) & 0x03
        var cursor = 0
        guard variable.count >= 2 else { return nil }
        let topicLen = Int(variable[0]) << 8 | Int(variable[1])
        cursor = 2
        guard variable.count >= cursor + topicLen else { return nil }
        let topicBytes = Array(variable[cursor..<cursor + topicLen])
        cursor += topicLen
        let topic = String(decoding: topicBytes, as: UTF8.self)

        var packetID: UInt16?
        if qos > 0 {
            guard variable.count >= cursor + 2 else { return nil }
            packetID = UInt16(variable[cursor]) << 8 | UInt16(variable[cursor + 1])
            cursor += 2
        }
        let payloadBytes = cursor <= variable.count ? Array(variable[cursor...]) : []
        let payload = String(decoding: payloadBytes, as: UTF8.self)
        return .publish(MQTTPublish(topic: topic, payload: payload), qos: qos, packetID: packetID)
    }
}
