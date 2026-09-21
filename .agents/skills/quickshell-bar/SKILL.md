---
name: quickshell-bar
description: Use when changing the quickshell bar or one of its dropdowns in modules/home/wayland/quickshell — type-checking the QML, picking icon glyphs that actually exist in the font, or seeing a bar module render before switching. Covers the traps that cost time; the QML itself is readable on its own.
---

# quickshell bar

The bar lives in `modules/home/wayland/quickshell`: `qml/` holds the components,
and `default.nix` generates `Config.qml` (theme, sizes, icon ramps, shared
helpers) into the same directory at build time. Only the notes below are
non-obvious; everything else follows the existing components.

## Subscribe, do not poll

The bar runs for weeks at a time, so a module that asks "has it changed yet?"
on a timer pays that cost forever and still shows a stale value in between.
Every module here is driven by something that announces the change instead, and
there is no polling timer left in the tree — the one repeating `Timer` is an
animation, gated on being on screen.

Find the announcement before reaching for an interval. Most of it is already
done for you: `UPower`, `Pipewire`, `Networking`, `Bluetooth` and `I3` are
quickshell services that push. Below those, a helper that follows is a
`Process` whose stdout is a `SplitParser` — `Voxtype` runs `voxtype status
--follow`, `IdleInhibit` subscribes to logind over `gdbus monitor` — and a
`Process` with `StdioCollector` re-run on each of those lines is how a follower
that only signals *that* something changed gets turned into the answer.

Two things that come with a subscription and not with a poll:

- **It can die, and then the module latches silently.** Give every follower
  `onExited: <timer>.restart()` and a `Timer` that sets `running` back to true,
  as `Voxtype` and `IdleInhibit` both do. A restart re-reads on its own if the
  tool greets a fresh subscription with a line, which is what makes dropping
  the backstop poll safe.
- **Check what the signal actually covers before trusting it.** logind looked
  like it could only announce the *union* of inhibited operations, missing a
  second app inhibiting idle; it turns out to send a count in the same message,
  so the poll could go entirely. Five minutes in the VM changed the design.

## Prior art

When a surface here needs a mechanism it does not have yet, grep a large
quickshell config before inventing one. Their module formats are not
importable — read them for idioms, not to vendor code (both MIT; attribute
anything lifted):

- [DankMaterialShell](https://github.com/AvengeMedia/DankMaterialShell) — ~900
  QML files, the biggest one going. `quickshell/Services/` is a singleton per
  system service, `quickshell/Modules/` a directory per surface, so "how does
  anyone do X in quickshell" usually has an answer there. Its `AGENTS.md` is a
  short read.
- [Omarchy Quattro](https://github.com/omacom/omarchy/tree/quattro/shell) —
  ~120 QML files, much closer to this bar's scale. `shell/plugins/osd` and
  `shell/plugins/notifications` are direct analogues of `Osd.qml` and
  `NotificationPopups.qml`.
- [Noctalia v4.7.7](https://github.com/noctalia-dev/noctalia/tree/v4.7.7) —
  ~420 QML files. **Only at this tag**: v5 rewrote it native without Qt, so
  `main` has no QML at all. `Services/` is a singleton per service,
  `Modules/Bar/Widgets/` a file per bar item, and `Modules/OSD`,
  `Modules/Notification` and `Modules/Panels/*` the analogues of the surfaces
  here. Frozen at May 2026, so check its APIs against the other two.

## Type-check with lint.sh

Run [lint.sh](lint.sh) after editing any `.qml`, with no arguments for the whole
bar or with filenames for just those:

```bash
.claude/skills/quickshell-bar/lint.sh Battery.qml BatteryMenu.qml
```

Do not point `qmllint` at `qml/` directly. `Config.qml` is not there — it is
generated — and the singleton needs a `qmldir` that the runtime never requires,
so a naive run reports nothing but unresolved types. The script builds the
config, lints the built copy, and takes `qmllint`, Qt's QML modules and
quickshell's own from the same nixpkgs the bar runs against.

**A file with a `dropdown:` component or a `Repeater` delegate needs `pragma
ComponentBehavior: Bound` as its first line.** Both reach their parent through
`root`, and until the pragma binds the component's context qmllint cannot
resolve that and reports every such access as `[unqualified]` — 34 of them
across this bar before the pragma went in, against 1 after (a `margins`
grouped-property quirk in `NotificationPopups` that is qmllint's, not ours).
The pragma also makes `required property var modelData` mandatory in delegates,
which every delegate here already declared. Whatever survives now is worth
reading; this counts what is left:

```bash
.claude/skills/quickshell-bar/lint.sh 2>&1 | grep -E '^(Warning|Error)' \
  | sed 's/:[0-9]*:[0-9]*:.*\[/ [/' | sort | uniq -c | sort -rn
```

The rest of the baseline is qmllint failing to see through quickshell's C++
types — `uncreatable-type` on every `PanelWindow`, `Qt.formatDateTime`,
duck-typed `owner.dropdown`, `QProcess::ExitStatus` on an `onExited`. None of
those are fixable from the QML.

**`[property-override]` is always a real finding.** Every
component here roots in an `Item`, so a property named after one of its members
shadows it. `enabled` is the dangerous one — it switches input off for the whole
subtree, so a menu that names its own `enabled` after the adapter or device it
watches goes deaf to clicks exactly when that thing is off, including on the row
that would turn it back on. `state`, `visible`, `focus` and `opacity` are the
same trap. Rename to the domain word (`powered`, `present`) rather than reaching
for `final`.

## A new .qml file has to be snapshotted before it exists

`nix build` reads the flake's git tree, which excludes untracked files. A newly
created component is therefore **absent from the built config** while every
edit to a tracked file is picked up, and the failure is confusing: the build
succeeds, and the bar fails at runtime with `<Name> was not found`. Run `jj st`
(see the [jujutsu](../jujutsu/SKILL.md) skill) to snapshot before building or
switching.

## Icon glyphs

`Config.fontFamily` is stylix's `"DejaVu Sans Mono"`, but the icons are Material
Design glyphs resolved by fontconfig fallback to `nerd-fonts.dejavu-sans-mono`
(`hosts/framework/home/default.nix`). That package's cmap is what decides
whether a codepoint draws or shows tofu, so check it there — and search it by
glyph name to find one in the first place:

```bash
font=$(nix build --no-link --print-out-paths '.#nixosConfigurations.framework.pkgs.nerd-fonts.dejavu-sans-mono')
ttx=$(nix build --no-link --print-out-paths '.#nixosConfigurations.framework.pkgs.python3Packages.fonttools')/bin/ttx
"$ttx" -t cmap -o - "$font"/share/fonts/truetype/NerdFonts/DejaVuSansM/DejaVuSansMNerdFontMono-Regular.ttf \
  | grep -E 'name="md-(leaf|rocket_launch)"'
# <map code="0xf032a" name="md-leaf"/>
```

Distinct silhouettes beat one icon family: three speedometer positions for the
power profiles were indistinguishable at 14pt and had to become leaf / scale /
rocket.

## A positioner drops a zero-sized child out of the layout

`Row` and `Column` skip a child whose width **or height** is zero -- Qt treats
it as invisible rather than as an empty slot. A strip of level bars drawn as
`Rectangle { height: level * H }` therefore has no columns where the level is
zero, and the rest close up: the waveform grew from the left as it filled and
shrank from the right as it emptied, when both were meant to scroll. Wrap each
one in a fixed-size `Item` and let the bar inside it be zero high, as
`VoxtypeWave` does.

This is invisible in a screenshot of a steady state and obvious in a sequence:
dump a row of per-column values per frame (`magick <shot> -crop <box> -resize
Nx1! txt:-`) and compare consecutive frames at a few shifts. Content that
scrolls matches its neighbour at a shift of one column; content that is being
truncated matches at zero.

## Seeing a module render in the agent VM

Use the [nixos-agent-test-vm](../nixos-agent-test-vm/SKILL.md) skill, and
capture with `grim` into the driver's shared dir rather than
`machine.screenshot`, which returns a sheared and often stale frame:

```bash
runuser -u lbischof -- env XDG_RUNTIME_DIR=/run/user/1000 \
  WAYLAND_DISPLAY=wayland-1 grim /tmp/shared/shot.png
```

### One component on its own, next to the running bar

A dropdown or a row does not need the whole bar around it, and a second bar is
the thing most likely to make a screenshot lie (below). Copy the built config
out of the store, drop the file under test and a throwaway `shell.qml` into the
copy, and run that as its own quickshell -- the session's bar keeps running
untouched, and the window is an ordinary sway window the cursor can reach:

```bash
cp -rL /home/lbischof/.config/quickshell/bar /tmp/bartest   # Config.qml comes with it
chmod -R u+w /tmp/bartest && chown -R lbischof /tmp/bartest
# copy the edited .qml files from the repo over it, add a test shell, then
systemd-run --user --machine=lbischof@ --unit=bar-test --collect \
  --setenv=WAYLAND_DISPLAY=wayland-1 --setenv=XDG_RUNTIME_DIR=/run/user/1000 \
  <quickshell>/bin/quickshell -p /tmp/bartest/test.qml
```

`<quickshell>` is the store path out of `systemctl --user -M lbischof@ show -p
ExecStart quickshell.service`; the guest's login PATH has no `qs`. There is no
`python3` in the VM either — patch files with `sed`, or splice them with
`head`/`tail`.

The test shell is a `ShellRoot { FloatingWindow { … } }` holding the component,
with whatever it requires supplied by hand -- `WifiMenu { active: … }` drives
the real `Networking` singleton, while a row that takes an object (`WifiRow`'s
`network`) takes a `QtObject` stub: properties for what it reads, `signal`s for
every handler its `Connections` declares (a missing one is an error, not a
no-op), and functions that `console.log` what they were called with, which
`journalctl _SYSTEMD_USER_UNIT=<unit>.service` reads back as a transcript.
Driving it is `sway 'seat - cursor …'` plus `machine.send_chars`.

**Make sure the bar in the shot is yours.** `quickshell.service` comes back on
its own, a second bar is another layer surface at the same anchor, and which
one sway puts on top is not something to bet a result on -- two runs that
"proved" a module did not move were both pictures of the session's own bar.
Stop the service, kill any shell left from an earlier run (by `comm`, see the
VM skill), check `pgrep -c -x .quickshell-wra` is 1, and start yours last.

Restarting the shell to change what a stub reports reintroduces exactly that
ambiguity. Have the stub follow a file instead and write the state into it:

```sh
while :; do
  s=$(cat /tmp/bartest/state 2>/dev/null || echo idle)
  [ "$s" = "$last" ] || { printf '{"class":"%s",...}\n' "$s"; last=$s; }
  sleep 0.2
done
```

Dropdowns open normally in the VM, but nothing in the test driver moves the
pointer. Click through sway instead:

```bash
sway() { runuser -u lbischof -- env SWAYSOCK="$(ls /run/user/1000/sway-ipc.*)" swaymsg "$@"; }
sway 'seat - cursor set 637 14'      # the module in the bar
sway 'seat - cursor press button1'
sway 'seat - cursor release button1'
```

### Scrolling needs a device, not a sway command

`cursor press button4` reports success and delivers nothing: sway's scroll
pseudo-buttons only ever drive its own bindings, never the surface under the
pointer. Scroll events have to come from a real input device, and the two
sources behave differently in a way that matters for anything counting them:

- **Fine-grained (what a touchpad sends)** — `wlrctl pointer scroll <down>
  <right>` over wlr-virtual-pointer. It joins the seat, so it scrolls whatever
  the sway-placed cursor is over. Qt reports `angleDelta.y` as **12x the
  surface units** (`scroll 3` -> 36, `scroll 15` -> 180) with a matching
  non-zero `pixelDelta`, and brackets each one with **frames whose angle is
  zero** — an accumulator that treats those as a direction change throws its
  remainder away every event.
- **A wheel notch** — a uinput mouse emitting `REL_WHEEL_HI_RES 120` plus
  `REL_WHEEL 1`. Qt reports exactly `angleDelta.y = 120`, `pixelDelta = 0`, so
  120 is the constant to divide by for whole notches. Neither tool is in the
  guest: build `nixpkgs#wlrctl` and `nixpkgs#python3` on the host and run the
  store paths there (the host store is mounted). `/dev/uinput` already exists;
  the script needs root, a ~1.5 s settle for libinput to pick the device up,
  and `UI_DEV_DESTROY` at the end.

To read what Qt actually delivers, point a throwaway shell at a `FloatingWindow`
whose `MouseArea` logs `wheel.angleDelta.y`, and read it back with
`journalctl _SYSTEMD_USER_UNIT=<unit>.service`. That is how both mappings above
were measured, and it is faster than inferring them from what a module did.

`button3` opens a row's action panel. To find a module's x, set the cursor and
screenshot before clicking: `BarModule` paints its surface background under the
pointer, so the highlight tells you which one you are on. If you do fall back to
`machine.screenshot`, a row's y is still honest there — the shear only shifts
pixels sideways, so only the x you read off it is a lie.

The exception is a module the VM cannot make visible — `Battery` is
`visible: present` and QEMU has no battery — and then there is nothing to click.
Fall back to the throwaway shell above, with the menu inside a `PopupSurface`
and a `QtObject` stub for the device it expects. State the real services cannot
produce (a ppd hold, a profile the placeholder driver lacks) can be forced with
a throwaway `sed` on the guest's copy of the component.

### Bluetooth is conjurable rather than stubbable

QEMU emulates no adapter, but bluez's `btvirt` over `hci_vhci` gives the guest
real `org.bluez` controllers, so the whole menu can be driven for real. `btvirt`
is not in nixpkgs' `bluez` — build it out of tree:

```nix
pkgs.bluez.overrideAttrs (old: {
  pname = "btvirt";
  configureFlags = old.configureFlags ++ [ "--enable-testing" ];
  doCheck = false;
  doInstallCheck = false;
  postInstall = (old.postInstall or "") + ''
    install -Dm755 emulator/btvirt $out/bin/btvirt
  '';
})
```

In the guest (the host store is mounted, so the path resolves):

```bash
modprobe hci_vhci
systemd-run --unit=btvirt --collect <store>/bin/btvirt -l2
systemctl start bluetooth.service
busctl --system set-property org.bluez /org/bluez/hci1 org.bluez.Adapter1 Discoverable b true
```

`-l2` gives `hci0` and `hci1`, which discover and pair with **each other**.
Restart `quickshell.service` afterwards so it re-probes bluez. Assert against
the bus rather than the screenshot — `busctl --system get-property org.bluez
/org/bluez/hci0 org.bluez.Adapter1 Discovering` is what proves a click landed.

Two emulator quirks that read as UI bugs: an unbonded device object is dropped
from the bus once discovery stops, so scan and act in one pass; and `Pair()`
with no agent registered leaves `Paired=true` but `Bonded=false`, which is why
the menu treats either flag as known.

## A window that sizes itself off its own content

`NotificationPopups` is a `PanelWindow` with no fixed height: it is as tall as
the stack of toasts inside it, and down entirely when there are none. Two traps
come with that shape, and both look like "the popup never appears".

**Never take `visible` from a positioner's height.** A `Column` lays out on
polish, and polish only runs for a window that is rendering — so
`visible: column.implicitHeight > 0` can never come true: the column stays zero
high until the window is up, and the window is waiting on the column. Count the
model instead (`server.trackedNotifications.values.length > 0`). `Dropdown.qml`
meets the same rule from the other side, calling `forceLayout()` before it opens.

**Give the content an explicit width, not `parent.width`.** A window that is
down has a zero-wide content item, so wrapping `Text` inside it measures to
nothing and the column reports roughly one line — which is the height the window
then maps at, because the first item is what brings it up. It never recovers.
Bind the content to the same constant the window's `implicitWidth` uses.

`Notification.tracked = true` also does not reach `trackedNotifications` before
the `onNotification` handler returns, so there is nothing to measure or lay out
from inside it.

When a popup renders in a second shell but not under `quickshell.service`,
suspect neither: a notification sent in the first seconds after the unit reports
`active` can land before the window is up. Wait a few seconds past `is-active`
before asserting. To see the real geometry rather than guess at it, log it —
`console.log` from a `Timer` in a patched guest copy reaches
`journalctl _SYSTEMD_USER_UNIT=<unit>.service`, and one repeating tick
distinguishes "never sized" from "sized a frame late".

The guest screen is also narrower than the real panel (~470 px against 1128
logical), so a full-width popup runs off the left edge there. Narrow the width
in the guest's `Config.qml` with `sed` to see the whole layout.

### A notification's icon is all on `image`, and a missing one does not fail

`Notification.appIcon` is empty even when the sender passed `--icon=`: quickshell
folds the app icon in with the image hint and publishes both on
`Notification.image`, as a url for its own provider —
`image://icon/<theme name>` or `image://icon//absolute/path`.

That provider answers a name it cannot resolve with a magenta checkerboard
rather than with a failure, so `Image.status` stays `Ready` and there is nothing
for a fallback to catch. `iconPath`'s `check` flag does not help either; it
covers a different case. Unwrap the url and ask each half the question it can
answer — `Quickshell.hasThemeIcon(name)` for a theme name, and plain
`file://<path>` for a path, which Qt loads itself and does report `Image.Error`
for. `NotificationToast.qml` does exactly that.

Worth knowing when testing: the guest has only the `hicolor` theme, so
`--icon=system-reboot` is the missing-icon case there and `--icon=nix-snowflake`
is the resolving one.
