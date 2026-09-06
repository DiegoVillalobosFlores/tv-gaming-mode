#!/bin/sh
# Apollo prep-cmd: stream on a real head that can do the client's resolution.
# Apollo/Sunshine cannot change display mode on Linux (libdisplaydevice is Windows-only),
# and the ultrawide DP-1 has no 1080p EDID mode, so streaming switches to HDMI-A-1.
# ponytail: needs the HDMI sink present (TV powered, or an HDMI dummy plug).
set -e
HEAD=HDMI-A-1

# Apollo's service environment has no Wayland socket; kscreen-doctor aborts without it.
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}"
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=$XDG_RUNTIME_DIR/bus}"
STATE="$XDG_RUNTIME_DIR/apollo-display.json"

# Apollo only logs the exit code, so keep the actual error somewhere readable.
exec 2>>"$XDG_RUNTIME_DIR/apollo-display.log"

# kscreen renumbers mode ids between runs, so everything here addresses modes by name.
case "$1" in
on)
  # Apollo's values are not always plain integers, so keep only digits and fall back.
  echo "client env: w=[$SUNSHINE_CLIENT_WIDTH] h=[$SUNSHINE_CLIENT_HEIGHT] fps=[$SUNSHINE_CLIENT_FPS]" >&2
  int() { printf %s "$1" | tr -cd 0-9. | cut -d. -f1; }
  W=$(int "$SUNSHINE_CLIENT_WIDTH"); [ -n "$W" ] || W=1920
  H=$(int "$SUNSHINE_CLIENT_HEIGHT"); [ -n "$H" ] || H=1080
  F=$(int "$SUNSHINE_CLIENT_FPS"); [ -n "$F" ] || F=60

  kscreen-doctor -j > "$STATE"

  # exact WxH, refresh closest to F; otherwise the mode with the closest pixel count
  MODE=$(jq -r --arg head "$HEAD" --argjson w "$W" --argjson h "$H" --argjson f "$F" '
    [.outputs[] | select(.name == $head) | .modes[]]
    | map(select(.size.width == $w and .size.height == $h)) as $exact
    | (if ($exact | length) > 0
       then $exact | min_by(.refreshRate - $f | fabs)
       else min_by((.size.width * .size.height) - ($w * $h) | fabs)
       end).name' "$STATE")
  [ -n "$MODE" ] && [ "$MODE" != "null" ] || { echo "no usable mode on $HEAD" >&2; exit 1; }

  kscreen-doctor output.$HEAD.enable output.$HEAD.mode.$MODE output.$HEAD.scale.1 output.$HEAD.position.0,0

  # only blank the other heads once the stream head is really up
  kscreen-doctor -j | jq -e --arg head "$HEAD" '.outputs[] | select(.name == $head and .enabled)' >/dev/null
  ARGS=$(jq -r --arg head "$HEAD" '.outputs[] | select(.name != $head and .enabled) | "output.\(.name).disable"' "$STATE")
  [ -n "$ARGS" ] && kscreen-doctor $ARGS
  ;;
off)
  [ -f "$STATE" ] || exit 0
  ARGS=$(jq -r '.outputs[] | select(.enabled) | . as $o | ($o.modes[] | select(.id == $o.currentModeId) | .name) as $m |
    "output.\($o.name).enable output.\($o.name).mode.\($m) output.\($o.name).scale.\($o.scale) output.\($o.name).position.\($o.pos.x),\($o.pos.y)"' "$STATE")
  OFF=$(jq -r '.outputs[] | select(.enabled | not) | "output.\(.name).disable"' "$STATE")
  kscreen-doctor $ARGS $OFF
  rm -f "$STATE"
  ;;
*) echo "usage: $0 on|off" >&2; exit 2 ;;
esac
