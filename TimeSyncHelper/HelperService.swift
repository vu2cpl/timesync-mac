import Foundation
import Darwin
import Security

/// Accepts XPC connections from clients that match our code requirement.
final class HelperListenerDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection conn: NSXPCConnection) -> Bool {
        let pid = conn.processIdentifier
        guard validateClient(conn) else {
            NSLog("TimeSyncHelper: rejecting connection from PID \(pid) — code requirement not satisfied")
            return false
        }
        NSLog("TimeSyncHelper: accepted connection from PID \(pid)")
        conn.exportedInterface = NSXPCInterface(with: TimeSyncHelperProtocol.self)
        conn.exportedObject = HelperService()
        conn.resume()
        return true
    }

    private func validateClient(_ conn: NSXPCConnection) -> Bool {
        let pid = conn.processIdentifier
        guard pid > 0 else { return false }

        // Look up the SecCode for the connecting process by PID.
        var clientCode: SecCode?
        let attrs: CFDictionary = [kSecGuestAttributePid: pid] as CFDictionary
        let lookup = SecCodeCopyGuestWithAttributes(nil, attrs, [], &clientCode)
        guard lookup == errSecSuccess, let clientCode else {
            NSLog("TimeSyncHelper: SecCodeCopyGuestWithAttributes failed: \(lookup)")
            return false
        }

        // For ad-hoc signed personal builds we only check the bundle identifier.
        // TODO: For distribution, harden by adding an anchor and Team ID:
        //   anchor apple generic and identifier "com.vu2cpl.TimeSync"
        //     and certificate leaf[subject.OU] = "<TEAMID>"
        let reqString = "identifier \"\(HelperConstants.mainAppBundleID)\""
        var req: SecRequirement?
        let createRC = SecRequirementCreateWithString(reqString as CFString, [], &req)
        guard createRC == errSecSuccess, let req else {
            NSLog("TimeSyncHelper: SecRequirementCreateWithString failed: \(createRC)")
            return false
        }

        let validRC = SecCodeCheckValidity(clientCode, [], req)
        if validRC != errSecSuccess {
            NSLog("TimeSyncHelper: SecCodeCheckValidity failed: \(validRC)")
            return false
        }
        return true
    }
}

/// Implements the XPC interface. Runs as root inside the helper process.
final class HelperService: NSObject, TimeSyncHelperProtocol {
    func setSystemTime(unixSeconds: Double, with reply: @escaping (Bool, String?) -> Void) {
        guard unixSeconds.isFinite, unixSeconds > 0 else {
            reply(false, "Invalid time value")
            return
        }
        // Refuse to jump the clock by more than ~10 years — sanity check against bad inputs.
        let now = Date().timeIntervalSince1970
        let delta = abs(unixSeconds - now)
        if delta > 10 * 365 * 24 * 3600 {
            reply(false, String(format: "Refusing to set time: |delta| = %.0f s exceeds sanity limit", delta))
            return
        }

        var tv = timeval()
        let secs = floor(unixSeconds)
        tv.tv_sec = time_t(secs)
        tv.tv_usec = suseconds_t((unixSeconds - secs) * 1_000_000)

        let rc = settimeofday(&tv, nil)
        if rc == 0 {
            NSLog("TimeSyncHelper: set time to %.6f", unixSeconds)
            reply(true, nil)
        } else {
            let msg = String(cString: strerror(errno))
            NSLog("TimeSyncHelper: settimeofday failed: \(msg)")
            reply(false, "settimeofday: \(msg) (errno \(errno))")
        }
    }

    func getHelperVersion(with reply: @escaping (String) -> Void) {
        reply("0.1.0")
    }
}
