---
name: test-nixos-vm
description: Use when testing NixOS configuration changes in a VM.
---

# Test NixOS VM

This repo includes a VM harness that boots the full `framework` NixOS configuration inside QEMU. The important mental model is that this is a NixOS test driven by the upstream NixOS test driver, with a Unix socket command interface layered on top so AI agents can control it without needing an interactive terminal.

Use the upstream NixOS test documentation as the canonical reference for test-driver behavior and `machine.*` APIs:

- https://nixos.org/manual/nixos/unstable/#sec-nixos-tests

## Architecture

- Defined in `flake.nix` under `apps.framework-vm`
- Boots the real framework config with overrides for virtualisation (software rendering, disabled services)
- Auto-logs in via `greetd` and starts a Sway session with `WLR_RENDERER_ALLOW_SOFTWARE=1`
- The NixOS test driver listens on a Unix socket at `$XDG_RUNTIME_DIR/framework-vm.sock` and evaluates Python expressions sent to it
- Results are returned as JSON on the same connection

## Launching the VM

```bash
nix run .#framework-vm -L > /tmp/vm-log 2>&1 &

# Wait for the VM to be ready (typically ~30-60s)
while ! grep -q "VM_READY" /tmp/vm-log 2>/dev/null; do sleep 1; done
```

If the background launch exits unexpectedly or `/tmp/vm-log` stays empty, rerun `nix run .#framework-vm -L` in the foreground once to capture the failure before retrying.

## Using the test driver

Interact with the NixOS test driver by sending Python expressions via `socat` and getting JSON back on the same connection:

```bash
echo 'machine.succeed("hostname")' | socat -t 120 - UNIX-CONNECT:$XDG_RUNTIME_DIR/framework-vm.sock
# {"ok": true, "result": "framework\n"}
```

**Always use `socat -t 120`** (or a higher value for very slow commands). Without `-t`, socat closes the socket as soon as stdin is exhausted. For fast commands this works by accident; for slow commands the response is silently lost. `-t N` tells socat to wait N seconds after stdin closes before giving up on reading the response.

`$XDG_RUNTIME_DIR/framework-vm.sock` is a plain Unix socket. If `socat` is unavailable, use another local Unix-socket client such as a short `perl` or Python snippet rather than giving up on VM validation.

Response format:
- Success: `{"ok": true, "result": "..."}`
- Failure: `{"ok": false, "error": "traceback..."}`

The `machine` object exposed here is the standard NixOS test driver machine object. Prefer the upstream docs for the full API; the table below lists the methods that are most useful in this repo.

## Useful machine methods

| Method | Description |
|---|---|
| `machine.succeed("cmd")` | Run shell command, fail if exit code != 0 |
| `machine.fail("cmd")` | Run shell command, fail if exit code == 0 |
| `machine.execute("cmd")` | Run shell command, return `(exit_code, stdout)` tuple |
| `machine.wait_for_unit("name.service")` | Wait until a systemd unit is active |
| `machine.wait_for_open_port(port)` | Wait until a TCP port is open |
| `machine.screenshot("/tmp/shot.png")` | Capture the VM screen to a file on the host |
| `machine.send_chars("text")` | Type text into the VM (keyboard input) |
| `machine.send_key("ctrl-l")` | Send a key combination |
| `machine.wait_for_text("text")` | Wait until OCR detects text on screen (requires `tesseract`) |
| `machine.systemctl("start foo.service")` | Run systemctl in the VM |

## Shutting down and rebuilding

When done, or when you need to test Nix configuration changes, shut down the VM:

```bash
echo 'exit()' | socat -t 5 - UNIX-CONNECT:$XDG_RUNTIME_DIR/framework-vm.sock
```

After making changes to Nix configuration files, you must restart the VM for them to take effect — the VM boots from a build of the config, so a rebuild and relaunch is required.

## Waiting for the graphical session

`VM_READY` fires once `default.target` is reached, but the graphical session may still be starting. Before taking screenshots or interacting with the GUI:

```bash
echo 'machine.wait_for_unit("graphical.target")' | socat -t 120 - UNIX-CONNECT:$XDG_RUNTIME_DIR/framework-vm.sock
```

## Gotchas

- **Keyboard layout**: The VM forces `console.keyMap = "us"` because the host uses ADNW. Without this, `send_chars()` sends incorrect keys. Sway's XKB layout must also be forced to `us` for keybindings to work correctly — `console.keyMap` alone is not enough.
- **Super key name**: Use `"meta_l"` not `"super"` for the Super/Mod4 key in `send_key()`. Example: `machine.send_key("meta_l-t")` triggers `Mod4+t`.
- **`agenix` failures**: Decryption errors are expected — the VM lacks host secret keys.
- **`vde_plug2tap` warnings**: Non-fatal, can be ignored.
- **No reboot needed between commands**: The VM stays running. Send as many commands as you need.
- **Screenshots**: Always use absolute paths under `/tmp/` (e.g. `/tmp/shot.png`). Relative paths write to the repo root.
- **Validation standard**: For tasks about desktop runtime behavior, use the VM to validate the final state after your code change, not just the hypothesis before editing.

## Keeping this skill up to date

If you discover new test patterns, useful machine methods, gotchas, or workarounds while using this VM harness — especially if you had to retry several times before finding a working approach — **update this skill file** with what you learned. Future agents (including yourself in later conversations) will benefit from those lessons. Examples of things worth adding:

- A method or technique that wasn't obvious but turned out to be the right way
- A failure mode you hit repeatedly before finding the fix
- Timing or ordering constraints that aren't documented above
- New `machine.*` methods or `socat` patterns that proved useful
