import Foundation

struct GPSUpdate {
    enum Kind {
        case fix(gpsTime: Date, receivedAt: Date)
        case noFix
    }
    let kind: Kind
    let satellitesInView: Int?
}

/// Owns a SerialPort + NMEAParser and emits high-level GPSUpdates.
final class GPSReader {
    private let port: String
    private let baud: Int32
    private let serial = SerialPort()
    private let parser = NMEAParser()

    private var lastSatsInView: Int?

    /// Emitted for every relevant sentence (fix or no-fix). Called on the serial port's queue.
    var onUpdate: ((GPSUpdate) -> Void)?

    init(port: String, baud: Int32) {
        self.port = port
        self.baud = baud
    }

    func start() throws {
        parser.onSentence = { [weak self] sentence, arrivedAt in
            self?.handle(sentence: sentence, arrivedAt: arrivedAt)
        }
        serial.onData = { [weak self] data, arrivedAt in
            self?.parser.feed(data, arrivedAt: arrivedAt)
        }
        serial.onClosed = { [weak self] _ in
            self?.lastSatsInView = nil
        }
        try serial.open(path: port, baud: baud)
    }

    func stop() {
        serial.close()
    }

    // MARK: - Sentence routing

    private func handle(sentence: NMEASentence, arrivedAt: Date) {
        switch sentence {
        case .rmc(let rmc):
            if rmc.status == .active, let utc = rmc.utc {
                onUpdate?(GPSUpdate(
                    kind: .fix(gpsTime: utc, receivedAt: arrivedAt),
                    satellitesInView: lastSatsInView
                ))
            } else {
                onUpdate?(GPSUpdate(kind: .noFix, satellitesInView: lastSatsInView))
            }
        case .zda(let zda):
            // ZDA carries time even without a position fix on most receivers.
            onUpdate?(GPSUpdate(
                kind: .fix(gpsTime: zda.utc, receivedAt: arrivedAt),
                satellitesInView: lastSatsInView
            ))
        case .gsv(let gsv):
            lastSatsInView = gsv.satellitesInView
        case .other, .invalid:
            break
        }
    }
}
