// SPDX-License-Identifier: MIT

import Foundation
import Network

struct NTPResult {
    let server: String
    let stratum: UInt8
    let originateTime: Date     // T1 — system clock when we sent
    let receiveTime: Date       // T2 — server clock when it received
    let transmitTime: Date      // T3 — server clock when it sent reply
    let destinationTime: Date   // T4 — system clock when we received reply

    /// Standard NTP offset = ((T2 - T1) + (T3 - T4)) / 2.
    /// Positive means the server is ahead of our system clock (i.e. we are behind).
    var serverAheadByMs: Double {
        let t1 = originateTime.timeIntervalSince1970
        let t2 = receiveTime.timeIntervalSince1970
        let t3 = transmitTime.timeIntervalSince1970
        let t4 = destinationTime.timeIntervalSince1970
        return (((t2 - t1) + (t3 - t4)) / 2.0) * 1000.0
    }

    /// "System clock minus reference", i.e. positive = system is ahead of true time.
    var systemAheadOfReferenceMs: Double { -serverAheadByMs }

    var roundTripDelayMs: Double {
        let t1 = originateTime.timeIntervalSince1970
        let t2 = receiveTime.timeIntervalSince1970
        let t3 = transmitTime.timeIntervalSince1970
        let t4 = destinationTime.timeIntervalSince1970
        return ((t4 - t1) - (t3 - t2)) * 1000.0
    }
}

enum NTPError: Error, CustomStringConvertible {
    case timeout
    case shortPacket
    case invalidStratum(UInt8)
    case kissOfDeath
    case connectionFailed(String)

    var description: String {
        switch self {
        case .timeout: return "NTP request timed out"
        case .shortPacket: return "Short NTP packet"
        case .invalidStratum(let s): return "Invalid stratum (\(s))"
        case .kissOfDeath: return "Server returned KoD"
        case .connectionFailed(let s): return s
        }
    }
}

final class NTPClient {
    /// Seconds between 1900-01-01 (NTP epoch) and 1970-01-01 (Unix epoch).
    private static let ntpEpochOffset: Double = 2_208_988_800

    func query(server: String, port: UInt16 = 123, timeout: TimeInterval = 4.0) async throws -> NTPResult {
        let host = NWEndpoint.Host(server)
        let nport = NWEndpoint.Port(rawValue: port)!
        let connection = NWConnection(host: host, port: nport, using: .udp)
        defer { connection.cancel() }

        try await waitUntilReady(connection, timeout: timeout)

        let t1 = Date()
        let request = Self.buildRequest(transmitTime: t1)
        try await send(connection: connection, data: request)

        let response = try await receive(connection: connection, timeout: timeout)
        let t4 = Date()

        guard response.count >= 48 else { throw NTPError.shortPacket }

        let stratum = response[1]
        if stratum == 0 { throw NTPError.kissOfDeath }
        guard stratum < 16 else { throw NTPError.invalidStratum(stratum) }

        let t2 = Self.parseTimestamp(response, offset: 32)
        let t3 = Self.parseTimestamp(response, offset: 40)

        return NTPResult(
            server: server,
            stratum: stratum,
            originateTime: t1,
            receiveTime: t2,
            transmitTime: t3,
            destinationTime: t4
        )
    }

    // MARK: - Packet helpers

    private static func buildRequest(transmitTime: Date) -> Data {
        var packet = Data(count: 48)
        // LI = 0, VN = 4, Mode = 3 (client) → 0b00 100 011 = 0x23
        packet[0] = 0x23
        // Place T1 in the transmit field (bytes 40..47). Server echoes it back as "originate".
        let ntpSeconds = transmitTime.timeIntervalSince1970 + ntpEpochOffset
        let secs = UInt32(ntpSeconds)
        let frac = UInt32((ntpSeconds - Double(secs)) * 4_294_967_296.0)
        writeUInt32BE(secs, into: &packet, at: 40)
        writeUInt32BE(frac, into: &packet, at: 44)
        return packet
    }

    private static func parseTimestamp(_ data: Data, offset: Int) -> Date {
        let secs = readUInt32BE(data, at: offset)
        let frac = readUInt32BE(data, at: offset + 4)
        let ntpSeconds = Double(secs) + Double(frac) / 4_294_967_296.0
        return Date(timeIntervalSince1970: ntpSeconds - ntpEpochOffset)
    }

    private static func readUInt32BE(_ data: Data, at offset: Int) -> UInt32 {
        let b = data
        return (UInt32(b[offset]) << 24)
             | (UInt32(b[offset + 1]) << 16)
             | (UInt32(b[offset + 2]) << 8)
             |  UInt32(b[offset + 3])
    }

    private static func writeUInt32BE(_ value: UInt32, into data: inout Data, at offset: Int) {
        data[offset]     = UInt8((value >> 24) & 0xFF)
        data[offset + 1] = UInt8((value >> 16) & 0xFF)
        data[offset + 2] = UInt8((value >> 8) & 0xFF)
        data[offset + 3] = UInt8(value & 0xFF)
    }

    // MARK: - Network plumbing

    private final class FireOnce {
        private let lock = NSLock()
        private var fired = false
        func tryFire(_ work: () -> Void) {
            lock.lock(); defer { lock.unlock() }
            if fired { return }
            fired = true
            work()
        }
    }

    private func waitUntilReady(_ connection: NWConnection, timeout: TimeInterval) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                    let once = FireOnce()
                    connection.stateUpdateHandler = { state in
                        switch state {
                        case .ready:
                            once.tryFire { cont.resume() }
                        case .failed(let err):
                            once.tryFire { cont.resume(throwing: NTPError.connectionFailed(err.localizedDescription)) }
                        case .cancelled:
                            once.tryFire { cont.resume(throwing: NTPError.connectionFailed("cancelled")) }
                        default:
                            break
                        }
                    }
                    connection.start(queue: .global(qos: .utility))
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw NTPError.timeout
            }
            try await group.next()
            group.cancelAll()
        }
    }

    private func send(connection: NWConnection, data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed({ err in
                if let err = err {
                    cont.resume(throwing: NTPError.connectionFailed(err.localizedDescription))
                } else {
                    cont.resume()
                }
            }))
        }
    }

    private func receive(connection: NWConnection, timeout: TimeInterval) async throws -> Data {
        return try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
                    let once = FireOnce()
                    connection.receiveMessage { data, _, _, err in
                        if let err = err {
                            once.tryFire { cont.resume(throwing: NTPError.connectionFailed(err.localizedDescription)) }
                        } else if let data = data, !data.isEmpty {
                            once.tryFire { cont.resume(returning: data) }
                        } else {
                            once.tryFire { cont.resume(throwing: NTPError.shortPacket) }
                        }
                    }
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw NTPError.timeout
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
}
