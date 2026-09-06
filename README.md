# TV Gaming Mode

Turns this desktop into a 10-foot console: the LG TV becomes the only head, audio
moves to the GPU's HDMI out, and the running `plasmashell` is swapped to the
Plasma Bigscreen shell. Running it again reverses every step from the state
captured on the way in.

Two patched Plasma packages come with it, both aimed at the same thing — never
needing to get up for a keyboard or a mouse. One lists running apps in the
Bigscreen home overlay; the other lets a game controller type on the on-screen
keyboard.

Built for one machine (CachyOS, Plasma 6.7, NVIDIA AD102, LG TV on `HDMI-A-1`).
The head name, PCI address and sink description at the top of `bin/tv-mode.sh`
are hardware-specific — read them before running this anywhere else.

<p align="center">
  <img src="docs/home-overlay-sidebar.png" alt="The Bigscreen home overlay sidebar, listing Discord, kitty, Orca, Steam and TIDAL Hi-Fi as shortcuts between Search and All Open Apps" width="300">
</p>
<p align="center">
  <em>The patched home overlay: the running apps listed inline, one press from the Home button.</em>
</p>

**[Setup and configuration →](SETUP.md)** — dependencies, adapting the scripts to
your hardware, building the patch, controller mapping, troubleshooting.
Agents working in this repo should start with [AGENTS.md](AGENTS.md).

## Contents

| Path | What it is |
| --- | --- |
| `bin/tv-mode.sh` | The mode switch: `on` / `off` / `toggle` / `status`. |
| `bin/apollo-display.sh` | Apollo/Sunshine `prep-cmd` that does the same head swap for game streaming. |
| `desktop/tv-mode.desktop` | Launcher, with *Switch to the TV* / *Back to the desktop* actions. |
| `plasma-bigscreen/` | A patch against Plasma Bigscreen 6.7.4, plus a PKGBUILD that builds it. |
| `plasma-keyboard/` | A patch against Plasma's on-screen keyboard 6.7.4 adding game-controller input, plus a PKGBUILD. |
| `install.sh` | Copies the scripts and launcher into `~/.local`. |
| `SETUP.md` | Full setup and configuration guide. |
| `AGENTS.md` | Invariants and unsafe commands, for coding agents. |

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

## The on-screen keyboard patch

`plasma-keyboard` is the Qt VirtualKeyboard-based panel KWin pops up for text
entry. Stock, it is driven by touch, a mouse, or a physical keyboard's arrow keys
— none of which exist on the couch. Entering a password or a search term on the
TV meant fetching a keyboard.

`plasma-keyboard/0001-gamepad-navigation-for-the-on-screen-keyboard.patch` reads
game controllers straight from `/dev/input` with libevdev and drives the panel's
own navigation mode. Against upstream `v6.7.4`, 12 files:

- **`src/gamepadlistener.{h,cpp}`** (new) — finds controllers by evdev capability
  (`BTN_SOUTH` plus a stick or hat), so any pad the kernel understands works;
  hotplugs off a watch on `/dev/input`; auto-repeats held directions; owns the
  button mapping.
- **`src/inputlisteneritem.{h,cpp}`** — feeds directions into the keyboard
  navigation Qt VirtualKeyboard already had but only wired to arrow keys, and
  sends backspace/space/enter to the focused app as keysyms.
- **`src/qml/main.qml`** — hold-to-shift, re-asserted after every character.
- **`plasmakeyboardsettings.kcfg` + the KCM** — two toggles, both on by default.

The mapping copies the Steam Deck's on-screen keyboard, so it needs no learning:

| Input | Keyboard shown | Keyboard hidden |
| --- | --- | --- |
| D-pad / left stick | Move the highlight (repeats) | — |
| A | Type the highlighted key | — |
| B | Close the keyboard | — |
| X | Backspace (repeats) | **Summon the keyboard** |
| Y | Space | — |
| L2 | Shift, held rather than toggled | — |
| R2 | Enter | — |
| L1 / R1 | Unbound, as on Steam | — |

Two things are deliberate and easy to "fix" wrongly:

- **The controller is grabbed (`EVIOCGRAB`) while the panel is up**, so the app
  underneath does not also act on your A presses. **Home / Guide (`BTN_MODE`) is
  excluded** — the grab is dropped for as long as it is held, because on this
  machine that button is what `plasma-remotecontrollers` turns into the Bigscreen
  home overlay key. Without the exclusion the keyboard swallows it.
- **X summons only when the focused window reports it can take text input**
  (KWin's `activeClientSupportsTextInput`). X is a face button games use; without
  that check the keyboard would pop up mid-game.

## Installing

```sh
./install.sh                          # scripts + launcher into ~/.local
cd plasma-bigscreen && makepkg -si    # the patched Bigscreen package
cd ../plasma-keyboard && makepkg -si  # the patched on-screen keyboard
plasmashell --replace                 # reload, from inside the Bigscreen session
```

Both patched packages install as `6.7.4-1.9`, and **any `pacman -Syu` that updates
either silently reverts it** — the file lists are identical to stock, so nothing
looks wrong. `pacman -Qi plasma-bigscreen plasma-keyboard` is the tell.

Adapting the hardware constants to a different machine, the controller button
mapping, the Apollo prep-cmd and troubleshooting are all in **[SETUP.md](SETUP.md)**.
