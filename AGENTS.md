# Notes for coding agents

Read this before changing anything here. Instructions for humans are in
[`README.md`](README.md) and [`SETUP.md`](SETUP.md); this file covers what is
easy to get wrong and what is unsafe to run.

## What this repo is

Three things that ship together because they are used together:

1. **`bin/tv-mode.sh`** — switches the machine into a 10-foot console (TV as the
   only head, HDMI audio, Plasma Bigscreen shell) and back. `bin/apollo-display.sh`
   is a related Apollo/Sunshine prep-cmd; `bin/tv-mode-watch.sh` triggers the
   switch from the TV remote and `bin/tv-mode-boot.sh` from the game controller
   after a boot, and `bin/tv-mode-zoom.sh` puts KWin's magnifier on the
   controller's bumpers while TV mode is on — all three over the shared
   `bin/tv-mode-input.sh` and each with a user unit under `systemd/`.
   `udev/93-wolverine-wake.rules` arms the controller's receiver as a wake source.
2. **`plasma-bigscreen/`** — two patches against upstream Plasma Bigscreen `v6.7.4`:
   one lists running apps inline in the home overlay sidebar, one restyles the
   launcher's app tiles as smoked glass. Plus a PKGBUILD that applies both.
3. **`plasma-keyboard/`** — a patch against upstream `plasma-keyboard` `v6.7.4` that
   lets a game controller drive the on-screen keyboard, plus a PKGBUILD.

There is no build system, no test suite and no CI. The scripts are POSIX `sh`
(`#!/bin/sh`, not bash — keep it that way). The Bigscreen patches are plain QML; the
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
- **`DISABLE_MANGOHUD=1`, not MangoHud's `no_display`.** `no_display=1` only hides
  the overlay; the Vulkan layer is still loaded into every game. The env var is
  the layer's own `disable_environment`, so the layer never loads. It is pushed
  through `dbus-update-activation-environment --systemd` because that is what
  Bigscreen's app launches inherit. Games already running keep their HUD.
- **`keyboard_restart` on both switches.** The head swap passes through a moment
  with no outputs, and `plasma-keyboard` answers that by creating a placeholder
  screen it never gives back — every later paint fails with `eglSwapBuffers
  failed with 0x300d` and the on-screen keyboard silently never appears again.
  The process stays alive and keeps reading the pad, so it is still summoned and
  still grabs: the visible symptom is *both* a missing keyboard and a controller
  that dies in whichever app has a text field focused. Killing it is the whole
  fix and costs nothing — KWin owns it as the session's input method and
  relaunches it on demand. Do not "optimise" the restart away, and do not move it
  before the `kscreen-doctor` commit: it has to run once the output set is final.
- **Modes addressed by name, never by id.** kscreen renumbers mode ids between runs,
  so a saved id restores the wrong mode.
- **`exec 2>>"$XDG_RUNTIME_DIR/tv-mode.log"`.** Errors are not on your terminal.
  Read that file when debugging; do not conclude "no output means it worked".
- **State in `$XDG_RUNTIME_DIR`.** Deliberate: a reboot always lands back on the
  desktop. Do not move it somewhere persistent.
- **`zoom_reset` on both switches, and `ZOOM_STEPS` duplicated.** KWin's magnifier
  is session-wide state, so a zoom left on the TV is still there on the desktop —
  where `tv-mode-zoom.sh` is gated off and no controller can walk it back. There
  is no reset action in KWin, only repeated `view_zoom_out`, which is why this is
  a loop; KWin clamps at 1.0 so the surplus calls are free. `ZOOM_STEPS` has to
  stay equal to `MAX_STEPS` in `tv-mode-zoom.sh` — that is the ceiling the bumpers
  can reach, so it is the number of steps that is guaranteed to undo it.

## Working on the three watchers

`tv-mode-watch.sh` waits for `BTN_LEFT` on the TV remote's mouse node.
`tv-mode-boot.sh` waits for any button on the game controller, once, for two
minutes after login. Both end in `tv-mode.sh on`. `tv-mode-zoom.sh` is the odd
one out: it never switches modes, it maps the pad's bumpers onto KWin's zoom for
as long as TV mode is on. All three get their `evtest` handling from
`tv-mode-input.sh`, which is **sourced, never executed** — it defines
`wait_for_event`, `stream_events` and `require_input_group` and does nothing on
its own. `install.sh` installs it mode 644 for that reason.

### `wait_for_event`

Three of its choices look like detours:

- **The read loop is fed by a FIFO, not by a pipe from `evtest`.** A pipeline is
  not finished until *every* member has exited, and `evtest` only notices a
  closed pipe when it next writes — which is whenever the device is next moved.
  Rewriting this as `evtest ... | while read` reintroduces exactly the lag the
  feature exists to remove: the press is seen instantly, then the switch waits.
  The FIFO lets the loop run in the calling shell so `evtest` can be killed
  explicitly. `stdbuf -oL` execs `evtest` in place, so the recorded pid is
  `evtest` itself and the kill lands on it rather than on a wrapper.
- **`stdbuf -oL`.** `evtest` block-buffers as soon as stdout is not a terminal,
  so without it the press sits in a 4K buffer instead of arriving.
- **The timeout kills the writer instead of using `read -t`.** `read -t` is a
  bashism and these are `#!/bin/sh`. Closing the FIFO's only writer is what ends
  the loop, so a `sleep`-and-`kill` subshell is the whole mechanism.

Two smaller ones that are easy to undo by tidying:

- **The cleanup is an `if`, not `[ -n "$_timer" ] && …`.** With no timeout there
  is no timer, and a trailing AND-list whose test fails returns 1 — which `set -e`
  in the caller reads as `wait_for_event` having failed. `tv-mode-watch.sh` is
  the caller that passes no timeout, so this breaks the *working* script, not the
  new one.
- **The pattern is matched via an unquoted `$_pat` in a `case`.** It expands
  after the `case` is parsed, so the parentheses in `type 1 (EV_KEY)` are literal
  rather than closing the branch. Inlining the pattern as a literal will not
  compile. Keep patterns from starting with `*(`, which some shells read as an
  extglob.

### `stream_events`

The second function, and the one `tv-mode-zoom.sh` uses. It differs from
`wait_for_event` in that it never returns on a match — it calls a handler
function for every line until `evtest` exits.

- **It uses a FIFO for a *different* reason.** Not latency this time: the loop
  has to run in the calling shell so the handler can keep state across presses
  (`steps` in `tv-mode-zoom.sh`). The obvious `evtest | while read` puts the loop
  in a subshell and silently discards every variable it sets. `stdbuf` is still
  there for the original reason.
- **The handler must return 0.** It runs in the calling shell, so a non-zero
  return trips the caller's `set -e` and takes the watcher down. Every branch of
  `on_event` ends in an explicit `return 0`; do not "simplify" the trailing one
  away, and note that a bare `case` whose last-evaluated command fails is enough
  to do it.

The node is read, never grabbed — no `EVIOCGRAB` — so the press still reaches
the session. Reading `/dev/input` needs the `input` group; all three scripts
check for it at startup rather than looping on an unreadable device.

### `tv-mode-boot.sh` specifically

- **It matches `EV_KEY` only, never `EV_ABS`.** Sticks drift. A pad face-down in
  the sofa reports axis movement all night, and an `EV_ABS` match would put the
  machine on the TV every single boot.
- **Any button, not Home.** Home is already claimed by
  `plasma-remotecontrollers`. Nothing here can see which button caused the
  power-on anyway — see below.
- **There is no wake-source detection, and there cannot be.** This is a cold boot
  out of S5, not a resume: no `/sys/…/power/wakeup_count` survives the power
  cycle and no resume hook runs, because nothing resumed. The 120s window is the
  substitute, and "no press" is a legitimate answer (started at the desk), not a
  failure — hence `Type=oneshot` and no `Restart=`.
- **`HEAD_WAIT` duplicates `tv-mode.sh`'s head check on purpose.** `tv-mode.sh`
  refuses outright when the TV is absent, which is correct for a deliberate
  switch and wrong for a TV that was switched on at the same moment as the PC and
  is still negotiating HDMI. The script waits, then lets `tv-mode.sh` make the
  real check. `HEAD` is duplicated at the top for the same reason
  `apollo-display.sh` duplicates it.

### `tv-mode-zoom.sh` specifically

- **KWin's magnifier, not a display rescale.** The tempting implementation is
  `kscreen-doctor output.HDMI-A-1.scale.N`. It is wrong for the same reason
  `displays_to_tv` is one single call: every scale change is its own atomic
  kscreen commit that re-runs HDMI link training + HDCP, and the TV cannot hold a
  4K120 HDR link through a stream of them — which is exactly what a bumper held
  down produces. The magnifier is a compositor-side transform and touches no
  output.
- **`invokeShortcut` on the `kwin` component, not a synthetic `Meta+-`.** The key
  binding is the user's to rebind and a synthetic keystroke would land in
  whatever has focus; `view_zoom_in` / `view_zoom_out` are the action names and
  they are stable. The effect has to be loaded — `isEffectLoaded zoom`.
- **Two gates, both needed.** The TV-mode check keeps the desk sane: L1 and R1 are
  two of the pad's most-used buttons, and a desktop that zooms when you play is
  worse than no feature. The `pad_claimed` check keeps games sane. Removing
  either makes the bumpers unusable somewhere.
- **`pad_claimed` mirrors the keyboard patch's `scanForOtherReaders()`**, in
  shell, over `fuser` — including checking the `jsN` sibling from sysfs, because
  plenty of software opens that node instead. Both halves are load-bearing here
  too: without the ignore list the scan always matches, since
  `plasma-remotecontrollers`, Bigscreen's inputhandler, Steam and
  `plasma-keyboard` hold every pad open all session. The two lists have to stay in step, and
  **`evtest` is on both** — our own reader is an `evtest`, and so is
  `tv-mode-boot.sh`'s. Leaving it out here makes the script stand down against
  itself; leaving it out of the patch's makes the *keyboard* stand down for as
  long as this watcher runs, which is the whole session. `comm` is truncated to 15 characters by the kernel, which is
  why the names are the odd-looking `plasma-remoteco` / `plasma-bigscree`.
- **Zoom-in is clamped, zoom-out only floored.** `steps` counts our own presses,
  so a `Meta++` from a keyboard desyncs it. Clamping the *out* direction on a
  desynced counter would leave a visibly zoomed screen the couch cannot undo, so
  L1 always fires and KWin's own clamp at 1.0 is the real floor. The in-direction
  clamp is what stops a lean on the bumper stranding the session.
- **No hold-to-repeat.** It was considered and rejected: the release event is one
  packet over a 2.4GHz link, and a lost release would leave a repeater zooming to
  the ceiling with the UI already too magnified to fix it. One step per press has
  no state that can get stuck.

### The S5 wake itself

**Settled by direct test: the board will not wake from this receiver in S5.**
Full shutdown, receiver in the armed port `USB32_8`, press Home — nothing. Do not
reopen it, and in particular do not propose BIOS changes: every relevant setting
was already correct at the time of the test (`Deep Sleep` Disabled,
`USB Device Power on (USB32_8)` Enabled, S5 power delivery Enabled), as was the
Linux side (`power/wakeup=enabled`, `bmAttributes=a0`, controller's ACPI wake
node enabled).

Four hypotheses were tested and are all dead ends — do not re-run them:

- *"The receiver must be on a CPU-attached port."* False. Every USB controller
  has an enabled ACPI wake node, chipset included (`grep XH /proc/acpi/wakeup`).
  The CPU's USB 2.0 controller `XHC2` (`0000:79:00.0`) has one port, wired to the
  internal LED header — it reaches no rear socket at all.
- *"The udev rule is not applying."* It applies.
- *"The BIOS is misconfigured."* It is not.
- *"Test it with a real keyboard."* Void by construction. `USB Device Power on
  (USB32_8)` is scoped to **one named port**; a keyboard in any other socket is
  not armed, so its failure to wake the machine carries no information. Both
  keyboards on this machine (`10-5`, `8-2`) are outside that port.

The receiver's keyboard interface is enumerated but permanently silent (196
joystick events, 0 keyboard events over a 90s capture; Home is `BTN_MODE` on the
joystick node). That was suggestive but never sufficient — the setting says
`Device`, not `Keyboard`. The direct test is what settled it.

Note `Suspend to RAM` is **Disabled**, so `/sys/power/mem_sleep` offers only
`s2idle`; S3 needs that BIOS toggle before it is an option.

`udev/93-wolverine-wake.rules` is kept because it is correct and costs nothing,
and because it is what makes **suspend (S3)** work — there a kernel is running,
so ordinary USB remote wakeup resumes on any button and no keyboard interface is
needed. Two things about the rule are non-obvious: the kernel leaves USB remote
wakeup off for everything but the boot keyboard, and Linux arms the ACPI wake
bits *on the way down*, so the attribute has to already be set at shutdown.
Setting it from a login script would be too late.

If a machine is not waking, the answer is S3 or Wake-on-LAN, not more Linux
configuration.

### Never `pkill -x evtest`

`tv-mode-watch.service` runs an `evtest` child of its own on the TV remote's
mouse node for the whole session (`tv-mode-watch.sh` -> `evtest
.../usb-123_COM_Smart_Control-if03-event-mouse`), and `tv-mode-zoom.service` runs
one on the pad's `-event-joystick` node — the very device you are most likely to
be capturing. A blanket `pkill -x evtest` kills both. Each watcher's loop
re-spawns it, so `NRestarts` stays 0 and nothing looks wrong — you just silently
lose the remote, or the bumper zoom, until the next iteration. Kill capture jobs
by job spec or pid instead.

### Enabling

The units are installed by `install.sh` but **not enabled**. Do not enable any of
them, or start a watcher, unless the user asks. Two of them arm a remote or a
controller to blank the user's monitors and invoke `tv-mode.sh on`, which the
rest of this file explains you should not run uninvited; `tv-mode-zoom.service`
is milder but still reaches into the running session's compositor.

## Working on the Bigscreen patches

The homescreen QML is **compiled into `org.kde.bigscreen.homescreen.so`** as a Qt
resource, and the shared delegates into the `org.kde.bigscreen` QML module. Editing
QML under `/usr/lib/qt6/qml/` or in a Plasma package directory has no effect — the
shell loads the baked-in copy. Every change means a rebuild.

The two patches are disjoint — `0001` is the home overlay, `0002` is the launcher —
so regenerate them one at a time from a clean checkout rather than diffing a tree
that has both applied:

```sh
git clone --depth 1 -b v6.7.4 https://invent.kde.org/plasma/plasma-bigscreen.git
# edit under containments/homescreen/package/contents/ui/homeoverlay/
git diff > plasma-bigscreen/0001-homescreen-list-running-apps-in-home-overlay.patch
git checkout -- .
# edit AbstractDelegate.qml / launcher/delegates/IconDelegate.qml
git diff > plasma-bigscreen/0002-homescreen-frost-the-launcher-app-tiles.patch
# update both sha256s in the PKGBUILD, then:
cd plasma-bigscreen && makepkg -si
```

`prepare()` applies them in order, so a patch added later must not touch a file an
earlier one already changed.

### `0001`, running apps in the home overlay

It touches three files:

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

### `0002`, frosted launcher tiles

It touches four files:

- `components/bigscreenplugin/qml/AbstractDelegate.qml` — the frost, drawn under
  the existing frame, which becomes translucent (`frostOpacity`).
- `launcher/delegates/IconDelegate.qml` — sets `frostSourceItem` to
  `Plasmoid.wallpaperGraphicsObject`, which is what turns the frost on for the
  Favorites / Recent / Applications / Games rows, and pins the tile to black,
  the selection border to `#e6e6e6` and the label to `#f5f5f5`.
- `launcher/delegates/AppDelegate.qml`, `FavDelegate.qml` — drop `useIconColors`.

Five things here are load-bearing:

- **The frost is opt-in, and must stay opt-in.** `AbstractDelegate` is shared with
  the home-overlay sidebar rows and the wallpaper picker, neither of which has a
  wallpaper of its own behind it — they sit on a layer-shell window over whatever
  is running. `frostSourceItem` defaults to null and `frosted` is derived from it,
  so those delegates keep the opaque frame. Do not hoist the frost into the base
  and gate it on a bool that defaults true.
- **Each tile samples its own slice, at an eighth size.** `sourceRect` maps the
  tile into wallpaper coordinates and `textureSize` downsamples; the downsample is
  most of the blur, and `FastBlur` only softens what is left. Blurring at full
  resolution per tile, or sharing one full-screen blur and masking it per tile, are
  both much more expensive. `FastBlur` rather than `MultiEffect` for the same
  reason `main.qml` gives for the wallpaper blur.
- **The bare `delegate.x; delegate.y; …` reads in `sourceRect` are the binding.**
  `mapToItem()` is a function call, not a property, so it registers no dependency
  and the mapping would never re-run — the frost would stay pinned to wherever the
  tile first appeared. Those statements look dead and are not. The `listView`
  reads are what track scrolling, since a `ListView` moves its content item rather
  than its delegates.
- **`frostMask` follows `frame.radius`, not `baseRadius`.** The radius is animated
  by the delegate's own `states` as the selection grows into its inset, so a mask
  pinned to `baseRadius` desyncs from the frame for the length of every transition.
- **The three tile colours are hardcoded on purpose, and the icon-colour
  machinery is gone with them.** Upstream drove the tile, the label *and* the
  selection border off `Kirigami.ImageColors` sampled from the app's own icon, so
  the border came out in the same family as the tile behind it — that is the
  original complaint, and re-deriving any of the three from the icon brings it
  back. `IconDelegate` sets `Kirigami.Theme.inherit: false` so the assignments
  actually stick. Removing `ImageColors` also removed the only reader of
  `useIconColors`, and with it the only reader of the `coloredTiles` config key:
  **the Coloured tiles switch in Bigscreen Settings is now inert.** Its KCM and
  D-Bus plumbing are deliberately left alone — flipping it writes the key and
  nothing looks at it. Do not "fix" the switch by wiring the icon palette back
  in.

The blurred wallpaper is sampled *before* the homescreen's black scrim, so a tile
is brighter than the darkened background around it. That is what makes it read as
glass. `frostOpacity` (0.6) is the frame's alpha over it — raise it for more colour
and more contrast for the label, lower it for more wallpaper.

After a rebuild, verification is:

```sh
pacman -Qi plasma-bigscreen | grep -E '^(Version|Description)'   # 6.7.4-1.11, "(patched: ...)"
plasmashell --replace > /tmp/shell.log 2>&1 &                    # from the Bigscreen session
grep -iE 'MainColumn|TasksView|HomeOverlayWindow|AbstractDelegate|IconDelegate|\.qml:[0-9]+' /tmp/shell.log
qdbus6 | grep -i biglauncher                                     # Bigscreen shell is up
```

A clean build proves nothing about runtime — QML errors only appear when the
containment loads. Check the log. The frost in particular fails *silently*: a bad
`sourceItem` or mask gives an empty or an unclipped tile, not a warning, so look at
the screen as well as the log.

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

- **The standdown while a game holds the pad.** `scanForOtherReaders()` walks
  `/proc/*/fd` for another process holding our controller's `event*`/`js*` nodes;
  while one does, the keyboard neither summons nor grabs. Two halves are both
  load-bearing: without the scan, X pops the keyboard over a game *and* the grab
  steals the pad from it; without the `inputInfrastructure()` ignore list the scan
  always matches, because `plasma-remotecontrollers`, Bigscreen's inputhandler and
  the Steam client each hold every pad open for the whole session. Verified on this
  machine: with Monster Hunter Wilds running, `winedevice.exe` is the only
  non-infrastructure holder. Do not add `gamescope` or a game launcher to the list.
  **`evtest` is on the list too, and was added late.** `tv-mode-zoom.sh` reads the
  pad through one for as long as TV mode is on, so without it the keyboard counts
  our own watcher as a game and stands down for the entire session — it never
  summons and never grabs, and the symptom is a controller that has just stopped
  typing with nothing else visibly wrong. Both watchers only read the node;
  neither grabs it, so a pad they hold is still free.
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
pkgrel `1.11` (Bigscreen) / `1.10` (keyboard) and a `(patched: ...)` description. If a
user reports the shortcuts "just disappeared", the tiles "went solid again" or the
controller "stopped typing", check that first.
