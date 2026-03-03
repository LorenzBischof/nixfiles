# MicroVM Host Exec Approval Bridge

This doc keeps only operator-relevant behavior that is easy to miss in code.

## What it does

- Allows a VM to request host command execution through `hostexec`.
- Requires manual GUI approval (`zenity`) on the host for each request.
- Runs approved commands as `my.microvmHostExec.approverUser` (default: `lbischof`).
- Enforces request size, runtime timeout, output cap, and CID allowlist.

## Transport and listeners

- Main listener: AF_VSOCK on `my.microvmHostExec.listenPort` (default `40555`).
- Also starts per-VM Cloud Hypervisor socket listeners derived from `my.microvms.*.vsockCid`.
- Host service: `microvm-hostexec-vsock.service`.

## VM usage

```bash
hostexec -- id
hostexec --json -- id
```

Approval UI allows editing the command before execution.

## Response shape

- Success/exec response fields:
  - `ok`
  - `exit_code`
  - `stdout`
  - `stderr`
  - `timed_out`
  - `output_truncated`
- Validation/deny/internal error responses include:
  - `ok: false`
  - `exit_code`
  - `error`

## Useful logs

```bash
journalctl -u microvm-hostexec-vsock -n 200 --no-pager
journalctl -t microvm-hostexec -n 200 --no-pager
```

## Source of truth

- Module and server implementation:
  `hosts/framework/nixos/microvm/hostexec.nix`
- VM client CLI (`hostexec`) wiring:
  `hosts/framework/nixos/microvm/base.nix`
- Feature enablement in framework host:
  `hosts/framework/nixos/microvm/config.nix`
