// SPDX-License-Identifier: MIT

import Foundation

/// XPC interface exposed by TimeSyncHelper. Compiled into both the main app and the helper.
@objc public protocol TimeSyncHelperProtocol {
    /// Ask chrony to immediately step the system clock to its current best estimate
    /// (runs `/opt/homebrew/bin/chronyc makestep`). This is the supported way to force
    /// a re-discipline; chrony stays the sole owner of clock-setting decisions.
    /// Reply: (success, errorMessage). On success, errorMessage is nil.
    func runChronyMakestep(with reply: @escaping (Bool, String?) -> Void)

    /// Returns the helper's version string. Useful as a smoke-test for the connection.
    func getHelperVersion(with reply: @escaping (String) -> Void)

    /// Legacy: set the system clock directly to a Unix timestamp. Kept so older builds
    /// of the main app can still use an installed helper, but the new UI no longer
    /// calls this — chrony manages the clock now and direct sets just create conflict.
    func setSystemTime(unixSeconds: Double, with reply: @escaping (Bool, String?) -> Void)
}

/// Shared identifiers. Keep these in sync with project.yml and the LaunchDaemon plist.
public enum HelperConstants {
    public static let mainAppBundleID = "com.vu2cpl.TimeSync"
    public static let helperBundleID  = "com.vu2cpl.TimeSync.Helper"
    public static let machServiceName = "com.vu2cpl.TimeSync.Helper"
    public static let launchdPlistName = "com.vu2cpl.TimeSync.Helper.plist"
}
