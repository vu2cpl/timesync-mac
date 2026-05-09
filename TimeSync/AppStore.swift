import Combine
import Foundation
import ServiceManagement
import SwiftUI

@MainActor
final class AppStore: ObservableObject {
    @Published var preferences: Preferences
    @Published var ntpState = SourceState()
    @Published var gpsState = SourceState()
    @Published var availableSerialPorts: [String] = []
    @Published var lastSyncError: String?

    // Mirrored from helperClient so views update without nested-observable plumbing.
    @Published var helperStatus: SMAppService.Status = .notRegistered
    @Published var helperLastError: String?
    @Published var helperVersion: String?
    @Published var lastHelperSync: HelperSyncRecord?

    let helperClient = HelperClient()

    private let ntpClient = NTPClient()
    private var gpsReader: GPSReader?
    private var ntpPollTask: Task<Void, Never>?
    private var prefsBag = Set<AnyCancellable>()
    private var lastAutoSyncAt: Date?

    init() {
        self.preferences = Preferences.load()
        refreshAvailableSerialPorts()

        // Auto-pick the GPS port if we recognize the FTDI serial number from prior sessions
        if preferences.gpsPort.isEmpty {
            if let likely = availableSerialPorts.first(where: { $0.contains("usbserial") && !$0.contains("A50285BI") }) {
                preferences.gpsPort = likely
            }
        }

        // Persist + react to preference changes (debounce so we don't thrash on every keystroke)
        $preferences
            .removeDuplicates()
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] prefs in
                prefs.save()
                self?.applyPreferences(prefs)
            }
            .store(in: &prefsBag)

        // Persist immediately too (so first-launch defaults are written)
        preferences.save()

        // Mirror helperClient's published properties into ours.
        helperClient.$status.receive(on: DispatchQueue.main).assign(to: &$helperStatus)
        helperClient.$lastError.receive(on: DispatchQueue.main).assign(to: &$helperLastError)
        helperClient.$helperVersion.receive(on: DispatchQueue.main).assign(to: &$helperVersion)
        helperClient.$lastSync
            .map { tuple in tuple.map { HelperSyncRecord(at: $0.date, appliedOffsetMs: $0.appliedOffsetMs) } }
            .receive(on: DispatchQueue.main)
            .assign(to: &$lastHelperSync)

        startNTPPolling()
        restartGPS()
    }

    // MARK: - Helper lifecycle (delegates to HelperClient)

    func installHelper() {
        do { try helperClient.install() }
        catch { lastSyncError = error.localizedDescription }
    }

    func uninstallHelper() {
        do { try helperClient.uninstall() }
        catch { lastSyncError = error.localizedDescription }
    }

    func openHelperSettings() {
        helperClient.openLoginItemsSettings()
    }

    func pingHelper() async {
        do { _ = try await helperClient.ping() }
        catch { lastSyncError = error.localizedDescription }
    }

    // MARK: - NTP polling

    private func startNTPPolling() {
        ntpPollTask?.cancel()
        let interval = preferences.refreshIntervalSeconds
        ntpPollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollNTPOnce()
                try? await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000)
            }
        }
    }

    func pollNTPOnce() async {
        let server = preferences.ntpServer
        if server.isEmpty {
            ntpState.status = .error("No server configured")
            return
        }
        ntpState.status = .connecting
        do {
            let result = try await ntpClient.query(server: server)
            ntpState.status = .ok
            ntpState.offsetMs = result.systemAheadOfReferenceMs
            ntpState.roundTripMs = result.roundTripDelayMs
            ntpState.lastUpdate = Date()
            ntpState.connected = true
            await maybeAutoSync(source: .ntp)
        } catch {
            ntpState.status = .error(shortMessage(error))
            ntpState.connected = false
        }
    }

    // MARK: - GPS

    func restartGPS() {
        gpsReader?.stop()
        gpsReader = nil

        let port = preferences.gpsPort
        guard !port.isEmpty else {
            gpsState = SourceState()
            gpsState.status = .idle
            return
        }

        gpsState.status = .connecting
        let reader = GPSReader(port: port, baud: Int32(preferences.gpsBaud))
        reader.onUpdate = { [weak self] update in
            Task { @MainActor in self?.applyGPSUpdate(update) }
        }
        do {
            try reader.start()
            gpsReader = reader
        } catch {
            gpsState.status = .error(shortMessage(error))
        }
    }

    private func applyGPSUpdate(_ update: GPSUpdate) {
        gpsState.connected = true
        gpsState.satellites = update.satellitesInView
        gpsState.lastUpdate = Date()
        switch update.kind {
        case .fix(let gpsTime, let receivedAt):
            // GPS UTC corresponds (approximately) to start of the second containing the sentence.
            // We measured `receivedAt` as the moment the '$' arrived. Without PPS, accuracy is
            // limited to roughly the byte-transmission latency at this baud, ~10–100 ms.
            let offset = receivedAt.timeIntervalSince(gpsTime) * 1000.0
            gpsState.status = .ok
            gpsState.offsetMs = offset
            Task { await maybeAutoSync(source: .gps) }
        case .noFix:
            gpsState.status = .noFix
            gpsState.offsetMs = nil
        }
    }

    // MARK: - Serial port enumeration

    func refreshAvailableSerialPorts() {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: "/dev") else {
            availableSerialPorts = []
            return
        }
        availableSerialPorts = entries
            .filter { $0.hasPrefix("cu.") }
            .map { "/dev/\($0)" }
            .sorted()
    }

    // MARK: - Refresh

    func refreshAll() async {
        refreshAvailableSerialPorts()
        await pollNTPOnce()
    }

    // MARK: - Derived

    var bestOffsetMs: Double? {
        switch preferences.preferredSource {
        case .ntp: return ntpState.offsetMs
        case .gps: return gpsState.offsetMs
        case .best: return gpsState.offsetMs ?? ntpState.offsetMs
        }
    }

    var menuBarIcon: String {
        guard let off = bestOffsetMs else { return "clock.badge.questionmark" }
        if abs(off) > Double(preferences.warnThresholdMs) {
            return "clock.badge.exclamationmark"
        }
        return "clock.badge.checkmark"
    }

    // MARK: - Preference change handling

    private var lastApplied: Preferences?

    private func applyPreferences(_ new: Preferences) {
        defer { lastApplied = new }
        guard let old = lastApplied else {
            // First sink is the initial value — services already started in init.
            return
        }
        if new.ntpServer != old.ntpServer || new.refreshIntervalSeconds != old.refreshIntervalSeconds {
            startNTPPolling()
        }
        if new.gpsPort != old.gpsPort || new.gpsBaud != old.gpsBaud {
            restartGPS()
        }
    }

    private func shortMessage(_ error: Error) -> String {
        let s = String(describing: error)
        return s.count > 80 ? String(s.prefix(80)) + "…" : s
    }

    // MARK: - Sync (uses the privileged helper)

    /// User-initiated. Picks the best available source per preferences and pushes
    /// the corrected time to the helper.
    func syncNow() async {
        do {
            let target = try chooseSyncTarget()
            try await helperClient.syncSystemClock(to: target)
            lastSyncError = nil
            // Re-poll NTP after sync so the UI reflects the new (small) residual offset.
            await pollNTPOnce()
        } catch {
            lastSyncError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Auto-sync hook called after each successful NTP poll or GPS fix.
    private func maybeAutoSync(source: TimeSource) async {
        guard preferences.autoSyncEnabled else { return }
        guard helperClient.status == .enabled else { return }
        // Throttle: don't auto-sync more often than `autoSyncMinIntervalSeconds`.
        if let last = lastAutoSyncAt,
           Date().timeIntervalSince(last) < Double(preferences.autoSyncMinIntervalSeconds) {
            return
        }
        // Only sync from the source that just updated, AND only if it matches the preferred source.
        switch preferences.preferredSource {
        case .ntp where source != .ntp: return
        case .gps where source != .gps: return
        default: break
        }
        guard let offset = (source == .gps) ? gpsState.offsetMs : ntpState.offsetMs else { return }
        guard abs(offset) > Double(preferences.warnThresholdMs) else { return }

        do {
            let target = Date().addingTimeInterval(-offset / 1000.0)
            try await helperClient.syncSystemClock(to: target)
            lastAutoSyncAt = Date()
            lastSyncError = nil
        } catch {
            lastSyncError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func chooseSyncTarget() throws -> Date {
        // Prefer GPS if available and we're not specifically NTP-locked.
        let preferGPS = preferences.preferredSource != .ntp
        if preferGPS, let off = gpsState.offsetMs, gpsState.status == .ok {
            return Date().addingTimeInterval(-off / 1000.0)
        }
        if let off = ntpState.offsetMs, ntpState.status == .ok {
            return Date().addingTimeInterval(-off / 1000.0)
        }
        if let off = gpsState.offsetMs, gpsState.status == .ok {
            return Date().addingTimeInterval(-off / 1000.0)
        }
        throw HelperClientError.setFailed("No source has a fresh offset to sync from")
    }
}
