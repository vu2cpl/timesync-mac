# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this app is

A macOS menubar app that displays system clock drift against NTP and a GPS source, and (optionally) sets the system clock via a privileged launchd helper. Aimed at ham radio operators who need ~1-second accuracy for digital modes (FT8 etc.). The author is VU2CPL.

The repo also contains [`server/`](server/) — chrony + gpsd LaunchDaemon configs that turn this Mac into a GPS-disciplined NTP server for the local LAN, useful for remote field operation with no internet. The Swift app talks to that gpsd instance (or any other) over TCP.

## Build / run

```bash
./generate.sh                                                  # XcodeGen → TimeSync.xcodeproj
xcodebuild -project TimeSync.xcodeproj -scheme TimeSync build  # full build (app + helper)
xcodebuild -project TimeSync.xcodeproj -scheme TimeSyncHelper build  # helper only
open ~/Library/Developer/Xcode/DerivedData/TimeSync-*/Build/Products/Debug/TimeSync.app
```

`TimeSync.xcodeproj` is **gitignored** — `project.yml` is the source of truth. Regenerate after any structural change. Brew dependency: `xcodegen`.

## Release (universal binary, signed + notarized + stapled)

Latest release: **v0.1.7** (2026-10-09 — notarized, stapled, universal; the first with the update check). Download the asset back after publishing and check it before calling a release done.

Notarization keychain profile is **`timesync`** (created once via `xcrun notarytool store-credentials timesync --apple-id vu2cpl@gmail.com --team-id CHVNJ85C9F`). Do not assume the default `AC_PASSWORD` name. Verify the profile exists with `xcrun notarytool history --keychain-profile timesync`.

```bash
# 1. Bump version in project.yml: MARKETING_VERSION + CURRENT_PROJECT_VERSION

# 2. Regenerate + universal Release build (Debug defaults to ONLY_ACTIVE_ARCH=YES,
#    so the arch flags must be forced explicitly or the binary ships arm64-only)
./generate.sh
rm -rf build
xcodebuild -project TimeSync.xcodeproj -scheme TimeSync \
  -configuration Release -derivedDataPath build \
  ONLY_ACTIVE_ARCH=NO ARCHS="arm64 x86_64" build

APP=build/Build/Products/Release/TimeSync.app
lipo -info "$APP/Contents/MacOS/TimeSync"        # expect: x86_64 arm64
lipo -info "$APP/Contents/MacOS/TimeSyncHelper"  # expect: x86_64 arm64

# 3. Submit, staple, repack
ditto -c -k --norsrc --keepParent "$APP" /tmp/TimeSync-submit.zip
xcrun notarytool submit /tmp/TimeSync-submit.zip --keychain-profile timesync --wait
xcrun stapler staple "$APP"
spctl -a -vvv "$APP"                              # expect: Notarized Developer ID, accepted
ditto -c -k --norsrc --keepParent "$APP" TimeSync-X.Y.Z.zip
zipinfo -1 TimeSync-X.Y.Z.zip | grep -c '\._'      # expect: 0 (no AppleDouble entries)
shasum -a 256 TimeSync-X.Y.Z.zip                  # paste into release notes

# 4. Tag + GitHub release
git tag vX.Y.Z && git push origin main && git push origin vX.Y.Z
gh release create vX.Y.Z TimeSync-X.Y.Z.zip --title "..." --notes-file ...
# 5. Download the asset back, check its sha256, `ditto -x -k` it, spctl it
```

Use `ditto -c -k --norsrc --keepParent`, never `zip -r` — `zip` mangles xattrs/symlinks inside .app bundles and Gatekeeper rejects the unpacked app. `--norsrc` keeps AppleDouble `._*` entries out of the zip (v0.1.6 and earlier carried 15 of them; since v0.1.7 there are none), so a non-Apple unzipper can't drop them into the bundle and break its seal. Staple the .app *before* the final zip, not the zip itself; otherwise users hit Apple's notary network on first launch (slow, fails offline).

The app is `LSUIElement = true` (no Dock icon, menubar only). To inspect runtime behavior, run the binary directly so `NSLog` goes to stderr:

```bash
APP=~/Library/Developer/Xcode/DerivedData/TimeSync-*/Build/Products/Debug/TimeSync.app
"$APP/Contents/MacOS/TimeSync" 2>/tmp/timesync.err
```

## Architecture

Two Mach-O targets, sharing `Shared/HelperProtocol.swift`:

```
TimeSync.app/                              ← main app (com.vu2cpl.TimeSync)
├── Contents/MacOS/TimeSync                ← SwiftUI app, runs as user
├── Contents/MacOS/TimeSyncHelper          ← helper, run as root by launchd
└── Contents/Library/LaunchDaemons/com.vu2cpl.TimeSync.Helper.plist
```

**Data flow on the main side:**
- `ChronyMonitor` (subprocess invocation of `chronyc -c tracking` every 5s) → parses CSV → publishes `ChronyTracking`. **This is the canonical "what is my system clock offset?" source for the UI** — chrony filters across all its sources (GPS via SHM, internet pool) and gives a stable, smooth number. Single-sample per-source offsets (next two below) are for diagnostics only.
- `GPSDClient` (TCP to `gpsd` on `localhost:2947`, JSON line-protocol) → parses TPV / SKY messages → emits `GPSUpdate { fix | noFix }` → `AppStore.applyGPSUpdate` → `@Published gpsState`. The single-sample offset here is noisy (TCP/JSON arrival latency); don't rely on it for the headline drift.
- `NTPClient` (pure-Swift SNTPv4 over UDP/123 via `Network.framework`) — polls every `refreshIntervalSeconds`. Same caveat: per-poll offset is single-sample and noisy.

`AppStore.bestOffsetMs` returns chrony's view first; falls back to per-source if chrony is unreachable.

**Update check:** `TimeSync/UpdateChecker.swift` — one anonymous `GET https://api.github.com/repos/vu2cpl/timesync-mac/releases/latest` about 10 s after launch and again from an hourly timer while the app runs, at most once per 24 h after the last *successful* check (HTTP 200 + `tag_name`; a failure stores nothing, and a failed automatic attempt holds automatic ones off for 1 h, in memory only), never on its own for a development build (version containing "dev"), and only while Settings → General → "Check for updates automatically" is on (default on; UserDefaults `UpdateCheck.*`, deliberately *not* inside the `Preferences` JSON blob — a new non-optional field there would make every old blob fail to decode). The file is **byte-identical** across VU2CPL's Swift apps (timesync-mac, DXClusterAggregator-macOS, kst2mac, macexpert-spe, AmateurRadioSuite): fix it in one, copy the whole file to the others. The per-app part is the `UpdateChecker.Configuration.app` extension in `TimeSyncApp.swift`. Being `LSUIElement`, TimeSync has no app menu, so the **Check for Updates…** button sits in Settings → General beside the toggle. To see the dialog against the real latest release: quit TimeSync, `open --env UPDATE_CHECK_TEST_CURRENT_VERSION=0.0.1 <path>/TimeSync.app`, then Settings → Check for Updates….

Note: the app no longer opens the GPS serial device itself — `gpsd` owns the port and the app is one of its TCP clients. This lets the same Mac simultaneously feed GPS time to chrony (via shared memory) AND show GPS state in TimeSync's menubar, without two processes fighting for `/dev/cu.usbserial-*`. See [`server/`](server/) for the chrony + gpsd LaunchDaemons.

**Step Clock path:** user clicks "Step Clock" → `AppStore.chronyMakestep` → `HelperClient.runChronyMakestep` → XPC to helper → helper validates the caller's `SecCode` against `identifier "com.vu2cpl.TimeSync"` → spawns `/opt/homebrew/bin/chronyc makestep`. Chrony then immediately steps the system clock to its current best estimate. Used to recover when chrony has lost quorum and fallen back to local stratum 8.

The helper's protocol still includes a legacy `setSystemTime(unixSeconds:)` method for backward compat with older app builds — but the current app never calls it. **Don't add new direct-clock-setting code paths**: chrony is the sole owner of clock discipline. If you need a different chrony command exposed (e.g. `burst`, `cyclelogs`), add it to `TimeSyncHelperProtocol` alongside `runChronyMakestep`.

**Helper installation:** `HelperClient.install()` calls `SMAppService.daemon(plistName:).register()`. First call shows a system admin prompt. The helper survives main-app restarts (launchd manages its lifecycle); only re-register when the helper plist or binary changes. After updating the helper binary in a new build, run `sudo launchctl kickstart -k system/com.vu2cpl.TimeSync.Helper` to force launchd to relaunch with the new binary (or just bump `CFBundleVersion` in `TimeSyncHelper/Helper-Info.plist`).

**State propagation:** `HelperClient` is its own `ObservableObject`, but `AppStore` mirrors its `@Published` properties (`status`, `lastError`, `helperVersion`, `lastMakestepAt`) via Combine `assign(to:)` so SwiftUI views only need to observe `AppStore`.

## Code signing — required, not optional

Both targets must be signed with the **same Team ID** (`CHVNJ85C9F`, the author's Developer ID). macOS 13+'s `backgroundtaskmanagementd` rejects ad-hoc-signed daemons with the cryptic error *"Bundle identifiers from launchd plist ignored because the executable doesn't have a Team ID"* → `Job is not allowed to bootstrap`. The signing settings live in `project.yml` under `settings.base`. If contributors fork this repo, they must change `DEVELOPMENT_TEAM` and likely `PRODUCT_BUNDLE_IDENTIFIER` (and the matching plist `Label` / `MachServices` / `AssociatedBundleIdentifiers` keys in `LaunchDaemons/com.vu2cpl.TimeSync.Helper.plist`).

Helper Xcode target is `type: tool` with `CREATE_INFOPLIST_SECTION_IN_BINARY = YES` so its `Helper-Info.plist` is embedded in the `__TEXT,__info_plist` section of the Mach-O — required for SMAppService to identify the daemon.

## Two non-obvious traps already paid for

**1. FTDI USB-serial open dance** (now handled by gpsd, but documented here because the wrapper script in `server/gpsd-wrapper.sh` has to deal with it). `cfsetspeed` + `tcsetattr` after `open(O_RDWR | O_NONBLOCK)` silently leaves the FTDI at the wrong baud rate on macOS — reads return clean bytes for ~60 then drift to high-bit-set garbage. The fix is to pre-configure with `/bin/stty` *before* the daemon opens the device. That's what `server/gpsd-wrapper.sh` does, then `exec`s gpsd. The Swift app no longer opens the serial port directly; if you ever need to (e.g., to add a fallback path), use the same stty + `O_RDONLY | O_NOCTTY` (blocking) + post-open `fcntl(F_SETFL, O_NONBLOCK)` sequence.

**2. YAML coercion in Info.plist values.** `LSMinimumSystemVersion: 14.0` in `project.yml` is interpreted as a YAML float and emitted as a `<real>` in Info.plist; LaunchServices then calls `CFStringGetCString` on the number and AppKit raises `NSInvalidArgumentException` during `NSStatusItem` setup. **Always quote string-valued plist properties** in `project.yml` (`"14.0"`).

## Conventions

- **Offset sign:** `system - reference`, in milliseconds. Positive = system is ahead. Both `NTPResult.systemAheadOfReferenceMs` and `applyGPSUpdate`'s `receivedAt - gpsTime` follow this convention.
- **GPS timing precision:** ~10–100 ms without PPS. The `receivedAt` timestamp is when the `$` of the sentence first arrived in our process, not when the GPS-second-boundary was actually crossed. Acceptable for FT8; not WSPR-grade.
- **Bundle ID prefix:** `com.vu2cpl.` — change everywhere consistently (project.yml, both plists, `HelperConstants` in `Shared/HelperProtocol.swift`, the code-requirement string in `HelperService.validateClient`, and the LaunchDaemon labels in `server/launchd/`) if forking.

## Server stack (chrony + gpsd)

Optional but recommended for the "remote FT8" use case: `server/install.sh` deploys chrony + gpsd as system LaunchDaemons. The flow is:

```
GPS → gpsd (writes time samples to SHM segment NTP0)
chrony refclock SHM 0  ← reads SHM as a stratum-1 source
chrony (server) → LAN clients on UDP/123, also disciplines local clock
```

No `prefer` flag on the GPS refclock — when internet is reachable, chrony picks the more-accurate internet pool sources; when internet is down, GPS becomes the only selectable source and chrony switches to it automatically. Downstream PCs see continuous time service either way.

The TimeSync app and chrony's gpsd refclock both consume the same gpsd instance — TimeSync over TCP/2947, chrony over SHM. They don't conflict.
