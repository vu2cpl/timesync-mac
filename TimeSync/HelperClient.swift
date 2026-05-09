import Foundation
import ServiceManagement
import AppKit

enum HelperClientError: LocalizedError {
    case notRegistered
    case registrationFailed(String)
    case xpcUnavailable(String)
    case setFailed(String)

    var errorDescription: String? {
        switch self {
        case .notRegistered:
            return "Helper is not installed. Install it from the Helper tab in Settings."
        case .registrationFailed(let s): return "Helper registration failed: \(s)"
        case .xpcUnavailable(let s):     return "Helper is not reachable: \(s)"
        case .setFailed(let s):          return "Helper refused to set time: \(s)"
        }
    }
}

@MainActor
final class HelperClient: ObservableObject {
    @Published private(set) var status: SMAppService.Status = .notRegistered
    @Published private(set) var lastError: String?
    @Published private(set) var helperVersion: String?
    @Published private(set) var lastSync: (date: Date, appliedOffsetMs: Double)?

    private let service = SMAppService.daemon(plistName: HelperConstants.launchdPlistName)
    private var connection: NSXPCConnection?

    init() {
        refreshStatus()
    }

    // MARK: - Lifecycle

    func refreshStatus() {
        status = service.status
    }

    /// Register the daemon with launchd. The first call shows a system admin prompt.
    func install() throws {
        do {
            try service.register()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            throw HelperClientError.registrationFailed(error.localizedDescription)
        }
        refreshStatus()
    }

    func uninstall() throws {
        do {
            try service.unregister()
            tearDownConnection()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            throw HelperClientError.registrationFailed(error.localizedDescription)
        }
        refreshStatus()
    }

    /// macOS opens the Login Items / Background Items settings pane focused on this daemon.
    /// Useful when status is `.requiresApproval`.
    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    // MARK: - XPC

    /// Smoke-test: ask the helper for its version. Also caches it.
    @discardableResult
    func ping() async throws -> String {
        let proxy = try makeProxy()
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            proxy.getHelperVersion { version in
                Task { @MainActor in self.helperVersion = version }
                cont.resume(returning: version)
            }
        }
    }

    /// Set the system clock to `referenceTime`. Records the offset that was just applied
    /// (system - reference, in ms, *before* the sync) so the UI can show "applied -34 ms".
    func syncSystemClock(to referenceTime: Date) async throws {
        guard status == .enabled else {
            throw HelperClientError.notRegistered
        }
        let preSyncOffsetMs = Date().timeIntervalSince(referenceTime) * 1000.0
        let proxy = try makeProxy()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            proxy.setSystemTime(unixSeconds: referenceTime.timeIntervalSince1970) { ok, errMsg in
                if ok {
                    Task { @MainActor in
                        self.lastSync = (Date(), preSyncOffsetMs)
                        self.lastError = nil
                    }
                    cont.resume()
                } else {
                    let msg = errMsg ?? "unknown error"
                    Task { @MainActor in self.lastError = msg }
                    cont.resume(throwing: HelperClientError.setFailed(msg))
                }
            }
        }
    }

    // MARK: - Connection plumbing

    private func makeProxy() throws -> TimeSyncHelperProtocol {
        let conn = currentConnection()
        var thrown: Error?
        let proxy = conn.remoteObjectProxyWithErrorHandler { err in
            Task { @MainActor in self.lastError = err.localizedDescription }
            thrown = HelperClientError.xpcUnavailable(err.localizedDescription)
        } as? TimeSyncHelperProtocol
        if let proxy = proxy { return proxy }
        throw thrown ?? HelperClientError.xpcUnavailable("proxy is nil")
    }

    private func currentConnection() -> NSXPCConnection {
        if let c = connection { return c }
        let c = NSXPCConnection(machServiceName: HelperConstants.machServiceName, options: [.privileged])
        c.remoteObjectInterface = NSXPCInterface(with: TimeSyncHelperProtocol.self)
        c.invalidationHandler = { [weak self] in
            Task { @MainActor in self?.connection = nil }
        }
        c.interruptionHandler = { [weak self] in
            Task { @MainActor in self?.connection = nil }
        }
        c.resume()
        connection = c
        return c
    }

    private func tearDownConnection() {
        connection?.invalidate()
        connection = nil
    }
}

extension SMAppService.Status {
    var humanReadable: String {
        switch self {
        case .notRegistered: return "Not installed"
        case .enabled:       return "Installed and enabled"
        case .requiresApproval: return "Awaiting user approval (open Login Items)"
        case .notFound:      return "Not found"
        @unknown default:    return "Unknown (\(rawValue))"
        }
    }
}
