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
//  - Automatic check: about 10 s after launch, at most once per 24 h, only
//    while "Check for updates automatically" is on (default on). Silent on any
//    failure (offline, timeout, HTTP 403 rate limit, bad JSON), and silent
//    for a version the user chose to skip.
//  - Manual check (Check for Updates…): always runs and always reports — the
//    update dialog (even for a skipped version), "You're up to date", or
//    "Couldn't check for updates" with the reason.
//  - Update dialog: release notes as plain text (trimmed to ~4000
//    characters), buttons Download / Skip This Version / Remind Me Later.
//  - The current version is CFBundleShortVersionString. An unbundled
//    `swift run` build has none: a manual check says so, an automatic one
//    stays quiet.
//
// UserDefaults keys, in the app's own domain:
//   UpdateCheck.automatic  Bool, absent = on
//   UpdateCheck.lastCheck  seconds since 1970 of the last check GitHub answered
//                          (a check that never reached GitHub, e.g. offline,
//                          does not count, so the next launch tries again)
//   UpdateCheck.skippedTag the release tag the user chose to skip
//
// TEST HOOK (inert unless set): the environment variable
// UPDATE_CHECK_TEST_CURRENT_VERSION replaces the current version, so the
// dialog can be seen against the real latest release. Quit the app, then
//     open --env UPDATE_CHECK_TEST_CURRENT_VERSION=0.0.1 /Applications/<App>.app
// and choose Check for Updates… (an automatic check uses it too, subject to
// the 24 h gate).

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

        /// GitHub answered (as opposed to the request never arriving), so
        /// the attempt counts towards the once-a-day limit.
        var reachedGitHub: Bool {
            switch self {
            case .rateLimited, .noRelease, .http, .unreadable: return true
            case .noCurrentVersion, .network: return false
            }
        }
    }

    nonisolated static let automaticChecksKey = "UpdateCheck.automatic"
    nonisolated static let lastCheckKey = "UpdateCheck.lastCheck"
    nonisolated static let skippedTagKey = "UpdateCheck.skippedTag"
    nonisolated static let testVersionVariable = "UPDATE_CHECK_TEST_CURRENT_VERSION"
    nonisolated static let launchDelaySeconds: UInt64 = 10
    nonisolated static let minimumInterval: TimeInterval = 24 * 60 * 60
    nonisolated static let requestTimeout: TimeInterval = 10
    nonisolated static let notesLimit = 4000

    static let shared = UpdateChecker(configuration: .app)

    let configuration: Configuration
    private let defaults: UserDefaults
    private var scheduled = false
    private var checking = false
    private var reportPending = false

    init(configuration: Configuration, defaults: UserDefaults = .standard) {
        self.configuration = configuration
        self.defaults = defaults
    }

    // MARK: - Entry points

    /// The "Check for updates automatically" setting. Absent means on.
    var automaticChecksEnabled: Bool {
        get { defaults.object(forKey: Self.automaticChecksKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Self.automaticChecksKey) }
    }

    /// Call once at launch: about 10 s later, checks if enabled and due.
    /// Further calls are ignored.
    func scheduleAutomaticCheck() {
        guard !scheduled else { return }
        scheduled = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: Self.launchDelaySeconds * 1_000_000_000)
            guard self.automaticChecksEnabled,
                  Self.isDue(lastCheck: self.defaults.double(forKey: Self.lastCheckKey),
                             now: Date().timeIntervalSince1970) else { return }
            await self.check(userInitiated: false)
        }
    }

    /// Check for Updates… — always runs, always reports.
    func checkNow() {
        Task { @MainActor in await self.check(userInitiated: true) }
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

        guard let current = Self.currentVersion() else {
            if userInitiated { presentFailure(Failure.noCurrentVersion) }
            return
        }

        let outcome: Result<Release, Failure>
        do {
            outcome = .success(try await Self.fetchLatestRelease(
                configuration: configuration, currentVersion: current))
        } catch let failure as Failure {
            outcome = .failure(failure)
        } catch {
            outcome = .failure(.network(error.localizedDescription))
        }
        let report = userInitiated || reportPending

        switch outcome {
        case .success(let release):
            defaults.set(Date().timeIntervalSince1970, forKey: Self.lastCheckKey)
            if Self.isVersion(release.tagName, newerThan: current) {
                if !report && defaults.string(forKey: Self.skippedTagKey) == release.tagName {
                    return
                }
                presentUpdate(release, currentVersion: current)
            } else if report {
                presentUpToDate(currentVersion: current, latest: release)
            }
        case .failure(let failure):
            if failure.reachedGitHub {
                defaults.set(Date().timeIntervalSince1970, forKey: Self.lastCheckKey)
            }
            if report { presentFailure(failure) }
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

    /// Due when never checked, when 24 h have passed, or when the stored time
    /// lies in the future (the clock was wrong when it was written — that
    /// must not block checks until the clock catches up).
    nonisolated static func isDue(lastCheck: TimeInterval, now: TimeInterval) -> Bool {
        if lastCheck <= 0 { return true }
        let elapsed = now - lastCheck
        return elapsed < 0 || elapsed >= minimumInterval
    }

    /// CFBundleShortVersionString, unless the test hook replaces it.
    nonisolated static func currentVersion(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundle: Bundle = .main
    ) -> String? {
        if let test = environment[testVersionVariable]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !test.isEmpty {
            return test
        }
        if let version = (bundle.infoDictionary?["CFBundleShortVersionString"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !version.isEmpty {
            return version
        }
        return nil
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

    private func presentUpdate(_ release: Release, currentVersion: String) {
        let alert = makeUpdateAlert(release: release, currentVersion: currentVersion)
        Self.bringAppForward()
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            if let page = Self.releasePage(for: release, repository: configuration.repository) {
                NSWorkspace.shared.open(page)
            }
        case .alertSecondButtonReturn:
            defaults.set(release.tagName, forKey: Self.skippedTagKey)
        default:
            break   // Remind Me Later: the next automatic check asks again.
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
        Self.bringAppForward()
        alert.runModal()
    }

    private func presentFailure(_ failure: Failure) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Couldn't check for updates"
        alert.informativeText = failure.errorDescription ?? "Unknown error."
        Self.bringAppForward()
        alert.runModal()
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
                .help("About 10 seconds after launch, at most once a day, ask GitHub (api.github.com) whether a newer release exists. Nothing is downloaded or installed automatically.")
        }
    }
}
