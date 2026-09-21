---
name: quickshell-bar
description: Use when changing the quickshell bar or one of its dropdowns in modules/home/wayland/quickshell — type-checking the QML, picking icon glyphs that actually exist in the font, or seeing a bar module render before switching. Covers the traps that cost time; the QML itself is readable on its own.
---

# quickshell bar

The bar lives in `modules/home/wayland/quickshell`: `qml/` holds the components,
and `default.nix` generates `Config.qml` (theme, sizes, icon ramps, shared
helpers) into the same directory at build time. Only the notes below are
non-obvious; everything else follows the existing components.

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

**`[unqualified]` warnings are the baseline, not findings.** Every existing menu
has them — `VolumeMenu` has 8 — because a `dropdown:` component and a `Repeater`
delegate both reach their parent through `root`, which is the established
pattern here. Compare counts against a neighbouring file before chasing one:

```bash
.claude/skills/quickshell-bar/lint.sh 2>&1 | grep -E '^(Warning|Error)' \
  | sed 's/:[0-9]*:[0-9]*:.*\[/ [/' | sort | uniq -c | sort -rn
```

**`[property-override]` is the opposite: always a real finding.** Every
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

## Seeing a module render in the agent VM

Use the [nixos-agent-test-vm](../nixos-agent-test-vm/SKILL.md) skill, and
capture with `grim` into the driver's shared dir rather than
`machine.screenshot`, which returns a sheared and often stale frame:

```bash
runuser -u lbischof -- env XDG_RUNTIME_DIR=/run/user/1000 \
  WAYLAND_DISPLAY=wayland-1 grim /tmp/shared/shot.png
```

Dropdowns open normally in the VM, but nothing in the test driver moves the
pointer. Click through sway instead:

```bash
sway() { runuser -u lbischof -- env SWAYSOCK="$(ls /run/user/1000/sway-ipc.*)" swaymsg "$@"; }
sway 'seat - cursor set 637 14'      # the module in the bar
sway 'seat - cursor press button1'
sway 'seat - cursor release button1'
```

`button3` opens a row's action panel. To find a module's x, set the cursor and
screenshot before clicking: `BarModule` paints its surface background under the
pointer, so the highlight tells you which one you are on. If you do fall back to
`machine.screenshot`, a row's y is still honest there — the shear only shifts
pixels sideways, so only the x you read off it is a lie.

The exception is a module the VM cannot make visible — `Battery` is
`visible: present` and QEMU has no battery — and then there is nothing to click.
For those, render the menu component directly instead of reaching it through the
bar:
copy the built config into the guest, replace `shell.qml` with a
`FloatingWindow` holding the menu inside a `PopupSurface`, and feed it a
`QtObject` stub for the device it expects. State the real services cannot
produce (a ppd hold, a profile the placeholder driver lacks) can be forced with
a throwaway `sed` on the guest's copy of the component.

Launch it without the terminal keybinding, which would otherwise sit on top of
the screenshot:

```bash
systemd-run --user --machine=lbischof@ --unit=bar-test --collect \
  --setenv=WAYLAND_DISPLAY=wayland-1 --setenv=XDG_RUNTIME_DIR=/run/user/1000 \
  <quickshell>/bin/quickshell -p /tmp/bartest/shell.qml
```

`<quickshell>` is the store path out of `systemctl --user -M lbischof@ show -p
ExecStart quickshell.service`; the guest's login PATH has no `qs`. There is no
`python3` in the VM either — patch files with `sed`, or splice them with
`head`/`tail`.

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
