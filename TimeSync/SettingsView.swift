// SPDX-License-Identifier: MIT

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("General", systemImage: "gear") }
            ntpTab
                .tabItem { Label("NTP", systemImage: "network") }
            gpsTab
                .tabItem { Label("GPS", systemImage: "location.fill") }
            helperTab
                .tabItem { Label("Helper", systemImage: "lock.shield") }
        }
        .padding()
    }

    // MARK: - General

    private var generalTab: some View {
        Form {
            Toggle("Launch at login", isOn: Binding(
                get: { store.launchAtLoginEnabled },
                set: { store.setLaunchAtLogin($0) }
            ))
            .help("When enabled, TimeSync.app starts automatically each time you log in. Requires the app to live in /Applications. macOS will show a one-time notification the first time you turn this on.")

            Picker("Diagnostic source", selection: $store.preferences.preferredSource) {
                ForEach(TimeSource.allCases) { src in
                    Text(src.label).tag(src)
                }
            }
            .help("Which per-source single-sample offset to fall back to if chrony is unavailable. Chrony's filtered view is always used when present.")
            Toggle("Show offset in menu bar", isOn: $store.preferences.showOffsetInMenuBar)
            Stepper(value: $store.preferences.refreshIntervalSeconds, in: 5...3600, step: 5) {
                Text("Refresh NTP every \(store.preferences.refreshIntervalSeconds)s")
            }
            Stepper(value: $store.preferences.warnThresholdMs, in: 10...10_000, step: 10) {
                Text("Warn when drift > \(store.preferences.warnThresholdMs) ms")
            }
            Text("Clock discipline is owned by chrony. The helper exposes only chronyc makestep, used by the Step Clock button when chrony loses quorum.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 6)
        }
        .onAppear { store.refreshLaunchAtLogin() }
    }

    // MARK: - Helper

    private var helperTab: some View {
        Form {
            LabeledContent("Status", value: store.helperStatus.humanReadable)

            if let v = store.helperVersion {
                LabeledContent("Helper version", value: v)
            }

            if let last = store.lastMakestepAt {
                LabeledContent("Last makestep",
                               value: last.formatted(date: .omitted, time: .standard))
            }

            HStack {
                switch store.helperStatus {
                case .enabled:
                    Button("Test connection") {
                        Task { await store.pingHelper() }
                    }
                    Button("Uninstall…", role: .destructive) {
                        store.uninstallHelper()
                    }
                case .requiresApproval:
                    Button("Open Login Items") { store.openHelperSettings() }
                case .notRegistered, .notFound:
                    Button("Install Helper…") { store.installHelper() }
                @unknown default:
                    Text("Unknown helper state")
                }
                Spacer()
            }

            if let err = store.helperLastError {
                Text(err)
                    .foregroundStyle(.red)
                    .font(.caption)
            }

            Text("The helper is a small launchd daemon that runs as root. It accepts connections only from this app (verified by code signature) and exposes one XPC method: run `chronyc makestep`. The legacy setSystemTime method is still in the protocol for backward compat but no longer called by this app — chrony owns clock discipline.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 6)
        }
    }

    // MARK: - NTP

    private var ntpTab: some View {
        Form {
            TextField("Server", text: $store.preferences.ntpServer, prompt: Text("pool.ntp.org"))
            HStack {
                Button("Test now") {
                    Task { await store.pollNTPOnce() }
                }
                Spacer()
                Text(store.ntpState.statusText)
                    .foregroundStyle(store.ntpState.statusColor)
            }
            if let rtt = store.ntpState.roundTripMs {
                LabeledContent("Round trip", value: String(format: "%.0f ms", rtt))
            }
            Text("Per-source offset isn't shown — half the round trip is just network latency, not clock drift. The chrony section in the menu bar shows the actual disciplined offset.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 6)
        }
    }

    // MARK: - GPS

    private var gpsTab: some View {
        Form {
            TextField("gpsd host", text: $store.preferences.gpsdHost, prompt: Text("localhost"))
            TextField("gpsd port", value: $store.preferences.gpsdPort, format: .number.grouping(.never))
            HStack {
                Button(store.gpsState.connected ? "Reconnect" : "Connect") {
                    store.restartGPSD()
                }
                Spacer()
                Text(store.gpsState.statusText)
                    .foregroundStyle(store.gpsState.statusColor)
            }
            if let sats = store.gpsState.satellites {
                LabeledContent("Satellites used", value: "\(sats)")
            }
            Text("GPS is read via gpsd over TCP. Per-sample arrival timestamps are dominated by NMEA + USB + TCP buffering latency (typically 100-500 ms without PPS), so we don't show them as a drift number — chrony filters this and exposes the real disciplined offset.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 6)
        }
    }
}
