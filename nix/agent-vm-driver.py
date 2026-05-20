"""
Agent-VM driver: hosts a Python REPL over a Unix socket so external tools can
drive the running VM via the NixOS test driver `machine` API.

This file is read verbatim into the testScript of a runNixOSTest by
mkAgentVm in flake.nix. The Nix wrapper prepends `SOCKET_NAME = "...";`.

Trust boundary: the socket lives in $XDG_RUNTIME_DIR (user-private). Running
`eval`/`exec` against arbitrary input is intentional — only the owning user
can connect.

Wire protocol (line-delimited; many round-trips per connection):
  Request  : one line of Python (expression OR statement(s)).
  Response : one line of JSON, either
               {"ok": true,  "result": <repr|null>}
             or
               {"ok": false, "error":  <traceback>}
"""

import json
import os
import socket
import traceback
from pathlib import Path

start_all()

NS = globals()  # shared REPL namespace; `machine`, `nodes`, ... live here

def _evaluate(src):
    try:
        return eval(compile(src, "<agent>", "eval"), NS)
    except SyntaxError:
        exec(compile(src, "<agent>", "exec"), NS)
        return None

runtime_dir = os.environ.get("XDG_RUNTIME_DIR", "/tmp")
sock_path = Path(runtime_dir) / SOCKET_NAME
sock_path.unlink(missing_ok=True)

srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
try:
    srv.bind(str(sock_path))
    srv.listen(1)
    while True:
        conn, _ = srv.accept()
        with conn:
            for raw_line in conn.makefile("r"):
                line = raw_line.rstrip("\n")
                if not line:
                    continue
                try:
                    value = _evaluate(line)
                    resp = {"ok": True, "result": None if value is None else repr(value)}
                except SystemExit:
                    raise
                except BaseException as e:
                    # format_exception_only drops the call stack and our internal
                    # eval/exec frames, leaving just the exception type + message
                    # (and for SyntaxError, the source location + caret).
                    resp = {"ok": False, "error": "".join(traceback.format_exception_only(type(e), e)).rstrip()}
                conn.sendall((json.dumps(resp) + "\n").encode())
finally:
    srv.close()
    sock_path.unlink(missing_ok=True)
