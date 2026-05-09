// SPDX-License-Identifier: MIT

import SwiftUI

struct MenuBarContent: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.openSettings) private var openSettings
    @State private var nowTick: Date = Date()
    private let timer = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            setupBanner   // EmptyView when chrony is reachable

            Divider()

            chronySection

            Divider()

            sourceSection(
                title: "NTP",
                state: store.ntpState,
                detailLines: ntpDetailLines
            )

            Divider()

            sourceSection(
                title: "GPS",
                state: store.gpsState,
                detailLines: gpsDetailLines
            )

            Divider()

            helperSection

            HStack {
                Button {
                    Task { await store.refreshAll() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }

                Button {
                    Task { await store.chronyMakestep() }
                } label: {
                    Label("Step Clock", systemImage: "bolt.horizontal")
                }
                .disabled(store.helperStatus != .enabled || store.chronyTracking == nil)
                .help(stepClockHelp)

                Spacer()

                Button("Settings…") { openSettings() }
                    .keyboardShortcut(",", modifiers: .command)

                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q", modifiers: .command)
            }
        }
        .padding(14)
        .frame(width: 360)
        .onReceive(timer) { nowTick = $0 }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("System Time (UTC)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(formatUTC(nowTick))
                .font(.system(.title3, design: .monospaced))
        }
    }

    // MARK: - Source sections

    @ViewBuilder
    private func sourceSection(title: String, state: SourceState, detailLines: [String]) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(state.statusColor)
                .frame(width: 8, height: 8)
                .padding(.top, 6)

            VStack(alignment: .leading, spacing: 2) {
                // No offset number here — single-sample per-source offsets are mostly
                // transport latency (NTP RTT/2, GPS pipeline jitter), not actual drift.
                // The chrony section above shows the only drift number worth reading.
                Text(title).font(.headline)
                ForEach(detailLines, id: \.self) { line in
                    Text(line)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var ntpDetailLines: [String] {
        var lines: [String] = []
        lines.append("Server: \(store.preferences.ntpServer)")
        lines.append("Status: \(store.ntpState.statusText)")
        if let rtt = store.ntpState.roundTripMs {
            lines.append(String(format: "Round trip: %.0f ms", rtt))
        }
        if let last = store.ntpState.lastUpdate {
            lines.append("Last poll: \(formatRelative(last, now: nowTick))")
        }
        return lines
    }

    private var gpsDetailLines: [String] {
        var lines: [String] = []
        lines.append("gpsd: \(store.preferences.gpsdHost):\(store.preferences.gpsdPort)")
        lines.append("Status: \(store.gpsState.statusText)")
        if let sats = store.gpsState.satellites {
            lines.append("Satellites used: \(sats)")
        }
        if let last = store.gpsState.lastUpdate {
            lines.append("Last fix: \(formatRelative(last, now: nowTick))")
        }
        return lines
    }

    // MARK: - Formatting

    private func formatUTC(_ date: Date) -> String {
        let f = DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f.string(from: date)
    }

    private func formatOffset(_ ms: Double) -> String {
        let sign = ms >= 0 ? "+" : "-"
        let absMs = abs(ms)
        if absMs < 1_000 {
            return String(format: "%@%.1f ms", sign, absMs)
        }
        return String(format: "%@%.3f s", sign, absMs / 1000.0)
    }

    private func formatRelative(_ when: Date, now: Date) -> String {
        let dt = now.timeIntervalSince(when)
        if dt < 1.0 { return "just now" }
        if dt < 60 { return String(format: "%.0fs ago", dt) }
        if dt < 3600 { return String(format: "%.0fm ago", dt / 60) }
        return String(format: "%.1fh ago", dt / 3600)
    }

    // MARK: - chrony section

    @ViewBuilder
    private var chronySection: some View {
        if let chrony = store.chronyTracking {
            HStack(alignment: .top, spacing: 10) {
                Circle()
                    .fill(Color.blue)
                    .frame(width: 8, height: 8)
                    .padding(.top, 6)
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("chrony").font(.headline)
                        Spacer()
                        Text(formatOffset(chrony.systemAheadOfReferenceMs))
                            .font(.system(.body, design: .monospaced))
                    }
                    Text("Reference: \(chrony.referenceName) (stratum \(chrony.stratum))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(String(format: "RMS offset: %.1f ms · Root delay: %.0f ms",
                                chrony.rmsOffsetMs, chrony.rootDelayMs))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(String(format: "Frequency: %+.2f ppm · update %.0fs · %@",
                                chrony.frequencyPpm,
                                chrony.updateIntervalSeconds,
                                chrony.leapStatus))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } else if let err = store.chronyError {
            Text("chrony: \(err)")
                .font(.caption)
                .foregroundStyle(.orange)
        } else {
            Text("chrony: starting…")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Helper section

    @ViewBuilder
    private var helperSection: some View {
        switch store.helperStatus {
        case .enabled:
            HStack(spacing: 8) {
                Image(systemName: "lock.shield")
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Helper installed")
                        .font(.caption)
                    if let last = store.lastMakestepAt {
                        Text("Last makestep: \(formatRelative(last, now: nowTick))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
        case .requiresApproval:
            VStack(alignment: .leading, spacing: 4) {
                Text("Helper needs your approval")
                    .font(.caption)
                Button("Open Login Items…") { store.openHelperSettings() }
                    .controlSize(.small)
            }
        case .notRegistered, .notFound:
            VStack(alignment: .leading, spacing: 4) {
                Text("Helper not installed — Sync Now is disabled")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Install Helper…") { store.installHelper() }
                    .controlSize(.small)
                    .help("Installs a privileged background daemon. Requires admin auth — one time.")
            }
        @unknown default:
            Text("Helper status: \(store.helperStatus.rawValue)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        if let err = store.helperLastError ?? store.lastActionError {
            Text(err)
                .font(.caption2)
                .foregroundStyle(.red)
                .lineLimit(3)
        }
    }

    private var stepClockHelp: String {
        if store.helperStatus != .enabled {
            return "Install the helper first (one-time admin auth)."
        }
        if store.chronyTracking == nil {
            return "chrony is not running. Set it up with server/install.sh."
        }
        return "Run `chronyc makestep` — forces chrony to immediately step the system clock to its current best estimate. Useful when chrony has fallen back to local stratum 8."
    }

    // MARK: - Setup banner (chrony not installed / not running)

    /// Shown at the top of the popover when chrony is unreachable. The most
    /// common cause for fresh installers is that they downloaded the .app but
    /// never ran server/install.sh — point them there explicitly.
    @ViewBuilder
    private var setupBanner: some View {
        if store.chronyTracking == nil, let err = store.chronyError {
            VStack(spacing: 0) {
                Divider()
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.title3)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(err.localizedCaseInsensitiveContains("not found")
                             ? "chrony is not installed"
                             : "chrony is not running")
                            .font(.headline)
                        Text("This Mac's clock isn't being externally disciplined right now. Run server/install.sh from the timesync-mac repo to set up chrony + gpsd.")
                            .font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Open setup instructions") {
                            if let url = URL(string: "https://github.com/vu2cpl/timesync-mac#install--server-stack-gpsd--chrony") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .controlSize(.small)
                        .padding(.top, 2)
                    }
                }
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.orange.opacity(0.12))
                )
                .padding(.top, 8)
            }
        }
    }
}
