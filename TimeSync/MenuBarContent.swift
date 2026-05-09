import SwiftUI

struct MenuBarContent: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.openSettings) private var openSettings
    @State private var nowTick: Date = Date()
    private let timer = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

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
                    Task { await store.syncNow() }
                } label: {
                    Label("Sync Now", systemImage: "checkmark.circle")
                }
                .disabled(!canSyncNow)
                .help(syncNowHelp)

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
                HStack {
                    Text(title).font(.headline)
                    Spacer()
                    if let off = state.offsetMs {
                        Text(formatOffset(off))
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(state.offsetColor)
                    } else {
                        Text("—").foregroundStyle(.secondary)
                    }
                }
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
        lines.append("Port: \(store.preferences.gpsPort.isEmpty ? "(none selected)" : store.preferences.gpsPort) @ \(store.preferences.gpsBaud)")
        lines.append("Status: \(store.gpsState.statusText)")
        if let sats = store.gpsState.satellites {
            lines.append("Satellites in view: \(sats)")
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
                    if let last = store.lastHelperSync {
                        Text(String(format: "Last sync: %@ (applied %+.1f ms)",
                                    formatRelative(last.at, now: nowTick),
                                    last.appliedOffsetMs))
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

        if let err = store.helperLastError ?? store.lastSyncError {
            Text(err)
                .font(.caption2)
                .foregroundStyle(.red)
                .lineLimit(3)
        }
    }

    private var canSyncNow: Bool {
        store.helperStatus == .enabled
            && (store.ntpState.offsetMs != nil || store.gpsState.offsetMs != nil)
    }

    private var syncNowHelp: String {
        if store.helperStatus != .enabled {
            return "Install the helper first (one-time admin auth)."
        }
        if store.ntpState.offsetMs == nil && store.gpsState.offsetMs == nil {
            return "Waiting for an NTP or GPS reading."
        }
        return "Set the system clock to the current reference time."
    }
}
