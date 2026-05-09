// SPDX-License-Identifier: MIT

import SwiftUI

struct SourceState: Equatable {
    enum Status: Equatable {
        case idle
        case connecting
        case ok
        case noFix         // GPS specific
        case warning(String)
        case error(String)
    }

    var status: Status = .idle
    var offsetMs: Double? = nil
    var roundTripMs: Double? = nil
    var satellites: Int? = nil
    var lastUpdate: Date? = nil
    var connected: Bool = false

    var statusText: String {
        switch status {
        case .idle: return "Idle"
        case .connecting: return "Connecting…"
        case .ok: return "OK"
        case .noFix: return "No fix"
        case .warning(let msg): return "Warning: \(msg)"
        case .error(let msg): return "Error: \(msg)"
        }
    }

    var statusColor: Color {
        switch status {
        case .idle: return .gray
        case .connecting: return .blue
        case .ok: return .green
        case .noFix, .warning: return .orange
        case .error: return .red
        }
    }

    var offsetColor: Color {
        guard let off = offsetMs else { return .secondary }
        let absOff = abs(off)
        if absOff < 50 { return .green }
        if absOff < 250 { return .orange }
        return .red
    }
}
