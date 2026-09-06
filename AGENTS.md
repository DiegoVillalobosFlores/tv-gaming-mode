# Notes for coding agents

Read this before changing anything here. Instructions for humans are in
[`README.md`](README.md) and [`SETUP.md`](SETUP.md); this file covers what is
easy to get wrong and what is unsafe to run.

## What this repo is

Three things that ship together because they are used together:

1. **`bin/tv-mode.sh`** — switches the machine into a 10-foot console (TV as the
   only head, HDMI audio, Plasma Bigscreen shell) and back. `bin/apollo-display.sh`
   is a related Apollo/Sunshine prep-cmd.
2. **`plasma-bigscreen/`** — a patch against upstream Plasma Bigscreen `v6.7.4` that
   lists running apps inline in the home overlay sidebar, plus a PKGBUILD.
3. **`plasma-keyboard/`** — a patch against upstream `plasma-keyboard` `v6.7.4` that
   lets a game controller drive the on-screen keyboard, plus a PKGBUILD.

There is no build system, no test suite and no CI. The scripts are POSIX `sh`
(`#!/bin/sh`, not bash — keep it that way). The Bigscreen patch is plain QML; the
keyboard patch is C++ and QML and does have to compile (`makepkg -Cf`).

## This repo edits the live session

`tv-mode.sh` reconfigures displays, audio routing and the running shell **of the
machine it is executed on**. There is no dry-run and no sandbox. On a headless or
CI machine `kscreen-doctor` fails and the script exits; on the user's desktop it
will blank monitors and restart their shell.

**Do not run `tv-mode.sh on`, `off` or `toggle` to "check that it works" unless the
user has asked you to.** `tv-mode.sh status` is free — it only tests for a state file.

## Things that look like bugs and are not

Each of these is load-bearing. Read the comment above it before touching it.

- **One `kscreen-doctor` call.** `displays_to_tv` enables the TV and disables the
  other heads in a single invocation. Splitting it into two "clearer" calls breaks
  the TV: each call is its own atomic commit, every commit re-runs HDMI link
  training + HDCP, and at 4K120 HDR the panel cannot hold a signal through two in a
  row.
- **The TV-presence pre-flight.** It exits rather than proceeding when the head is
  absent. That is the only guard against blanking the remaining head into a
  headless session. Do not "make it more robust" by continuing anyway.
- **Matching the sink by EDID description, not name.** The sink name flips between
  `hdmi-surround71` and `hdmi-stereo-extra1` depending on whether the TV was awake
  at login. The name match is the *fallback*, deliberately second.
- **`plasma-bigscreen-swap-session`, not `plasmashell -p org.kde.plasma.bigscreen`.**
  The bare form leaves the TV remote dead: `plasma-bigscreen-inputhandler` exits
  immediately unless `PLASMA_PLATFORM=mediacenter`, which swap-session sets by
  sourcing `plasma-bigscreen-common-env`.
- **Modes addressed by name, never by id.** kscreen renumbers mode ids between runs,
  so a saved id restores the wrong mode.
- **`exec 2>>"$XDG_RUNTIME_DIR/tv-mode.log"`.** Errors are not on your terminal.
  Read that file when debugging; do not conclude "no output means it worked".
- **State in `$XDG_RUNTIME_DIR`.** Deliberate: a reboot always lands back on the
  desktop. Do not move it somewhere persistent.

## Working on the Bigscreen patch

The homescreen QML is **compiled into `org.kde.bigscreen.homescreen.so`** as a Qt
resource. Editing QML under `/usr/lib/qt6/qml/` or in a Plasma package directory has
no effect — the shell loads the baked-in copy. Every change means a rebuild.

```sh
git clone --depth 1 -b v6.7.4 https://invent.kde.org/plasma/plasma-bigscreen.git
# edit under containments/homescreen/package/contents/ui/homeoverlay/
git diff > plasma-bigscreen/0001-homescreen-list-running-apps-in-home-overlay.patch
# update the patch's sha256 in the PKGBUILD, then:
cd plasma-bigscreen && makepkg -si
```

The patch touches three files:

- `TasksView.qml` — exposes its existing `TaskManager.TasksModel` as
  `taskManagerModel`, adds `activateTask(index)`. **Do not instantiate a second
  `TasksModel`** for the sidebar; one model, shared.
- `MainColumn.qml` — a `ListView` renders each running app as a `ButtonDelegate`.
  Icons come from `model.decoration` through the delegate's `leading` slot, *not*
  `icon.name`: `ButtonDelegate` binds `source: root.icon.name`, a string, so a
  `QIcon` from the model silently renders nothing there.
- `HomeOverlayWindow.qml` — wiring only.

The app list is a `ListView`, not a `Repeater`, and the reasons are load-bearing:

- **It has to scroll.** With enough windows open a `Repeater` in the `ColumnLayout`
  grows without limit and pushes Controller / Keyboard / Settings off the bottom of
  the sidebar. The sizing that bounds it is a set: `Layout.fillHeight` claims slack,
  `Layout.maximumHeight: contentHeight` stops it growing past its own content so the
  spacer keeps the toggles at the bottom, and `Layout.minimumHeight` keeps a few rows
  visible when space runs out. Removing any one of the three breaks a different case.
- **`AbstractDelegate` is built for it.** It walks up the parent chain for a
  `Flickable` and derives `isCurrent` from `listView.currentIndex && activeFocus`, so
  delegates highlight correctly inside a view and `ListView` scrolls the selection
  into sight on its own.
- **Do not navigate by grabbing sibling items.** `itemAtIndex()` returns null for
  rows the view has not realised, so walking to `index ± 1` breaks the moment the
  list is long enough to scroll — which is exactly when it matters. Internal movement
  belongs to `keyNavigationEnabled`; only the two ends are ours, intercepted by
  `Keys.onUpPressed` / `onDownPressed` on the view (attached `Keys` run before the
  view's own handler, so setting `event.accepted = false` hands movement back to it).

`onVisibleChanged` resets `currentIndex` to 0 and calls `positionViewAtBeginning()`
before focusing Home, so the overlay always opens at the top of the list instead of
wherever it was left.

After a rebuild, verification is:

```sh
pacman -Qi plasma-bigscreen | grep -E '^(Version|Description)'   # 6.7.4-1.9, "(patched: ...)"
plasmashell --replace > /tmp/shell.log 2>&1 &                    # from the Bigscreen session
grep -iE 'MainColumn|TasksView|HomeOverlayWindow|\.qml:[0-9]+' /tmp/shell.log
qdbus6 | grep -i biglauncher                                     # Bigscreen shell is up
```

A clean build proves nothing about runtime — QML errors only appear when the
containment loads. Check the log.

## Working on the keyboard patch

Upstream already had keyboard navigation of the on-screen keys, driven only by a
physical keyboard's arrow keys through `InputListenerItem` into
`InputContext.priv.navigationKeyPressed`. The patch feeds a controller into **that
same path** rather than building a parallel one. Keep it that way.

```sh
git clone -b v6.7.4 https://invent.kde.org/plasma/plasma-keyboard.git
# edit, then:
git diff v6.7.4 -- . ':(exclude)build' > .../plasma-keyboard/0001-....patch
# update the patch sha256 in the PKGBUILD, then:
cd plasma-keyboard && makepkg -Cf && sudo pacman -U plasma-keyboard-*.pkg.tar.zst
pkill -x plasma-keyboard     # KWin respawns it on demand
```

**`makepkg -Cf`, not `makepkg -f`.** Without `-C` the previously patched `src/` is
reused and `patch` reports "1 out of 1 hunk ignored" — it is detecting its own work,
not a broken patch.

### Load-bearing details

- **The grab excludes `BTN_MODE`.** `EVIOCGRAB` is all-or-nothing, so while the panel
  is up it would swallow the controller's Home button — the one
  `plasma-remotecontrollers` turns into the Bigscreen home-overlay key. The grab is
  released for as long as Home is held. Remove that and Home dies while typing.
- **`m_userDismissed`.** Upstream re-shows the panel on *any* `surroundingTextChanged`
  while it is hidden, and KWin emits one immediately after a hide — so closing the
  keyboard bounced it straight back open. The flag suppresses that one re-show and is
  cleared on a new input context, on deactivate, and on an explicit summon. It is not
  redundant.
- **Trigger axes are detected via `ABS_RX`.** Pads with a real right stick report it
  there, leaving `ABS_Z`/`ABS_RZ` free to be the analog triggers; pads without it use
  `ABS_Z`/`ABS_RZ` *for* the right stick. Inverting this check makes L2/R2 dead on
  every Xbox-style pad.
- **X summons only when `activeClientSupportsTextInput` is true.** X is a face button
  games use. Without the check, `forceActivate()` pops the keyboard mid-game.
- **Shift is re-asserted from QML.** Qt VirtualKeyboard clears `shiftActive` after
  every character, so hold-to-shift needs the `onShiftActiveChanged` handler in
  `main.qml` putting it back. Deleting it makes only the first letter capitalise.
- **Devices are matched by capability, not by name** — `BTN_SOUTH` plus a stick or a
  hat. Do not add a vendor/product allowlist.

### Verifying

A clean build proves nothing. Check the running process actually opened the pad:

```sh
sudo ls -l /proc/$(pgrep -x plasma-keyboard)/fd | grep input/event
```

Then focus a text field and drive it. Reading `/dev/input` needs the `input` group.

## Inspecting a running Bigscreen shell

Useful and safe:

```sh
qdbus6 org.kde.biglauncher /BigLauncher                          # list methods
qdbus6 org.kde.biglauncher /BigLauncher org.kde.biglauncher.displayHomeScreenShortcut
qdbus6 org.kde.kglobalaccel /component/plasmashell \
  org.kde.kglobalaccel.Component.invokeShortcut "Toggle Bigscreen Home Screen"
spectacle -b -n -f -o /tmp/shot.png                              # screenshot to verify visually
```

**Do not call these** — they take over the user's session with no programmatic way
back:

- `org.kde.KWin.showDebugConsole` — opens a window on the user's screen.
- `org.kde.KWin.queryWindowInfo` — puts KWin into interactive window-pick mode,
  waiting for a click. Killing your caller does not cancel it.

`invokeShortcut` on a toggle leaves the overlay **open on the user's TV**. Call it a
second time to close it, and confirm with a screenshot.

## Conventions

- POSIX `sh`, `set -e`, no bashisms.
- Comments explain *why*, especially where the obvious simplification is wrong. The
  existing density is the target — match it rather than stripping or padding.
- The `.desktop` file intentionally carries an absolute `Exec=`; `install.sh`
  rewrites it to `$HOME`. Do not "fix" it to a bare command.
- Hardware constants (`HEAD`, `SINK_MATCH`, `SINK_DESC`, PCI addresses) are specific
  to one machine. Keep them in the header block, not scattered inline.

## Gotcha that outlives this repo

Both patched packages install a **byte-identical file list** to stock
`plasma-bigscreen` / `plasma-keyboard`. Any `pacman -Syu` that updates either reverts
the patch with no warning and nothing looks broken. The only tell is `pacman -Qi`:
pkgrel `1.9` and a `(patched: ...)` description. If a user reports the shortcuts "just
disappeared" or the controller "stopped typing", check that first.
