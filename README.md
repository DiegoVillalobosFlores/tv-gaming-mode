# TV Gaming Mode

Turns this desktop into a 10-foot console: the LG TV becomes the only head, audio
moves to the GPU's HDMI out, and the running `plasmashell` is swapped to the
Plasma Bigscreen shell. Running it again reverses every step from the state
captured on the way in.

Built for one machine (CachyOS, Plasma 6.7, NVIDIA AD102, LG TV on `HDMI-A-1`).
The head name, PCI address and sink description at the top of `bin/tv-mode.sh`
are hardware-specific — read them before running this anywhere else.

## Contents

| Path | What it is |
| --- | --- |
| `bin/tv-mode.sh` | The mode switch: `on` / `off` / `toggle` / `status`. |
| `bin/apollo-display.sh` | Apollo/Sunshine `prep-cmd` that does the same head swap for game streaming. |
| `desktop/tv-mode.desktop` | Launcher, with *Switch to the TV* / *Back to the desktop* actions. |
| `plasma-bigscreen/` | A patch against Plasma Bigscreen 6.7.4, plus a PKGBUILD that builds it. |

## How the switch works

Three steps, applied in order and undone in reverse:

1. **Displays** — refuses to run unless the TV is actually on (it drops off the
   bus when powered down, and blanking the other head would leave a headless
   session). Enables `HDMI-A-1` and disables every other head in a *single*
   `kscreen-doctor` commit: each commit re-runs HDMI link training and HDCP, and
   at 4K120 HDR the TV cannot hold a signal through two of them back to back.
2. **Audio** — wakes the HDMI card if the TV was asleep at login, then matches
   the sink by its EDID description (`LG TV`), because the profile and sink name
   flip between `surround71` and `stereo-extra1` depending on the TV's state.
   Existing streams are dragged over; `set-default-sink` alone only affects new ones.
3. **Shell** — stops the `plasma-plasmashell` user unit, then runs
   `plasma-bigscreen-swap-session`. Swapping the shell by hand is not enough:
   `plasma-bigscreen-inputhandler` quits unless `PLASMA_PLATFORM=mediacenter`, so
   a bare `plasmashell -p org.kde.plasma.bigscreen` leaves the TV remote (CEC)
   dead. If Bigscreen fails to come up within 3s, the desktop shell is restored
   rather than leaving the session without one.

State lives in `$XDG_RUNTIME_DIR` (`tv-mode.displays.json`, `tv-mode.sink`), so a
reboot always lands back on the desktop. Errors go to `$XDG_RUNTIME_DIR/tv-mode.log`.

## The Bigscreen patch

Plasma Bigscreen's home overlay — the sidebar on the Home button — listed
**Search**, a single **Tasks** button, and the settings toggles. Reaching a
running app meant Home, then Tasks, then hunting the grid.

`plasma-bigscreen/0001-homescreen-list-running-apps-in-home-overlay.patch` lists
the running apps inline in that sidebar, one shortcut each, so switching apps is
Home then one press. Against upstream `v6.7.4`, 3 files:

- **`TasksView.qml`** — exposes its existing `TaskManager.TasksModel` as
  `taskManagerModel` and adds `activateTask(index)`. No second model is created.
- **`MainColumn.qml`** — a `Repeater` over that model renders each running app as
  a `ButtonDelegate` (icon from `model.decoration` via the delegate's `leading`
  slot, label from `model.AppName`), between **Search** and the overview button.
  D-pad chaining is explicit — `Search → app 1 … app N → All Open Apps →
  Controller` — so it stays correct as apps open and close.
- **`HomeOverlayWindow.qml`** — wires the model in; activating a shortcut raises
  the window and closes the overlay.

The old **Tasks** button stays, below the list and relabelled **All Open Apps**,
so the grid overview with hold-to-close and *Close all apps* is still reachable.
Nothing was removed.

### Building it

```sh
cd plasma-bigscreen
makepkg -si
```

Installs as `6.7.4-1.tasks1`. Any `pacman -Syu` that updates `plasma-bigscreen`
replaces it with the stock build — rerun `makepkg -si` (and bump `pkgver` +
`sha256sums`) after an upstream bump.

## Installing the mode switch

```sh
./install.sh
```

Copies the scripts to `~/.local/bin` and the launcher to
`~/.local/share/applications`. The `.desktop` file hardcodes
`/home/diegov/.local/bin/tv-mode.sh`; `install.sh` rewrites that path to `$HOME`.

## Requirements

`kscreen-doctor`, `jq`, `pactl` (PipeWire), `plasma-bigscreen`, `libcec` for the
TV remote, and `notify-send` for the toasts.
