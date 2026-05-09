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
            Picker("Preferred source", selection: $store.preferences.preferredSource) {
                ForEach(TimeSource.allCases) { src in
                    Text(src.label).tag(src)
                }
            }
            Toggle("Show offset in menu bar", isOn: $store.preferences.showOffsetInMenuBar)
            Stepper(value: $store.preferences.refreshIntervalSeconds, in: 5...3600, step: 5) {
                Text("Refresh every \(store.preferences.refreshIntervalSeconds)s")
            }
            Stepper(value: $store.preferences.warnThresholdMs, in: 10...10_000, step: 10) {
                Text("Warn when drift > \(store.preferences.warnThresholdMs) ms")
            }
            Section("Auto-sync") {
                Toggle("Sync clock automatically when drift exceeds threshold",
                       isOn: $store.preferences.autoSyncEnabled)
                    .help("Requires the privileged helper to be installed.")
                Stepper(value: $store.preferences.autoSyncMinIntervalSeconds, in: 10...3600, step: 10) {
                    Text("Don't auto-sync more often than every \(store.preferences.autoSyncMinIntervalSeconds)s")
                }
                .disabled(!store.preferences.autoSyncEnabled)
            }
        }
    }

    // MARK: - Helper

    private var helperTab: some View {
        Form {
            LabeledContent("Status", value: store.helperStatus.humanReadable)

            if let v = store.helperVersion {
                LabeledContent("Helper version", value: v)
            }

            if let last = store.lastHelperSync {
                LabeledContent("Last sync") {
                    Text(String(format: "%@ — applied %+.1f ms",
                                last.at.formatted(date: .omitted, time: .standard),
                                last.appliedOffsetMs))
                }
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

            Text("The helper is a small launchd daemon that runs as root. It accepts connections only from this app (verified by code signature) and exposes a single XPC method: set the system clock.")
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
            if let off = store.ntpState.offsetMs {
                LabeledContent("Last offset", value: String(format: "%+.1f ms", off))
            }
            if let rtt = store.ntpState.roundTripMs {
                LabeledContent("Round trip", value: String(format: "%.0f ms", rtt))
            }
        }
    }

    // MARK: - GPS

    private var gpsTab: some View {
        Form {
            HStack {
                Picker("Port", selection: $store.preferences.gpsPort) {
                    Text("(none)").tag("")
                    ForEach(store.availableSerialPorts, id: \.self) { p in
                        Text(p).tag(p)
                    }
                }
                Button {
                    store.refreshAvailableSerialPorts()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
            Picker("Baud", selection: $store.preferences.gpsBaud) {
                ForEach([4800, 9600, 19200, 38400, 57600, 115200], id: \.self) { b in
                    Text("\(b)").tag(b)
                }
            }
            HStack {
                Button(store.gpsState.connected ? "Reconnect" : "Connect") {
                    store.restartGPS()
                }
                Spacer()
                Text(store.gpsState.statusText)
                    .foregroundStyle(store.gpsState.statusColor)
            }
            if let off = store.gpsState.offsetMs {
                LabeledContent("Last offset", value: String(format: "%+.1f ms", off))
            }
        }
    }
}
