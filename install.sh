#!/bin/sh
# Install the TV gaming mode scripts and launcher into the user's home.
set -e
cd "$(dirname "$0")"

BIN="$HOME/.local/bin"
APPS="$HOME/.local/share/applications"
mkdir -p "$BIN" "$APPS"

install -m 755 bin/tv-mode.sh bin/apollo-display.sh "$BIN/"
# The launcher ships with an absolute Exec= path; point it at this user's home.
sed "s|/home/diegov/.local/bin|$BIN|g" desktop/tv-mode.desktop > "$APPS/tv-mode.desktop"
chmod 644 "$APPS/tv-mode.desktop"

echo "Installed:"
echo "  $BIN/tv-mode.sh"
echo "  $BIN/apollo-display.sh"
echo "  $APPS/tv-mode.desktop"
echo
echo "The Bigscreen patch is separate: cd plasma-bigscreen && makepkg -si"
