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

    /// Candidate paths for the chronyc binary. Apple Silicon brew lives at
    /// /opt/homebrew, Intel brew at /usr/local. We try each in order.
    private static let chronycCandidates = [
        "/opt/homebrew/bin/chronyc",
        "/usr/local/bin/chronyc",
    ]

    private static func findChronyc() -> String? {
        chronycCandidates.first { FileManager.default.fileExists(atPath: $0) }
    }

    func runChronyMakestep(with reply: @escaping (Bool, String?) -> Void) {
        guard let chronycPath = Self.findChronyc() else {
            reply(false,
                  "chrony is not installed. Run server/install.sh from the timesync-mac repo "
                + "(https://github.com/vu2cpl/timesync-mac) to set up chrony + gpsd.")
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: chronycPath)
        process.arguments = ["makestep"]
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.terminationHandler = { proc in
            let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let stdout = String(data: outData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let stderr = String(data: errData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if proc.terminationStatus == 0 {
                NSLog("TimeSyncHelper: chronyc makestep -> \(stdout)")
                reply(true, nil)
            } else {
                // chronyc emits its protocol responses ("506 Cannot talk to daemon",
                // "501 Not authorised", etc.) to STDOUT, not stderr. Pass both streams
                // through friendlyError so we recognise the patterns either way.
                let combined = [stdout, stderr]
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
                NSLog("TimeSyncHelper: chronyc makestep failed (\(proc.terminationStatus)): \(combined)")
                reply(false, Self.friendlyError(exitCode: proc.terminationStatus, output: combined))
            }
        }
        do {
            try process.run()
        } catch {
            reply(false, "spawn chronyc failed: \(error.localizedDescription)")
        }
    }

    /// Translate raw chronyc errors into messages a user can act on. `output` is
    /// the combined stdout+stderr — chronyc's protocol responses (506, 501, etc.)
    /// come out on stdout, real errno-style errors on stderr; we check both.
    private static func friendlyError(exitCode: Int32, output: String) -> String {
        // chronyc emits "506 Cannot talk to daemon" when chronyd isn't running or
        // its socket isn't where chronyc expects it. By far the most common cause
        // for a fresh installer who hasn't run server/install.sh yet.
        if output.contains("Cannot talk to daemon") || output.contains("506") {
            return "chronyd is not running. Run server/install.sh from the timesync-mac repo "
                 + "(https://github.com/vu2cpl/timesync-mac) to install and start it."
        }
        // 501 Not authorised — chronyd is running but the calling process can't
        // execute the privileged command. Shouldn't happen in practice (the helper
        // runs as root) but leave a clear message in case it does.
        if output.contains("Not authorised") || output.contains("501") {
            return "chrony refused the makestep request (501 Not authorised). "
                 + "The helper isn't running as root, or chronyd's command socket "
                 + "permissions are wrong."
        }
        // Anything else: surface the raw output so we have something to debug.
        return "chronyc exit \(exitCode): \(output.isEmpty ? "(no output)" : output)"
    }

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
