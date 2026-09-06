# Setup

Start to finish: dependencies, adapting the scripts to your hardware, installing,
building the two patched Plasma packages, and wiring up the controller and streaming.

Everything here targets **Arch / CachyOS with Plasma 6.7 on Wayland**. On another
distro the scripts still work but the package names and the `plasma-bigscreen`
build do not.

---

## 1. Dependencies

```sh
sudo pacman -S --needed libkscreen jq libpulse libnotify qt6-tools plasma-bigscreen libevdev
```

| Package | Provides | Used for |
| --- | --- | --- |
| `libkscreen` | `kscreen-doctor` | enabling/disabling heads, reading modes |
| `jq` | `jq` | parsing `kscreen-doctor -j` state |
| `libpulse` | `pactl` | sink switching (works against PipeWire) |
| `libnotify` | `notify-send` | the toasts; optional, failures are swallowed |
| `qt6-tools` | `qdbus6` | inspecting/setting the Bigscreen shortcuts |
| `plasma-bigscreen` | the 10-foot shell | the mode's whole point |
| `libevdev` | reading controllers | build dep of the on-screen keyboard patch (§5) |

Optional:

- **`libcec`** — TV remote over HDMI-CEC.
- **`plasma-remotecontrollers`** (AUR: `plasma-remotecontrollers-git`) — gamepad and
  CEC input. Needed for the controller Home button to reach Plasma at all.
- **`apollo`**/**`sunshine`** — only if you want `apollo-display.sh`.
- **`evtest`** — only if you want the TV remote to arm the switch itself (§3).

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

### Optional: switch on the first click of the TV remote

`install.sh` also drops `tv-mode-watch.sh` and a user unit in place. Enabling the
unit makes the first click of the TV remote's left mouse button switch the
machine over, so the couch needs no keyboard:

```sh
systemctl --user daemon-reload
systemctl --user enable --now tv-mode-watch.service
systemctl --user status tv-mode-watch.service
```

It is installed but not enabled by default — it hands a remote the power to
blank your monitors, so turning it on should be a deliberate act.

Two things have to be true first:

```sh
pacman -Qq evtest                       # the watcher reads the device with it
id -nG | tr ' ' '\n' | grep -x input    # reading /dev/input needs this group
```

`usermod -aG input $USER` and a re-login if the group is missing. The watcher
refuses to start rather than looping on a device it cannot read.

The device it watches is the hardware constant at the top of the script:

```sh
DEV=/dev/input/by-id/usb-123_COM_Smart_Control-if03-event-mouse
```

For a different remote, find yours and confirm which node carries the pointer:

```sh
ls /dev/input/by-id/                    # by-id, never eventN - the number moves
sudo libinput debug-events --show-keycodes    # click, see which device speaks
evtest /dev/input/by-id/<yours>         # BTN_LEFT is code 272
```

A combo device presents several nodes; the one you want reports `EV_REL` and
`BTN_LEFT`, and its by-id name usually ends in `-event-mouse`.

Debugging: the watcher logs to the journal, not to `tv-mode.log`.

```sh
journalctl --user -u tv-mode-watch.service -f
```

Both this and `tv-mode-boot.sh` below share their `evtest` plumbing through
`tv-mode-input.sh`, which `install.sh` drops alongside them. It is sourced, not
run, so it is installed non-executable.

### Optional: land a controller-started boot in TV mode

```sh
systemctl --user enable tv-mode-boot.service
```

A press on the game controller in the first two minutes after login switches the
machine over, so a boot started from the couch ends up on the TV and a boot
started at the desk does not. Powering the machine on with the controller in the
first place is a BIOS matter — both halves are in §6.

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

## 5. Build the on-screen keyboard patch

Same shape as §4, and the same revert-on-upgrade caveat.

```sh
cd plasma-keyboard
makepkg -si
```

Installs as **`6.7.4-1.9`** with the description `(patched: driven by a game
controller)`. The keyboard is respawned by KWin on demand, so there is no shell
reload — just restart it:

```sh
pkill -x plasma-keyboard
```

### Confirming it took

```sh
pacman -Qi plasma-keyboard | grep -E '^(Version|Description)'
```

Then focus any text field and check the keyboard actually opened your controller:

```sh
sudo ls -l /proc/$(pgrep -x plasma-keyboard)/fd | grep input/event
```

One line per controller. Nothing means the device was not recognised as a gamepad
— it needs `BTN_SOUTH` plus a stick or a hat — or that you are not in the `input`
group (`id -nG | grep input`).

### Using it

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
| Home / Guide | Passed through to the shell | Passed through to the shell |

Copied from the Steam Deck's on-screen keyboard, so it needs no learning. X does
double duty because the two states never overlap.

### While a game is running

The keyboard stands down completely — no summoning, no grabbing, no navigation —
whenever another process has the controller's `/dev/input` nodes open. Check who
does:

```sh
for p in /proc/[0-9]*; do
  for f in $p/fd/*; do
    case "$(readlink "$f" 2>/dev/null)" in
      /dev/input/event*|/dev/input/js*) echo "$(cat $p/comm) -> $(readlink $f)";;
    esac
  done
done | sort -u
```

Four names are ignored by that check, because they hold every pad open for the
whole session and counting them would disable the feature permanently:
`plasma-remoteco`, `plasma-bigscree`, `steam`, `steamwebhelper` (they are
`/proc/<pid>/comm`, which the kernel truncates to 15 characters). Anything else —
including a game launched through Steam, which is its own process — means hands
off. If your setup has another always-resident controller reader, add it to
`inputInfrastructure()` in `src/gamepadlistener.cpp` or the keyboard will never
activate.

### Settings

System Settings → Plasma Keyboard, or `~/.config/plasmakeyboardrc`:

| Setting | Default | What it does |
| --- | --- | --- |
| Game controller navigation | on | The whole feature. Off closes every device. |
| Reserve the controller | on | `EVIOCGRAB` while the panel is up, so the app underneath does not also act on your presses. Turn it off if a game needs the pad while a text field is focused. |

Home / Guide is excluded from the grab even when reserving is on — see §6, it is
the button that opens the Bigscreen overlay.

---

## 6. Controller and remote

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

### Typing

The on-screen keyboard is driven by the same controller, through a different
mechanism — `plasma-keyboard` reads `/dev/input` itself rather than going through
`plasma-remotecontrollers`. Mapping and settings are in §5. The two do not
conflict: the keyboard leaves Home / Guide alone precisely so the shortcuts above
keep working while it is on screen.

### CEC

Install `libcec` and the TV's own remote drives the same shortcuts over HDMI. If input
is dead, check `plasma-remotecontrollers` is running before suspecting the TV.

### Powering the machine on from the couch

Pressing **Home** on the controller to start a machine that is fully off, and
landing in TV mode, is two independent halves. The second works on its own; the
first is firmware and may not be possible on your board at all.

#### Half one — the power-on (firmware)

**On this machine, measured: this does not work, and cannot be made to.** The
reasoning below is kept because the *method* transfers to other receivers; the
verdict is specific to the Wolverine V3 Pro's 2.4GHz dongle.

Linux has no part in it. In S5 there is no kernel running, so waking the board is
entirely up to the BIOS and to whether the port still has +5VSB. ASRock's feature
is called `USB Keyboard/Remote Power On`, and the name is literal: the firmware
watches for **HID keyboard reports**. A gamepad's reports are not keyboard
reports and the firmware ignores them.

The Wolverine's receiver looked like it might slip through, because it enumerates
a keyboard interface next to the pad:

```sh
ls /dev/input/by-id/ | grep -i wolverine
# ...-if01-event-kbd    <- a full keyboard, as far as the descriptor goes
# ...-event-joystick    <- the xpad node the session reads
```

That interface is real — it opens, and it advertises the whole `KEY_A`..`KEY_Z`
range. The question is whether any button on the pad ever makes it *emit*
something. Watch all of its nodes at once and press every button:

```sh
for n in if01-event-kbd event-joystick if01-event-mouse; do
  stdbuf -oL evtest /dev/input/by-id/usb-Razer_Razer_Wolverine_V3_Pro_for_Xbox_2.4-$n \
    2>/dev/null | stdbuf -oL grep 'Event:' | sed "s|^|$n: |" &
done
# press Home, A, the D-pad...; then: pkill -x evtest
```

The answer for this receiver is unambiguous. Over a 90-second capture with Home
and other buttons pressed repeatedly:

| Node | Events |
| --- | --- |
| `-event-joystick` | 196 — Home arrives as `code 316 (BTN_MODE)` |
| `-if01-event-kbd` | **0** |
| `-if01-event-mouse` | 0 |

The keyboard interface is enumerated but permanently silent. So there is nothing
for the firmware to see in S5, whatever the BIOS is set to and whichever port the
receiver is in. The dongle presumably exposes it for Synapse key-remapping, which
is configured from Windows and stored on the pad.

**Two things that are *not* the problem** — both worth knowing, because both are
plausible-sounding dead ends:

*The port does not need to be CPU-attached.* This is commonly repeated and is
false on this board. Every USB controller, chipset ones included, has an ACPI
wake node and it is enabled:

```sh
grep XH /proc/acpi/wakeup
# XHC0  S4  *enabled  pci:0000:78:00.3   CPU
# XHC1  S4  *enabled  pci:0000:78:00.4   CPU
# XHC2  S4  *enabled  pci:0000:79:00.0   CPU, internal header only (1 port)
# XH00  S4  *enabled  pci:0000:10:00.0   chipset
# XH00  S4  *enabled  pci:0000:12:00.0   chipset
```

Note also that `XHC2` — the CPU's USB 2.0 controller, the one an earlier version
of this document recommended as "the classic wake port" — has `maxchild` of 1 and
is occupied by the internal ASRock LED controller. It reaches no rear socket at
all. The rear USB 2.0 pair is chipset surplus: compare each root hub's 2.0 port
count against its 3.x sibling's.

*The OS side is already correct.* `udev/93-wolverine-wake.rules` does its job —
verify rather than assume:

```sh
for d in /sys/bus/usb/devices/*/; do
  [ "$(cat "$d/idProduct" 2>/dev/null)" = 0a4c ] || continue
  echo "$d wakeup=$(cat "$d/power/wakeup") bmAttributes=$(cat "$d/bmAttributes")"
done
# .../10-4/ wakeup=enabled bmAttributes=a0     <- a0 = remote wakeup supported
```

The one hard port exclusion from the manual still stands if you try another
device: *"Ultra USB Power is supported on USB32_34 ports. ACPI wake-up function
is not supported on USB32_34 ports."* That is rear panel item 2, the three USB
3.2 Gen1 ports.

**If you want to try anyway**, or with a receiver whose keyboard interface does
emit, set these under *Advanced → ACPI Configuration*:

| Setting | Set it to | Why |
| --- | --- | --- |
| `Deep Sleep` | **Disabled** | Any other value cuts +5VSB in S5, so the receiver is unpowered and nothing can wake anything. This one is non-negotiable. |
| `USB Keyboard/Remote Power On` | **Enabled** | The actual feature. Named `PS/2 or USB Keyboard Power On` on some BIOS revisions. |
| `USB Power Delivery in Soft Off State (S5)` | **Enabled** | Keeps the ports live so the receiver stays associated. |
| `ErP Ready` (under *Advanced → Onboard Devices*) | **Disabled** | ErP is the EU standby-power mode; it forces everything above off. |

The board manual documents the hardware only — the BIOS options live in ASRock's
separate UEFI guide, so the exact wording above may differ by a word or two on
your revision (this machine is on 4.20).

**The fallbacks**, in increasing order of effort:

- **Suspend (S3) instead of S5.** A kernel *is* running in S3, so the receiver's
  USB remote wakeup — already armed, `bmAttributes=a0` — can resume the machine
  on any button, no keyboard interface needed. This is the path that actually
  works with this hardware, at the cost of the machine drawing standby power.
- **Wake-on-LAN** from a phone. `enp8s0` currently has `power/wakeup` disabled;
  `sudo ethtool enp8s0` will say whether the NIC supports `g` (magic packet).
- **A second small device in the wake port** that does emit keyboard reports — a
  cheap USB remote or a media-key keypad — used only to power the machine on.

#### Half two — landing in TV mode (the session)

```sh
sudo install -m 644 udev/93-wolverine-wake.rules /etc/udev/rules.d/
sudo udevadm control --reload
systemctl --user enable tv-mode-boot.service
```

The udev rule flips the receiver's `power/wakeup` to `enabled`. The kernel leaves
USB remote wakeup off for everything but the boot keyboard, and Linux arms the
ACPI GPE for wakeup-enabled devices *on the way down*, so the bit has to be set
before the shutdown. Check it took:

```sh
for d in /sys/bus/usb/devices/*/; do
  [ "$(cat "$d/power/wakeup" 2>/dev/null)" = enabled ] &&
    echo "$(basename "$d")  $(cat "$d/product" 2>/dev/null)"
done
# ...  Razer Wolverine V3 Pro for Xbox 2.4
```

`tv-mode-boot.sh` handles the rest. A cold boot leaves nothing behind that says
which button started it — this is a fresh boot, not a resume, so there is no wake
source to read and no `/sys` counter that outlives the power cycle. So the script
asks the controller instead: for **120 seconds after login**, any button press on
the pad switches to TV mode. Start the machine at the desk and press nothing, and
the desktop is left alone.

In practice that is one extra press — Home to power on, Home again when the
desktop appears — and the second press is the same button that opens the
Bigscreen overlay once you are there.

Constants at the top of the script:

| | |
| --- | --- |
| `DEV` | the pad's `-event-joystick` by-id node |
| `WINDOW` | 120s; how long a press counts as "I am on the couch" |
| `PLUG_WAIT` | 30s; how long to wait for the receiver to enumerate before giving up |
| `HEAD_WAIT` | 45s; how long to wait for the TV to reach the bus after the press |

`HEAD_WAIT` exists because a TV switched on at the same moment as the PC is still
negotiating HDMI while the desktop is already up. `tv-mode.sh` refuses outright
when the head is absent, which is right for a deliberate switch and wrong here.

Debugging: it logs to the journal, not to `tv-mode.log`.

```sh
journalctl --user -u tv-mode-boot.service -b
```

Autologin has to be on, or the boot stops at a login screen the controller
cannot type into. On this machine that is `/etc/plasmalogin.conf`:

```ini
[Autologin]
User=diegov
Session=plasma.desktop
```

---

## 7. Streaming (optional)

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

## 8. Troubleshooting

| Symptom | Cause |
| --- | --- |
| `HDMI-A-1 absent; is the TV on?` in the log | The TV is off, so it is not on the bus. This check is deliberate — blanking the other head with nothing to switch to would leave a headless session. |
| TV shows no picture, or flickers between two disconnects | Something split the display change into more than one `kscreen-doctor` call. Each call is its own atomic commit and re-runs HDMI link training + HDCP; at 4K120 HDR the TV cannot hold a signal through two back to back. Keep enable and disable in one invocation. |
| Bigscreen comes up but the remote does nothing | The shell was started without `PLASMA_PLATFORM=mediacenter`, so `plasma-bigscreen-inputhandler` quit at startup. Use `plasma-bigscreen-swap-session`, not a bare `plasmashell -p org.kde.plasma.bigscreen`. |
| Audio still on the desktop speakers | The card was asleep and the profile did not come back, or `SINK_DESC` does not match your EDID name. Check `pactl list sinks`. |
| Sound only moves for newly started apps | Expected of `set-default-sink` alone; the script also walks `sink-inputs`. If you changed that part, put it back. |
| Two shells fighting after a failed switch | `shell_restore` handles the legacy non-systemd case, but if you hit it, `pkill -x plasmashell` then `systemctl --user start plasma-plasmashell.service`. |
| Task shortcuts gone from the sidebar | `pacman` replaced the patched package. See §4. |
| Controller does nothing on the on-screen keyboard | `pacman` replaced the patched `plasma-keyboard`; or the pad is not in the fd list from §5; or you are not in the `input` group. |
| Controller Home stops opening the Bigscreen overlay while typing | The grab exclusion for `BTN_MODE` was removed. It is what keeps Home reaching `plasma-remotecontrollers` while the panel is up. |
| L2/R2 do nothing on the keyboard | Trigger detection keys off `ABS_RX` — a pad with no right stick reports its triggers where a right stick would be, and they are skipped. Check `evtest`. |
| Keyboard pops back open right after closing it | Upstream re-shows it on any surrounding-text update. The patch suppresses that after a deliberate close; if it returns, `m_userDismissed` in `inputlisteneritem.cpp` is no longer being set or is being cleared too eagerly. |
| Keyboard appears mid-game on an X press | The game is not being seen as a controller reader. Run the scan in §5 while it is running: if it does not appear, it reads the pad through something other than an evdev/js node, and only the weaker `activeClientSupportsTextInput` guard is left. |
| Keyboard never activates, even on the desktop | Something always-resident is holding the pad and is not on the ignore list in §5. Run the scan with no game running; whatever shows up needs adding to `inputInfrastructure()`. |
| Controller stops working in a game while a text field is focused | Should no longer happen — the grab is suppressed while a game holds the pad. If it does, the standdown check is failing to see that game. |
| Stuck in TV mode after a crash | State lives in `$XDG_RUNTIME_DIR`, so a reboot always lands back on the desktop. Or `tv-mode.sh off`. |
| Home does not power the machine on | Expected on this hardware — the receiver's keyboard interface emits nothing, so the firmware has nothing to see in S5. Confirm with the three-node `evtest` capture in §6 before chasing BIOS settings or ports. Use suspend (S3) or Wake-on-LAN instead. |
| Controller press does not switch to TV mode at boot | First check the receiver is actually enumerated: `lsusb | grep 1532:0a4c`. If it is absent, `tv-mode-boot.service` exits after its 30s `PLUG_WAIT` having done nothing, and the journal shows a start and a finish exactly 30 seconds apart. |
| Machine powers on but stays on the desktop | `tv-mode-boot.service` is not enabled, no button was pressed inside its 120s window, or the receiver took longer than `PLUG_WAIT` to enumerate. `journalctl --user -u tv-mode-boot.service -b`. |
| Every boot lands in TV mode | Something is pressing the pad — a controller wedged in the sofa reporting a stuck button. `evtest` the joystick node. Axis drift is already ignored; only `EV_KEY` counts. |
| Boot lands in TV mode but the TV is blank | The TV reached the bus after `HEAD_WAIT` expired, so `tv-mode.sh` ran against a head that was not there yet. Raise it, or turn the TV on first. |
| Boot stops at a login screen | Autologin is off, and the controller cannot type a password. See the end of §6. |

---

## 9. Uninstall

```sh
rm ~/.local/bin/tv-mode.sh ~/.local/bin/apollo-display.sh
rm ~/.local/share/applications/tv-mode.desktop
sudo pacman -S plasma-bigscreen plasma-keyboard   # back to the stock packages
```

Run `tv-mode.sh off` first if you are currently in TV mode.
