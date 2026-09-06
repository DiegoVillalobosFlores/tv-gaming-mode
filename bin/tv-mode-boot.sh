#!/bin/sh
# Lands a boot in TV mode when the boot was started from the couch.
#
# The machine is powered on out of S5 by the controller's Home button; the BIOS
# side of that is in SETUP.md. Nothing survives S5 to tell the session which
# button did it - this is a cold boot and not a resume, so there is no wake
# source to read and no /sys wakeup counter that outlives the power cycle. The
# session asks the controller instead: for WINDOW seconds after login, any
# button press on the pad means "I am on the couch" and switches to TV mode.
# Press nothing - because the machine was started at the desk, from the case
# button or a keyboard - and the desktop is left exactly as it is.
#
# The press is deliberately *any* EV_KEY, not Home specifically: Home is already
# spoken for by plasma-remotecontrollers, and by the time the desktop is up the
# obvious thing to do with a pad in your hands is press something.
#
# Runs as a systemd user service - see systemd/tv-mode-boot.service.
set -e

# The Wolverine's 2.4GHz receiver. by-id, never eventN: the number moves with
# probe order. The receiver presents a keyboard and a mouse interface too (if01,
# which is what makes the BIOS see it as a wake-capable HID); -event-joystick is
# the xpad node, the only one that carries the face and shoulder buttons.
DEV=/dev/input/by-id/usb-Razer_Razer_Wolverine_V3_Pro_for_Xbox_2.4-event-joystick
HEAD=HDMI-A-1     # must match tv-mode.sh; apollo-display.sh carries its own too
WINDOW=120        # seconds after login during which a press means "TV mode"
PLUG_WAIT=30      # seconds to wait for the receiver to enumerate at all
HEAD_WAIT=45      # seconds to wait for the TV to reach the bus after the press

HERE="$(dirname "$0")"
TV_MODE="$HERE/tv-mode.sh"
. "$HERE/tv-mode-input.sh"                # wait_for_event, require_input_group

export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"

require_input_group

# Already there - a session restarted inside TV mode has nothing to decide.
[ "$("$TV_MODE" status)" = off ] || exit 0

# The receiver re-enumerates a moment after login and the pad itself takes a
# second to re-associate, so absence at t=0 is normal rather than an answer.
# Absence for the whole PLUG_WAIT is an answer: no controller, no couch.
waited=0
while [ ! -e "$DEV" ]; do
  [ "$waited" -lt "$PLUG_WAIT" ] || exit 0
  sleep 1
  waited=$((waited + 1))
done

# Sticks drift, so only EV_KEY counts. An EV_ABS filter would fire on a pad
# resting face-down in the sofa.
wait_for_event "$DEV" "*type 1 (EV_KEY)*, value 1" "$WINDOW" || exit 0

# tv-mode.sh refuses outright when the head is absent, which is right for a
# deliberate switch but wrong here: a TV started at the same moment as the PC is
# still negotiating HDMI while the desktop is already up. Wait for it, then let
# tv-mode.sh make the same check for real and report if it is still missing.
waited=0
while ! kscreen-doctor -j 2>/dev/null |
        jq -e --arg h "$HEAD" '.outputs[]|select(.name==$h)' >/dev/null; do
  [ "$waited" -lt "$HEAD_WAIT" ] || break
  sleep 1
  waited=$((waited + 1))
done

exec "$TV_MODE" on
