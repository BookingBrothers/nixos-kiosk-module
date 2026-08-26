#!/usr/bin/env bash
# The one client cage launches. Backgrounds the rotation wait-and-apply
# (screen-rotation.sh, run as its own script rather than sourced in, so
# this file stays plain shell with no Nix templating in it) before
# exec'ing Firefox, both inside the ONE process cage manages -- see
# ../default.nix's `program` comment for why this has to be in-process
# rather than a separate ExecStartPost.
#
# Everything host-specific comes in via environment variables set by
# ../default.nix's `services.cage.environment`, so this file itself
# never needs to change when the URL, kiosk mode, or rotation does:
#   SCREEN_ROTATION_SCRIPT  path to the built screen-rotation.sh
#   FIREFOX_BIN             path to the firefox binary to exec
#   KIOSK_MODE_FLAG         "--kiosk" or "--private-window"
#   KIOSK_URL               the site to show
set -eu

( "${SCREEN_ROTATION_SCRIPT:?}" ) &
exec "${FIREFOX_BIN:?}" --profile /tmp/firefox-kiosk-profile "${KIOSK_MODE_FLAG:?}" "${KIOSK_URL:?}"
