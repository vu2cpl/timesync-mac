import Combine
import Foundation
import ServiceManagement
import SwiftUI

@MainActor
final class AppStore: ObservableObject {
    @Published var preferences: Preferences
    @Published var ntpState = SourceState()
    @Published var gpsState = SourceState()
    @Published var lastActionError: String?

    // chrony's view of system clock offset — much more stable than per-source
    // single-sample offsets because chrony filters across all its sources.
    @Published var chronyTracking: ChronyTracking?
    @Published var chronyError: String?

    // Mirrored from helperClient so views update without nested-observable plumbing.
    @Published var helperStatus: SMAppService.Status = .notRegistered
    @Published var helperLastError: String?
    @Published var helperVersion: String?
    @Published var lastMakestepAt: Date?

    let helperClient = HelperClient()
    let chronyMonitor = ChronyMonitor()

    /// Whether macOS will auto-launch TimeSync.app at login. Mirrors
    /// `SMAppService.mainApp.status == .enabled`. Toggled from Settings.
    @Published var launchAtLoginEnabled: Bool = false
    private let loginItemService = SMAppService.mainApp

    private let ntpClient = NTPClient()
    private var gpsdClient: GPSDClient?
    private var ntpPollTask: Task<Void, Never>?
    private var prefsBag = Set<AnyCancellable>()

    init() {
        self.preferences = Preferences.load()

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
        helperClient.$lastMakestepAt.receive(on: DispatchQueue.main).assign(to: &$lastMakestepAt)

        // chrony is now the canonical source of "what's the system clock offset?".
        // Mirror its publishers so views can read store.chronyTracking directly.
        chronyMonitor.$tracking.receive(on: DispatchQueue.main).assign(to: &$chronyTracking)
        chronyMonitor.$lastError.receive(on: DispatchQueue.main).assign(to: &$chronyError)

        refreshLaunchAtLogin()

        startNTPPolling()
        restartGPSD()
        chronyMonitor.start()
    }

    // MARK: - Launch at Login

    /// Re-read the actual status from SMAppService. The user can flip the
    /// state from System Settings → General → Login Items behind our back,
    /// so we shouldn't trust our cached @Published value over too long a
    /// period; refresh whenever Settings is opened.
    func refreshLaunchAtLogin() {
        launchAtLoginEnabled = (loginItemService.status == .enabled)
    }

    /// Register or unregister TimeSync.app as a Login Item. Errors surface
    /// in `lastActionError` for the popover to show.
    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try loginItemService.register()
            } else {
                try loginItemService.unregister()
            }
            lastActionError = nil
        } catch {
            // Common reasons this can fail:
            //  - app launched from DerivedData / Downloads (SMAppService rejects
            //    transient paths). Move to /Applications.
            //  - macOS prompted user to approve and they declined.
            lastActionError = "Launch at Login change failed: \(error.localizedDescription)"
        }
        refreshLaunchAtLogin()
    }

    // MARK: - Helper lifecycle (delegates to HelperClient)

    func installHelper() {
        do { try helperClient.install() }
        catch { lastActionError = error.localizedDescription }
    }

    func uninstallHelper() {
        do { try helperClient.uninstall() }
        catch { lastActionError = error.localizedDescription }
    }

    func openHelperSettings() {
        helperClient.openLoginItemsSettings()
    }

    func pingHelper() async {
        do { _ = try await helperClient.ping() }
        catch { lastActionError = error.localizedDescription }
    }

    /// Force chrony to immediately step the system clock to its current best estimate.
    /// Useful after the clock has drifted far enough that chrony loses quorum and
    /// falls back to local stratum 8 — `makestep` jolts it out of that state.
    func chronyMakestep() async {
        do {
            try await helperClient.runChronyMakestep()
            lastActionError = nil
            // Pull a fresh chronyc tracking right after so the UI reflects the step.
            await chronyMonitor.pollOnce()
        } catch {
            lastActionError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
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
        } catch {
            ntpState.status = .error(shortMessage(error))
            ntpState.connected = false
        }
    }

    // MARK: - GPS (via gpsd)

    func restartGPSD() {
        gpsdClient?.stop()
        gpsdClient = nil

        gpsState = SourceState()
        gpsState.status = .connecting

        let host = preferences.gpsdHost.isEmpty ? "localhost" : preferences.gpsdHost
        let port = UInt16(clamping: preferences.gpsdPort)
        let client = GPSDClient(host: host, port: port)
        client.onUpdate = { [weak self] update in
            Task { @MainActor in self?.applyGPSUpdate(update) }
        }
        client.onConnectionChange = { [weak self] connected, errMsg in
            Task { @MainActor in self?.applyGPSDConnection(connected: connected, error: errMsg) }
        }
        client.start()
        gpsdClient = client
    }

    private func applyGPSDConnection(connected: Bool, error: String?) {
        gpsState.connected = connected
        if !connected {
            // Don't blow away offsetMs immediately — UI shows "stale, last seen Xs ago".
            if let err = error {
                gpsState.status = .error(err)
            } else {
                gpsState.status = .idle
            }
        }
    }

    private func applyGPSUpdate(_ update: GPSUpdate) {
        gpsState.connected = true
        gpsState.satellites = update.satellitesInView
        gpsState.lastUpdate = Date()
        switch update.kind {
        case .fix(let gpsTime, let receivedAt):
            // Single-sample, noisy: TCP arrival time is a poor proxy for the GPS-second
            // mark (gpsd parsing + TCP coalescing add 50-200 ms of variable latency).
            // Use this only as a sanity check; the headline drift comes from chrony.
            let offset = receivedAt.timeIntervalSince(gpsTime) * 1000.0
            gpsState.status = .ok
            gpsState.offsetMs = offset
        case .noFix:
            gpsState.status = .noFix
            gpsState.offsetMs = nil
        }
    }

    // MARK: - Refresh

    func refreshAll() async {
        await pollNTPOnce()
        await chronyMonitor.pollOnce()
    }

    // MARK: - Derived

    /// The "main" drift number to display. Prefers chrony's filtered view over any
    /// single-sample per-source offset. Falls back to per-source if chrony is
    /// unavailable (not installed, daemon down, etc.).
    var bestOffsetMs: Double? {
        if let chrony = chronyTracking {
            return chrony.systemAheadOfReferenceMs
        }
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
        if new.gpsdHost != old.gpsdHost || new.gpsdPort != old.gpsdPort {
            restartGPSD()
        }
    }

    private func shortMessage(_ error: Error) -> String {
        let s = String(describing: error)
        return s.count > 80 ? String(s.prefix(80)) + "…" : s
    }
}
