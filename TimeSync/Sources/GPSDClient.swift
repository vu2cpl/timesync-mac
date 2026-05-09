// SPDX-License-Identifier: MIT

import Foundation
import Network

/// A single GPS update from upstream (gpsd or otherwise). Consumed by AppStore.
struct GPSUpdate {
    enum Kind {
        case fix(gpsTime: Date, receivedAt: Date)
        case noFix
    }
    let kind: Kind
    let satellitesInView: Int?
}

/// One TPV/SKY message from gpsd. We only decode the fields we care about.
private struct GPSDMessage: Decodable {
    enum CodingKeys: String, CodingKey {
        case messageClass = "class"
        case mode, time, lat, lon
        case uSat, nSat
        case device
    }

    let messageClass: String
    // TPV fields
    let mode: Int?
    let time: String?    // ISO 8601, e.g. "2026-05-09T02:47:00.000Z"
    let lat: Double?
    let lon: Double?
    // SKY fields
    let uSat: Int?       // satellites used in fix
    let nSat: Int?       // satellites visible (not always present)
    // Common
    let device: String?
}

/// Connects to gpsd's JSON socket (default localhost:2947), parses TPV/SKY messages,
/// and emits GPSUpdate values shaped exactly like the old direct-serial GPSReader did.
/// This is the runtime replacement for `GPSReader` once gpsd is the GPS owner.
final class GPSDClient {
    private let host: String
    private let port: UInt16
    private let queue = DispatchQueue(label: "TimeSync.GPSDClient", qos: .userInitiated)

    private var connection: NWConnection?
    private var receiveBuffer = Data()
    private var lastSatsInView: Int?

    /// (sentence, arrivalTimeOfFirstByte) — matches the old GPSReader contract.
    var onUpdate: ((GPSUpdate) -> Void)?
    /// Called when the connection state changes. (connected, errorMsg)
    var onConnectionChange: ((Bool, String?) -> Void)?

    init(host: String = "localhost", port: UInt16 = 2947) {
        self.host = host
        self.port = port
    }

    func start() {
        stop()
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(integerLiteral: port)
        )
        let conn = NWConnection(to: endpoint, using: .tcp)
        conn.stateUpdateHandler = { [weak self] state in self?.handleState(state) }
        connection = conn
        conn.start(queue: queue)
    }

    func stop() {
        connection?.cancel()
        connection = nil
        receiveBuffer.removeAll(keepingCapacity: false)
        lastSatsInView = nil
    }

    // MARK: - Connection lifecycle

    private func handleState(_ state: NWConnection.State) {
        switch state {
        case .ready:
            sendWatch()
            startReceiving()
            onConnectionChange?(true, nil)
        case .failed(let err):
            onConnectionChange?(false, err.localizedDescription)
        case .cancelled:
            onConnectionChange?(false, nil)
        case .waiting(let err):
            // .waiting means the OS can't reach the endpoint right now (e.g. nothing
            // listening on :2947). Surface as a connection failure for the UI.
            onConnectionChange?(false, "waiting: \(err.localizedDescription)")
        default:
            break
        }
    }

    private func sendWatch() {
        let cmd = "?WATCH={\"enable\":true,\"json\":true};\n".data(using: .utf8)!
        connection?.send(content: cmd, completion: .contentProcessed({ [weak self] err in
            if let err {
                self?.onConnectionChange?(false, "send: \(err.localizedDescription)")
            }
        }))
    }

    // MARK: - Receive + parse

    private func startReceiving() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, err in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.handleReceived(data)
            }
            if let err {
                self.onConnectionChange?(false, "recv: \(err.localizedDescription)")
                return
            }
            if isComplete {
                self.onConnectionChange?(false, nil)
                return
            }
            // Continue draining.
            self.startReceiving()
        }
    }

    private func handleReceived(_ data: Data) {
        let arrivedAt = Date()
        receiveBuffer.append(data)
        // gpsd emits one JSON object per line, separated by \n.
        while let nlIdx = receiveBuffer.firstIndex(of: 0x0A) {
            let lineEnd = receiveBuffer.index(after: nlIdx)
            let line = receiveBuffer.subdata(in: receiveBuffer.startIndex..<nlIdx)
            receiveBuffer.removeSubrange(receiveBuffer.startIndex..<lineEnd)
            handleLine(line, arrivedAt: arrivedAt)
        }
        // Cap the buffer: a single line >32KB is malformed.
        if receiveBuffer.count > 32_768 {
            receiveBuffer.removeAll(keepingCapacity: false)
        }
    }

    private func handleLine(_ line: Data, arrivedAt: Date) {
        guard !line.isEmpty else { return }
        let msg: GPSDMessage
        do {
            msg = try JSONDecoder().decode(GPSDMessage.self, from: line)
        } catch {
            return  // ignore malformed JSON
        }
        switch msg.messageClass {
        case "TPV":
            handleTPV(msg, arrivedAt: arrivedAt)
        case "SKY":
            // Prefer uSat (satellites contributing to fix) over nSat (visible).
            if let used = msg.uSat {
                lastSatsInView = used
            } else if let visible = msg.nSat {
                lastSatsInView = visible
            }
        default:
            break  // VERSION, DEVICES, WATCH, etc.
        }
    }

    private func handleTPV(_ msg: GPSDMessage, arrivedAt: Date) {
        // mode: 0=unknown, 1=no fix, 2=2D, 3=3D
        let mode = msg.mode ?? 0
        if mode >= 2, let timeStr = msg.time, let utc = Self.parseISO8601(timeStr) {
            onUpdate?(GPSUpdate(
                kind: .fix(gpsTime: utc, receivedAt: arrivedAt),
                satellitesInView: lastSatsInView
            ))
        } else {
            onUpdate?(GPSUpdate(kind: .noFix, satellitesInView: lastSatsInView))
        }
    }

    // ISO 8601 with fractional seconds, UTC. e.g. "2026-05-09T02:47:00.000Z".
    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static func parseISO8601(_ s: String) -> Date? {
        if let d = isoFormatter.date(from: s) { return d }
        // Fallback for the no-fractional-seconds form.
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}
