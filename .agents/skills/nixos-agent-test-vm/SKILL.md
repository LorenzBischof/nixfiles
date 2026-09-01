---
name: nixos-agent-test-vm
description: Test NixOS configuration changes in an isolated, session-scoped agent VM. Use when validating a NixOS change at runtime, reusing a VM within one agent session, applying a new configuration without rebooting, setting up the VM harness for a host, or updating this skill.
---

# Test NixOS VM

This skill describes a VM harness that boots a real NixOS host configuration inside QEMU. Reuse the VM for fast iterations within one agent session, isolate it from other agents by session ID, and always stop it before finishing the task.

The harness is provided by the [`nixos-agent-test-vm`](https://github.com/lorenzbischof/nixos-agent-test-vm) flake: the consuming flake adds it as an input and exposes one `apps.<system>.<host>-agent-vm` attribute per host it wants to drive. **If `nix run .#<host>-agent-vm` doesn't exist yet for the host you want to test, read [SETUP.md](SETUP.md) to wire it up; otherwise stay here.**

> Examples below use `framework` as the host name. Substitute your own host wherever you see it.

> **Checking / refreshing this skill.** `check.sh` from this skill's directory (e.g. `.claude/skills/nixos-agent-test-vm/check.sh`) is a read-only probe: it prints `ok` (exit 0) when the vendored copy matches the `nixos-agent-test-vm` revision pinned in their `flake.lock`, or `stale` (exit 1) when it doesn't. It changes nothing, so run it freely — at the start of a VM session if the user has recently run `nix flake update`, or whenever the user asks whether the skill is current; skip it on routine VM interactions. If it reports `stale`, refreshing **overwrites the vendored files**, so only run `check.sh --refresh` yourself once the user asks or grants permission; afterward ask them to commit the result.

Use the upstream NixOS test documentation as the canonical reference for test-driver behavior and `machine.*` APIs:

- https://nixos.org/manual/nixos/unstable/#sec-nixos-tests

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
vm_socket="$XDG_RUNTIME_DIR/framework-agent-vm-$session_key/framework-agent-vm.sock"

printf '%s\n' 'machine.process is not None and machine.process.poll() is None' \
  | socat -t 5 - UNIX-CONNECT:"$vm_socket"
```

If that succeeds with `{"ok": true, "result": "True"}`, reuse this session's VM. This checks the host-side QEMU process without waiting for a guest shell. Never attach to a socket from a different session.

Only when the probe fails, start the VM:

```bash
nix run .#framework-agent-vm -- start

printf '%s\n' 'machine.wait_for_unit("default.target")' \
  | socat -t 120 - UNIX-CONNECT:"$vm_socket"
```

`start` is idempotent within the session and prints its socket and log paths. It detaches a new VM when needed and waits for the control socket. Use `nix run .#framework-agent-vm -- run` only when a foreground driver is useful for debugging.

## Using the test driver

Interact with the NixOS test driver by sending one complete Python program per socket connection. Write-side EOF marks the end of the program and the server replies with one JSON object. Use a quoted heredoc for anything non-trivial so Bash passes quotes, newlines, and indentation through unchanged:

```bash
socat -t 120 - UNIX-CONNECT:"$vm_socket" <<'PY'
code, out = machine.execute("hostname")
assert code == 0, out
out
PY
# {"ok": true, "result": "'framework\\n'"}
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
- `machine.execute("false")` returns a non-zero status rather than raising. Check it with `assert code == 0, out`, or deliberately use `machine.succeed(...)` when exception-on-failure semantics are convenient.
- `SystemExit` is intentionally not caught because the lifecycle runner uses it to stop the VM.
- `socat` reports transport success even if the response contains `ok: false`. Inspect `.ok` when a shell command must fail on a Python error: `response="$(...)"; jq -e '.ok == true' <<<"$response"`.
- State persists across connections. This is useful for helper functions and variables, but a failed program can leave state created before the failing statement.

The `machine` object exposed here is the standard NixOS test driver machine object. Prefer the upstream docs for the full API; the table below lists the methods that are most useful in practice.

## Interaction patterns

A few patterns that proved useful in practice:

- **Prefer `machine.execute(cmd)` for shell commands.** It returns `(exit, output)`, which makes both success and failure easy to inspect. Assert the status in the same program and leave the desired value as the final expression. To suppress output when you do not need it, discard it with `code, _ = ...`.
- **Send one readable Python cell.** Avoid semicolons and nested shell quoting:

  ```bash
  socat -t 60 - UNIX-CONNECT:"$vm_socket" <<'PY'
  code, out = machine.execute(
      "systemctl show -p ExecStart some.service"
  )
  assert code == 0, out
  out.split("path=")[1].split(";")[0]
  PY
  ```

- **For human reading, use `jq -r 'if .ok then .result else .error end'`.** On success this gives the final expression's `repr`; on failure it renders the multiline traceback. For programmatic success values, extract `.result` and use `ast.literal_eval()` to round-trip the representation.
- **Long-running programs**: pass a higher `-t N` to `socat` (e.g. `-t 300` for a service start that hits the network); the server waits as long as the Python needs.

### Reserved names — do NOT use as variables

The persistent execution namespace contains the native test-driver symbols but is separate from the socket server's own globals. Most assignments therefore cannot corrupt the server. Still avoid replacing the objects that lifecycle operations use:

- `machine`, `nodes` — the test-driver objects you are trying to use; `machine` is also used by lifecycle probes and `apply`.
- `SystemExit` — used by the lifecycle runner to shut down the driver.

Use ordinary local names such as `code`, `out`, and `result`.

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

## Apply configuration changes without rebooting

After editing the NixOS configuration, keep QEMU running and activate the new VM toplevel:

```bash
nix run .#framework-agent-vm -- apply
```

This builds the current test configuration and runs its `switch-to-configuration test` inside the existing guest. It is the default edit/test loop for packages, services, desktop settings, users, and other runtime-switchable configuration. The guest state and graphical session survive between iterations.

After `apply`, verify the changed unit or behavior directly. If the activation stops or replaces a graphical session, wait for `graphical.target` and the relevant display-manager/session unit again before interacting with the GUI.

### Restart only when required

Use one clean restart when the test depends on kernel, initrd, bootloader, filesystems, QEMU/virtualisation settings, early boot, or state that an in-place activation may preserve. Also restart if `apply` reports an incompatible init interface or the result looks contaminated by earlier imperative testing:

```bash
nix run .#framework-agent-vm -- stop
nix run .#framework-agent-vm -- start
```

After a restart, continue using the same session ID and socket path.

## Mandatory cleanup

Stop this session's VM as the final tool action before replying to the user, including after failed validation or an interrupted approach:

```bash
nix run .#framework-agent-vm -- stop
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

## Launching Wayland Applications

Commands run through `machine.succeed()` execute outside the logged-in graphical session. To launch GUI apps with the same environment as the real desktop, open a terminal in the session and type the command there. Example for a Sway host with a `Mod4+t` terminal binding:

```bash
echo 'machine.send_key("meta_l-t")' \
  | socat -t 120 - UNIX-CONNECT:"$vm_socket"

echo 'machine.send_chars("logseq\n")' \
  | socat -t 120 - UNIX-CONNECT:"$vm_socket"
```

## Gotchas

- **Keyboard layout**: The harness forces `console.keyMap = "us"` so `send_chars()` produces predictable keys regardless of the host's real keymap. If the host runs Sway/X11 with a non-US XKB layout, that layout must also be forced to `us` in the VM's `extraConfig` for keybindings to fire correctly — `console.keyMap` alone is not enough.
- **Super key name**: Use `"meta_l"` not `"super"` for the Super/Mod4 key in `send_key()`. Example: `machine.send_key("meta_l-t")` triggers `Mod4+t`.
- **`agenix` failures**: Decryption errors are expected — the VM lacks host secret keys.
- **`vde_plug2tap` warnings**: Non-fatal, can be ignored.
- **Session isolation**: Keep the same session ID throughout one task. Different IDs are safe to run concurrently; the same ID intentionally addresses the same VM.
- **Subagents in one thread**: If several agents share a thread-level session variable, give each one a unique `AGENT_VM_SESSION`; automatic `CODEX_THREAD_ID` isolation applies between independent threads.
- **Reuse before rebuild**: Probe this session's socket first. Do not invoke `nix run ... start` merely to discover whether it exists.
- **One program per connection**: Do not expect multiple responses from one socket connection. Put related statements in one Python program or open another connection; the namespace persists either way.
- **Hot apply is not a boot test**: Use `apply` for fast iterations, then restart when the behavior under test depends on boot-time state.
- **No reboot needed between commands**: The VM stays running across commands within the current agent session only.
- **Screenshots**: Always use absolute paths under `/tmp/` (e.g. `/tmp/shot.png`). Relative paths write to the current working directory of the test driver (typically the flake root).
- **Validation standard**: For tasks about desktop runtime behavior, apply the final Nix configuration and validate the final state in the VM, not just the hypothesis before editing.

## Keeping this skill up to date

If you discover new test patterns, useful machine methods, gotchas, or workarounds while using this VM harness — especially if you had to retry several times before finding a working approach — **update this skill file** with what you learned. Future agents (including yourself in later conversations) will benefit from those lessons. Examples of things worth adding:

- A method or technique that wasn't obvious but turned out to be the right way
- A failure mode you hit repeatedly before finding the fix
- Timing or ordering constraints that aren't documented above
- New `machine.*` methods or `socat` patterns that proved useful
