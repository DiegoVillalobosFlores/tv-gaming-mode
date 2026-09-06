# Notes for coding agents

Read this before changing anything here. Instructions for humans are in
[`README.md`](README.md) and [`SETUP.md`](SETUP.md); this file covers what is
easy to get wrong and what is unsafe to run.

## What this repo is

Two things that ship together because they are used together:

1. **`bin/tv-mode.sh`** — switches the machine into a 10-foot console (TV as the
   only head, HDMI audio, Plasma Bigscreen shell) and back. `bin/apollo-display.sh`
   is a related Apollo/Sunshine prep-cmd.
2. **`plasma-bigscreen/`** — a patch against upstream Plasma Bigscreen `v6.7.4` that
   lists running apps inline in the home overlay sidebar, plus a PKGBUILD.

There is no build system, no test suite and no CI. The scripts are POSIX `sh`
(`#!/bin/sh`, not bash — keep it that way). The patch is plain QML.

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
- `MainColumn.qml` — a `Repeater` renders each running app as a `ButtonDelegate`.
  Icons come from `model.decoration` through the delegate's `leading` slot, *not*
  `icon.name`: `ButtonDelegate` binds `source: root.icon.name`, a string, so a
  `QIcon` from the model silently renders nothing there.
- `HomeOverlayWindow.qml` — wiring only.

D-pad navigation between the shortcuts is done with explicit `Keys.onUpPressed` /
`Keys.onDownPressed` handlers calling `tasksRepeater.itemAt(...)`, deliberately not
`KeyNavigation` bindings: `itemAt()` is not a bindable property, so a binding
evaluates to a stale or null item when apps open and close. Keep navigation
evaluated at keypress time.

After a rebuild, verification is:

```sh
pacman -Qi plasma-bigscreen | grep -E '^(Version|Description)'   # 6.7.4-1.9, "(patched: ...)"
plasmashell --replace > /tmp/shell.log 2>&1 &                    # from the Bigscreen session
grep -iE 'MainColumn|TasksView|HomeOverlayWindow|\.qml:[0-9]+' /tmp/shell.log
qdbus6 | grep -i biglauncher                                     # Bigscreen shell is up
```

A clean build proves nothing about runtime — QML errors only appear when the
containment loads. Check the log.

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

The patched package installs a **byte-identical file list** to stock
`plasma-bigscreen`. Any `pacman -Syu` that updates it reverts the patch with no
warning and nothing looks broken. The only tell is `pacman -Qi`: pkgrel `1.9` and a
`(patched: ...)` description. If a user reports the shortcuts "just disappeared",
check that first.
