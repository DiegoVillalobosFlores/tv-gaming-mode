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
MANGOFILE="$XDG_RUNTIME_DIR/tv-mode.mangohud"
VKBDFILE="$XDG_RUNTIME_DIR/tv-mode.vkbd"
CURSORFILE="$XDG_RUNTIME_DIR/tv-mode.cursor"
exec 2>>"$XDG_RUNTIME_DIR/tv-mode.log"
# A successful run says nothing at all, so the log reads as empty and a failed
# launch from the Bigscreen shell leaves no trace of what it was even asked to
# do. Record the argv, and the status, whenever the run does not end at 0.
echo "[$(date -Is)] tv-mode.sh ${*:-toggle} (pid $$)" >&2
trap 'rc=$?; if [ "$rc" -ne 0 ]; then echo "[$(date -Is)] failed with status $rc" >&2; fi' EXIT

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

# --- on-screen keyboard ------------------------------------------------
# The head swap passes through a moment with no outputs at all, and
# plasma-keyboard answers that by creating a placeholder screen it never gives
# back: every later paint fails with "eglSwapBuffers failed with 0x300d"
# (EGL_BAD_SURFACE) and the keyboard silently stops appearing for the rest of
# the session -- the process is alive and still reading the pad, it just cannot
# put pixels anywhere. Restarting it is the whole fix, and it is free: KWin
# owns plasma-keyboard as the session's input method and relaunches it on
# demand, so this only has to be run after the output set is final.
keyboard_restart() {
  pkill -x plasma-keyboard 2>/dev/null || true
}

# Whether the keyboard is offered at all is KWin's call, not plasma-keyboard's,
# and it is one setting: VirtualKeyboardMode, 0 = never, 1 = with touch and
# tablet input, 2 = with touch, tablet and mouse. A desktop sits on 0 or 1,
# where a pointer click into a text field summons nothing -- which on the TV
# means the remote's pointer and the controller's cursor can both reach a field
# they cannot type into. TV mode forces 2 and puts the old value back on the way
# out; nothing here replaces the controller's own X-to-summon, it is what makes
# the other two inputs work.
#
# Set over D-Bus rather than with kwriteconfig6 because KWin applies the change
# live *and* writes it through to kwinrc itself, so there is no reconfigure to
# trigger and no window where the file and the running compositor disagree. It
# is a property rather than a method, hence the Properties.Set spelling on the
# write; the read has a short form and uses it.
VKBD_TV=2
vkbd_get() {
  qdbus6 org.kde.KWin /VirtualKeyboard org.kde.kwin.VirtualKeyboard.mode 2>/dev/null
}

vkbd_set() {
  qdbus6 org.kde.KWin /VirtualKeyboard org.freedesktop.DBus.Properties.Set \
    org.kde.kwin.VirtualKeyboard mode "$1" >/dev/null 2>&1 || true
}

keyboard_to_tv() {
  PREV=$(vkbd_get) || PREV=
  # Only record a mode that was actually read. A KWin that did not answer must
  # not be remembered as an empty value and then restored over a real setting.
  # An "if", not a trailing AND-list, whose failing test would trip set -e.
  if [ -n "$PREV" ]; then
    echo "$PREV" > "$VKBDFILE"
  fi
  vkbd_set "$VKBD_TV"
}

keyboard_restore() {
  [ -f "$VKBDFILE" ] || return 0
  vkbd_set "$(cat "$VKBDFILE")"
  rm -f "$VKBDFILE"
}

# --- cursor ------------------------------------------------------------
# The pointer is not how the TV is driven: the controller navigates with the
# d-pad and the buttons, and the mouse cursor is a leftover - from the desk, or
# from the last time the remote's pointer was waved at something - parked on top
# of the tile being looked at.
#
# KWin already hides it on key input, in the "hidecursor" effect, and every
# controller press *is* a key event by the time it reaches KWin:
# plasma-remotecontrollers maps the pad and injects the result either through
# /dev/uinput or through KWin's fake-input protocol, and both land in the same
# input redirection the effect filters. So the effect is the whole feature, and
# the next pointer move brings the cursor back on its own.
#
# InactivityDuration is set to 0 - the KCM's "Never" - so only input hides the
# cursor. Hiding it after a pause is not what is wanted here: on a TV the
# pointer is slow to re-find, and losing it while still looking at where it was
# left is worse than leaving it up.
#
# The effect is off by default and its two settings live in kwinrc, so all three
# are saved and put back on the way out, as with the keyboard mode above. It is
# loaded over D-Bus rather than by writing Plugins/hidecursorEnabled, which
# needs a full KWin reconfigure - every setting KWin has re-read for the sake of
# one effect.
CURSOR_EFFECT=hidecursor

cursor_loaded() {
  [ "$(qdbus6 org.kde.KWin /Effects org.kde.kwin.Effects.isEffectLoaded \
        "$CURSOR_EFFECT" 2>/dev/null)" = true ]
}

cursor_get() {
  kreadconfig6 --file kwinrc --group "Effect-$CURSOR_EFFECT" --key "$1" 2>/dev/null
}

# An empty value is a key that was not in kwinrc at all; deleting it is the
# restore, because writing "" back would leave the effect reading an empty
# string where it expects a number or a bool.
cursor_set() {
  if [ -n "$2" ]; then
    kwriteconfig6 --file kwinrc --group "Effect-$CURSOR_EFFECT" --key "$1" "$2"
  else
    kwriteconfig6 --file kwinrc --group "Effect-$CURSOR_EFFECT" --key "$1" --delete
  fi
}

cursor_effect() {
  qdbus6 org.kde.KWin /Effects "org.kde.kwin.Effects.$1" "$CURSOR_EFFECT" \
    >/dev/null 2>&1 || true
}

cursor_to_tv() {
  if cursor_loaded; then WAS=loaded; else WAS=unloaded; fi
  DUR=$(cursor_get InactivityDuration) || DUR=
  TYPING=$(cursor_get HideOnTyping) || TYPING=
  printf '%s\n%s\n%s\n' "$WAS" "$DUR" "$TYPING" > "$CURSORFILE"

  cursor_set InactivityDuration 0
  cursor_set HideOnTyping true
  # loadEffect does nothing to an effect that is already loaded, and it is the
  # reconfigure that makes the two settings above apply to this session; both
  # are needed because either state is possible here.
  cursor_effect loadEffect
  cursor_effect reconfigureEffect
}

cursor_restore() {
  [ -f "$CURSORFILE" ] || return 0
  WAS=$(sed -n 1p "$CURSORFILE")
  cursor_set InactivityDuration "$(sed -n 2p "$CURSORFILE")"
  cursor_set HideOnTyping "$(sed -n 3p "$CURSORFILE")"
  # Only unload an effect this script loaded. Someone who runs the desktop with
  # the cursor hidden keeps it, on their own settings.
  if [ "$WAS" = loaded ]; then
    cursor_effect reconfigureEffect
  else
    cursor_effect unloadEffect
  fi
  rm -f "$CURSORFILE"
}

# --- MangoHud ----------------------------------------------------------
# Disable the overlay outright rather than hiding it: MangoHud's own
# no_display=1 still loads the Vulkan layer into every game. The layer's
# disable_environment (DISABLE_MANGOHUD=1, see the implicit_layer.d json) keeps
# it from being loaded at all, which is what we want on the TV.
#
# It has to go into the systemd user manager *and* the D-Bus activation
# environment, because that is what Bigscreen's app launches inherit from.
# Already-running games keep their HUD; a Vulkan layer cannot be unloaded.
mangohud_disable() {
  systemctl --user show-environment | sed -n 's/^DISABLE_MANGOHUD=//p' > "$MANGOFILE"
  # One call sets it for both D-Bus-activated and systemd-user-started children.
  dbus-update-activation-environment --systemd DISABLE_MANGOHUD=1 >/dev/null 2>&1 ||
    systemctl --user set-environment DISABLE_MANGOHUD=1 || true
}

mangohud_restore() {
  [ -f "$MANGOFILE" ] || return 0
  # No previous value means the variable was unset; the activation environment
  # has no unset, so blank it there - the layer only disables itself on "1".
  PREV=$(cat "$MANGOFILE")
  dbus-update-activation-environment --systemd "DISABLE_MANGOHUD=$PREV" >/dev/null 2>&1 || true
  if [ -n "$PREV" ]; then
    systemctl --user set-environment "DISABLE_MANGOHUD=$PREV" || true
  else
    systemctl --user unset-environment DISABLE_MANGOHUD || true
  fi
  rm -f "$MANGOFILE"
}

# --- zoom --------------------------------------------------------------
# tv-mode-zoom.sh puts KWin's magnifier on the controller's bumpers, and the
# magnifier is session-wide state: a zoom left on the TV is still there on the
# desktop afterwards, where there is no controller to walk it back. Both
# switches start from 1.0 instead.
#
# ZOOM_STEPS matches MAX_STEPS in tv-mode-zoom.sh - that is how far in the
# bumpers can go, so that many steps out is how far back it can ever be. KWin
# clamps at 1.0, so the surplus calls when it is already there do nothing.
ZOOM_STEPS=8
zoom_reset() {
  i=0
  while [ "$i" -lt "$ZOOM_STEPS" ]; do
    qdbus6 org.kde.kglobalaccel /component/kwin \
      org.kde.kglobalaccel.Component.invokeShortcut view_zoom_out >/dev/null 2>&1 || true
    i=$((i + 1))
  done
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
  # An "[ -f x ] && cmd" here is an AND-OR list whose status is 1 when the file
  # is absent - which is the normal case - and "set -e" can take the script out
  # on it before the shell is ever restarted. Spell it out as an if instead.
  if [ -f "$XDG_RUNTIME_DIR/tv-mode.shell.pid" ]; then
    kill "$(cat "$XDG_RUNTIME_DIR/tv-mode.shell.pid")" 2>/dev/null || true
  fi
  rm -f "$XDG_RUNTIME_DIR/tv-mode.shell.pid"
  pkill -f "plasmashell -p org.kde.plasma.bigscreen" 2>/dev/null || true
  systemctl --user start plasma-plasmashell.service ||
    setsid plasmashell -p "$SHELL_DESKTOP" >/dev/null 2>&1 &
  :
}

case "${1:-toggle}" in
on)
  zoom_reset || true
  # displays_to_tv stays fatal: it has its own "is the TV even on the bus"
  # pre-flight, and there is no point dressing the session for a TV that is
  # not there. Everything between it and the shell swap is a comfort setting
  # though - HDMI audio in particular is missing whenever the TV has not
  # settled on this input yet - and none of them are worth landing on the TV
  # with no Bigscreen shell, which is what aborting here used to do.
  displays_to_tv
  audio_to_hdmi || true
  mangohud_disable || true
  keyboard_restart || true
  keyboard_to_tv || true
  cursor_to_tv || true
  shell_to_tv
  note "LG TV only, HDMI audio, MangoHud off, on-screen keyboard on, cursor hidden on the pad, Bigscreen shell"
  ;;
off)
  # Every step here is best-effort. Under "set -e" a single non-zero restore
  # used to abort the rest of the sequence, and the two steps that actually
  # get you out - displays_restore and shell_restore - sit at the end of it:
  # the session was left on a dark TV, DP-1 still disabled, Bigscreen still
  # up, with no way back. A restore that fails must not take the others down.
  zoom_reset || true
  shell_restore || true
  cursor_restore || true
  keyboard_restore || true
  mangohud_restore || true
  audio_restore || true
  displays_restore || true
  keyboard_restart || true
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
