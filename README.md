# TimeSync

A macOS menu-bar app that shows your system clock's drift against NTP and a USB GPS receiver, with optional one-click "step the clock now" recovery via [chrony](https://chrony-project.org/).

Built for ham radio operators running digital modes (FT8, FT4, JS8) where ~1 second of clock accuracy matters, especially in field conditions where there's no internet — but useful for anyone who wants a clean visual on their Mac's timekeeping.

```
┌─────────────────────────────────────┐
│  System Time (UTC)                  │
│  2026-05-09 14:23:51.328            │
│  ─────────────────                  │
│  ● chrony              -3.2 ms      │
│      Reference: time.cloudflare...  │
│      RMS offset: 1.4 ms · ...       │
│  ─────────────────                  │
│  ● NTP                              │
│      Server: pool.ntp.org           │
│      Round trip: 38 ms · OK         │
│  ─────────────────                  │
│  ● GPS                              │
│      gpsd: localhost:2947           │
│      Satellites used: 9 · OK        │
│  ─────────────────                  │
│  🛡 Helper installed                 │
│      Last makestep: 12m ago         │
│  ─────────────────                  │
│  [Refresh] [Step Clock]   [Settings…] [Quit]
└─────────────────────────────────────┘
```

## What it does

- Reads NTP from a public pool over UDP/123 (pure Swift, no daemon needed for this part)
- Reads a USB-connected GPS via [`gpsd`](https://gpsd.io/) over TCP/2947
- Polls `chronyc tracking` to display the *real, filtered* system clock offset — not single-sample noise from any one source
- Lets you trigger `chronyc makestep` from the menu bar via a privileged helper (one-time admin auth on install)

The companion `server/` directory turns your Mac into a stratum-2 NTP server for your local LAN, GPS-disciplined when internet is unavailable. Useful for remote operating where you have several PCs and no upstream time source.

## Requirements

- macOS 14 (Sonoma) or later, Apple Silicon
- A USB GPS receiver — anything that emits NMEA at 4800 or 9600 baud. Tested with a u-blox 7 module on an FTDI cable.
- For the optional NTP server: [Homebrew](https://brew.sh)

## Install — app only

1. Download `TimeSync-0.1.0.zip` from the [latest release](https://github.com/vu2cpl/timesync-mac/releases/latest).
2. Unzip, drag `TimeSync.app` to `/Applications/`.
3. Open it. A clock icon appears in your menu bar.
4. Click the icon → **Settings… → Helper → Install Helper…** if you want the "Step Clock" button to work. macOS will prompt you to authorize a system extension; this is the privileged daemon that lets the app run `chronyc makestep`. One-time auth.

That's it for menu-bar monitoring. If you don't have `chrony` running yet, the popover will say `chrony: chronyc not found`. To get a working `chrony` setup (and turn this Mac into an NTP server for your LAN), continue below.

## Install — server stack (gpsd + chrony)

Plug your GPS in via USB. Then from a Terminal:

```bash
git clone https://github.com/vu2cpl/timesync-mac
cd timesync-mac
./server/install.sh
```

The installer is interactive — it will:

1. Detect your Homebrew prefix (Apple Silicon `/opt/homebrew` or Intel `/usr/local`)
2. `brew install gpsd chrony` if not already
3. **Scan `/dev/cu.usb*` and list GPS-candidate devices**, ask which one is yours
4. **Ask for the baud rate** (default 4800)
5. **Sniff the device** for 3 s to verify NMEA actually arrives at that combination
6. **Detect your LAN subnet** from `en0`'s IP, ask which CIDR to allow chrony clients from
7. Render customized copies of `chrony.conf`, `gpsd-wrapper.sh`, and the two LaunchDaemon plists
8. Install them to the right paths under `<brew>/etc/` and `/Library/LaunchDaemons/` (sudo prompt)
9. Bootstrap both daemons via `launchctl`
10. Print `chronyc tracking` so you can confirm it converged

Verify:

```bash
chronyc tracking      # stratum 2-3, sub-10 ms offset
chronyc sources       # GPS + 7-ish internet sources
sntp <your-mac-IP>    # downstream test
```

### Re-running the installer

Safe to re-run — `bootout`/`bootstrap` cycles the daemons cleanly. Use it whenever you swap GPS hardware, change LAN subnet, etc.

### Pointing your other PCs at the Mac

**Windows:** Admin PowerShell —

```powershell
w32tm /config /manualpeerlist:"<MAC_IP>,0x8" /syncfromflags:manual /update
Restart-Service w32time
w32tm /resync
```

**Linux (systemd-timesyncd):** edit `/etc/systemd/timesyncd.conf`, set `NTP=<MAC_IP>`, then `sudo systemctl restart systemd-timesyncd`.

**macOS:** System Settings → General → Date & Time → "Set time and date automatically: `<MAC_IP>`".

## Architecture (short version)

Four processes, clear separation of concerns:

- **TimeSync.app** (Swift / SwiftUI menu-bar app, runs as you) — purely a viewer. Talks to gpsd over TCP/2947 (JSON), polls `chronyc tracking` every 5s for the canonical drift number, sends NTP queries via UDP. Never touches the system clock directly.
- **TimeSyncHelper** (small launchd daemon, runs as root) — exposes one XPC method: `runChronyMakestep`. The "Step Clock" button calls this. Validates the calling app's code signature so only the real signed TimeSync.app can talk to it.
- **chrony** (server-side) — disciplines the system clock from GPS (when fix is good) and internet pool. Picks the best available source automatically. Serves UDP/123 to the LAN.
- **gpsd** (server-side) — owns the GPS serial port; writes time samples to a shared-memory segment chrony reads, also serves JSON on TCP/2947 for everything else.

For the long version with diagrams, design rationale, failure modes, and the security model: **[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)**.

For chrony specifically — what it is, walking through our config line by line, operational commands, common scenarios and how to read the output: **[docs/CHRONY.md](docs/CHRONY.md)**.

For the in-repo developer guide (build instructions, code layout, the two macOS gotchas we paid for): **[CLAUDE.md](CLAUDE.md)**.

## Source build

```bash
brew install xcodegen
./generate.sh           # generates TimeSync.xcodeproj
open TimeSync.xcodeproj # build with ⌘R, or:
xcodebuild -project TimeSync.xcodeproj -scheme TimeSync build
```

The shipped binary is signed with my Developer ID (`Manoj Ramawarrier — CHVNJ85C9F`) and notarized by Apple. If you fork this and want to build/distribute under your own identity, edit `DEVELOPMENT_TEAM` in `project.yml` and `PRODUCT_BUNDLE_IDENTIFIER` everywhere it appears (project.yml, both LaunchDaemon plists, `Shared/HelperProtocol.swift`, and the `identifier "com.vu2cpl.TimeSync"` string in `TimeSyncHelper/HelperService.swift`).

## License

[MIT](LICENSE) — VU2CPL, 2026.

73 de Manoj
