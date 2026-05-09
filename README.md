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

The script does:

1. `brew install gpsd chrony`
2. Installs `/opt/homebrew/etc/chrony.conf` and `/opt/homebrew/etc/gpsd-wrapper.sh`
3. Creates `/var/log/chrony` etc.
4. Drops two LaunchDaemons in `/Library/LaunchDaemons/`:
   - `com.vu2cpl.gpsd` — owns the GPS serial port, decodes NMEA / UBX
   - `com.vu2cpl.chrony` — uses gpsd's SHM segment as a stratum-1 source, plus the public pool, and serves time on UDP/123
5. Bootstraps both daemons (you'll be prompted for your admin password)

Verify:

```bash
chronyc tracking      # should show stratum 2-3, sub-10ms offset
chronyc sources       # should list GPS + 7 internet sources
sntp 192.168.1.157    # adjust IP — should respond
```

### You will need to edit two files

The shipped configs assume my LAN (`192.168.1.0/24`) and my GPS device path (`/dev/cu.usbserial-D306Y9DQ`). Edit before installing:

- **`server/chrony.conf`** — change the `allow 192.168.1.0/24` line to match your subnet.
- **`server/gpsd-wrapper.sh`** — change the `DEV=` line to your GPS's `/dev/cu.*` path. Find it with `ls /dev/cu.usbserial-*` after plugging the GPS in.

If you use a different GPS baud rate, also adjust `BAUD=` in `gpsd-wrapper.sh`.

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

- **TimeSync.app** (this repo, Swift / SwiftUI menu-bar app) — purely a viewer. Talks to gpsd over TCP/2947 (JSON), polls `chronyc tracking` every 5s for the real drift number, sends NTP queries via UDP. Zero clock-setting code paths in the app itself.
- **TimeSyncHelper** (small launchd daemon, runs as root) — exposes one XPC method: `runChronyMakestep`. The "Step Clock" button calls this. Validates the calling app's code signature so only the real signed TimeSync.app can talk to it.
- **chrony** (server-side) — disciplines the system clock from GPS (when fix is good) and internet pool. Serves UDP/123 to the LAN.
- **gpsd** (server-side) — owns the GPS serial port; writes time samples to a SHM segment chrony reads.

For more depth see [`CLAUDE.md`](CLAUDE.md), which is the in-repo development guide.

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
