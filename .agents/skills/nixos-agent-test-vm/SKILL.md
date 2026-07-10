---
name: nixos-agent-test-vm
description: Use when testing a NixOS configuration in a VM, when setting up the VM harness for a new host, or when asked to update/refresh this skill. Reach for it whenever you need to verify a NixOS change actually works at runtime, not just that it builds.
---

# Test NixOS VM

This skill describes a VM harness that boots a real NixOS host configuration inside QEMU. The mental model is: a NixOS test driven by the upstream NixOS test driver, with a Unix socket command interface layered on top so AI agents can control it without an interactive terminal.

The harness is provided by the [`nixos-agent-test-vm`](https://github.com/lorenzbischof/nixos-agent-test-vm) flake: the consuming flake adds it as an input and exposes one `apps.<system>.<host>-agent-vm` attribute per host it wants to drive. **If `nix run .#<host>-agent-vm` doesn't exist yet for the host you want to test, read [SETUP.md](SETUP.md) to wire it up; otherwise stay here.**

> Examples below use `framework` as the host name. Substitute your own host wherever you see it.

> **Refreshing this skill.** When the user asks to update or refresh this skill, run `check.sh` from this skill's directory (e.g. `.claude/skills/nixos-agent-test-vm/check.sh`) to compare the vendored copy against the revision pinned in their `flake.lock`. If it reports `ok`, tell the user the skill is already in sync. If it reports `stale`, run the `nix run github:lorenzbischof/nixos-agent-test-vm/<rev>` command that `check.sh` prints (it embeds the locked revision so the install matches the pin) and ask the user to commit the result. Also run the same check once at the start of a VM session if the user has recently run `nix flake update`; otherwise skip it on routine VM interactions.

Use the upstream NixOS test documentation as the canonical reference for test-driver behavior and `machine.*` APIs:

- https://nixos.org/manual/nixos/unstable/#sec-nixos-tests

## Architecture

- The flake input `nixos-agent-test-vm` exposes `mkAgentVm` as a top-level output; the consuming flake calls it once per host to produce an `apps.<system>.<host>-agent-vm` entry.
- The helper boots the host's real NixOS config plus a few virtualisation overrides (memory/cores, virtio-gpu, predictable keymap).
- The test script is `agent-vm-driver.py` (lives inside `nixos-agent-test-vm`), read verbatim by the helper. It calls `start_all()` then hosts a Python REPL on `$XDG_RUNTIME_DIR/<host>-agent-vm.sock`.
- Hosts with a graphical session typically add an auto-login override (e.g. `greetd` → Sway) via the per-host `extraConfig`; see SETUP.md for the pattern.

## Launching the VM

```bash
nix run .#framework-agent-vm -L > /tmp/vm-log 2>&1 &

# Wait for the socket to appear (typically ~30-60s)
while ! test -S "$XDG_RUNTIME_DIR/framework-agent-vm.sock" 2>/dev/null; do sleep 1; done

# Wait for default.target to be reached
echo 'machine.wait_for_unit("default.target")' | socat -t 120 - UNIX-CONNECT:$XDG_RUNTIME_DIR/framework-agent-vm.sock
```

If the background launch exits unexpectedly or `/tmp/vm-log` stays empty, rerun `nix run .#framework-agent-vm -L` in the foreground once to capture the failure before retrying.

## Using the test driver

Interact with the NixOS test driver by sending Python lines via `socat` and getting JSON lines back. Each line is one expression or statement; multiple lines per connection are fine, and the namespace persists across both lines and connections:

```bash
echo 'machine.succeed("hostname")' | socat -t 120 - UNIX-CONNECT:$XDG_RUNTIME_DIR/framework-agent-vm.sock
# {"ok": true, "result": "'framework\\n'"}
```

**Use `socat -t N`** (`-t 120` or higher for slow commands). Without `-t`, socat closes the socket as soon as stdin is exhausted, which can lose a slow response.

`$XDG_RUNTIME_DIR/framework-agent-vm.sock` is a plain Unix socket. If `socat` is unavailable, use another local Unix-socket client such as a short `perl` or Python snippet rather than giving up on VM validation.

Response format (one JSON object per line):
- Success: `{"ok": true, "result": <repr-of-value-or-null>}`
- Failure: `{"ok": false, "error": <exception type + message>}` — call stack and driver frames are stripped, so the error is one short line for runtime errors (e.g. `NameError: name 'foo' is not defined`) and source-line + caret + message for `SyntaxError`.

Notes on the protocol:
- The line is tried as a Python expression first; if it doesn't parse, it's executed as a statement and `result` is `null`.
- State persists. Assignments like `code, out = machine.execute("...")` are visible to later lines.

The `machine` object exposed here is the standard NixOS test driver machine object. Prefer the upstream docs for the full API; the table below lists the methods that are most useful in practice.

## Interaction patterns

A few patterns that proved useful in practice:

- **Always use `machine.execute(cmd)`.** It returns `(exit, output)`; check the int, ignore `succeed`/`fail` (their exception-on-non-zero semantics give you a verbose traceback you have to read just to learn "exit was 7"). To suppress stdout when you don't need it, discard it: `code, _ = machine.execute("...")`. Smaller responses, less context to read back.
- **Tuple-unpack on one line, parse on the next.** Variables persist within and across connections (the REPL namespace is the test script's globals):

  ```bash
  printf 'code, out = machine.execute("systemctl show -p ExecStart some.service")\nout.split("path=")[1].split(";")[0]\n' \
    | socat -t 60 - UNIX-CONNECT:$XDG_RUNTIME_DIR/framework-agent-vm.sock
  ```

- **For human reading, pipe through `jq -r '.result'`** — gives the `repr` directly. For programmatic use, `jq -r '.result'` then `ast.literal_eval()` to round-trip a string/tuple value back to Python.
- **Long-running commands**: pass a higher `-t N` to socat (e.g. `-t 300` for a service start that hits the network); the server side waits as long as the command needs.

### Reserved names — do NOT use as variables

The REPL namespace is the test script's globals, so anything you assign sticks across lines and connections. Avoid these names; shadowing them breaks the harness:

- `machine`, `nodes` — the test-driver objects you're actually trying to use.
- `exit`, `quit` — needed to shut the VM down.
- `start_all`, `print`, `eval`, `exec`, `compile`, `globals` — Python builtins / test-driver primitives.

Use `code, out` (not `exit, out`), `result` (not `eval`), etc.

## Useful machine methods

| Method | Description |
|---|---|
| `machine.execute("cmd")` | Run shell command, return `(exit_code, stdout)` tuple. **The default — use this, not `succeed`/`fail`.** |
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
echo 'exit()' | socat -t 5 - UNIX-CONNECT:$XDG_RUNTIME_DIR/framework-agent-vm.sock
```

If a prior line accidentally bound `exit` as a variable, `exit()` will raise `TypeError`. Use `import sys; sys.exit(0)` instead, or `del exit` first. (See the "Reserved names" list above.)

After making changes to Nix configuration files, you must restart the VM for them to take effect — the VM boots from a build of the config, so a rebuild and relaunch is required.

## Waiting for the graphical session

`default.target` is reached before the graphical session is fully up. Before taking screenshots or interacting with the GUI:

```bash
echo 'machine.wait_for_unit("graphical.target")' | socat -t 120 - UNIX-CONNECT:$XDG_RUNTIME_DIR/framework-agent-vm.sock
```

## Launching Wayland Applications

Commands run through `machine.succeed()` execute outside the logged-in graphical session. To launch GUI apps with the same environment as the real desktop, open a terminal in the session and type the command there. Example for a Sway host with a `Mod4+t` terminal binding:

```bash
echo 'machine.send_key("meta_l-t")' \
  | socat -t 120 - UNIX-CONNECT:$XDG_RUNTIME_DIR/framework-agent-vm.sock

echo 'machine.send_chars("logseq\n")' \
  | socat -t 120 - UNIX-CONNECT:$XDG_RUNTIME_DIR/framework-agent-vm.sock
```

## Gotchas

- **Keyboard layout**: The harness forces `console.keyMap = "us"` so `send_chars()` produces predictable keys regardless of the host's real keymap. If the host runs Sway/X11 with a non-US XKB layout, that layout must also be forced to `us` in the VM's `extraConfig` for keybindings to fire correctly — `console.keyMap` alone is not enough.
- **Super key name**: Use `"meta_l"` not `"super"` for the Super/Mod4 key in `send_key()`. Example: `machine.send_key("meta_l-t")` triggers `Mod4+t`.
- **`agenix` failures**: Decryption errors are expected — the VM lacks host secret keys.
- **`vde_plug2tap` warnings**: Non-fatal, can be ignored.
- **No reboot needed between commands**: The VM stays running. Send as many commands as you need.
- **Screenshots**: Always use absolute paths under `/tmp/` (e.g. `/tmp/shot.png`). Relative paths write to the current working directory of the test driver (typically the flake root).
- **Validation standard**: For tasks about desktop runtime behavior, use the VM to validate the final state after your code change, not just the hypothesis before editing.
- **DNS false positives via slirp**: The VM's eth0 DNS (10.0.2.3, QEMU slirp) forwards to the **host's** resolver. A name that only the host can resolve (e.g. a host-local dnsmasq zone) still resolves inside the VM through that path, masking broken in-VM DNS routing. When validating DNS config, check *where* the answer came from (`resolvectl query` prints `-- link: ...`; or query the in-VM server directly), not just that a name resolves.

## Keeping this skill up to date

If you discover new test patterns, useful machine methods, gotchas, or workarounds while using this VM harness — especially if you had to retry several times before finding a working approach — **update this skill file** with what you learned. Future agents (including yourself in later conversations) will benefit from those lessons. Examples of things worth adding:

- A method or technique that wasn't obvious but turned out to be the right way
- A failure mode you hit repeatedly before finding the fix
- Timing or ordering constraints that aren't documented above
- New `machine.*` methods or `socat` patterns that proved useful
