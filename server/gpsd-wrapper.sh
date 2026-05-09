#!/bin/bash
# SPDX-License-Identifier: MIT
# gpsd wrapper that pre-configures the FTDI USB-serial port via stty before launching
# gpsd. macOS's in-process tcsetattr is unreliable for FTDI (silently fails to set the
# hardware baud rate) — stty's path through the kernel works.
set -e
DEV="/dev/cu.usbserial-D306Y9DQ"
BAUD=4800

/bin/stty -f "$DEV" "$BAUD" cs8 -cstopb -parenb -icanon -echo raw 2>/dev/null || true
exec /opt/homebrew/sbin/gpsd -N -n -D 2 "$DEV"
