#!/bin/sh
# Zoom the TV from the couch: the controller's shoulder buttons drive KWin's
# screen magnifier. L1 zooms out, R1 zooms in.
#
# A 4K panel seen from a sofa turns small text into no text at all, and nothing
# on the TV - not Bigscreen, not a browser inside it - offers a zoom a
# controller can reach. KWin already has one, the "zoom" effect that ships bound
# to Meta+- / Meta++, so the bumpers are mapped onto those two actions.
#
# Deliberately *not* a display rescale. Changing output.<head>.scale is a fresh
# kscreen commit, every commit re-runs HDMI link training + HDCP, and at 4K120
# HDR the panel cannot hold a signal through a stream of them - the same reason
# displays_to_tv in tv-mode.sh is one single kscreen-doctor call. The magnifier
# is a compositor-side transform: instant, and it touches no output at all.
#
# Runs as a systemd user service - see systemd/tv-mode-zoom.service.
set -e

# The Wolverine's 2.4GHz receiver, as in tv-mode-boot.sh. -event-joystick is the
# xpad node; the bumpers exist nowhere else on this device.
DEV=/dev/input/by-id/usb-Razer_Razer_Wolverine_V3_Pro_for_Xbox_2.4-event-joystick
BTN_OUT=310       # BTN_TL, left bumper
BTN_IN=311        # BTN_TR, right bumper
MAX_STEPS=8       # zoom-in presses allowed; KWin's step is 1.2x, so ~4.3x total

HERE="$(dirname "$0")"
TV_MODE="$HERE/tv-mode.sh"
. "$HERE/tv-mode-input.sh"                # stream_events, require_input_group

export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=$XDG_RUNTIME_DIR/bus}"

require_input_group

steps=0

# Fire KWin's own action rather than synthesising Meta+-: the shortcut is the
# user's to rebind, and a synthetic key would need a virtual keyboard and would
# land in whatever has focus. The action name is stable, the key is not.
zoom() {
  qdbus6 org.kde.kglobalaccel /component/kwin \
    org.kde.kglobalaccel.Component.invokeShortcut "$1" >/dev/null 2>&1 || true
}

# The same standdown the plasma-keyboard patch makes in C++: while a game holds
# the pad open, L1 and R1 belong to the game and not to us. The ignore list is
# what makes the scan mean anything - plasma-remotecontrollers, Bigscreen's
# input handler, the Steam client and the on-screen keyboard each keep every pad
# open for the whole session, so without it the scan always matches. evtest is
# in the list because our own reader is one, as is tv-mode-boot.sh's.
#
# comm is truncated to 15 characters by the kernel, hence the short names.
pad_claimed() {
  _node=$(readlink -f "$DEV")
  # The same pad is also /dev/input/jsN and plenty of software opens that one
  # instead; both node names sit together in the device's sysfs directory.
  _nodes=$_node
  for _sib in $(ls "/sys/class/input/${_node##*/}/device" 2>/dev/null); do
    case "$_sib" in
      js[0-9]*|event[0-9]*) [ "/dev/input/$_sib" = "$_node" ] ||
                              _nodes="$_nodes /dev/input/$_sib" ;;
    esac
  done

  for _pid in $(fuser $_nodes 2>/dev/null); do
    case "$(cat "/proc/$_pid/comm" 2>/dev/null)" in
      plasma-remoteco|plasma-bigscree|plasma-keyboard|steam|steamwebhelper|evtest) ;;
      "") ;;                              # exited between fuser and the read
      *) return 0 ;;
    esac
  done
  return 1
}

on_event() {
  case "$1" in
    *"code $BTN_OUT "*", value 1") _dir=out ;;
    *"code $BTN_IN "*", value 1")  _dir=in ;;
    *) return 0 ;;
  esac

  # Only on the TV. At the desk the bumpers are two of the pad's most-used
  # buttons and a zooming desktop would be nothing but a surprise; the state
  # file is the same one tv-mode-watch.sh derives "first click" from.
  [ "$("$TV_MODE" status)" = on ] || return 0
  # "! pad_claimed || return", not "pad_claimed && return": a trailing AND-list
  # whose test fails returns 1, and this runs in the watcher's own shell under
  # set -e, so that form would take the watcher down on every unclaimed press.
  ! pad_claimed || return 0

  if [ "$_dir" = in ]; then
    # Clamped so a handful of presses cannot strand the session at a zoom level
    # that takes thirty presses to walk back.
    [ "$steps" -lt "$MAX_STEPS" ] || return 0
    steps=$((steps + 1))
    zoom view_zoom_in
  else
    # Zooming out is never clamped, only floored. The counter tracks our own
    # presses and a Meta++ from a keyboard desyncs it; letting L1 through
    # regardless means the visible zoom can always be undone from the couch,
    # and KWin stops at 1.0 on its own.
    [ "$steps" -eq 0 ] || steps=$((steps - 1))
    zoom view_zoom_out
  fi
  return 0
}

while :; do
  # The receiver is a dongle: routinely absent at login, plugged in later.
  while [ ! -e "$DEV" ]; do sleep 5; done
  stream_events "$DEV" on_event
  sleep 1     # evtest died on a device that is still present; do not spin
done
