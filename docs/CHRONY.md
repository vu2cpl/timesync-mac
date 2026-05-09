# chrony — what it does, our config, how to operate it

[chrony](https://chrony-project.org/) is the NTP implementation we use. This doc covers what it is, how our specific config in [`server/chrony.conf`](../server/chrony.conf) is laid out, and the day-to-day commands worth knowing for ham radio operation. If you've installed via [`server/install.sh`](../server/install.sh), everything below is already running on your Mac.

## What chrony is

A modern NTP daemon. Picks the most accurate reference clock available (internet pool, GPS via shared memory, PPS hardware pulse, etc.), filters across all sources to reject outliers, and steers the system clock smoothly. Originally written for Linux but works fine on macOS via Homebrew. Compared to the alternatives:

| Tool | Where it ships | Server? | GPS refclock? | Comment |
|---|---|---|---|---|
| `timed` | macOS built-in | No | No | Client only, single source (`time.apple.com`), opaque |
| `ntpd` | Was in macOS pre-10.13; removed | Yes | Yes | Apple removed it; can install via `brew install ntp` but the codebase is older than chrony |
| `systemd-timesyncd` | Linux | No | No | Lightweight client-only |
| **`chrony`** | Homebrew | Yes | Yes (SHM, SOCK, PPS, …) | What we use |

For a ham operating in the field with GPS and a need to serve time to other PCs, chrony is the standard answer.

## Our config, line by line

[`server/chrony.conf`](../server/chrony.conf) installs to `/opt/homebrew/etc/chrony.conf` and is read by chrony at startup. Walk-through:

### GPS via gpsd (stratum 1 source)

```
refclock SHM 0 refid GPS precision 1e-1 offset 0.100 delay 0.2
```

Tells chrony to read SHM segment 0 (which is key `0x4e545030` — gpsd's "NTP0" segment for the first GPS). The flags:

- `refid GPS` — label this source as `GPS` in `chronyc sources` output
- `precision 1e-1` — claim ~100 ms precision (typical for non-PPS NMEA)
- `offset 0.100` — apply a 100 ms compensation for typical USB/NMEA latency
- `delay 0.2` — assume up to 200 ms one-way path delay

No `prefer` flag. We deliberately let chrony pick the most accurate source rather than forcing GPS. When internet is reachable, internet sources usually win (their RTT/2 is smaller than GPS's NMEA jitter). When internet drops, GPS is the only selectable source and chrony switches to it automatically. **That auto-switch is the whole point of having both.**

### Upstream sources (fallback / sanity check)

```
pool in.pool.ntp.org    iburst maxsources 4
pool 0.pool.ntp.org     iburst maxsources 2
pool time.apple.com     iburst maxsources 1
```

Three pools, mixed:

- **Indian regional pool** (`in.pool.ntp.org`) for low RTT — most servers under 30 ms from here
- **Global pool** (`0.pool.ntp.org`) as a sanity check across continents
- **Apple's pool** (`time.apple.com`) as a stable, well-run alternative

`iburst` makes chrony do an initial 4-packet burst on startup to converge faster (10s instead of ~64s). `maxsources` limits how many actual servers are picked from each pool.

If you're outside India, change `in.pool.ntp.org` to your country code: `us.pool.ntp.org`, `de.pool.ntp.org`, `au.pool.ntp.org`, etc. See [pool.ntp.org](https://www.pool.ntp.org/zone/@) for the list.

### Serve to LAN

```
allow 192.168.1.0/24
```

Allows clients on the `192.168.1.0/24` subnet to query us as an NTP server. Adjust to your subnet. To allow only specific hosts: `allow 192.168.1.50` (single IP). To allow all RFC1918 ranges: three lines, one each for `192.168.0.0/16`, `10.0.0.0/8`, `172.16.0.0/12`.

If you don't want to serve at all (just discipline this Mac's clock from chrony, no LAN), comment out the `allow` line entirely.

### Local stratum fallback

```
local stratum 8
```

If all upstream sources are unreachable AND GPS is unavailable (e.g., remote operation with no internet and the GPS lost fix), chrony has no real reference. Without `local stratum`, it would refuse to serve clients at all. With `local stratum 8`, it keeps serving the system clock as-is at stratum 8, so LAN clients still get *some* time rather than going dark.

Stratum 8 is intentionally weak — clients will prefer any other source they can find. If you're running other GPS-disciplined NTP servers on the LAN at lower stratum, they'll win.

### Clock discipline

```
makestep 1.0 3
rtcsync
```

- `makestep 1.0 3` — for the first 3 measurements after startup, if the offset is more than 1 second, *step* the clock instead of slewing it. Avoids waiting hours for a slow slew to converge after a clock jump. After 3 measurements, only slew is allowed (avoiding sudden jumps that would confuse downstream clients).
- `rtcsync` — periodically sync the system clock to the kernel's RTC, so the clock survives sleep/wake reasonably.

### State files

```
driftfile /opt/homebrew/var/lib/chrony/drift
logdir    /opt/homebrew/var/log/chrony
log       measurements statistics tracking
pidfile   /opt/homebrew/var/run/chrony/chronyd.pid
bindcmdaddress /opt/homebrew/var/run/chrony/chronyd.sock
```

Chrony's runtime state. The two macOS-specific points worth flagging:

- **`pidfile`** — we override the default `/var/run/chrony/chronyd.pid` because that directory doesn't exist as writable on macOS (it's a transient `tmpfs`). Brew's `var/run` is writable.
- **`bindcmdaddress`** — same reason: the `chronyd.sock` that `chronyc` connects to needs a writable parent directory.

The `log measurements statistics tracking` line creates per-event log files in `logdir/`. Useful for post-mortem analysis but they grow over time — `chronyc cyclelogs` rotates them.

## Operational commands

You'll mostly interact with chrony via `chronyc` (the control client). Most commands work as a regular user; the privileged ones (like `makestep`) need `sudo`.

### Read-only diagnostics

```
chronyc tracking
```

The single most useful command. Shows:

```
Reference ID    : A29FC87B (time.cloudflare.com)
Stratum         : 4
Ref time (UTC)  : Sat May 09 03:31:18 2026
System time     : 0.029733540 seconds fast of NTP time
Last offset     : +0.083164126 seconds
RMS offset      : 0.099533878 seconds
Frequency       : 2.333 ppm slow
Residual freq   : +783.765 ppm
Skew            : 3.330 ppm
Root delay      : 0.123776056 seconds
Root dispersion : 0.053172540 seconds
Update interval : 64.5 seconds
Leap status     : Normal
```

What to read:

- **`Reference ID`** — *which* source chrony is currently using. If it's hex like `7F7F0101` with a blank name, that means **local stratum fallback** — chrony is serving the local clock without external discipline. Bad sign. See [Recovering from quorum loss](#recovering-from-quorum-loss) below.
- **`Stratum`** — typically 2 (one hop from a stratum-1 source like Apple's). If 8, it's the local fallback.
- **`System time : X seconds fast/slow`** — how far off the system clock is from chrony's filtered best estimate. The number you actually care about.
- **`Update interval`** — how often chrony's polling. Normally 16-64 s. If 500+ s, chrony has given up on its sources.

```
chronyc sources
```

Lists all configured sources and their current state:

```
MS Name/IP address         Stratum Poll Reach LastRx Last sample
===============================================================================
#* GPS                           0   4   377    15    +37ms[ +37ms] +/-  200ms
^+ time.cloudflare.com           3   6   377    50    +20ms[ +25ms] +/-   65ms
^? ntp5.mum-in.hosts.301-mo>     2   6     1     2    +74ms[  +74ms] +/-   87ms
^x time.cloudflare.com           3   6   377    50  -452ms[ -452ms] +/-   64ms
```

Two columns to read:

- **M** (mode): `^` = network server, `=` = peer, `#` = local refclock (our GPS via SHM)
- **S** (state):
  - `*` — currently selected (this is the source disciplining the clock)
  - `+` — combined into the chosen estimate
  - `-` — combined but down-weighted
  - `?` — unreachable, no recent sample
  - `x` — **falseticker** (chrony rejected it; disagrees with majority)
  - `~` — too variable

`Reach=377` is octal 11111111 — last 8 polls all succeeded. `Reach=0` means all 8 last polls failed.

```
chronyc sourcestats
```

More detail per source — frequency, skew, standard deviation. Useful for tuning.

```
chronyc clients
```

(Needs sudo.) Lists which downstream clients have queried us recently — confirms your Windows / Linux PCs are actually using this Mac as their time source.

### Privileged commands

```
sudo chronyc makestep
```

Force chrony to immediately step the clock to its current best estimate, ignoring the slow-slew safety. Use this when chrony has fallen back to local stratum 8 and won't recover on its own. The "Step Clock" button in TimeSync.app does exactly this via the privileged helper.

```
sudo chronyc burst 4/4
```

Tell chrony to do an immediate burst of 4 NTP packets to all sources (out of 4 attempts). Useful right after sleep/wake or network reconnection to converge faster than the normal poll interval allows.

```
sudo chronyc cyclelogs
```

Rotate the log files in `/opt/homebrew/var/log/chrony/`. Run periodically if you care about disk space.

## Common scenarios

### Healthy steady state

```
$ chronyc tracking | head -5
Reference ID    : 11FD747D (twtpe2-ntp-001.aaplimg.com)
Stratum         : 2
Ref time (UTC)  : Sat May 09 03:35:00 2026
System time     : 0.000000001 seconds fast of NTP time
Last offset     : -0.001 seconds
```

`Stratum 2`, sub-millisecond `System time`, real-named `Reference ID`. Nothing to do.

### Internet down, GPS up (remote operation)

```
$ chronyc tracking | head -5
Reference ID    : 47505300 (GPS)
Stratum         : 1
System time     : 0.000003 seconds fast of NTP time
Last offset     : -0.034 seconds
```

`Reference ID` is the hex of "GPS" (4 bytes ASCII). `Stratum 1` means we are *the* stratum-1 source — chrony promoted GPS now that internet is gone. LAN clients see us at stratum 2. Everything still working; remote FT8 ops continue.

### Internet up, GPS up — both available

chrony picks whichever has the lower expected error. Internet usually wins because non-PPS GPS is ±100-200 ms while internet RTT/2 is ±5-30 ms. GPS shows up as `#-` (combined but not selected) in `chronyc sources`. This is fine.

### Internet down AND GPS lost fix (worst case)

```
$ chronyc tracking | head -5
Reference ID    : 7F7F0101 ()
Stratum         : 8
System time     : 0.000680 seconds slow of NTP time
Last offset     : +0.000583
Frequency       : 5.928 ppm slow
```

`7F7F0101` (= `127.127.1.1`) is chrony's local-clock refclock identifier. `Stratum 8` matches our `local stratum 8` fallback. The clock is no longer being disciplined externally — it's drifting at hardware rate. LAN clients still get time from us, but its accuracy is whatever it was when the last real source disappeared, plus drift since.

If this happens during operation: get GPS fix back, or reconnect internet, then run `sudo chronyc burst 4/4` to converge.

### Recovering from quorum loss

After a clock jump (often caused by an earlier `setSystemTime`-style direct clock-set, or a clock_settime call by another tool), chrony's sources can disagree wildly. Some say the clock is right (their measurement was before the jump); some say it's hundreds of ms off (their measurement was after). Chrony rejects the disagreeing ones as falsetickers and may not be able to form a majority — falls back to `local stratum 8`.

Symptoms:

```
$ chronyc tracking | head -2
Reference ID    : 7F7F0101 ()
Stratum         : 8

$ chronyc sources
... shows multiple ^x (falseticker) sources ...
```

Fix:

```
$ sudo chronyc makestep
200 OK
```

(Or click **Step Clock** in TimeSync.app — same thing through the helper.)

After this, sources agree again within a poll cycle and chrony picks the best one normally. Confirm with `chronyc tracking` — `Reference ID` should now be a real server name.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `chronyc: Could not open connection to daemon` | chronyd not running, or socket dir not readable as you | `pgrep chronyd`; if missing, `sudo launchctl kickstart -k system/com.vu2cpl.chrony` |
| GPS shows `#?` (unreachable) but gpsd is fine | SHM permissions wrong, or chrony running as wrong user | gpsd writes SHM as root; chrony must run as root too. Check `ipcs -ma | grep 4e545030` — should show `--rw-------` and `root` owner; chrony's NATTCH should be ≥1 |
| `Frequency` keeps growing without bound | System clock slewing aggressively to catch up after a step | Normal for ~24h after a `makestep`; will settle |
| All sources marked `^x` falseticker | Clock jumped recently (often from sleep/wake or another tool) | `sudo chronyc makestep` |
| Stratum 8 with reference `()` | Local fallback active — no real source available | If GPS attached: check with `ipcs` and gpsd logs; if internet expected: check `ping pool.ntp.org` |
| `chronyc serverstats` returns `501 Not authorised` | Some commands need to be run from a local socket with proper auth | Not currently configured; safe to ignore |

## Logs

Located in `/opt/homebrew/var/log/chrony/`:

- `tracking.log` — one line per source-selection or step event
- `measurements.log` — per-poll measurements from each source (verbose, useful for post-mortem)
- `statistics.log` — chrony's internal frequency/offset statistics
- `chronyd.err` — stderr from the chronyd process (rare; mostly startup messages)

Rotate periodically with `sudo chronyc cyclelogs` or set up `newsyslog` if you care.
