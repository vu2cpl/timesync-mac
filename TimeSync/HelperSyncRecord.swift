import Foundation

/// One successful sync via the privileged helper.
struct HelperSyncRecord: Equatable {
    let at: Date
    let appliedOffsetMs: Double
}
