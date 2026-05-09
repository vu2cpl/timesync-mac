# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this app is

A macOS menubar app that displays system clock drift against NTP and a USB-connected GPS, and (optionally) sets the system clock via a privileged launchd helper. Aimed at ham radio operators who need ~1-second accuracy for digital modes (FT8 etc.). The author is VU2CPL.

## Build / run

```bash
./generate.sh                                                  # XcodeGen → TimeSync.xcodeproj
xcodebuild -project TimeSync.xcodeproj -scheme TimeSync build  # full build (app + helper)
xcodebuild -project TimeSync.xcodeproj -scheme TimeSyncHelper build  # helper only
open ~/Library/Developer/Xcode/DerivedData/TimeSync-*/Build/Products/Debug/TimeSync.app
```

`TimeSync.xcodeproj` is **gitignored** — `project.yml` is the source of truth. Regenerate after any structural change. Brew dependency: `xcodegen`.

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

**Data flow on the main side:** `SerialPort` (POSIX termios + DispatchSourceRead) → `NMEAParser` (streaming, $RMC/$ZDA/$GSV with checksum) → `GPSReader` (emits `GPSUpdate { fix | noFix }`) → `AppStore.applyGPSUpdate` → `@Published gpsState` → SwiftUI. `NTPClient` runs in parallel (pure-Swift SNTPv4 over UDP/123 via `Network.framework`), polls every `refreshIntervalSeconds`.

**Sync path:** user clicks "Sync Now" → `AppStore.syncNow` picks the best source per `preferredSource` pref → computes target time = `Date() - offset` → `HelperClient.syncSystemClock(to:)` → XPC to helper → helper validates the caller's `SecCode` against `identifier "com.vu2cpl.TimeSync"` → `settimeofday(2)`. Auto-sync (opt-in, off by default) hooks into `applyGPSUpdate`/`pollNTPOnce` and only fires when drift exceeds `warnThresholdMs`, throttled by `autoSyncMinIntervalSeconds`.

**Helper installation:** `HelperClient.install()` calls `SMAppService.daemon(plistName:).register()`. First call shows a system admin prompt. The helper survives main-app restarts (launchd manages its lifecycle); only re-register when the helper plist or binary changes.

**State propagation:** `HelperClient` is its own `ObservableObject`, but `AppStore` mirrors its `@Published` properties (`status`, `lastError`, `helperVersion`, `lastSync`) via Combine `assign(to:)` so SwiftUI views only need to observe `AppStore`.

## Code signing — required, not optional

Both targets must be signed with the **same Team ID** (`CHVNJ85C9F`, the author's Developer ID). macOS 13+'s `backgroundtaskmanagementd` rejects ad-hoc-signed daemons with the cryptic error *"Bundle identifiers from launchd plist ignored because the executable doesn't have a Team ID"* → `Job is not allowed to bootstrap`. The signing settings live in `project.yml` under `settings.base`. If contributors fork this repo, they must change `DEVELOPMENT_TEAM` and likely `PRODUCT_BUNDLE_IDENTIFIER` (and the matching plist `Label` / `MachServices` / `AssociatedBundleIdentifiers` keys in `LaunchDaemons/com.vu2cpl.TimeSync.Helper.plist`).

Helper Xcode target is `type: tool` with `CREATE_INFOPLIST_SECTION_IN_BINARY = YES` so its `Helper-Info.plist` is embedded in the `__TEXT,__info_plist` section of the Mach-O — required for SMAppService to identify the daemon.

## Two non-obvious traps already paid for

**1. FTDI USB-serial open dance.** `cfsetspeed` + `tcsetattr` after `open(O_RDWR | O_NONBLOCK)` silently leaves the FTDI at the wrong baud rate on macOS — reads return clean bytes for ~60 then drift to high-bit-set garbage. `SerialPort.open` works around this by:
1. Shelling out to `/bin/stty` to pre-configure the device
2. Opening with `O_RDONLY | O_NOCTTY` (blocking, no `O_NONBLOCK`, no `O_RDWR`)
3. Then `fcntl(F_SETFL, O_NONBLOCK)` after open succeeds

The dead `configure()` method is left in place as a reference but is no longer called. Don't "simplify" the open flow back to the textbook POSIX pattern — it doesn't work for FTDI on this OS.

**2. YAML coercion in Info.plist values.** `LSMinimumSystemVersion: 14.0` in `project.yml` is interpreted as a YAML float and emitted as a `<real>` in Info.plist; LaunchServices then calls `CFStringGetCString` on the number and AppKit raises `NSInvalidArgumentException` during `NSStatusItem` setup. **Always quote string-valued plist properties** in `project.yml` (`"14.0"`).

## SerialPort fd lifecycle

`DispatchSource.makeReadSource`'s cancel handler must be the only thing that closes the underlying fd. The handler captures `fd` by value (not via `[weak self]`, which goes nil if the SerialPort is deallocated mid-cancel and silently leaks the fd). `close()` calls `source.cancel()` and returns; the OS fd is closed asynchronously by the cancel handler. Don't preemptively `Darwin.close(fd)` — closing an fd while a DispatchSource still references it is undefined behavior in GCD.

## Conventions

- **Offset sign:** `system - reference`, in milliseconds. Positive = system is ahead. Both `NTPResult.systemAheadOfReferenceMs` and `applyGPSUpdate`'s `receivedAt - gpsTime` follow this convention.
- **GPS timing precision:** ~10–100 ms without PPS. The `receivedAt` timestamp is when the `$` of the sentence first arrived in our process, not when the GPS-second-boundary was actually crossed. Acceptable for FT8; not WSPR-grade.
- **Bundle ID prefix:** `com.vu2cpl.` — change everywhere consistently (project.yml, both plists, `HelperConstants` in `Shared/HelperProtocol.swift`, the code-requirement string in `HelperService.validateClient`) if forking.
