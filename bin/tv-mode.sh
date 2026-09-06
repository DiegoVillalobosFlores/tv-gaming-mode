#!/bin/sh
# TV gaming mode: LG TV becomes the only head, audio goes out the GPU's HDMI,
# and the running plasmashell is swapped to the Bigscreen (10-foot) shell.
# Reverses cleanly from the state captured at "on" time.
# Companion to apollo-display.sh, which does the same head-swap for streaming.
set -e
HEAD=HDMI-A-1
SINK_MATCH=alsa_output.pci-0000_01_00.1.hdmi   # AD102 HDMI audio -> LG TV
SINK_DESC="LG TV"                              # EDID name, survives profile changes
SHELL_DESKTOP=org.kde.plasma.desktop
# plasma-bigscreen-swap-session picks the Bigscreen shell itself, via the
# PLASMA_DEFAULT_SHELL that plasma-bigscreen-common-env exports.

export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}"
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=$XDG_RUNTIME_DIR/bus}"

STATE="$XDG_RUNTIME_DIR/tv-mode.displays.json"
SINKFILE="$XDG_RUNTIME_DIR/tv-mode.sink"
exec 2>>"$XDG_RUNTIME_DIR/tv-mode.log"

note() { notify-send -a "TV mode" -i video-television "TV mode" "$1" 2>/dev/null || true; }

# --- audio -------------------------------------------------------------
audio_to_hdmi() {
  pactl get-default-sink > "$SINKFILE"
  # The card sits on "off" whenever the TV was asleep at login, so wake it first.
  pactl list short sinks | grep -q "$SINK_MATCH" ||
    pactl set-card-profile alsa_card.pci-0000_01_00.1 output:hdmi-stereo || true
  # The profile (and so the sink name) flips between surround71 and stereo-extra1
  # depending on whether the TV was awake, so match the EDID name first.
  SINK=$(pactl list sinks | awk -v d="$SINK_DESC" '
    /^\tName: / {n=$2} /^\tDescription: / && index($0,d) {print n; exit}')
  [ -n "$SINK" ] ||
    SINK=$(pactl list short sinks | awk -v m="$SINK_MATCH" 'index($2,m)==1 {print $2; exit}')
  [ -n "$SINK" ] || { echo "no HDMI sink matching $SINK_MATCH" >&2; return 1; }
  pactl set-default-sink "$SINK"
  # set-default-sink only affects new streams; drag whatever is already playing over.
  pactl list short sink-inputs | cut -f1 | while read -r i; do
    pactl move-sink-input "$i" "$SINK" || true
  done
}

audio_restore() {
  [ -f "$SINKFILE" ] || return 0
  SINK=$(cat "$SINKFILE")
  if pactl list short sinks | cut -f2 | grep -qx "$SINK"; then
    pactl set-default-sink "$SINK"
    pactl list short sink-inputs | cut -f1 | while read -r i; do
      pactl move-sink-input "$i" "$SINK" || true
    done
  fi
  rm -f "$SINKFILE"
}

# --- displays ----------------------------------------------------------
displays_to_tv() {
  # The TV drops off the bus entirely when it is powered down, so there is
  # nothing to switch to and blanking DP-1 would leave a headless session.
  kscreen-doctor -j | jq -e --arg h "$HEAD" '.outputs[]|select(.name==$h)' >/dev/null || {
    note "$HEAD is not connected - turn the LG TV on first"
    echo "$HEAD absent; is the TV on?" >&2
    exit 1
  }
  kscreen-doctor -j > "$STATE"
  # Enable the TV and blank the other heads in ONE kscreen-doctor call. Each
  # separate call is its own atomic commit, and every commit re-runs HDMI link
  # training + HDCP; at 4K120 HDR the TV cannot hold a signal through that, so
  # two commits read as two disconnects before the picture settles. The
  # presence pre-flight above (TV absent from kscreen unless it is on) is the
  # guard against blanking DP-1 into a headless session.
  OFF=$(jq -r --arg h "$HEAD" '.outputs[]|select(.name!=$h and .enabled)|"output.\(.name).disable"' "$STATE")
  kscreen-doctor output.$HEAD.enable output.$HEAD.position.0,0 $OFF
}

displays_restore() {
  [ -f "$STATE" ] || return 0
  # kscreen renumbers mode ids between runs, so restore modes by name.
  ARGS=$(jq -r '.outputs[]|select(.enabled)|. as $o|($o.modes[]|select(.id==$o.currentModeId)|.name) as $m|
    "output.\($o.name).enable output.\($o.name).mode.\($m) output.\($o.name).scale.\($o.scale) output.\($o.name).position.\($o.pos.x),\($o.pos.y)"' "$STATE")
  OFF=$(jq -r '.outputs[]|select(.enabled|not)|"output.\(.name).disable"' "$STATE")
  kscreen-doctor $ARGS $OFF
  rm -f "$STATE"
}

# --- shell -------------------------------------------------------------
# Swapping the shell alone is not enough: plasma-bigscreen-inputhandler quits
# immediately unless PLASMA_PLATFORM=mediacenter, so the TV remote (CEC) is dead
# in a bare "plasmashell -p org.kde.plasma.bigscreen". swap-session sources
# plasma-bigscreen-common-env for the whole swapped-in shell and starts the
# input handler with it, which is the part that makes the remote work.
#
# plasmashell is a systemd user unit here; stop it first rather than letting
# swap-session's --replace race systemd into restarting the desktop shell.
shell_to_tv() {
  systemctl --user stop plasma-plasmashell.service || true
  # swap-session toggles on an *inherited* PLASMA_BIGSCREEN_LAUNCH_REASON, which
  # our .desktop launcher may already carry; clear it to force the "on" branch.
  PLASMA_BIGSCREEN_LAUNCH_REASON= plasma-bigscreen-swap-session >/dev/null 2>&1 || true
  # Never leave the session shell-less: if Bigscreen dies on startup, come back.
  sleep 3
  pgrep -u "$(id -u)" -x plasmashell >/dev/null 2>&1 || {
    note "Bigscreen failed to start - keeping the normal shell"
    shell_restore
    return 1
  }
}

shell_restore() {
  pkill -f plasma-bigscreen-inputhandler 2>/dev/null || true
  # Restarting the unit gives a plasmashell with systemd's pristine session env,
  # which drops the mediacenter variables wholesale - a cleaner restore than
  # sourcing swap-session's saved-env snapshot, and it cannot half-apply.
  rm -f "$HOME/.cache/plasma-bigscreen/saved-env"
  # Legacy cleanup: shells started by the pre-swap-session version of this script
  # are not systemd-managed, so the unit restart below would leave them running
  # and we would end up with two shells fighting over the session.
  [ -f "$XDG_RUNTIME_DIR/tv-mode.shell.pid" ] &&
    kill "$(cat "$XDG_RUNTIME_DIR/tv-mode.shell.pid")" 2>/dev/null
  rm -f "$XDG_RUNTIME_DIR/tv-mode.shell.pid"
  pkill -f "plasmashell -p org.kde.plasma.bigscreen" 2>/dev/null || true
  systemctl --user start plasma-plasmashell.service ||
    setsid plasmashell -p "$SHELL_DESKTOP" >/dev/null 2>&1 &
  :
}

case "${1:-toggle}" in
on)
  displays_to_tv
  audio_to_hdmi
  shell_to_tv
  note "LG TV only, HDMI audio, Bigscreen shell"
  ;;
off)
  shell_restore
  audio_restore
  displays_restore
  note "Back to the desktop"
  ;;
toggle)
  if [ -f "$STATE" ]; then exec "$0" off; else exec "$0" on; fi
  ;;
status)
  [ -f "$STATE" ] && echo "on" || echo "off"
  ;;
*) echo "usage: $0 on|off|toggle|status" >&2; exit 2 ;;
esac
