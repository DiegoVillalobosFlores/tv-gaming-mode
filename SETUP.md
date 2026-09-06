# Setup

Start to finish: dependencies, adapting the scripts to your hardware, installing,
building the Bigscreen patch, and wiring up the controller and streaming.

Everything here targets **Arch / CachyOS with Plasma 6.7 on Wayland**. On another
distro the scripts still work but the package names and the `plasma-bigscreen`
build do not.

---

## 1. Dependencies

```sh
sudo pacman -S --needed libkscreen jq libpulse libnotify qt6-tools plasma-bigscreen
```

| Package | Provides | Used for |
| --- | --- | --- |
| `libkscreen` | `kscreen-doctor` | enabling/disabling heads, reading modes |
| `jq` | `jq` | parsing `kscreen-doctor -j` state |
| `libpulse` | `pactl` | sink switching (works against PipeWire) |
| `libnotify` | `notify-send` | the toasts; optional, failures are swallowed |
| `qt6-tools` | `qdbus6` | inspecting/setting the Bigscreen shortcuts |
| `plasma-bigscreen` | the 10-foot shell | the mode's whole point |

Optional:

- **`libcec`** — TV remote over HDMI-CEC.
- **`plasma-remotecontrollers`** (AUR: `plasma-remotecontrollers-git`) — gamepad and
  CEC input. Needed for the controller Home button to reach Plasma at all.
- **`apollo`**/**`sunshine`** — only if you want `apollo-display.sh`.

---

## 2. Find your hardware values

`bin/tv-mode.sh` is written for one machine. Three values at the top must match
yours. **Do this with the TV powered on** — it drops off the bus when it is off.

### The head name

```sh
kscreen-doctor -o
```

Look for the output your TV is on — `HDMI-A-1` here. Note the name exactly.

### The audio sink and card

```sh
pactl list sinks | grep -E 'Name:|Description:'
pactl list cards short
```

You need two things:

- **`SINK_DESC`** — the sink's *Description*, which comes from the TV's EDID
  (`LG TV` here). Match on this first: the sink *name* changes between
  `...hdmi-surround71` and `...hdmi-stereo-extra1` depending on whether the TV was
  awake when the session started, so a name-only match breaks intermittently.
- **`SINK_MATCH`** — the stable name prefix, e.g.
  `alsa_output.pci-0000_01_00.1.hdmi`. Used as the fallback, and to notice the card
  is asleep.

The card id in `audio_to_hdmi()` (`alsa_card.pci-0000_01_00.1`) has to match the same
PCI address — it is what wakes the card when the TV was off at login.

### Apply them

Edit the header of `bin/tv-mode.sh`:

```sh
HEAD=HDMI-A-1
SINK_MATCH=alsa_output.pci-0000_01_00.1.hdmi
SINK_DESC="LG TV"
SHELL_DESKTOP=org.kde.plasma.desktop     # shell to come back to
```

and the `set-card-profile` line inside `audio_to_hdmi()` if your PCI address differs.
`bin/apollo-display.sh` has its own `HEAD=` to match.

---

## 3. Install

```sh
./install.sh
```

Copies both scripts to `~/.local/bin`, and the launcher to
`~/.local/share/applications/tv-mode.desktop` with the hardcoded `Exec=` path
rewritten to your `$HOME`. Make sure `~/.local/bin` is on your `PATH`.

Check it before trusting it to a keybind:

```sh
tv-mode.sh status     # -> off
tv-mode.sh on
tv-mode.sh off
```

If anything goes wrong the error is in `$XDG_RUNTIME_DIR/tv-mode.log`
(`/run/user/1000/tv-mode.log`), because the script's stderr is redirected there —
nothing useful is printed to your terminal.

### Optional: a hotkey

System Settings → Keyboard → Shortcuts → Add Command, pointing at
`~/.local/bin/tv-mode.sh toggle`.

---

## 4. Build the Bigscreen patch

```sh
cd plasma-bigscreen
makepkg -si
```

This fetches `plasma-bigscreen-6.7.4.tar.xz` from `download.kde.org`, verifies both
checksums, applies the patch, builds, and installs as **`6.7.4-1.9`**.

Then reload the shell:

```sh
plasmashell --replace
```

Run this **from inside the Bigscreen session** — it picks the shell back up from the
session's `PLASMA_DEFAULT_SHELL`. From a plain desktop session it would come back as
the desktop shell instead.

### Confirming it took

```sh
pacman -Qi plasma-bigscreen | grep -E '^(Version|Description)'
```

Patched: `6.7.4-1.9` and `(patched: running apps listed in the home overlay sidebar)`.
Stock: `6.7.4-1.1` and `Plasma shell for TVs`.

> **This is reverted by any `pacman -Syu` that updates `plasma-bigscreen`**, with no
> warning — the patched package installs exactly the same file list as stock, so
> nothing looks wrong. After an upstream bump, edit `pkgver` and the tarball
> `sha256sums` in `plasma-bigscreen/PKGBUILD` and rerun `makepkg -si`. If the patch
> no longer applies, re-derive it against the new tag from
> `invent.kde.org/plasma/plasma-bigscreen`; it touches three files under
> `containments/homescreen/package/contents/ui/homeoverlay/`.

---

## 5. Controller and remote

### The daemon

`plasma-remotecontrollers` translates gamepad buttons and HDMI-CEC into key events.
It autostarts via `/etc/xdg/autostart/org.kde.plasma-remotecontrollers.desktop`;
confirm it is alive, because **without it the controller's Home button produces
nothing at all**:

```sh
pgrep -af plasma-remotecontrollers
```

### Button mapping

Gamepad button → key mapping lives in `/etc/xdg/plasma-remotecontrollersrc`, override
per-user at `~/.config/plasma-remotecontrollersrc`. Stock:

```ini
[General]
ButtonEnter=0
ButtonUp=1
ButtonDown=2
ButtonLeft=3
ButtonRight=4
ButtonHomepage=9      # -> KEY_HOMEPAGE, the "Home Page" key
ButtonMenu=10         # -> the "Menu" key
ButtonBack=13
```

### What the buttons open

Bigscreen registers four global shortcuts under `plasmashell`. Defaults:

| Action | Key | Reached by |
| --- | --- | --- |
| Toggle Bigscreen Home Screen | `Home Page` | controller **Home** — opens the sidebar this repo patches |
| Toggle Bigscreen Tasks Overview | `Menu` | controller **Menu** — the full task grid |
| Toggle Bigscreen Settings | `Settings` | remotes with a settings key |
| Toggle Bigscreen Home Overlay | `Meta+O` | keyboard |

Read and change them over D-Bus rather than editing `kglobalshortcutsrc` by hand —
the running daemon owns that file and will overwrite hand edits:

```sh
# read
qdbus6 org.kde.biglauncher /BigLauncher org.kde.biglauncher.displayHomeScreenShortcut
qdbus6 org.kde.biglauncher /BigLauncher org.kde.biglauncher.activateTasksShortcut

# change (free the key from its current owner first — two actions cannot share one)
qdbus6 org.kde.biglauncher /BigLauncher org.kde.biglauncher.setActivateTasksShortcut ''
qdbus6 org.kde.biglauncher /BigLauncher org.kde.biglauncher.setDisplayHomeScreenShortcut 'Menu'
qdbus6 org.kde.biglauncher /BigLauncher org.kde.biglauncher.setActivateTasksShortcut 'Home Page'

# back to defaults
qdbus6 org.kde.biglauncher /BigLauncher org.kde.biglauncher.resetActivateTasksShortcut
qdbus6 org.kde.biglauncher /BigLauncher org.kde.biglauncher.resetDisplayHomeScreenShortcut
```

`org.kde.biglauncher` is only on the bus while the Bigscreen shell is running.

### CEC

Install `libcec` and the TV's own remote drives the same shortcuts over HDMI. If input
is dead, check `plasma-remotecontrollers` is running before suspecting the TV.

---

## 6. Streaming (optional)

`apollo-display.sh` is an Apollo/Sunshine **prep-cmd**, not something you run by hand.
Apollo and Sunshine cannot change display mode on Linux — `libdisplaydevice` is
Windows-only — so it switches to a head that has a mode matching what the client asked
for, reading `SUNSHINE_CLIENT_WIDTH` / `_HEIGHT` / `_FPS` from the environment.

In the Apollo/Sunshine web UI, per application:

- **Do** — `/home/YOU/.local/bin/apollo-display.sh on`
- **Undo** — `/home/YOU/.local/bin/apollo-display.sh off`

It needs the HDMI head present, so the TV must be on or an HDMI dummy plug fitted.
Errors land in `$XDG_RUNTIME_DIR/apollo-display.log`; Apollo itself only logs an exit
code.

Do not use it and `tv-mode.sh` at the same time — both capture and restore display
state through their own file, and interleaving them will restore the wrong layout.

---

## 7. Troubleshooting

| Symptom | Cause |
| --- | --- |
| `HDMI-A-1 absent; is the TV on?` in the log | The TV is off, so it is not on the bus. This check is deliberate — blanking the other head with nothing to switch to would leave a headless session. |
| TV shows no picture, or flickers between two disconnects | Something split the display change into more than one `kscreen-doctor` call. Each call is its own atomic commit and re-runs HDMI link training + HDCP; at 4K120 HDR the TV cannot hold a signal through two back to back. Keep enable and disable in one invocation. |
| Bigscreen comes up but the remote does nothing | The shell was started without `PLASMA_PLATFORM=mediacenter`, so `plasma-bigscreen-inputhandler` quit at startup. Use `plasma-bigscreen-swap-session`, not a bare `plasmashell -p org.kde.plasma.bigscreen`. |
| Audio still on the desktop speakers | The card was asleep and the profile did not come back, or `SINK_DESC` does not match your EDID name. Check `pactl list sinks`. |
| Sound only moves for newly started apps | Expected of `set-default-sink` alone; the script also walks `sink-inputs`. If you changed that part, put it back. |
| Two shells fighting after a failed switch | `shell_restore` handles the legacy non-systemd case, but if you hit it, `pkill -x plasmashell` then `systemctl --user start plasma-plasmashell.service`. |
| Task shortcuts gone from the sidebar | `pacman` replaced the patched package. See §4. |
| Stuck in TV mode after a crash | State lives in `$XDG_RUNTIME_DIR`, so a reboot always lands back on the desktop. Or `tv-mode.sh off`. |

---

## 8. Uninstall

```sh
rm ~/.local/bin/tv-mode.sh ~/.local/bin/apollo-display.sh
rm ~/.local/share/applications/tv-mode.desktop
sudo pacman -S plasma-bigscreen          # back to the stock package
```

Run `tv-mode.sh off` first if you are currently in TV mode.
