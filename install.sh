#!/bin/sh
# Install the TV gaming mode scripts and launcher into the user's home.
set -e
cd "$(dirname "$0")"

BIN="$HOME/.local/bin"
APPS="$HOME/.local/share/applications"
UNITS="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
mkdir -p "$BIN" "$APPS" "$UNITS"

install -m 755 bin/tv-mode.sh bin/apollo-display.sh bin/tv-mode-watch.sh \
               bin/tv-mode-boot.sh bin/tv-mode-zoom.sh "$BIN/"
# Sourced by the watchers, not run on its own, so it is not executable.
install -m 644 bin/tv-mode-input.sh "$BIN/"
# The launcher ships with an absolute Exec= path; point it at this user's home.
sed "s|/home/diegov/.local/bin|$BIN|g" desktop/tv-mode.desktop > "$APPS/tv-mode.desktop"
chmod 644 "$APPS/tv-mode.desktop"
# The units use %h, so they need no rewriting. They are installed but
# deliberately not enabled: enabling either hands a remote or a controller the
# power to blank this machine's monitors, which is the user's call to make, not
# the installer's.
install -m 644 systemd/tv-mode-watch.service systemd/tv-mode-boot.service \
               systemd/tv-mode-zoom.service "$UNITS/"

# Bigscreen's input handler drives the pointer through the RemoteDesktop portal,
# so the portal asks "Plasma Bigscreen is asking for special privileges: control
# input devices" the first time. The portal names the asker after its systemd
# unit, and tv-mode.sh starts the shell through plasma-bigscreen-swap-session,
# so the handler inherits *that* app id - answering the prompt under any other
# id does not stop it coming back. Pre-answer it here; the store is persistent.
if command -v gdbus >/dev/null 2>&1; then
  for app in plasma-bigscreen-swap-session plasma-bigscreen-inputhandler \
             org.kde.plasma.bigscreen.inputhandler org.kde.plasma-remotecontrollers; do
    gdbus call --session --dest org.freedesktop.impl.portal.PermissionStore \
      --object-path /org/freedesktop/impl/portal/PermissionStore \
      --method org.freedesktop.impl.portal.PermissionStore.SetPermission \
      kde-authorized true remote-desktop "$app" '["yes"]' >/dev/null 2>&1 ||
      echo "Note: could not pre-approve the input portal for $app - approve the prompt by hand."
  done
fi

echo "Installed:"
echo "  $BIN/tv-mode.sh"
echo "  $BIN/apollo-display.sh"
echo "  $BIN/tv-mode-watch.sh"
echo "  $BIN/tv-mode-boot.sh"
echo "  $BIN/tv-mode-zoom.sh"
echo "  $BIN/tv-mode-input.sh"
echo "  $APPS/tv-mode.desktop"
echo "  $UNITS/tv-mode-watch.service"
echo "  $UNITS/tv-mode-boot.service"
echo "  $UNITS/tv-mode-zoom.service"
echo
echo "To have the TV remote switch modes on its own:"
echo "  systemctl --user daemon-reload"
echo "  systemctl --user enable --now tv-mode-watch.service"
echo
echo "To land a controller-started boot in TV mode:"
echo "  systemctl --user enable tv-mode-boot.service"
echo "  sudo install -m 644 udev/93-wolverine-wake.rules /etc/udev/rules.d/"
echo
echo "To zoom the TV from the controller's bumpers:"
echo "  systemctl --user enable --now tv-mode-zoom.service"
echo
echo "The Bigscreen patch is separate: cd plasma-bigscreen && makepkg -si"
