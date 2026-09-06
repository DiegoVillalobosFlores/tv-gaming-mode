#!/bin/sh
# Arms the TV remote: the first click of the COM Smart Control's left mouse
# button switches the machine into TV mode. Picking the remote up off the
# coffee table is the gesture; nothing else has to be reached for.
# Runs as a systemd user service - see systemd/tv-mode-watch.service.
set -e

# The keyboard/mouse combo that comes with the TV. Addressed by by-id, never by
# /dev/input/eventN: the number moves with probe order and with every other USB
# device on the machine. if03 is the mouse interface; the same physical device
# also presents a keyboard (if02) and consumer/system-control nodes, unused here.
DEV=/dev/input/by-id/usb-123_COM_Smart_Control-if03-event-mouse
BTN=272                                   # BTN_LEFT
COOLDOWN=30                               # seconds to back off after a failed switch

HERE="$(dirname "$0")"
TV_MODE="$HERE/tv-mode.sh"
. "$HERE/tv-mode-input.sh"                # wait_for_event, require_input_group

export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"

require_input_group

while :; do
  # The receiver is a dongle. It is routinely absent at login and plugged in
  # later, so wait for the node instead of treating "missing" as an error.
  while [ ! -e "$DEV" ]; do sleep 5; done

  if wait_for_event "$DEV" "*code $BTN *, value 1"; then
    # "First time" is derived from tv-mode.sh's own state file rather than from
    # a flag of our own: while TV mode is already on, a click on the remote is
    # just a click. Switching back off re-arms this with no extra bookkeeping.
    if [ "$("$TV_MODE" status)" = off ]; then
      "$TV_MODE" on ||
        # tv-mode.sh has already said why - almost always that the TV is off,
        # so the head is not on the bus at all. Back off instead of repeating
        # the same notification on every click of a remote aimed at a dark TV.
        sleep "$COOLDOWN"
    fi
  else
    sleep 1     # evtest died on a device that is still present; do not spin
  fi
done
