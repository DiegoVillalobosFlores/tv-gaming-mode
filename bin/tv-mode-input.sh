#!/bin/sh
# Shared evtest plumbing for the two scripts that block on an input device:
# tv-mode-watch.sh (the TV remote's click) and tv-mode-boot.sh (the controller).
# Sourced, never executed - it defines functions and does nothing on its own.

# Reading an event node needs the "input" group. Callers check at startup so a
# device that is present but unreadable fails loudly instead of looping.
require_input_group() {
  id -nG | tr ' ' '\n' | grep -qx input ||
    { echo "not in the 'input' group; cannot read /dev/input" >&2; exit 1; }
}

# wait_for_event DEV PATTERN [TIMEOUT]
#
# Blocks until a line of evtest's output for DEV matches the case(1) glob
# PATTERN, or until TIMEOUT seconds have passed (0, the default, waits forever).
# Returns 0 on a match, non-zero on timeout or if evtest exits first - which is
# how an unplugged receiver shows up.
#
# The read loop runs in the calling shell, fed through a FIFO, rather than on
# the right-hand side of a pipe: a pipeline is not done until *every* member
# exits, and evtest only notices the closed pipe when it next writes - which is
# when the device is next moved. Reading the press and then waiting for some
# later event before acting on it is exactly the lag these scripts exist to
# avoid, so evtest gets an explicit kill instead.
#
# stdbuf is the other half of that: evtest block-buffers as soon as its stdout
# is not a terminal, so without it the press sits in a 4K buffer. stdbuf execs
# evtest in place, so the recorded pid is evtest itself and the kill lands.
#
# The node is read, never grabbed - no EVIOCGRAB - so the press still reaches
# whatever is underneath.
wait_for_event() {
  _dev=$1
  _pat=$2
  _limit=${3:-0}
  _fifo="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/tv-mode-input.$$.fifo"

  rm -f "$_fifo"
  mkfifo "$_fifo"
  stdbuf -oL evtest "$_dev" >"$_fifo" 2>/dev/null &
  _reader=$!

  # The timeout kills the writer rather than using "read -t", which is a
  # bashism: closing the FIFO's only writer is what ends the loop below.
  _timer=
  if [ "$_limit" -gt 0 ]; then
    ( sleep "$_limit"; kill "$_reader" 2>/dev/null ) &
    _timer=$!
  fi

  _rc=1
  while read -r _line; do
    # $_pat is expanded after the case is parsed, so parentheses in the pattern
    # are matched literally rather than closing the branch.
    case "$_line" in
      $_pat) _rc=0; break ;;
    esac
  done < "$_fifo"

  kill "$_reader" 2>/dev/null || true
  wait "$_reader" 2>/dev/null || true
  # An "if", not "[ -n ... ] && ...": with no timeout there is no timer, and a
  # trailing AND-list whose test fails returns 1, which set -e in the caller
  # takes as the function failing.
  if [ -n "$_timer" ]; then
    kill "$_timer" 2>/dev/null || true
    wait "$_timer" 2>/dev/null || true
  fi
  rm -f "$_fifo"
  return "$_rc"
}
