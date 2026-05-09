# Architecture

How TimeSync, the helper daemon, chrony, and gpsd fit together — and why each piece exists.

## What problem this solves

Ham radio digital modes — FT8 above all — need the operator's PC clock within ~1 second of true UTC. WSJT-X won't decode signals from a station whose clock is more than ~2.5 s off. In a fixed shack with internet, this is trivial: macOS's built-in `timed` keeps the system clock close enough.

Two situations make it harder:

1. **Operating from remote locations with no internet** — repeater hilltops, contest field sites, DXpeditions. Need a self-contained time reference. A USB GPS receiver is the standard solution; gpsd + chrony is the standard plumbing.
2. **Multiple PCs in the operating position** (laptop running WSJT-X, a separate logger, a Linux box for spectrum analysis, …). All need to agree on time, ideally without each one needing its own GPS.

This project does both — uses a USB GPS as the time reference, runs an NTP server so all the LAN's PCs can sync from it, and gives the operator a menu-bar app that shows what's happening at a glance.

## The four processes

```
                    ┌─────────────────────────────────────────────────┐
                    │                  Your Mac                       │
                    │                                                 │
   GPS via FTDI ──▶ │  gpsd (root)                                    │
   USB-serial       │   • opens /dev/cu.usbserial-...                 │
                    │   • parses NMEA / UBX                           │
                    │   • writes time samples to SHM segment NTP0     │
                    │   • exposes JSON on TCP/2947                    │
                    │                  │                              │
                    │       ┌──────────┴──────────┐                   │
                    │       ▼ SHM read            ▼ TCP/2947          │
                    │  chrony (root)         TimeSync.app (user)      │
                    │   • disciplines the          │                  │
                    │     system clock             ├─ NTPClient ──────┼──▶ pool.ntp.org
                    │   • picks best source        ├─ GPSDClient      │   (UDP/123)
                    │     across SHM + pool        ├─ ChronyMonitor ─▶│   chronyc tracking
                    │   • serves on UDP/123  ──────┼──────────────────┼──▶ LAN clients
                    │                              │       (UDP/123)  │
                    │                              ▼                  │
                    │                      TimeSyncHelper (root) ◀──┐ │
                    │                       • XPC mach service      │ │
                    │                       • runs `chronyc makestep`│ │
                    │                       on demand               │ │
                    │                                               │ │
                    │      "Step Clock" button ─── XPC call ────────┘ │
                    │                                                 │
                    └─────────────────────────────────────────────────┘
```

There are exactly four processes you need to know about:

| Process | Runs as | Started by | What it does |
|---|---|---|---|
| `gpsd` | root | LaunchDaemon `com.vu2cpl.gpsd` | Owns GPS serial port; speaks NMEA/UBX with the receiver; writes time samples to SHM (for chrony) and JSON to TCP/2947 (for everything else) |
| `chrony` | root | LaunchDaemon `com.vu2cpl.chrony` | Reads SHM (GPS) and polls internet pool; disciplines system clock; serves time on UDP/123 to LAN |
| `TimeSync.app` | user | Manually (or Login Items) | The menu-bar UI. Pure viewer — never touches the clock directly |
| `TimeSyncHelper` | root | On-demand by launchd | One narrow XPC method: spawn `chronyc makestep`. The "Step Clock" button calls this |

## Data flow — three independent paths

### 1. GPS → chrony → system clock (the discipline path)

```
GPS hardware                  ~1 Hz NMEA / UBX sentences
    │
    ▼ USB-serial (FTDI cable, 4800 or 9600 baud)
gpsd
    │ parses, extracts UTC + position
    ▼ writes (gps_time, system_time_at_sample) tuple
SHM segment NTP0  (key 0x4e545030, root-only, mode 0600)
    │
    ▼ chrony's `refclock SHM 0` reads every poll interval
chrony
    │ Allan-deviation Kalman across SHM + 8 internet sources
    ▼ adjtime() / settimeofday() under the hood
Mac system clock
```

The `chrony` source labeled **GPS** in `chronyc sources` represents this path. It's typically reported as ±100-200 ms accurate without PPS — the receiver puts the NMEA sentence on the wire slightly after the GPS-second mark, USB has polling latency, and so on. Good enough for FT8 (which needs ~1 s); not good enough for WSPR-tight requirements.

### 2. System clock → LAN clients (the serving path)

```
Mac system clock
    │ (disciplined by chrony per path 1)
    ▼
chrony NTP server (UDP/123, listening on all interfaces)
    │
    ▼ serves stratum 2 (or whatever, +1 from the source chrony chose)
LAN clients
   • Windows (w32time)
   • Linux (chrony / systemd-timesyncd)
   • other Macs (sntp / Date & Time settings)
```

The Mac becomes a stratum-2 NTP server visible to anything on its LAN. Configured by the `allow 192.168.1.0/24` line in `chrony.conf` — change the subnet for your network.

If chrony loses all its sources (no internet *and* no GPS), the `local stratum 8` directive keeps it serving from the local clock so downstream clients stay synced to whatever the Mac thinks the time is — better than going completely silent.

### 3. TimeSync app — three diagnostic streams (the viewer path)

The app is a pure viewer. It reads three independent sources:

```
                         TimeSync.app
                              │
              ┌───────────────┼───────────────┐
              ▼               ▼               ▼
        ChronyMonitor    GPSDClient       NTPClient
              │               │               │
              ▼               ▼               ▼
   `chronyc -c tracking`  TCP/2947        UDP/123
   every 5 s               JSON line       direct query
                          protocol
```

Three things to know:

1. **The chrony view is the only number that matters for "drift".** Chrony's filtered offset (system vs. its picked reference) is what's shown as the headline drift in the menu bar. Updates every 5 s.
2. **GPS and NTP single-sample views are diagnostic.** They're shown in the popover so you can confirm "is the GPS connected?" / "is NTP responding?" but the offset numbers from them include transport latency (NMEA + USB + TCP for GPS, RTT/2 for NTP). They're noisy and don't represent actual clock drift; we deliberately don't display the offset numbers in the UI.
3. **The app never sets the clock directly.** Even the "Step Clock" button only asks chrony to step — the legacy `setSystemTime` XPC method is in the helper for backward compat but unused by the current app.

## Design decisions

### Why chrony instead of macOS's `timed`?

macOS's built-in `timed` is a client-only daemon — it can sync the system clock from `time.apple.com` and not much else. It has no concept of a GPS refclock, can't serve other PCs, and is notoriously sluggish to converge after a clock jump. chrony is the de facto standard NTP daemon for Linux/BSD systems, has been ported cleanly to macOS via Homebrew, and supports everything we need: SHM refclock, multiple sources with combined filtering, serving, the works.

### Why `gpsd` between GPS and chrony?

We could read NMEA directly from the serial port (the app used to). Two reasons we don't:

1. **Multiple consumers.** The serial port can only be open in one process at a time. Without gpsd, either chrony or the app could read the GPS, not both. With gpsd, both consume from gpsd — chrony via SHM, the app via TCP — and gpsd handles the device exclusively.
2. **Receiver autodetection and resilience.** gpsd recognized the u-blox 7 on this Mac and switched to UBX binary protocol for tighter timing than NMEA gives. It also handles common receiver quirks (cold-start delays, lost-fix recovery, sentence quality filtering) that we'd otherwise have to reimplement.

The trade-off: gpsd's TCP/JSON output adds a few ms of latency over direct serial reads. Doesn't matter for our use case.

### Why a separate privileged helper?

macOS won't let an unsandboxed app set the system clock or run privileged binaries — and we wouldn't *want* the whole UI to run as root anyway. SMAppService (introduced in macOS 13) is Apple's modern replacement for the legacy SMJobBless privileged helper mechanism. It lets the user authorize a small daemon once, then the daemon runs as root in the background under launchd's care. Our helper is intentionally narrow — one XPC method (`runChronyMakestep`) — to minimize attack surface.

The helper validates every incoming XPC connection's code signature against the requirement `identifier "com.vu2cpl.TimeSync"` before accepting any call. Other apps on the same machine can't connect to it.

### Why poll `chronyc` from the app instead of computing offsets ourselves?

We tried computing offsets directly in the app and ran into exactly the noise problem you'd expect: a single GPS-via-TCP sample is dominated by transport latency, not clock drift; a single NTP query offset is dominated by RTT/2. The displayed drift would jump ±500 ms from second to second even though the system clock was perfectly fine.

Chrony already does the right thing — Allan-deviation Kalman filter across all its sources, with proper outlier rejection. So instead of duplicating that logic poorly, the app shells out to `chronyc -c tracking` (CSV output) every 5 s and uses chrony's filtered view as the canonical drift number.

### Why have the app at all if chrony does everything?

You don't strictly need it. chrony+gpsd works headless. The app exists for two practical reasons:

1. **Visibility.** Glancing at the menu bar to confirm "yes my clock is fine, GPS has fix, chrony is happy" is faster than running `chronyc tracking` in a terminal.
2. **Recovery.** When chrony loses quorum and falls back to local stratum 8 (see [CHRONY.md](CHRONY.md#failure-mode-quorum-loss)), the "Step Clock" button is the easy fix. Without the app, you'd type `sudo chronyc makestep` in a terminal — possible but less convenient when you're in the middle of a contest.

## Failure modes and recovery

### GPS loses fix (e.g., antenna shaded)

What happens: chrony's GPS source goes from `#*` to `#?` then stale. chrony switches to internet sources automatically. Display in the app: GPS section shows "No fix"; chrony section unaffected. **No action needed**; clock stays disciplined from internet.

If both GPS and internet are out, see "Internet goes down" below.

### Internet goes down (remote operation)

What happens: chrony's internet sources fall to unreachable; GPS becomes the only selectable source. chrony switches to GPS automatically. Display in the app: NTP section shows error; chrony section now lists `GPS` as the reference (or just shows whichever source is active). **No action needed**; clock stays disciplined from GPS.

If GPS *also* loses fix during this period, chrony falls back to `local stratum 8` (serves the system clock unchanged).

### Quorum loss / falseticker scenario

What happens: chrony detects that more than half its sources disagree (often after a clock jump or after one bad source). It rejects the disagreeing ones as falsetickers, but if it can't form a majority, it gives up and falls back to `local stratum 8`. The system clock then drifts at hardware rate (typically ~0.5 ppm = 2 s/day) until you intervene.

Symptoms in the app: chrony section shows reference `()` or stratum 8; menu-bar drift number creeps up over hours.

Recovery: click **Step Clock** in the menu bar (or run `sudo chronyc makestep` in a terminal). chrony immediately steps the clock to its current best estimate, sources start agreeing again, and quorum re-forms within 1-2 polling intervals.

### TimeSync.app crashes or the operator quits it

Nothing happens to the clock — the app is purely a viewer. chrony and gpsd keep doing their jobs under launchd's supervision. Re-launching the app picks up where it left off.

### Helper is not installed

The "Step Clock" button is greyed out with a tooltip explaining how to install it. Everything else works. To install, open Settings → Helper → Install Helper… and authorize once when macOS prompts.

## Security model

- **Code-signing chain:** both binaries (`TimeSync` and `TimeSyncHelper`) are signed with the same Developer ID (`Manoj Ramawarrier — CHVNJ85C9F`). macOS Gatekeeper verifies on first launch.
- **Notarization:** the app is notarized by Apple. macOS staples the notary ticket so the verification works offline.
- **Hardened Runtime:** enabled on both binaries. No relaxations (no `--allow-jit`, no `--allow-unsigned-libs`, etc.). Empty entitlements files — we don't request any special capabilities.
- **XPC validation:** the helper checks each incoming connection's `SecCode` against the requirement `identifier "com.vu2cpl.TimeSync"` — only the signed app can call it.
- **Helper attack surface:** one XPC method, which spawns one specific binary (`/opt/homebrew/bin/chronyc`) with one specific argument (`makestep`). No user input is ever passed to the subprocess.
- **Sandbox:** off. TimeSync is a system utility that needs to talk to gpsd, NTP, and chrony — all incompatible with the App Sandbox. Distribution is outside the App Store.

## Timing precision — what to expect

| Source | Typical accuracy | Use case |
|---|---|---|
| GPS via NMEA, no PPS | ±100-300 ms | What we have; fine for FT8 |
| GPS via NMEA + PPS | ±10 µs | Would need PPS-capable receiver + driver work |
| Internet NTP pool | ±5-30 ms | RTT-limited; depends on geography |
| chrony's filtered estimate | ±2-10 ms | What's displayed in the menu bar; combines all sources |

For ham digital modes (FT8 ±2.5s, FT4 ±1s, JS8 ±1s), any of the above is fine. For WSPR or anything time-coding-tight, you'd want PPS — see the future work section in the repo's issues.
