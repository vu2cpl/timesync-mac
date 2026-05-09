import Foundation

/// Parsed `chronyc -c tracking` output. All offsets in our app convention:
/// positive = system clock is ahead of reference. Frequencies in ppm.
struct ChronyTracking: Equatable {
    let referenceID: String          // hex, e.g. "A29FC87B"
    let referenceName: String        // IP or hostname, e.g. "time.cloudflare.com"
    let stratum: Int
    let refTime: Date                // when chrony last sampled the reference

    /// System clock minus NTP-synchronised reference, in milliseconds.
    /// Positive = system ahead. This is *the* drift number to display.
    let systemAheadOfReferenceMs: Double

    /// Most recent measurement offset, signed. Same convention as above.
    let lastOffsetMs: Double

    /// RMS offset over the recent sliding window — chrony's noise-floor estimate.
    let rmsOffsetMs: Double

    /// Root delay (round-trip to selected reference, ms).
    let rootDelayMs: Double

    /// Root dispersion (chrony's bound on time error, ms).
    let rootDispersionMs: Double

    /// Frequency offset of system clock vs reference, ppm. Positive = system fast.
    let frequencyPpm: Double

    /// Time between updates, seconds.
    let updateIntervalSeconds: Double

    /// "Normal", "Insert second", etc. — leap-second flags.
    let leapStatus: String
}

enum ChronyMonitorError: LocalizedError {
    case chronycNotFound
    case chronycFailed(exitCode: Int32, stderr: String)
    case parseError(String)

    var errorDescription: String? {
        switch self {
        case .chronycNotFound:
            return "chronyc not found — install chrony (server/install.sh) or set custom path."
        case .chronycFailed(let code, let err):
            return "chronyc exited \(code): \(err)"
        case .parseError(let s):
            return "chronyc CSV parse error: \(s)"
        }
    }
}

/// Polls `chronyc -c tracking` every `pollIntervalSeconds` and publishes the parsed
/// view. chronyc is fast (<10ms typical), so polling every few seconds is cheap.
@MainActor
final class ChronyMonitor: ObservableObject {
    @Published private(set) var tracking: ChronyTracking?
    @Published private(set) var lastError: String?

    private let chronycPath: String
    private let pollIntervalSeconds: Int
    private var pollTask: Task<Void, Never>?

    init(chronycPath: String = "/opt/homebrew/bin/chronyc", pollIntervalSeconds: Int = 5) {
        self.chronycPath = chronycPath
        self.pollIntervalSeconds = pollIntervalSeconds
    }

    func start() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollOnce()
                try? await Task.sleep(nanoseconds: UInt64(self?.pollIntervalSeconds ?? 5) * 1_000_000_000)
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Single poll. Surfaced publicly so the user can manually refresh.
    func pollOnce() async {
        do {
            let csv = try await runChronyc()
            let parsed = try Self.parseTrackingCSV(csv)
            self.tracking = parsed
            self.lastError = nil
        } catch {
            self.lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            // Don't blow away the last good reading on a transient failure.
        }
    }

    // MARK: - Process invocation

    private func runChronyc() async throws -> String {
        guard FileManager.default.fileExists(atPath: chronycPath) else {
            throw ChronyMonitorError.chronycNotFound
        }
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: chronycPath)
            process.arguments = ["-c", "tracking"]
            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe
            process.terminationHandler = { proc in
                let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                if proc.terminationStatus == 0 {
                    cont.resume(returning: String(data: outData, encoding: .utf8) ?? "")
                } else {
                    let msg = String(data: errData, encoding: .utf8) ?? ""
                    cont.resume(throwing: ChronyMonitorError.chronycFailed(exitCode: proc.terminationStatus, stderr: msg))
                }
            }
            do {
                try process.run()
            } catch {
                cont.resume(throwing: error)
            }
        }
    }

    // MARK: - CSV parsing

    /// Field layout for `chronyc -c tracking` (chrony 4.x):
    /// 0:RefID  1:RefName  2:Stratum  3:RefTime(unixSec.fff)  4:SystemTime
    /// 5:LastOffset  6:RMSOffset  7:Frequency  8:ResidFreq  9:Skew
    /// 10:RootDelay  11:RootDispersion  12:UpdateInterval  13:LeapStatus
    ///
    /// Sign convention in CSV: SystemTime/LastOffset positive means system is *slow*
    /// (behind reference). We negate to match our app's "positive = system ahead".
    static func parseTrackingCSV(_ raw: String) throws -> ChronyTracking {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let fields = trimmed.split(separator: ",", omittingEmptySubsequences: false)
        guard fields.count >= 14 else {
            throw ChronyMonitorError.parseError("expected ≥14 fields, got \(fields.count): \(trimmed.prefix(120))")
        }

        guard let stratum = Int(fields[2]),
              let refTimeUnix = Double(fields[3]),
              let systemTime = Double(fields[4]),
              let lastOffset = Double(fields[5]),
              let rmsOffset = Double(fields[6]),
              let frequency = Double(fields[7]),
              let rootDelay = Double(fields[10]),
              let rootDispersion = Double(fields[11]),
              let updateInterval = Double(fields[12])
        else {
            throw ChronyMonitorError.parseError("could not decode numeric fields")
        }

        return ChronyTracking(
            referenceID: String(fields[0]),
            referenceName: String(fields[1]),
            stratum: stratum,
            refTime: Date(timeIntervalSince1970: refTimeUnix),
            systemAheadOfReferenceMs: -systemTime * 1000.0,
            lastOffsetMs: -lastOffset * 1000.0,
            rmsOffsetMs: rmsOffset * 1000.0,
            rootDelayMs: rootDelay * 1000.0,
            rootDispersionMs: rootDispersion * 1000.0,
            frequencyPpm: frequency,
            updateIntervalSeconds: updateInterval,
            leapStatus: String(fields[13])
        )
    }
}
