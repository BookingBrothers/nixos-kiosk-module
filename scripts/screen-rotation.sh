#!/usr/bin/env bash
# Applies SCREEN_ROTATION (normal|left|right|inverted, xrandr-style naming)
# via wlr-randr against the live compositor. Runs as ExecStartPost, which
# races cage's own startup, so wait for the Wayland socket first.
set -eu

: "${SCREEN_ROTATION:=normal}"

case "$SCREEN_ROTATION" in
  normal) exit 0 ;;
  left) transform=90 ;;
  right) transform=270 ;;
  inverted) transform=180 ;;
  *)
    echo "screen-rotation: unknown SCREEN_ROTATION '$SCREEN_ROTATION' (want normal|left|right|inverted), leaving as-is" >&2
    exit 0
    ;;
esac

for _ in $(seq 1 50); do
  [ -S "${XDG_RUNTIME_DIR:?}/${WAYLAND_DISPLAY:?}" ] && break
  sleep 0.1
done

output="$(wlr-randr | head -n1 | cut -d' ' -f1)"
if [ -z "$output" ]; then
  echo "screen-rotation: wlr-randr reported no output, skipping" >&2
  exit 0
fi

wlr-randr --output "$output" --transform "$transform"
