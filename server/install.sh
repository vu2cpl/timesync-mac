#!/bin/bash
# Install gpsd + chrony as macOS LaunchDaemons.
# Turns this Mac into a GPS-disciplined NTP server for the local LAN.
# Run from the repo root: ./server/install.sh
set -euo pipefail

cd "$(dirname "$0")"

echo "==> brew install gpsd chrony"
brew install gpsd chrony

echo "==> Installing config files"
sudo install -m 644 -o root -g wheel chrony.conf       /opt/homebrew/etc/chrony.conf
sudo install -m 755 -o root -g wheel gpsd-wrapper.sh   /opt/homebrew/etc/gpsd-wrapper.sh

echo "==> Creating runtime dirs"
sudo mkdir -p /opt/homebrew/var/run/chrony /opt/homebrew/var/lib/chrony /opt/homebrew/var/log/chrony

echo "==> Installing LaunchDaemons"
sudo install -m 644 -o root -g wheel launchd/com.vu2cpl.gpsd.plist   /Library/LaunchDaemons/com.vu2cpl.gpsd.plist
sudo install -m 644 -o root -g wheel launchd/com.vu2cpl.chrony.plist /Library/LaunchDaemons/com.vu2cpl.chrony.plist

echo "==> Bootstrapping daemons"
sudo launchctl bootout system/com.vu2cpl.gpsd 2>/dev/null || true
sudo launchctl bootout system/com.vu2cpl.chrony 2>/dev/null || true
sudo launchctl bootstrap system /Library/LaunchDaemons/com.vu2cpl.gpsd.plist
sleep 2
sudo launchctl bootstrap system /Library/LaunchDaemons/com.vu2cpl.chrony.plist
sleep 4

echo "==> chronyc tracking"
chronyc tracking || true

echo
echo "==> Done. Point clients at this Mac's LAN IP for time sync."
echo "    You may need to edit chrony.conf's 'allow' line to match your subnet,"
echo "    and gpsd-wrapper.sh's DEV path to match your GPS device."
