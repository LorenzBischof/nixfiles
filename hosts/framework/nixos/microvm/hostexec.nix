{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.my.microvmHostExec;
  vmCidMap =
    lib.pipe (lib.attrByPath [ "my" "microvms" ] { } config) [
      (lib.mapAttrs (name: vm: vm.vsockCid or null))
      (lib.filterAttrs (_: cid: cid != null))
    ];

  defaultAllowedCids =
    lib.pipe (lib.attrValues (lib.attrByPath [ "my" "microvms" ] { } config)) [
      (map (vm: vm.vsockCid or null))
      (lib.filter (cid: cid != null))
      lib.unique
      (lib.sort builtins.lessThan)
    ];

  promptScript = pkgs.writeShellApplication {
    name = "microvm-hostexec-prompt";
    runtimeInputs = with pkgs; [
      zenity
    ];
    text = ''
      set -euo pipefail

      request_id="$1"
      source_cid="$2"
      cmd="$3"
      timeout_sec="$4"

      message="$(printf 'Edit the command to run on the host as ${cfg.approverUser}.\n\nRequest: %s\nSource CID: %s' "$request_id" "$source_cid")"

      edited="$(${pkgs.zenity}/bin/zenity \
        --entry \
        --title="MicroVM Host Exec Approval" \
        --width=1000 \
        --ok-label="Run" \
        --cancel-label="Deny" \
        --timeout="$timeout_sec" \
        --text="$message" \
        --entry-text="$cmd")" || exit 1

      printf '%s\n' "$edited"
    '';
  };

  vsockServerScript = pkgs.writeShellApplication {
    name = "microvm-hostexec-vsock-server";
    runtimeInputs = with pkgs; [
      python3
      systemd
      util-linux
    ];
    text = ''
      set -euo pipefail

      export HOSTEXEC_VSOCK_PORT='${toString cfg.listenPort}'
      export HOSTEXEC_MAX_REQUEST_BYTES='${toString cfg.maxCommandBytes}'
      export HOSTEXEC_MAX_OUTPUT_BYTES='${toString cfg.maxOutputBytes}'
      export HOSTEXEC_EXEC_TIMEOUT_SECONDS='${toString cfg.executionTimeoutSeconds}'
      export HOSTEXEC_ALLOWED_CIDS='${lib.concatMapStringsSep "," toString cfg.allowedCids}'
      export HOSTEXEC_VM_CID_MAP='${lib.concatMapStringsSep "," (name: "${name}:${toString vmCidMap.${name}}") (lib.attrNames vmCidMap)}'
      export HOSTEXEC_VM_STATE_BASE='/var/lib/microvms'
      export HOSTEXEC_APPROVER_USER='${cfg.approverUser}'
      export HOSTEXEC_PROMPT_SCRIPT='${lib.getExe promptScript}'
      export HOSTEXEC_PROMPT_TIMEOUT_SECONDS='${toString cfg.promptTimeoutSeconds}'

      exec ${pkgs.python3}/bin/python3 - <<'PY'
import json
import glob
import os
import pwd
import selectors
import shlex
import socket
import subprocess
import syslog
import threading
import time
import traceback
import uuid

PORT = int(os.environ["HOSTEXEC_VSOCK_PORT"])
MAX_REQUEST_BYTES = int(os.environ["HOSTEXEC_MAX_REQUEST_BYTES"])
MAX_OUTPUT_BYTES = int(os.environ["HOSTEXEC_MAX_OUTPUT_BYTES"])
EXEC_TIMEOUT_SECONDS = int(os.environ["HOSTEXEC_EXEC_TIMEOUT_SECONDS"])
VM_CID_MAP_RAW = os.environ.get("HOSTEXEC_VM_CID_MAP", "")
VM_STATE_BASE = os.environ.get("HOSTEXEC_VM_STATE_BASE", "/var/lib/microvms")
ALLOWED_CIDS = {
    int(x)
    for x in os.environ["HOSTEXEC_ALLOWED_CIDS"].split(",")
    if x.strip()
}
APPROVER_USER = os.environ["HOSTEXEC_APPROVER_USER"]
PROMPT_SCRIPT = os.environ["HOSTEXEC_PROMPT_SCRIPT"]
PROMPT_TIMEOUT_SECONDS = int(os.environ["HOSTEXEC_PROMPT_TIMEOUT_SECONDS"])

syslog.openlog("microvm-hostexec", syslog.LOG_PID, syslog.LOG_DAEMON)

APPROVAL_SEMAPHORE = threading.Semaphore(1)


def parse_vm_cid_map(raw: str) -> dict[str, int]:
    result: dict[str, int] = {}
    if not raw.strip():
        return result
    for entry in raw.split(","):
        if not entry:
            continue
        parts = entry.split(":", 1)
        if len(parts) != 2:
            continue
        name = parts[0].strip()
        cid_raw = parts[1].strip()
        if not name or not cid_raw:
            continue
        try:
            result[name] = int(cid_raw)
        except ValueError:
            continue
    return result


VM_CID_MAP = parse_vm_cid_map(VM_CID_MAP_RAW)


def log_line(message: str) -> None:
    syslog.syslog(syslog.LOG_INFO, message)


def error_response(exit_code: int, error: str) -> dict:
    return {"ok": False, "exit_code": exit_code, "error": error}


def run_limited(argv: list[str], timeout_seconds: int, max_output_bytes: int) -> tuple[int, bytes, bytes, bool, bool]:
    proc = subprocess.Popen(
        argv,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )

    assert proc.stdout is not None
    assert proc.stderr is not None

    os.set_blocking(proc.stdout.fileno(), False)
    os.set_blocking(proc.stderr.fileno(), False)

    sel = selectors.DefaultSelector()
    sel.register(proc.stdout, selectors.EVENT_READ, "stdout")
    sel.register(proc.stderr, selectors.EVENT_READ, "stderr")

    out_buf = bytearray()
    err_buf = bytearray()
    total = 0
    timed_out = False
    output_truncated = False
    deadline = time.monotonic() + timeout_seconds

    while sel.get_map():
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            timed_out = True
            proc.kill()
            break

        events = sel.select(timeout=min(0.5, remaining))
        if not events:
            if proc.poll() is not None:
                break
            continue

        for key, _ in events:
            try:
                chunk = key.fileobj.read(4096)
            except Exception:
                chunk = b""

            if not chunk:
                try:
                    sel.unregister(key.fileobj)
                except Exception:
                    pass
                continue

            remaining_capacity = max_output_bytes - total
            if remaining_capacity <= 0:
                output_truncated = True
                proc.kill()
                break

            clipped = chunk[:remaining_capacity]
            if key.data == "stdout":
                out_buf.extend(clipped)
            else:
                err_buf.extend(clipped)
            total += len(clipped)

            if len(clipped) < len(chunk):
                output_truncated = True
                proc.kill()
                break

        if output_truncated:
            break

    if timed_out or output_truncated:
        try:
            proc.wait(timeout=2)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait(timeout=2)
    else:
        proc.wait()

    if timed_out:
        return 124, bytes(out_buf), bytes(err_buf), True, False
    if output_truncated:
        return 76, bytes(out_buf), bytes(err_buf), False, True
    return proc.returncode, bytes(out_buf), bytes(err_buf), False, False


def find_sessions_for_user(username: str) -> list[str]:
    p = subprocess.run(
        ["loginctl", "list-sessions", "--no-legend"],
        capture_output=True,
        text=True,
        check=False,
    )
    sessions: list[str] = []
    for line in p.stdout.splitlines():
        parts = line.split()
        if len(parts) >= 3 and parts[2] == username:
            sessions.append(parts[0])
    return sessions


def read_session_env(session_id: str) -> dict[str, str] | None:
    p = subprocess.run(
        ["loginctl", "show-session", session_id, "-p", "Leader", "--value"],
        capture_output=True,
        text=True,
        check=False,
    )
    leader = p.stdout.strip()
    if not leader or not leader.isdigit() or leader == "0":
        return None
    env_path = f"/proc/{leader}/environ"
    try:
        raw = open(env_path, "rb").read()
    except OSError:
        return None

    env = {}
    for entry in raw.split(b"\0"):
        if not entry or b"=" not in entry:
            continue
        k, v = entry.split(b"=", 1)
        env[k.decode("utf-8", errors="ignore")] = v.decode("utf-8", errors="ignore")
    return env


def resolve_login_path(username: str) -> str:
    p = subprocess.run(
        ["runuser", "-l", username, "-c", "printf %s \"$PATH\""],
        capture_output=True,
        text=True,
        check=False,
    )
    if p.returncode != 0:
        return ""
    return p.stdout.strip()


def request_approval(request_id: str, source_cid: int, display_cmd: str) -> tuple[bool, str, str, str]:
    session_ids = find_sessions_for_user(APPROVER_USER)
    wayland_display = ""
    display_value = ""
    xauthority = ""
    path_value = ""
    selected_session = ""
    for session_id in session_ids:
        env = read_session_env(session_id)
        if env is None:
            continue
        candidate_wayland = env.get("WAYLAND_DISPLAY", "")
        candidate_display = env.get("DISPLAY", "")
        if not candidate_wayland and not candidate_display:
            continue
        wayland_display = candidate_wayland
        display_value = candidate_display
        xauthority = env.get("XAUTHORITY", "")
        path_value = env.get("PATH", "")
        selected_session = session_id
        break

    approver_uid = pwd.getpwnam(APPROVER_USER).pw_uid
    xdg_runtime_dir = f"/run/user/{approver_uid}"
    if not selected_session:
        wayland_sockets = sorted(glob.glob(f"{xdg_runtime_dir}/wayland-*"))
        if wayland_sockets:
            wayland_display = os.path.basename(wayland_sockets[0])
            selected_session = "fallback-wayland-socket"
    if not selected_session:
        return False, "no-display-env", "", ""

    if not path_value:
        path_value = resolve_login_path(APPROVER_USER)

    prompt_env = {
        "XDG_RUNTIME_DIR": xdg_runtime_dir,
        "DBUS_SESSION_BUS_ADDRESS": f"unix:path={xdg_runtime_dir}/bus",
    }
    if wayland_display:
        prompt_env["WAYLAND_DISPLAY"] = wayland_display
    if display_value:
        prompt_env["DISPLAY"] = display_value
    if xauthority:
        prompt_env["XAUTHORITY"] = xauthority

    env_args = [f"{k}={v}" for k, v in prompt_env.items()]
    try:
        p = subprocess.run(
            [
                "runuser",
                "-u",
                APPROVER_USER,
                "--",
                "env",
                *env_args,
                PROMPT_SCRIPT,
                request_id,
                str(source_cid),
                display_cmd,
                str(PROMPT_TIMEOUT_SECONDS),
            ],
            capture_output=True,
            text=True,
            check=False,
            timeout=PROMPT_TIMEOUT_SECONDS + 5,
        )
    except subprocess.TimeoutExpired:
        return False, "prompt-timeout", "", path_value
    edited_cmd = p.stdout.rstrip("\r\n")
    return (p.returncode == 0), "approve" if p.returncode == 0 else "deny", edited_cmd, path_value


def handle_connection(
    conn: socket.socket,
    addr: tuple[int, int],
    source_cid_override: int | None = None,
    transport: str = "af-vsock",
) -> None:
    with conn:
        request_id = str(uuid.uuid4())
        if source_cid_override is None:
            try:
                source_cid = int(addr[0])
            except Exception:
                source_cid = -1
        else:
            source_cid = source_cid_override

        try:
            data = b""
            payload = None
            while True:
                chunk = conn.recv(4096)
                if not chunk:
                    break
                if len(data) + len(chunk) > MAX_REQUEST_BYTES:
                    response = error_response(73, f"request too large (max {MAX_REQUEST_BYTES} bytes)")
                    conn.sendall((json.dumps(response) + "\n").encode("utf-8"))
                    return
                data += chunk
                if b"\n" in data:
                    candidate = data.split(b"\n", 1)[0]
                    try:
                        payload = json.loads(candidate.decode("utf-8").strip())
                        break
                    except Exception:
                        response = error_response(74, "request must be UTF-8 JSON")
                        conn.sendall((json.dumps(response) + "\n").encode("utf-8"))
                        return
                try:
                    payload = json.loads(data.decode("utf-8").strip())
                    break
                except json.JSONDecodeError:
                    # Likely partial JSON; keep reading.
                    pass
                except Exception:
                    response = error_response(74, "request must be UTF-8 JSON")
                    conn.sendall((json.dumps(response) + "\n").encode("utf-8"))
                    return

            if payload is None:
                try:
                    payload = json.loads(data.decode("utf-8").strip())
                except Exception:
                    response = error_response(74, "request must be UTF-8 JSON")
                    conn.sendall((json.dumps(response) + "\n").encode("utf-8"))
                    return

            if not isinstance(payload, dict):
                response = error_response(74, "request must be a JSON object")
                conn.sendall((json.dumps(response) + "\n").encode("utf-8"))
                return

            argv = payload.get("argv")
            if not isinstance(argv, list) or len(argv) == 0 or not all(isinstance(x, str) for x in argv):
                response = error_response(74, "request must include non-empty string array field 'argv'")
                conn.sendall((json.dumps(response) + "\n").encode("utf-8"))
                return

            if source_cid not in ALLOWED_CIDS:
                log_line(
                    f"request={request_id} phase=deny transport={transport} "
                    f"reason=cid-not-allowed source_cid={source_cid}"
                )
                response = error_response(65, f"source CID is not allowed: {source_cid}")
                conn.sendall((json.dumps(response) + "\n").encode("utf-8"))
                return

            display_cmd = shlex.join(argv)
            log_line(
                f"request={request_id} phase=request transport={transport} "
                f"source_cid={source_cid} cmd={display_cmd}"
            )

            if not APPROVAL_SEMAPHORE.acquire(blocking=False):
                log_line(f"request={request_id} phase=deny reason=prompt-busy source_cid={source_cid}")
                response = error_response(72, "another approval prompt is active; try again")
                conn.sendall((json.dumps(response) + "\n").encode("utf-8"))
                return
            try:
                approved, reason, edited_cmd, approved_path = request_approval(request_id, source_cid, display_cmd)
            finally:
                APPROVAL_SEMAPHORE.release()
            if not approved:
                log_line(f"request={request_id} phase=deny reason={reason} approver={APPROVER_USER}")
                response = error_response(72, "request denied")
                conn.sendall((json.dumps(response) + "\n").encode("utf-8"))
                return

            log_line(f"request={request_id} phase=approve approver={APPROVER_USER}")

            if not edited_cmd:
                log_line(f"request={request_id} phase=deny reason=empty-edited-command approver={APPROVER_USER}")
                response = error_response(77, "edited command is empty")
                conn.sendall((json.dumps(response) + "\n").encode("utf-8"))
                return

            if len(edited_cmd.encode("utf-8")) > MAX_REQUEST_BYTES:
                log_line(f"request={request_id} phase=deny reason=edited-command-too-large approver={APPROVER_USER}")
                response = error_response(73, f"edited command too large (max {MAX_REQUEST_BYTES} bytes)")
                conn.sendall((json.dumps(response) + "\n").encode("utf-8"))
                return

            try:
                approved_argv = shlex.split(edited_cmd, posix=True)
            except ValueError:
                log_line(f"request={request_id} phase=deny reason=invalid-edited-command approver={APPROVER_USER}")
                response = error_response(74, "edited command parsing failed")
                conn.sendall((json.dumps(response) + "\n").encode("utf-8"))
                return

            if not approved_argv:
                log_line(f"request={request_id} phase=deny reason=empty-edited-argv approver={APPROVER_USER}")
                response = error_response(77, "edited command is empty")
                conn.sendall((json.dumps(response) + "\n").encode("utf-8"))
                return

            if approved_path:
                run_argv = ["runuser", "-u", APPROVER_USER, "--", "env", f"PATH={approved_path}", *approved_argv]
            else:
                run_argv = ["runuser", "-u", APPROVER_USER, "--", *approved_argv]
            rc, out_b, err_b, timed_out, output_truncated = run_limited(
                run_argv,
                timeout_seconds=EXEC_TIMEOUT_SECONDS,
                max_output_bytes=MAX_OUTPUT_BYTES,
            )

            if rc == 0:
                log_line(f"request={request_id} phase=execute-end status=ok")
            else:
                extra = ""
                if timed_out:
                    extra = " timed_out=true"
                if output_truncated:
                    extra = f"{extra} output_truncated=true".strip()
                    if extra and not extra.startswith(" "):
                        extra = " " + extra
                log_line(f"request={request_id} phase=execute-end status=error rc={rc}{extra}")

            response = {
                "ok": rc == 0,
                "exit_code": rc,
                "stdout": out_b.decode("utf-8", errors="replace"),
                "stderr": err_b.decode("utf-8", errors="replace"),
                "timed_out": timed_out,
                "output_truncated": output_truncated,
            }
            conn.sendall((json.dumps(response) + "\n").encode("utf-8"))
        except Exception as exc:
            trace = traceback.format_exc().strip().replace("\n", "\\n")
            log_line(
                f"request={request_id} phase=error transport={transport} "
                f"source_cid={source_cid} "
                f"error={type(exc).__name__}:{exc} traceback={trace}"
            )
            response = error_response(70, "hostexec internal error")
            try:
                conn.sendall((json.dumps(response) + "\n").encode("utf-8"))
            except Exception:
                pass


def serve_af_vsock() -> None:
    cid_any = getattr(socket, "VMADDR_CID_ANY", 4294967295)
    with socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM) as server:
        server.bind((cid_any, PORT))
        server.listen(128)
        log_line(f"phase=listen transport=af-vsock port={PORT}")
        while True:
            conn, addr = server.accept()
            thread = threading.Thread(
                target=handle_connection,
                args=(conn, addr, None, "af-vsock"),
                daemon=True,
            )
            thread.start()


def cloud_hypervisor_socket_path(vm_name: str) -> str:
    return os.path.join(VM_STATE_BASE, vm_name, f"notify.vsock_{PORT}")


def serve_cloud_hypervisor_vm(vm_name: str, source_cid: int) -> None:
    path = cloud_hypervisor_socket_path(vm_name)
    vm_dir = os.path.dirname(path)
    while True:
        if not os.path.isdir(vm_dir):
            time.sleep(1)
            continue
        try:
            if os.path.exists(path):
                os.unlink(path)
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as server:
                server.bind(path)
                os.chmod(path, 0o666)
                server.listen(128)
                log_line(
                    f"phase=listen transport=ch-vsock vm={vm_name} "
                    f"source_cid={source_cid} path={path}"
                )
                while True:
                    conn, _ = server.accept()
                    thread = threading.Thread(
                        target=handle_connection,
                        args=(conn, (source_cid, PORT), source_cid, "ch-vsock"),
                        daemon=True,
                    )
                    thread.start()
        except Exception as exc:
            log_line(
                f"phase=listener-error transport=ch-vsock vm={vm_name} "
                f"source_cid={source_cid} error={type(exc).__name__}:{exc}"
            )
            time.sleep(1)


def serve() -> None:
    started_backends = 0

    if hasattr(socket, "AF_VSOCK"):
        thread = threading.Thread(target=serve_af_vsock, daemon=True)
        thread.start()
        started_backends += 1
    else:
        log_line("phase=backend-skip transport=af-vsock reason=unsupported")

    for vm_name, source_cid in VM_CID_MAP.items():
        thread = threading.Thread(
            target=serve_cloud_hypervisor_vm,
            args=(vm_name, source_cid),
            daemon=True,
        )
        thread.start()
        started_backends += 1

    if started_backends == 0:
        log_line("phase=fatal reason=no-listener-backends")
        raise RuntimeError("no listener backends available")

    while True:
        time.sleep(3600)


if __name__ == "__main__":
    serve()
PY
    '';
  };
in
{
  options.my.microvmHostExec = {
    enable = lib.mkEnableOption "manual host command approval bridge for microVM agents over vsock";

    approverUser = lib.mkOption {
      type = lib.types.str;
      default = "lbischof";
      description = "Host user that receives GUI approval prompts and executes approved commands.";
    };

    listenPort = lib.mkOption {
      type = lib.types.port;
      default = 40555;
      description = "AF_VSOCK port on the host listener.";
    };

    promptTimeoutSeconds = lib.mkOption {
      type = lib.types.int;
      default = 45;
      description = "GUI approval timeout in seconds.";
    };

    executionTimeoutSeconds = lib.mkOption {
      type = lib.types.int;
      default = 120;
      description = "Maximum runtime for an approved command in seconds.";
    };

    maxCommandBytes = lib.mkOption {
      type = lib.types.int;
      default = 8192;
      description = "Maximum incoming request payload size in bytes.";
    };

    maxOutputBytes = lib.mkOption {
      type = lib.types.int;
      default = 262144;
      description = "Maximum combined stdout+stderr bytes returned to the VM.";
    };

    allowedCids = lib.mkOption {
      type = lib.types.listOf lib.types.int;
      default = defaultAllowedCids;
      description = ''
        Allowed MicroVM CID values that may request host execution.
        By default this is derived from `my.microvms.*.vsockCid`.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.promptTimeoutSeconds > 0;
        message = "my.microvmHostExec.promptTimeoutSeconds must be > 0.";
      }
      {
        assertion = cfg.executionTimeoutSeconds > 0;
        message = "my.microvmHostExec.executionTimeoutSeconds must be > 0.";
      }
      {
        assertion = cfg.maxCommandBytes > 0;
        message = "my.microvmHostExec.maxCommandBytes must be > 0.";
      }
      {
        assertion = cfg.maxOutputBytes > 0;
        message = "my.microvmHostExec.maxOutputBytes must be > 0.";
      }
      {
        assertion = cfg.allowedCids != [ ];
        message = "my.microvmHostExec.allowedCids is empty; refusing to expose host exec bridge without CID allowlist.";
      }
    ];

    systemd.services.microvm-hostexec-vsock = {
      description = "MicroVM host exec approval broker over AF_VSOCK";
      wantedBy = [ "multi-user.target" ];
      after = [ "systemd-user-sessions.service" ];
      serviceConfig = {
        Type = "simple";
        ExecStart = lib.getExe vsockServerScript;
        Restart = "always";
        RestartSec = "1s";
      };
    };
  };
}
