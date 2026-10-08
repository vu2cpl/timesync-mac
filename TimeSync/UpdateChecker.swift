// UpdateChecker.swift — "is there a newer release on GitHub?" for VU2CPL's macOS apps.
//
// One self-contained file, kept byte-for-byte IDENTICAL in every app that uses
// it (timesync-mac, DXClusterAggregator-macOS, kst2mac, macexpert-spe,
// AmateurRadioSuite), so a fix made in one copy is copied to the others as a
// whole file. The only per-app part lives in the app, next to its @main:
//
//     extension UpdateChecker.Configuration {
//         static let app = UpdateChecker.Configuration(
//             repository: "vu2cpl/kst2mac", appName: "KST2Mac")
//     }
//
// The app then calls `UpdateChecker.shared.scheduleAutomaticCheck()` once at
// launch, puts `UpdateChecker.CheckButton()` in its app menu after About, and
// `UpdateChecker.AutomaticToggle()` in its settings.
//
// WHAT IT DOES
//  - Exactly one request per check, and no other network traffic:
//      GET https://api.github.com/repos/<repository>/releases/latest
//      Accept: application/vnd.github+json, User-Agent: <AppName>/<version>
//    10 s timeout, no token, no cookies, no cache. That endpoint never returns
//    drafts or prereleases. Nothing is downloaded or installed: Download opens
//    the release page in the default browser.
//  - Versions compare numerically: a leading "v" is dropped, both sides are
//    split into integers on any non-digit and compared as tuples, missing
//    parts counting as 0 (1.10 > 1.2, v0.7.10 > 0.7.2, 2.0 == 2.0.0).
//  - Automatic check: about 10 s after launch, then again from an hourly
//    timer for as long as the app runs (these apps stay up for days or weeks).
//    An attempt goes ahead only when "Check for updates automatically" is on
//    (default on), 24 h have passed since the last SUCCESSFUL check, at least
//    1 h has passed since a failed automatic attempt, and none of this
//    checker's dialogs is open (never two at once). Silent on any failure
//    (offline, timeout, any HTTP error including the 403 rate limit, bad
//    JSON), and silent for a version the user chose to skip.
//  - Success means GitHub answered HTTP 200 with JSON carrying a tag_name,
//    whether or not that release is newer. Only a success stores the check
//    time. A failure stores nothing, so the next launch tries again; a failed
//    AUTOMATIC attempt also holds automatic attempts off for 1 h, kept in
//    memory only.
//  - Development builds never check on their own: when the version contains
//    "dev" (any case — e.g. MacExpert's build-app.sh stamps 0.0.0-dev), there
//    is no request at launch or from the timer. Check for Updates… still works.
//  - Manual check (Check for Updates…): always runs and always reports — the
//    update dialog (even for a skipped version), "You're up to date", or
//    "Couldn't check for updates" with the reason. A manual check that fails
//    leaves the stored time and the back-off alone; one that succeeds stores
//    the time like any successful check.
//  - Update dialog: release notes as plain text (trimmed to ~4000
//    characters), buttons Download / Skip This Version / Remind Me Later.
//  - The current version is CFBundleShortVersionString. An unbundled
//    `swift run` build has none: a manual check says so, an automatic one
//    stays quiet.
//
// UserDefaults keys, in the app's own domain:
//   UpdateCheck.automatic  Bool, absent = on
//   UpdateCheck.lastCheck  seconds since 1970 of the last SUCCESSFUL check
//                          (HTTP 200 with a tag_name); no failure — offline,
//                          timeout, HTTP error, bad JSON — ever writes it
//   UpdateCheck.skippedTag the release tag the user chose to skip
//
// TEST HOOK (inert unless set): the environment variable
// UPDATE_CHECK_TEST_CURRENT_VERSION replaces the current version, so the
// dialog can be seen against the real latest release. Quit the app, then
//     open --env UPDATE_CHECK_TEST_CURRENT_VERSION=0.0.1 /Applications/<App>.app
// and choose Check for Updates…. Automatic checks use it too, subject to the
// 24 h gate; the "dev" rule above does not apply to it.

import AppKit
import Foundation
import SwiftUI

@MainActor
final class UpdateChecker {

    /// What differs between apps. Each app defines `Configuration.app`.
    struct Configuration: Sendable {
        /// GitHub "owner/name" whose releases are checked.
        let repository: String
        /// Shown in the dialogs; with spaces removed it is the User-Agent product.
        let appName: String
    }

    /// The fields read from GitHub's release JSON.
    struct Release: Decodable, Sendable, Equatable {
        let tagName: String
        let name: String?
        let htmlURL: String?
        let body: String?

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case name
            case htmlURL = "html_url"
            case body
        }

        /// The tag without its leading "v" — what the dialogs call the version.
        var version: String { UpdateChecker.displayVersion(tagName) }
    }

    enum Failure: LocalizedError, Sendable, Equatable {
        case noCurrentVersion
        case network(String)
        case rateLimited
        case noRelease
        case http(Int)
        case unreadable

        var errorDescription: String? {
            switch self {
            case .noCurrentVersion:
                return "This build has no version number (CFBundleShortVersionString), so there is nothing to compare. Release builds always carry one."
            case .network(let reason):
                return reason
            case .rateLimited:
                return "GitHub refused the request: the hourly limit for anonymous requests from this network is used up. Try again in an hour."
            case .noRelease:
                return "GitHub has no published release of this app yet."
            case .http(let status):
                return "GitHub answered with HTTP status \(status)."
            case .unreadable:
                return "GitHub's answer could not be read."
            }
        }
    }

    /// What a finished check puts on screen.
    enum Outcome: Sendable, Equatable {
        case silent
        case update(Release)
        case upToDate(Release)
        case failed(Failure)
    }

    /// The one network request, as `fetchLatestRelease`; a test can pass a
    /// stand-in for GitHub.
    typealias Fetch = @Sendable (Configuration, String) async throws -> Release

    nonisolated static let automaticChecksKey = "UpdateCheck.automatic"
    nonisolated static let lastCheckKey = "UpdateCheck.lastCheck"
    nonisolated static let skippedTagKey = "UpdateCheck.skippedTag"
    nonisolated static let testVersionVariable = "UPDATE_CHECK_TEST_CURRENT_VERSION"
    nonisolated static let launchDelaySeconds: UInt64 = 10
    /// The once-a-day gate, counted from the last successful check.
    nonisolated static let minimumInterval: TimeInterval = 24 * 60 * 60
    /// The re-check timer while the app runs: one tick an hour, counted from
    /// the end of the previous attempt, a few minutes' slack allowed.
    nonisolated static let recheckInterval: TimeInterval = 60 * 60
    nonisolated static let recheckTolerance: TimeInterval = 5 * 60
    /// No automatic attempt for this long after a failed automatic attempt.
    nonisolated static let failureBackoff: TimeInterval = 60 * 60
    nonisolated static let requestTimeout: TimeInterval = 10
    nonisolated static let notesLimit = 4000

    static let shared = UpdateChecker(configuration: .app)

    let configuration: Configuration
    private let defaults: UserDefaults
    private let fetch: Fetch
    private var scheduled = false
    private var checking = false
    private var reportPending = false
    /// True while one of this checker's dialogs is on screen.
    private(set) var dialogOpen = false
    /// When the last automatic attempt failed (seconds since 1970). Memory
    /// only: a relaunch starts without a back-off.
    private(set) var lastAutomaticFailure: TimeInterval?

    init(configuration: Configuration, defaults: UserDefaults = .standard,
         fetch: @escaping Fetch = { configuration, currentVersion in
             try await UpdateChecker.fetchLatestRelease(
                 configuration: configuration, currentVersion: currentVersion)
         }) {
        self.configuration = configuration
        self.defaults = defaults
        self.fetch = fetch
    }

    // MARK: - Entry points

    /// The "Check for updates automatically" setting. Absent means on.
    var automaticChecksEnabled: Bool {
        get { defaults.object(forKey: Self.automaticChecksKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Self.automaticChecksKey) }
    }

    /// Call once at launch: about 10 s later, and then every hour for as long
    /// as the app runs, makes an automatic attempt when
    /// `shouldCheckAutomatically` allows it. A development build (or one with
    /// no version) gets neither. Further calls are ignored.
    func scheduleAutomaticCheck() {
        guard !scheduled else { return }
        scheduled = true
        guard Self.automaticCheckVersion() != nil else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: Self.launchDelaySeconds * 1_000_000_000)
            while true {
                await self.automaticCheckIfDue()
                // The hourly timer. Each tick is counted from the end of the
                // previous attempt, so a failed attempt's back-off is always
                // over by the next tick. Tolerance only ever delays a tick.
                do {
                    try await Task.sleep(for: .seconds(Self.recheckInterval),
                                         tolerance: .seconds(Self.recheckTolerance))
                } catch {
                    return   // cancelled
                }
            }
        }
    }

    /// Check for Updates… — always runs, always reports.
    func checkNow() {
        Task { @MainActor in await self.check(userInitiated: true) }
    }

    /// One automatic attempt, if it is allowed right now — what the launch
    /// check and every timer tick run.
    func automaticCheckIfDue() async {
        guard Self.shouldCheckAutomatically(
            enabled: automaticChecksEnabled,
            lastSuccess: defaults.double(forKey: Self.lastCheckKey),
            lastFailure: lastAutomaticFailure,
            dialogOpen: dialogOpen,
            now: Date().timeIntervalSince1970) else { return }
        await check(userInitiated: false)
    }

    // MARK: - The check

    private func check(userInitiated: Bool) async {
        // One request at a time. A manual check that arrives while an
        // automatic one is in flight makes that one report its result.
        if checking {
            if userInitiated { reportPending = true }
            return
        }
        checking = true
        defer {
            checking = false
            reportPending = false
        }

        // A manual check compares whatever version this is, "dev" included;
        // an automatic one never runs for a development build.
        let version = userInitiated ? Self.currentVersion() : Self.automaticCheckVersion()
        guard let current = version else {
            if userInitiated { present(.failed(.noCurrentVersion), currentVersion: "") }
            return
        }

        let result: Result<Release, Failure>
        do {
            result = .success(try await fetch(configuration, current))
        } catch let failure as Failure {
            result = .failure(failure)
        } catch {
            result = .failure(.network(error.localizedDescription))
        }
        let outcome = record(result, currentVersion: current, automatic: !userInitiated,
                             report: userInitiated || reportPending,
                             now: Date().timeIntervalSince1970)
        present(outcome, currentVersion: current)
    }

    /// Stores what a finished check means for the throttle and says what to
    /// show. Only a success (HTTP 200 + tag_name, newer or not) stores the
    /// time, and it ends any back-off. A failure stores nothing, so the next
    /// launch tries again; a failed automatic attempt starts the 1 h back-off,
    /// in memory only. A failed manual check changes nothing at all.
    func record(_ result: Result<Release, Failure>, currentVersion: String,
                automatic: Bool, report: Bool, now: TimeInterval) -> Outcome {
        switch result {
        case .success(let release):
            defaults.set(now, forKey: Self.lastCheckKey)
            lastAutomaticFailure = nil
            if Self.isVersion(release.tagName, newerThan: currentVersion) {
                if !report && defaults.string(forKey: Self.skippedTagKey) == release.tagName {
                    return .silent
                }
                return .update(release)
            }
            return report ? .upToDate(release) : .silent
        case .failure(let failure):
            if automatic { lastAutomaticFailure = now }
            return report ? .failed(failure) : .silent
        }
    }

    // MARK: - Pure logic (no UI, no state) — testable on its own

    /// The tag or version without surrounding space and a leading "v"/"V".
    nonisolated static func displayVersion(_ version: String) -> String {
        let trimmed = version.trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = trimmed.first, first == "v" || first == "V" {
            return String(trimmed.dropFirst())
        }
        return trimmed
    }

    /// "v1.10.2-rc3" → [1, 10, 2, 3]: integers split on any non-digit.
    nonisolated static func versionComponents(_ version: String) -> [Int] {
        displayVersion(version)
            .split(whereSeparator: { !($0.isASCII && $0.isNumber) })
            .map { Int($0) ?? Int.max }
    }

    /// True only if `candidate` is strictly greater, compared as integer
    /// tuples with missing components counting as 0.
    nonisolated static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        let a = versionComponents(candidate)
        let b = versionComponents(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// Due when never checked successfully, when 24 h have passed since the
    /// last success, or when the stored time lies in the future (the clock
    /// was wrong when it was written — that must not block checks until the
    /// clock catches up).
    nonisolated static func isDue(lastCheck: TimeInterval, now: TimeInterval) -> Bool {
        if lastCheck <= 0 { return true }
        let elapsed = now - lastCheck
        return elapsed < 0 || elapsed >= minimumInterval
    }

    /// The rule for every automatic attempt, at launch and on each timer
    /// tick: the setting is on, 24 h have passed since the last successful
    /// check, the 1 h back-off after a failed automatic attempt is over (a
    /// failure time in the future — the clock stepped back — does not hold
    /// it), and none of this checker's dialogs is open.
    nonisolated static func shouldCheckAutomatically(
        enabled: Bool, lastSuccess: TimeInterval, lastFailure: TimeInterval?,
        dialogOpen: Bool, now: TimeInterval
    ) -> Bool {
        guard enabled, !dialogOpen, isDue(lastCheck: lastSuccess, now: now) else { return false }
        if let lastFailure {
            let elapsed = now - lastFailure
            if elapsed >= 0 && elapsed < failureBackoff { return false }
        }
        return true
    }

    /// A version string that marks a development build: it contains "dev",
    /// in any case ("0.0.0-dev", "1.2-DEV").
    nonisolated static func isDevelopmentVersion(_ version: String) -> Bool {
        version.range(of: "dev", options: .caseInsensitive) != nil
    }

    /// CFBundleShortVersionString, unless the test hook replaces it — what a
    /// manual check compares against.
    nonisolated static func currentVersion(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundle: Bundle = .main
    ) -> String? {
        testVersion(environment: environment) ?? bundleVersion(bundle)
    }

    /// What an automatic check compares against, or nil when automatic
    /// checks must not run: a development build, or a build with no version.
    /// The test hook replaces the version here too and is not subject to the
    /// "dev" rule.
    nonisolated static func automaticCheckVersion(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundle: Bundle = .main
    ) -> String? {
        if let test = testVersion(environment: environment) { return test }
        guard let version = bundleVersion(bundle), !isDevelopmentVersion(version) else {
            return nil
        }
        return version
    }

    private nonisolated static func testVersion(environment: [String: String]) -> String? {
        guard let test = environment[testVersionVariable]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !test.isEmpty else { return nil }
        return test
    }

    private nonisolated static func bundleVersion(_ bundle: Bundle) -> String? {
        guard let version = (bundle.infoDictionary?["CFBundleShortVersionString"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !version.isEmpty else { return nil }
        return version
    }

    /// Release notes as plain text: line endings normalised, trimmed to
    /// about `limit` characters (at a line break where one is near).
    nonisolated static func plainNotes(_ body: String?, limit: Int = notesLimit) -> String {
        let text = (body ?? "")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return "No release notes were published with this release." }
        guard text.count > limit else { return text }
        var cut = String(text.prefix(limit))
        if let newline = cut.lastIndex(of: "\n"),
           cut.distance(from: cut.startIndex, to: newline) > limit / 2 {
            cut = String(cut[..<newline])
        }
        return cut + "\n\n… (trimmed — the full notes are on the release page)"
    }

    /// The release page to open: GitHub's html_url when it is a github.com
    /// https link, else the repository's latest-release page.
    nonisolated static func releasePage(for release: Release, repository: String) -> URL? {
        if let link = release.htmlURL, let url = URL(string: link),
           url.scheme == "https", url.host == "github.com" {
            return url
        }
        return URL(string: "https://github.com/\(repository)/releases/latest")
    }

    /// The one network request.
    nonisolated static func fetchLatestRelease(
        configuration: Configuration, currentVersion: String
    ) async throws -> Release {
        guard let url = URL(string: "https://api.github.com/repos/\(configuration.repository)/releases/latest")
        else { throw Failure.unreadable }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: requestTimeout)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let product = configuration.appName.filter { !$0.isWhitespace }
        request.setValue("\(product)/\(displayVersion(currentVersion))",
                         forHTTPHeaderField: "User-Agent")

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.timeoutIntervalForRequest = requestTimeout
        sessionConfiguration.timeoutIntervalForResource = requestTimeout
        let session = URLSession(configuration: sessionConfiguration)
        defer { session.finishTasksAndInvalidate() }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw Failure.network(error.localizedDescription)
        }
        return try release(from: data, response: response)
    }

    /// GitHub's answer → the release, or the Failure that describes it. Only
    /// HTTP 200 whose JSON carries a non-empty tag_name is a success.
    nonisolated static func release(from data: Data, response: URLResponse) throws -> Release {
        guard let http = response as? HTTPURLResponse else { throw Failure.unreadable }
        switch http.statusCode {
        case 200:
            break
        case 404:
            throw Failure.noRelease
        case 429:
            throw Failure.rateLimited
        case 403 where http.value(forHTTPHeaderField: "x-ratelimit-remaining") == "0":
            throw Failure.rateLimited
        default:
            throw Failure.http(http.statusCode)
        }
        guard let release = try? JSONDecoder().decode(Release.self, from: data),
              !release.tagName.isEmpty
        else { throw Failure.unreadable }
        return release
    }

    // MARK: - Dialogs

    /// Built separately from showing it, so it can be rendered in a test.
    func makeUpdateAlert(release: Release, currentVersion: String) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "\(configuration.appName) \(release.version) is available"
        alert.informativeText = "You have \(Self.displayVersion(currentVersion))."
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Skip This Version")
        alert.addButton(withTitle: "Remind Me Later").keyEquivalent = "\u{1b}"
        alert.accessoryView = Self.notesView(for: release)
        return alert
    }

    private func present(_ outcome: Outcome, currentVersion: String) {
        switch outcome {
        case .silent:
            break
        case .update(let release):
            presentUpdate(release, currentVersion: currentVersion)
        case .upToDate(let release):
            presentUpToDate(currentVersion: currentVersion, latest: release)
        case .failed(let failure):
            presentFailure(failure)
        }
    }

    /// Every dialog of this checker runs through here, so `dialogOpen` is
    /// true while one is on screen and the timer never adds a second.
    private func runModal(_ alert: NSAlert) -> NSApplication.ModalResponse {
        dialogOpen = true
        defer { dialogOpen = false }
        Self.bringAppForward()
        return alert.runModal()
    }

    private func presentUpdate(_ release: Release, currentVersion: String) {
        let alert = makeUpdateAlert(release: release, currentVersion: currentVersion)
        switch runModal(alert) {
        case .alertFirstButtonReturn:
            if let page = Self.releasePage(for: release, repository: configuration.repository) {
                NSWorkspace.shared.open(page)
            }
        case .alertSecondButtonReturn:
            defaults.set(release.tagName, forKey: Self.skippedTagKey)
        default:
            break   // Remind Me Later: the next due automatic check (a day on) asks again.
        }
    }

    private func presentUpToDate(currentVersion: String, latest: Release) {
        let current = Self.displayVersion(currentVersion)
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "You're up to date"
        if Self.isVersion(currentVersion, newerThan: latest.tagName) {
            alert.informativeText = "\(configuration.appName) \(current) is newer than the latest release (\(latest.version))."
        } else {
            alert.informativeText = "\(configuration.appName) \(current) is the latest version."
        }
        _ = runModal(alert)
    }

    private func presentFailure(_ failure: Failure) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Couldn't check for updates"
        alert.informativeText = failure.errorDescription ?? "Unknown error."
        _ = runModal(alert)
    }

    private static func notesView(for release: Release) -> NSView {
        let scroll = NSTextView.scrollableTextView()
        scroll.frame = NSRect(x: 0, y: 0, width: 460, height: 240)
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        guard let text = scroll.documentView as? NSTextView else { return scroll }
        text.isEditable = false
        text.isSelectable = true
        text.textContainerInset = NSSize(width: 6, height: 6)

        let notes = NSMutableAttributedString()
        if let name = release.name?.trimmingCharacters(in: .whitespacesAndNewlines),
           !name.isEmpty, displayVersion(name) != release.version {
            notes.append(NSAttributedString(string: name + "\n\n", attributes: [
                .font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize),
                .foregroundColor: NSColor.textColor,
            ]))
        }
        notes.append(NSAttributedString(string: plainNotes(release.body), attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.textColor,
        ]))
        text.textStorage?.setAttributedString(notes)
        return scroll
    }

    /// A menu-bar-only app (or one in the background) would otherwise put the
    /// dialog behind whatever is in front. On macOS 14+ this is cooperative
    /// activation: the system may decline rather than steal focus.
    private static func bringAppForward() {
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    // MARK: - SwiftUI pieces for the app's menu and settings

    /// "Check for Updates…" — for the app menu, after About.
    struct CheckButton: View {
        init() {}

        var body: some View {
            Button("Check for Updates…") { UpdateChecker.shared.checkNow() }
        }
    }

    /// The "Check for updates automatically" checkbox (default on).
    struct AutomaticToggle: View {
        @AppStorage(UpdateChecker.automaticChecksKey) private var enabled = true

        init() {}

        var body: some View {
            Toggle("Check for updates automatically", isOn: $enabled)
                .help("About 10 seconds after launch, and once a day while the app keeps running, ask GitHub (api.github.com) whether a newer release exists. Development builds never ask on their own. Nothing is downloaded or installed automatically.")
        }
    }
}
