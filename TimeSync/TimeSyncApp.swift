// SPDX-License-Identifier: MIT

import SwiftUI

/// The per-app part of UpdateChecker.swift (that file is identical in every
/// VU2CPL app — see its header).
extension UpdateChecker.Configuration {
    static let app = UpdateChecker.Configuration(
        repository: "vu2cpl/timesync-mac", appName: "TimeSync")
}

@main
struct TimeSyncApp: App {
    @StateObject private var store = AppStore()

    init() {
        // About 10 s from now: ask GitHub whether a newer release exists
        // (at most once a day; off via Settings → General).
        UpdateChecker.shared.scheduleAutomaticCheck()
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent()
                .environmentObject(store)
        } label: {
            MenuBarLabel()
                .environmentObject(store)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(store)
                .frame(width: 460, height: 360)
        }
    }
}

struct MenuBarLabel: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: store.menuBarIcon)
            if let ms = store.bestOffsetMs, store.preferences.showOffsetInMenuBar {
                Text(Self.format(ms: ms))
                    .monospacedDigit()
                    .font(.system(size: 11, weight: .medium))
            }
        }
    }

    static func format(ms: Double) -> String {
        let absMs = abs(ms)
        let sign = ms >= 0 ? "+" : "-"
        if absMs < 1_000 {
            return "\(sign)\(Int(absMs.rounded()))ms"
        }
        let s = absMs / 1000.0
        return String(format: "%@%.2fs", sign, s)
    }
}
