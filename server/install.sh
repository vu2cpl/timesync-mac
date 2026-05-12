#!/bin/bash
# SPDX-License-Identifier: MIT
# Interactive installer for the gpsd + chrony LaunchDaemons used by TimeSync.
# Detects the Homebrew prefix, prompts for the GPS device and baud, sniffs to
# verify NMEA is actually present at that combination, and writes customized
# copies of chrony.conf, gpsd-wrapper.sh and both LaunchDaemon plists into the
# right locations before bootstrapping the daemons.
#
# Run from the repo root: ./server/install.sh
# Or from inside server/: ./install.sh

set -euo pipefail
cd "$(dirname "$0")"

# ---------------------------------------------------------------------------
# 1. Homebrew prefix detection
# ---------------------------------------------------------------------------
if   [ -x /opt/homebrew/bin/brew ]; then BREW_PREFIX=/opt/homebrew
elif [ -x /usr/local/bin/brew ];     then BREW_PREFIX=/usr/local
else
    echo "Homebrew not found at /opt/homebrew or /usr/local. Install from https://brew.sh first." >&2
    exit 1
fi
echo "==> Using Homebrew prefix: $BREW_PREFIX"

# ---------------------------------------------------------------------------
# 2. Install gpsd and chrony
# ---------------------------------------------------------------------------
echo "==> brew install gpsd chrony  (may be a no-op if already installed)"
brew install gpsd chrony >/dev/null
echo "    gpsd:   $($BREW_PREFIX/sbin/gpsd -V 2>&1 | head -1)"
echo "    chrony: $($BREW_PREFIX/bin/chronyc -v 2>&1 | head -1)"

# ---------------------------------------------------------------------------
# 3. Pick a GPS serial device
# ---------------------------------------------------------------------------
echo
echo "==> Scanning /dev/cu.* for USB-serial devices..."
DEVICES=()
for d in /dev/cu.usbserial-* /dev/cu.usbmodem*; do
    [ -e "$d" ] && DEVICES+=("$d")
done
if [ ${#DEVICES[@]} -eq 0 ]; then
    echo "    No /dev/cu.usbserial-* or /dev/cu.usbmodem* devices found." >&2
    echo "    Plug your GPS in (or check it's recognized: ls /dev/cu.usb*) and re-run." >&2
    exit 1
fi
echo "    Found:"
for i in "${!DEVICES[@]}"; do
    printf "      %d. %s\n" $((i+1)) "${DEVICES[$i]}"
done

read -r -p "    Which one is your GPS? [1-${#DEVICES[@]}, default 1]: " CHOICE
CHOICE=${CHOICE:-1}
if ! [[ "$CHOICE" =~ ^[0-9]+$ ]] || [ "$CHOICE" -lt 1 ] || [ "$CHOICE" -gt ${#DEVICES[@]} ]; then
    echo "    Invalid choice." >&2; exit 1
fi
GPS_DEV="${DEVICES[$((CHOICE-1))]}"
echo "    -> $GPS_DEV"

# ---------------------------------------------------------------------------
# 4. Pick a baud rate
# ---------------------------------------------------------------------------
echo
read -r -p "==> GPS baud rate? [default 4800; common: 4800, 9600, 38400]: " BAUD
BAUD=${BAUD:-4800}
case "$BAUD" in
    1200|2400|4800|9600|19200|38400|57600|115200|230400) ;;
    *) echo "    Unsupported baud rate: $BAUD" >&2; exit 1 ;;
esac
echo "    -> $BAUD"

# ---------------------------------------------------------------------------
# 5. Sniff to verify the combination produces NMEA
# ---------------------------------------------------------------------------
echo
echo "==> Sniffing 3 s of $GPS_DEV @ $BAUD baud..."
if lsof "$GPS_DEV" >/dev/null 2>&1; then
    echo "    ⚠ The port is already held by another process:"
    lsof "$GPS_DEV" 2>/dev/null | head -3 | sed 's/^/      /'
    echo "    Skipping sniff — close the other process first if you want verification."
else
    /bin/stty -f "$GPS_DEV" "$BAUD" cs8 -cstopb -parenb -icanon -echo raw 2>/dev/null || true
    SNIFF=$(/usr/bin/python3 - "$GPS_DEV" <<'PY' 2>/dev/null || true
import os, select, time, sys
dev = sys.argv[1]
try:
    fd = os.open(dev, os.O_RDONLY | os.O_NOCTTY)
except Exception as e:
    print(f"open failed: {e}"); raise SystemExit(0)
end = time.time() + 3
buf = b""
while time.time() < end:
    r, _, _ = select.select([fd], [], [], 0.4)
    if r:
        buf += os.read(fd, 256)
        if len(buf) > 1500: break
os.close(fd)
print(buf[:1500].decode("ascii", errors="replace"))
PY
)
    if echo "$SNIFF" | grep -qE '\$G[PNBL][A-Z]{3}'; then
        echo "    ✓ NMEA sentences detected — port and baud look right."
    else
        echo "    ⚠ Did NOT see NMEA sentences in 3 s. The port or baud might be wrong."
        read -r -p "    Proceed anyway? [y/N]: " YN
        case "$YN" in y|Y|yes|Yes) ;; *) echo "    Aborted."; exit 1 ;; esac
    fi
fi

# ---------------------------------------------------------------------------
# 6. Pick the LAN subnet
# ---------------------------------------------------------------------------
# Two sources of truth, in priority order:
#   (a) the existing chrony.conf's `allow` line  — preserves user's choice
#       across re-runs of this script
#   (b) the subnet of the primary interface (the one carrying the default
#       route)  — the natural choice for a fresh install
# We prompt with the higher-priority value and show the other in the hint
# if they differ, so the user can spot when their network changed.

EXISTING_SUBNET=""
if [ -f "$BREW_PREFIX/etc/chrony.conf" ]; then
    EXISTING_SUBNET=$(awk '/^allow / {print $2; exit}' "$BREW_PREFIX/etc/chrony.conf")
fi

DETECTED_SUBNET=""
PRIMARY_IFACE=$(route -n get default 2>/dev/null | awk '/interface:/ {print $2}')
if [ -n "$PRIMARY_IFACE" ]; then
    PRIMARY_IP=$(ifconfig "$PRIMARY_IFACE" 2>/dev/null | awk '/inet / && $2!~/^127/ {print $2; exit}')
    if [ -n "$PRIMARY_IP" ]; then
        DETECTED_SUBNET=$(echo "$PRIMARY_IP" | awk -F. '{printf "%s.%s.%s.0/24\n", $1, $2, $3}')
    fi
fi

DEFAULT_SUBNET="${EXISTING_SUBNET:-${DETECTED_SUBNET:-192.168.1.0/24}}"

HINT=""
if [ -n "$EXISTING_SUBNET" ] && [ -n "$DETECTED_SUBNET" ] && [ "$EXISTING_SUBNET" != "$DETECTED_SUBNET" ]; then
    HINT=" (current config: $EXISTING_SUBNET, but $PRIMARY_IFACE is on $DETECTED_SUBNET)"
elif [ -n "$EXISTING_SUBNET" ]; then
    HINT=" (preserving from current config)"
elif [ -n "$DETECTED_SUBNET" ]; then
    HINT=" (detected from $PRIMARY_IFACE = $PRIMARY_IP)"
fi

echo
read -r -p "==> LAN subnet (CIDR) chrony will accept clients from$HINT [$DEFAULT_SUBNET]: " SUBNET
SUBNET=${SUBNET:-$DEFAULT_SUBNET}
echo "    -> $SUBNET"

# ---------------------------------------------------------------------------
# 7. Render customized configs
# ---------------------------------------------------------------------------
echo
echo "==> Generating customized configs..."
TMP=$(mktemp -d)
trap "rm -rf '$TMP'" EXIT

# gpsd-wrapper.sh: substitute DEV and BAUD, plus the brew prefix
sed -e "s|^DEV=.*|DEV=\"$GPS_DEV\"|" \
    -e "s|^BAUD=.*|BAUD=$BAUD|" \
    -e "s|/opt/homebrew|$BREW_PREFIX|g" \
    gpsd-wrapper.sh > "$TMP/gpsd-wrapper.sh"

# chrony.conf: substitute the allow subnet and brew prefix
sed -e "s|^allow .*|allow $SUBNET|" \
    -e "s|/opt/homebrew|$BREW_PREFIX|g" \
    chrony.conf > "$TMP/chrony.conf"

# LaunchDaemon plists: substitute brew prefix
sed "s|/opt/homebrew|$BREW_PREFIX|g" launchd/com.vu2cpl.gpsd.plist   > "$TMP/com.vu2cpl.gpsd.plist"
sed "s|/opt/homebrew|$BREW_PREFIX|g" launchd/com.vu2cpl.chrony.plist > "$TMP/com.vu2cpl.chrony.plist"

# ---------------------------------------------------------------------------
# 8. Install (will prompt for sudo)
# ---------------------------------------------------------------------------
echo "==> Installing files (sudo prompt may appear)..."
sudo install -m 644 -o root -g wheel "$TMP/chrony.conf"           "$BREW_PREFIX/etc/chrony.conf"
sudo install -m 755 -o root -g wheel "$TMP/gpsd-wrapper.sh"       "$BREW_PREFIX/etc/gpsd-wrapper.sh"
sudo install -m 644 -o root -g wheel "$TMP/com.vu2cpl.gpsd.plist"   /Library/LaunchDaemons/com.vu2cpl.gpsd.plist
sudo install -m 644 -o root -g wheel "$TMP/com.vu2cpl.chrony.plist" /Library/LaunchDaemons/com.vu2cpl.chrony.plist

sudo mkdir -p "$BREW_PREFIX/var/lib/chrony" \
              "$BREW_PREFIX/var/log/chrony"

# chrony 4.x refuses to bind its Unix command socket unless its containing
# directory passes two checks: mode no more permissive than 0770 (no bits for
# "other") AND ownership group is GID 0 (wheel). Brew's default is
# `drwxr-xr-x root:admin` on Apple Silicon, which fails both — chronyd logs:
#
#   Wrong permissions on /opt/homebrew/var/run/chrony
#     ... or, after a partial fix ...
#   Wrong owner of /opt/homebrew/var/run/chrony (GID != 0)
#   Disabled command socket /opt/homebrew/var/run/chrony/chronyd.sock
#
# With the socket disabled, chronyc silently falls back to UDP loopback, which
# chronyd treats as untrusted — so privileged commands like `makestep` come
# back as "501 Not authorised". Read-only queries (tracking, sources) keep
# working over UDP, which is why TimeSync's chrony panel displays fine while
# Step Clock fails.
#
# Use `install -d` to create the directory atomically with the right mode and
# ownership, regardless of whether brew or a previous run made it differently.
sudo install -d -m 0750 -o root -g wheel "$BREW_PREFIX/var/run/chrony"

# ---------------------------------------------------------------------------
# 9. (Re)bootstrap LaunchDaemons
# ---------------------------------------------------------------------------
echo "==> Loading LaunchDaemons..."
sudo launchctl bootout system/com.vu2cpl.gpsd   2>/dev/null || true
sudo launchctl bootout system/com.vu2cpl.chrony 2>/dev/null || true
sudo launchctl bootstrap system /Library/LaunchDaemons/com.vu2cpl.gpsd.plist
sleep 2
sudo launchctl bootstrap system /Library/LaunchDaemons/com.vu2cpl.chrony.plist
sleep 4

# ---------------------------------------------------------------------------
# 10. Verify
# ---------------------------------------------------------------------------
echo
echo "==> Status:"
echo "--- chronyc tracking ---"
"$BREW_PREFIX/bin/chronyc" tracking 2>&1 | head -7 || true
echo
echo "==> Done. Summary:"
echo "    GPS device: $GPS_DEV @ $BAUD baud"
echo "    LAN allowed: $SUBNET"
echo "    Brew prefix: $BREW_PREFIX"
echo
echo "Other PCs on $SUBNET can now sync time from this Mac's LAN IP."
echo "If chrony shows stratum 8 or no real reference, give it ~30 s and re-check"
echo "with: chronyc tracking ; chronyc sources"
