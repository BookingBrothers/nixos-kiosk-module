#!/usr/bin/env bash
# Re-arms kiosk-idle-reset.timer on every touch event (see ../default.nix's
# `idleTimeoutMinutes` for the overall design). All the "has N minutes
# passed without activity" logic lives in the timer unit itself
# (OnActiveSec, set from idleTimeoutMinutes there) -- this script doesn't
# even know the minute value, only that it must keep restarting the
# timer's countdown, which is what `systemctl restart` on a .timer unit
# does: re-triggers its activation, so it only actually fires if this loop
# goes a full countdown without reading an event.
set -eu

: "${TOUCH_DEVICE:?}"

# TOUCH_DEVICE is a udev-created symlink (services.udev.extraRules); it may
# not exist yet the moment this unit starts, so wait for it rather than
# fail straight into a restart loop.
found=0
for _ in $(seq 1 50); do
  if [ -e "$TOUCH_DEVICE" ]; then
    found=1
    break
  fi
  sleep 0.2
done

# If the device never showed up, exit nonzero (Restart=always retries
# after RestartSec) WITHOUT touching the timer. Previously this fell
# through into re-arming the timer and then immediately entering the read
# loop below, where `dd` on a nonexistent device fails instantly -- the
# unit would restart every RestartSec, re-arming the timer each time and
# permanently preventing it from ever actually expiring, with no on-screen
# symptom at all. Only re-arm once there's an actual device to watch.
if [ "$found" -ne 1 ]; then
  echo "idle-watchdog: $TOUCH_DEVICE never appeared, not re-arming the timer" >&2
  exit 1
fi

# Start the countdown running from now, then re-arm it below on every event.
systemctl restart kiosk-idle-reset.timer

# Block-reads TOUCH_DEVICE one raw input_event at a time (24 bytes on
# 64-bit Linux -- struct input_event in linux/input.h: two longs for the
# timeval, then two u16s and an s32). read() blocks until the kernel has
# an event ready, so this loop is otherwise idle -- no polling. The exact
# byte count read doesn't matter for detecting *that* activity happened,
# so a short/partial read still counts.
while dd if="$TOUCH_DEVICE" of=/dev/null bs=24 count=1 status=none; do
  systemctl restart kiosk-idle-reset.timer
done
