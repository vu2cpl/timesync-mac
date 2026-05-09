import Foundation

enum TimeSource: String, CaseIterable, Identifiable, Codable {
    case ntp
    case gps
    case best

    var id: String { rawValue }
    var label: String {
        switch self {
        case .ntp: return "NTP"
        case .gps: return "GPS"
        case .best: return "Best available"
        }
    }
}

struct Preferences: Codable, Equatable {
    var ntpServer: String = "pool.ntp.org"
    // GPS is now read via gpsd over TCP. Default localhost:2947 (gpsd's standard port).
    var gpsdHost: String = "localhost"
    var gpsdPort: Int = 2947
    var refreshIntervalSeconds: Int = 30
    var preferredSource: TimeSource = .best
    var warnThresholdMs: Int = 100
    var showOffsetInMenuBar: Bool = true

    // Legacy fields, kept only so old Preferences.v1 blobs decode. Unused now —
    // gpsd owns the serial port and picks baud automatically; chrony owns clock
    // discipline so the helper-driven auto-sync was removed.
    var gpsPort: String = ""
    var gpsBaud: Int = 4800
    var autoSyncEnabled: Bool = false
    var autoSyncMinIntervalSeconds: Int = 60

    static let defaultsKey = "TimeSync.Preferences.v1"

    static func load() -> Preferences {
        guard
            let data = UserDefaults.standard.data(forKey: defaultsKey),
            let decoded = try? JSONDecoder().decode(Preferences.self, from: data)
        else {
            return Preferences()
        }
        return decoded
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Preferences.defaultsKey)
    }
}
