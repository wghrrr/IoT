#!/usr/bin/env bash
# Runs on the RPi HOST (not in a container) — needs dmesg/vcgencmd access.
# Exposes metrics via node-exporter's textfile collector and logs raw USB
# errors with timestamps so we can correlate future failures.
set -euo pipefail

# All writes go to the data disk, never to the SD card.
DATA1T_DIR="${DATA1T_DIR:-/mnt/Data1T}"
mountpoint -q "$DATA1T_DIR" || { echo "$DATA1T_DIR is not mounted - refusing to write to SD card" >&2; exit 1; }
TEXTFILE_DIR="$DATA1T_DIR/rpi-monitoring_data/textfile_collector"
LOGFILE="$DATA1T_DIR/rpi-monitoring_data/usb-health/usb-health.log"
STATE_DIR="$DATA1T_DIR/rpi-monitoring_data/usb-health"
ZIGBEE_DEV="/dev/serial/by-id"   # adjust if you use a specific by-id symlink

mkdir -p "$TEXTFILE_DIR" "$STATE_DIR"
DMESG_CURSOR="$STATE_DIR/dmesg.cursor"
ERR_COUNT_FILE="$STATE_DIR/usb_error_total"

touch "$ERR_COUNT_FILE"
[ -s "$ERR_COUNT_FILE" ] || echo 0 > "$ERR_COUNT_FILE"
prev_count=$(cat "$ERR_COUNT_FILE")

# --- 1. Zigbee/serial dongle presence -------------------------------------
if ls "$ZIGBEE_DEV"/* >/dev/null 2>&1; then
  zigbee_present=1
else
  zigbee_present=0
fi

# --- 2. Undervoltage flag ---------------------------------------------------
throttled_raw=$(vcgencmd get_throttled | cut -d= -f2)
throttled_dec=$((throttled_raw))

# --- 3. New USB error lines since last run (using journalctl cursor) --------
new_errors=0
if [ -f "$DMESG_CURSOR" ]; then
  cursor=$(cat "$DMESG_CURSOR")
  mapfile -t lines < <(journalctl -k --since "$cursor" 2>/dev/null | grep -Ei "usb .*(disconnect|reset|unable to enumerate|not responding|not accepting address)|Bluetooth: hci[0-9]+: Opcode.*failed" || true)
else
  lines=()
fi
new_errors=${#lines[@]}
if [ "$new_errors" -gt 0 ]; then
  for l in "${lines[@]}"; do echo "$(date -Is) $l" >> "$LOGFILE"; done
fi
date -Is > "$DMESG_CURSOR"

total_count=$((prev_count + new_errors))
echo "$total_count" > "$ERR_COUNT_FILE"

# --- 4. Write Prometheus textfile metrics (atomic write) --------------------
TMP="$TEXTFILE_DIR/usb_health.prom.$$"
{
  echo "# HELP rpi_zigbee_serial_present Whether the Zigbee/serial USB device is present (1) or missing (0)"
  echo "# TYPE rpi_zigbee_serial_present gauge"
  echo "rpi_zigbee_serial_present $zigbee_present"

  echo "# HELP rpi_throttled_raw Raw value of vcgencmd get_throttled"
  echo "# TYPE rpi_throttled_raw gauge"
  echo "rpi_throttled_raw $throttled_dec"

  echo "# HELP rpi_usb_error_total Cumulative count of USB disconnect/reset/enumerate-fail/BT-opcode-fail lines seen in kernel log"
  echo "# TYPE rpi_usb_error_total counter"
  echo "rpi_usb_error_total $total_count"
} > "$TMP"
mv "$TMP" "$TEXTFILE_DIR/usb_health.prom"
