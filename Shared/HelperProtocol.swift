import Foundation

/// XPC interface exposed by TimeSyncHelper. Compiled into both the main app and the helper.
@objc public protocol TimeSyncHelperProtocol {
    /// Set the system clock to the given Unix time (seconds since 1970, UTC).
    /// Reply: (success, errorMessage). On success, errorMessage is nil.
    func setSystemTime(unixSeconds: Double, with reply: @escaping (Bool, String?) -> Void)

    /// Returns the helper's version string. Useful as a smoke-test for the connection.
    func getHelperVersion(with reply: @escaping (String) -> Void)
}

/// Shared identifiers. Keep these in sync with project.yml and the LaunchDaemon plist.
public enum HelperConstants {
    public static let mainAppBundleID = "com.vu2cpl.TimeSync"
    public static let helperBundleID  = "com.vu2cpl.TimeSync.Helper"
    public static let machServiceName = "com.vu2cpl.TimeSync.Helper"
    public static let launchdPlistName = "com.vu2cpl.TimeSync.Helper.plist"
}
