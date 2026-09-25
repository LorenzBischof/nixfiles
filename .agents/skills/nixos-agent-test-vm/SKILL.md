---
name: nixos-agent-test-vm
description: Test NixOS configuration changes in an isolated, session-scoped agent VM. Use when validating a NixOS change at runtime, reusing a VM within one agent session, applying a new configuration without rebooting, setting up the VM harness for a host, or updating this skill.
---

# Test NixOS VM

This skill describes a VM harness that boots a real NixOS host configuration inside QEMU. Reuse the VM for fast iterations within one agent session, isolate it from other agents by session ID, and always stop it before finishing the task.

The harness is provided by the [`nixos-agent-test-vm`](https://github.com/lorenzbischof/nixos-agent-test-vm) flake: the consuming flake adds it as an input and exposes one `apps.<system>.<host>-agent-vm` attribute per host it wants to drive. **If `nix run .#<host>-agent-vm` doesn't exist yet for the host you want to test, read [SETUP.md](SETUP.md) to wire it up; otherwise stay here.**

> Examples below write the host name as `<host>`. Substitute your own host wherever you see it.

> **Checking / refreshing this skill.** `check.sh` from this skill's directory (e.g. `.claude/skills/nixos-agent-test-vm/check.sh`) is a read-only probe: it prints `ok` (exit 0) when the vendored copy matches the `nixos-agent-test-vm` revision pinned in their `flake.lock`, or `stale` (exit 1) when it doesn't. It changes nothing, so run it freely — at the start of a VM session if the user has recently run `nix flake update`, or whenever the user asks whether the skill is current; skip it on routine VM interactions. If it reports `stale`, refreshing **overwrites the vendored files**, so only run `check.sh --refresh` yourself once the user asks or grants permission; afterward ask them to commit the result.

Use the upstream NixOS test documentation as the canonical reference for test-driver behavior and `machine.*` APIs:

- https://nixos.org/manual/nixos/unstable/#sec-nixos-tests

### nixpkgs is a library of working examples

`nixos/tests/` in nixpkgs contains well over a thousand machine tests, and `nixos/modules/` is the authoritative source for option names and defaults. When something does not work in the VM, or the setup needs more than a service toggle (wifi, DHCP servers, multi-node networking, PAM/secrets, desktop sessions), find the upstream test that already does it and copy its configuration instead of inventing one. The pinned nixpkgs is already in the local store, so this is a `grep`, not a download:

```bash
# The nixpkgs this flake already pins — no host name, no download.
nixpkgs_src="$(nix flake archive --json . 2>/dev/null | jq -r '.inputs.nixpkgs.path')"
grep -rln mac80211_hwsim "$nixpkgs_src/nixos/tests"
sed -n '1,80p' "$nixpkgs_src/nixos/tests/wpa_supplicant.nix"
```

If the flake's input is not named `nixpkgs`, pick the right key out of `nix flake archive --json . | jq '.inputs'`. Any recent checkout works for reading tests, so `nix flake metadata nixpkgs --json | jq -r .path` is a fine fallback.

`nixos/tests/all-tests.nix` is the index of every test; `grep -rn "services.foo" "$nixpkgs_src/nixos/tests"` finds the ones exercising a given module. Those tests run in the same `runNixOSTest` driver this harness uses, so their node configuration and their test Python both transfer almost verbatim — including the `mkVMOverride` workarounds the VM instrumentation makes necessary.

## Architecture

- The flake input `nixos-agent-test-vm` exposes `mkAgentVm` as a top-level output; the consuming flake calls it once per host to produce an `apps.<system>.<host>-agent-vm` entry.
- The helper boots the host's real NixOS config plus a few virtualisation overrides (memory/cores, virtio-gpu, predictable keymap, a host-store mount, and `system.switch.enable = true`).
- The test script is `agent-vm-driver.py` (lives inside `nixos-agent-test-vm`), read verbatim by the helper. It calls `start_all()` then executes native NixOS test-Python cells received through a socket in the session-specific runtime directory.
- The flake app supports `start`, `apply`, `status`, `socket`, `stop`, and `run`. Each command selects an isolated instance from `AGENT_VM_SESSION`, `CODEX_THREAD_ID`, or a supported agent-specific session variable.
- Each session gets its own socket, QEMU state directory, log, PID, and GC root. Independent agents can run concurrently unless they deliberately reuse the same session ID.
- Hosts with a graphical session typically add an auto-login override (e.g. `greetd` → Sway) via the per-host `extraConfig`; see SETUP.md for the pattern.

## Session lifecycle

Use one stable, unique session ID for the entire task. Codex provides `CODEX_THREAD_ID` automatically. In another agent runtime, set `AGENT_VM_SESSION` explicitly and use the same value for every command; never borrow another agent's ID.

If tool calls use fresh shells, environment variables and `vm_socket` do not carry over. Prefix each runner invocation with the same explicit `AGENT_VM_SESSION=<id>` when no automatic session variable exists, and recompute `vm_socket` in each shell that needs it.

Derive the session socket without evaluating Nix, then probe it before starting anything:

```bash
agent_vm_session="${AGENT_VM_SESSION:-${CODEX_THREAD_ID:-${CLAUDE_CODE_SESSION_ID:-${CLAUDE_SESSION_ID:-}}}}"
test -n "$agent_vm_session" || { echo "set AGENT_VM_SESSION" >&2; exit 2; }
session_digest="$(printf '%s' "$agent_vm_session" | sha256sum)"
session_key="${session_digest%% *}"
session_key="${session_key:0:12}"
vm_socket="$XDG_RUNTIME_DIR/<host>-agent-vm-$session_key/<host>-agent-vm.sock"

printf '%s\n' 'machine.process is not None and machine.process.poll() is None' \
  | socat -t 5 - UNIX-CONNECT:"$vm_socket"
```

If that succeeds with `{"ok": true, "result": "True"}`, reuse this session's VM. This checks the host-side QEMU process without waiting for a guest shell. Never attach to a socket from a different session.

Only when the probe fails, start the VM:

```bash
nix run .#<host>-agent-vm -- start

printf '%s\n' 'machine.wait_for_unit("default.target")' \
  | socat -t 120 - UNIX-CONNECT:"$vm_socket"
```

`start` is idempotent within the session and prints its socket and log paths. It detaches a new VM when needed and waits for the control socket. Use `nix run .#<host>-agent-vm -- run` only when a foreground driver is useful for debugging.

## Using the test driver

Interact with the NixOS test driver by sending one complete Python program per socket connection. Write-side EOF marks the end of the program and the server replies with one JSON object. Use a quoted heredoc for anything non-trivial so Bash passes quotes, newlines, and indentation through unchanged:

```bash
socat -t 120 - UNIX-CONNECT:"$vm_socket" <<'PY'
code, out = sh("hostname")
assert code == 0, out
out
PY
# {"ok": true, "result": "'<host>\\n'"}
```

The program is ordinary NixOS test Python. Compound statements, multiline strings, function definitions, and the standard `machine`, `nodes`, `subtest`, and other test-driver symbols work directly. The complete program is compiled before any of it executes. Its final expression becomes `result`, while assignments and definitions persist for later connections.

You can also execute an existing Python file without involving shell quoting:

```bash
socat -t 120 - UNIX-CONNECT:"$vm_socket" < /absolute/path/to/check.py
```

**Use `socat -t N`** (`-t 120` or higher for slow programs). After stdin reaches EOF, `-t` keeps the read side alive long enough to receive the response.

`$vm_socket` is a plain Unix socket. If `socat` is unavailable, use another local Unix-socket client such as a short `perl` or Python snippet rather than giving up on VM validation.

Response format (one JSON object per connection):

- Success: `{"ok": true, "result": <repr-of-value-or-null>}`
- Failure: `{"ok": false, "error": <formatted Python error>}`

Notes on the protocol:

- Runtime errors stop the remainder of the current program, return `ok: false`, and leave the driver and VM available for the next connection. Effects from statements that already completed are not rolled back.
- Syntax errors prevent the entire program from executing. Errors include request-specific filenames such as `<agent:7>`, source line numbers, and relevant submitted-source frames; noisy socket and test-driver implementation frames are omitted.
- `sh("false")` returns a non-zero status rather than raising. Check it with `assert code == 0, out`.
- `SystemExit` is intentionally not caught because the lifecycle runner uses it to stop the VM.
- `socat` reports transport success even if the response contains `ok: false`. Inspect `.ok` when a shell command must fail on a Python error: `response="$(...)"; jq -e '.ok == true' <<<"$response"`.
- State persists across connections. This is useful for helper functions and variables, but a failed program can leave state created before the failing statement.

The `machine` object exposed here is the standard NixOS test driver machine object. Prefer the upstream docs for the full API; the table below lists the methods that are most useful in practice.

## Interaction patterns

A few patterns that proved useful in practice:

- **Use `sh(script)` for shell commands.** It returns `(exit, output)` with stderr merged, runs every line regardless of what failed before it, and cannot kill itself with `pkill -f`. Assert the status in the same program and leave the desired value as the final expression. To suppress output when you do not need it, discard it with `code, _ = ...`.
- **Send one readable Python cell.** Avoid semicolons and nested shell quoting:

  ```bash
  socat -t 60 - UNIX-CONNECT:"$vm_socket" <<'PY'
  code, out = sh("systemctl show -p ExecStart some.service")
  assert code == 0, out
  out.split("path=")[1].split(";")[0]
  PY
  ```

- **For human reading, use `jq -r 'if .ok then .result else .error end'`.** On success this gives the final expression's `repr`; on failure it renders the multiline traceback. For programmatic success values, extract `.result` and use `ast.literal_eval()` to round-trip the representation.
- **Long-running programs**: pass a higher `-t N` to `socat` (e.g. `-t 300` for a service start that hits the network); the server waits as long as the Python needs.

### Reserved names — do NOT use as variables

The persistent execution namespace contains the native test-driver symbols but is separate from the socket server's own globals. Most assignments therefore cannot corrupt the server. Still avoid replacing the objects that lifecycle operations use:

- `machine`, `nodes` — the test-driver objects you are trying to use; `machine` is also used by lifecycle probes and `apply`.
- `sh` — the guest-command helper.
- `SystemExit` — used by the lifecycle runner to shut down the driver.

Use ordinary local names such as `code`, `out`, and `result`.

## Useful machine methods

| Method | Description |
|---|---|
| `sh("script")` | Run a shell script in the guest, return `(exit_code, output)` with stderr merged. **The default — use this, not `machine.execute`/`succeed`/`fail`.** Cut off after 60 s (exit code 124). |
| `machine.wait_for_unit("name.service")` | Wait until a systemd unit is active |
| `machine.wait_for_open_port(port)` | Wait until a TCP port is open |
| `machine.screenshot("/tmp/shot.png")` | Capture the VM screen to a file on the host |
| `machine.send_chars("text")` | Type text into the VM (keyboard input) |
| `machine.send_key("ctrl-l")` | Send a key combination |
| `machine.wait_for_text("text")` | **Unavailable** — needs `enableOCR`, which this harness does not set. Screenshot and look instead. |
| `machine.systemctl("start foo.service")` | Run systemctl in the VM |

## Apply configuration changes without rebooting

After editing the NixOS configuration, keep QEMU running and activate the new VM toplevel:

```bash
nix run .#<host>-agent-vm -- apply
```

This builds the current test configuration and runs its `switch-to-configuration test` inside the existing guest. It is the default edit/test loop for packages, services, desktop settings, users, and other runtime-switchable configuration. The guest state and graphical session survive between iterations.

After `apply`, verify the changed unit or behavior directly. If the activation stops or replaces a graphical session, wait for `graphical.target` and the relevant display-manager/session unit again before interacting with the GUI.

### Restart only when required

Use one clean restart when the test depends on kernel, initrd, bootloader, filesystems, QEMU/virtualisation settings, early boot, or state that an in-place activation may preserve. Also restart if `apply` reports an incompatible init interface or the result looks contaminated by earlier imperative testing:

```bash
nix run .#<host>-agent-vm -- stop
nix run .#<host>-agent-vm -- start
```

After a restart, continue using the same session ID and socket path.

## Mandatory cleanup

Stop this session's VM as the final tool action before replying to the user, including after failed validation or an interrupted approach:

```bash
nix run .#<host>-agent-vm -- stop
```

Confirm that it reports `stopped`. This removes the session's QEMU state, log, and GC root. Do not leave the VM for a later agent session. Do not stop another session's VM.

If the changed flake no longer evaluates, stop through the already-known socket instead, then confirm the socket disappears:

```bash
printf '%s\n' 'raise SystemExit' \
  | socat -t 5 - UNIX-CONNECT:"$vm_socket" >/dev/null 2>&1 || true
```

## Waiting for the graphical session

`default.target` is reached before the graphical session is fully up. Before taking screenshots or interacting with the GUI:

```bash
echo 'machine.wait_for_unit("graphical.target")' | socat -t 120 - UNIX-CONNECT:"$vm_socket"
```

`graphical.target`, and even a running compositor process, still is not enough for **keyboard input**: keys sent before the compositor has taken the seat are dropped silently, with no error anywhere. Wait for the compositor's own socket, and resend the key until it has an effect:

```python
machine.wait_for_unit("graphical.target")
machine.wait_until_succeeds("ls /run/user/1000/sway-ipc.*.sock", timeout=120)
for _ in range(5):
    machine.send_key("meta_l-t")
    code, _ = sh("sleep 2; pgrep -x foot")
    if code == 0:
        break
assert code == 0, "Mod4+t never opened a terminal"
```

## Launching Wayland Applications

Commands run through `machine.succeed()` execute outside the logged-in graphical session. To launch GUI apps with the same environment as the real desktop, open a terminal in the session and type the command there. Example for a Sway host with a `Mod4+t` terminal binding:

```bash
echo 'machine.send_key("meta_l-t")' \
  | socat -t 120 - UNIX-CONNECT:"$vm_socket"

echo 'machine.send_chars("wev\n")' \
  | socat -t 120 - UNIX-CONNECT:"$vm_socket"
```

Any GUI program the host installs works here. `pkgs.wev` (Wayland event viewer) is a good first smoke test when you only want to prove the session is usable: it is tiny, Wayland-only, and prints the input events it receives, so it shows both that a client reached the compositor and that `send_key`/`send_chars` arrive.

## Simulated wifi

The VM instrumentation sets `networking.wireless.enable = mkVMOverride false` (`nixos/modules/virtualisation/qemu-vm.nix`: "Wireless won't work in the VM"). NetworkManager's own `networking.wireless.enable = true` is an ordinary definition and loses against it, so there is no supplicant and every wifi device sits at `unavailable`. `mkForce` is priority 50 and `mkVMOverride` is 10, so `mkForce` cannot undo it — use `lib.mkOverride 0`, as the upstream tests do.

Configure the whole simulation declaratively in the host's `extraConfig`, the way `nixos/tests/wpa_supplicant.nix` and `nixos/tests/kismet.nix` do, rather than running `modprobe` and hand-written `hostapd.conf` files inside the guest:

```nix
{ lib, pkgs, ... }:
{
  # Undo the qemu-vm.nix mkVMOverride so NetworkManager gets its supplicant back.
  networking.wireless.enable = lib.mkOverride 0 true;

  # One station radio (wlan0) plus two AP radios (wlan1, wlan2).
  boot.kernelModules = [ "mac80211_hwsim" ];
  boot.extraModprobeConfig = "options mac80211_hwsim radios=3";

  # Declarative `nmcli device set wlanN managed no` for the AP radios.
  networking.networkmanager.unmanaged = [
    "interface-name:wlan1"
    "interface-name:wlan2"
  ];

  services.hostapd = {
    enable = true;
    radios.wlan1 = {
      band = "2g";
      channel = 1;
      countryCode = "US";
      networks.wlan1 = {
        ssid = "home-wifi";
        bssid = "02:00:00:00:00:01";
        authentication = {
          mode = "wpa2-sha256";
          wpaPassword = "supersecret";
        };
      };
    };
    radios.wlan2 = {
      band = "2g";
      channel = 11;
      countryCode = "US";
      networks.wlan2 = {
        ssid = "guest-wifi";
        bssid = "02:00:00:00:00:02";
        authentication = {
          mode = "wpa2-sha256";
          wpaPassword = "supersecret";
        };
      };
    };
  };

  # hostapd serves no DHCP: without this NetworkManager hangs in "IP configuration".
  networking.interfaces.wlan1.ipv4.addresses = [
    { address = "10.10.1.1"; prefixLength = 24; }
  ];
  services.dnsmasq = {
    enable = true;
    settings = {
      interface = [ "wlan1" ];
      bind-interfaces = true;
      dhcp-range = [ "10.10.1.10,10.10.1.100,12h" ];
    };
  };

  environment.systemPackages = [ pkgs.iw ];
}
```

One `hostapd.service` serves both radios. The SSIDs then show up in `nmcli device wifi list` and in the desktop bar, and joining one really runs the supplicant. Give each AP you want to hand out leases on its own address and `interface` entry; an AP without DHCP still associates but never reaches `connected`.

Other authentication modes (`wpa3-sae`, `wpa3-sae-transition`, multiple BSSes on one radio, secrets from files) are all covered by `nixos/tests/wpa_supplicant.nix` — read it before hand-rolling anything.

Limits and alternatives:

- **All APs report the same signal strength.** `mac80211_hwsim` has no path-loss model, and `iw … set txpower` does not move the reported RSSI. The usual fix, `wmediumd`, is not packaged in nixpkgs.
- **`services.vwifi`** (module `nixos/modules/services/networking/vwifi.nix`, package `pkgs.vwifi`) simulates 802.11 *between* VMs through a server process: it manages the hwsim radios for you (`services.vwifi.module.numRadios`, `macPrefix`) and its server can induce packet loss and expose a monitor/spy interface. `nixos/tests/kismet.nix` is a four-node example (server, AP, station, monitor). Overkill for a single-VM AP+station setup, and not yet tried in this harness.

## Gotchas

- **Keyboard layout**: The harness forces `console.keyMap = "us"` so `send_chars()` produces predictable keys regardless of the host's real keymap. If the host runs Sway/X11 with a non-US XKB layout, that layout must also be forced to `us` in the VM's `extraConfig` for keybindings to fire correctly — `console.keyMap` alone is not enough.
- **Super key name**: Use `"meta_l"` not `"super"` for the Super/Mod4 key in `send_key()`. Example: `machine.send_key("meta_l-t")` triggers `Mod4+t`.
- **`agenix` failures**: Decryption errors are expected — the VM lacks host secret keys.
- **`vde_plug2tap` warnings**: Non-fatal, can be ignored.
- **Session isolation**: Keep the same session ID throughout one task. Different IDs are safe to run concurrently; the same ID intentionally addresses the same VM.
- **Subagents in one thread**: If several agents share a thread-level session variable, give each one a unique `AGENT_VM_SESSION`; automatic `CODEX_THREAD_ID` isolation applies between independent threads.
- **Reuse before rebuild**: Probe this session's socket first. Do not invoke `nix run ... start` merely to discover whether it exists.
- **One program per connection**: Do not expect multiple responses from one socket connection. Put related statements in one Python program or open another connection; the namespace persists either way.
- **A command that does not return blocks the socket**: while a program runs the driver answers nothing and later connections close empty, which looks like a crash. `sh()` bounds this at 60 s. `systemctl stop` on a unit that ignores SIGTERM (quickshell does) blocks for its full stop timeout — use `systemctl kill --signal=KILL <unit>`.
- **Match processes by name, not by pattern**: `pkill -x` needs the real name from `/proc/<pid>/comm` — a nixpkgs wrapper script shows up under its own name, e.g. quickshell as `.quickshell-wra`, so `pkill -x quickshell` silently matches nothing.
- **Hot apply is not a boot test**: Use `apply` for fast iterations, then restart when the behavior under test depends on boot-time state.
- **No reboot needed between commands**: The VM stays running across commands within the current agent session only.
- **Screenshots and files copied out of the guest**: relative paths land in the session directory `out/` (printed by `start`), never in the repository; absolute paths go where you name them. The other direction is `machine.copy_from_host("<host path>", "<guest path>")`. For text, `sh("cat <path>")` beats copying the file at all.
- **Simulated wifi**: needs `networking.wireless.enable = lib.mkOverride 0 true;` plus `mac80211_hwsim` radios — see [Simulated wifi](#simulated-wifi).
- **`systemd-run` in the guest needs absolute paths**: a transient unit does not inherit the calling shell's PATH, and `systemd-run --unit=x foo` simply goes inactive with nothing useful in its journal. Expand in the caller instead: `systemd-run --unit=x $(command -v foo)`.
- **Reading a user unit's journal**: `journalctl --user -M <user>@` fails with "Connecting to a machine as non-root is not supported". From the driver (which is root) use `journalctl _SYSTEMD_USER_UNIT=<name>.service` instead.
- **Validation standard**: For tasks about desktop runtime behavior, apply the final Nix configuration and validate the final state in the VM, not just the hypothesis before editing.

## Keeping this skill up to date

If you discover new test patterns, useful machine methods, gotchas, or workarounds while using this VM harness — especially if you had to retry several times before finding a working approach — **update this skill file** with what you learned. Future agents (including yourself in later conversations) will benefit from those lessons. Examples of things worth adding:

- A method or technique that wasn't obvious but turned out to be the right way
- A failure mode you hit repeatedly before finding the fix
- Timing or ordering constraints that aren't documented above
- New `machine.*` methods or `socat` patterns that proved useful
