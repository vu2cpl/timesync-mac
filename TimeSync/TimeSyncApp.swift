import SwiftUI

@main
struct TimeSyncApp: App {
    @StateObject private var store = AppStore()

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
