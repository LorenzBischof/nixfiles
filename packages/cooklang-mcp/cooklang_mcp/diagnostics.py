"""What the Cooklang parser makes of a file, as the language server reports it.

`cook server` keeps its parse report to itself. A file with a warning in it is
served as though it were clean — the warning goes to the server's own stderr —
and one with an error answers `500` with the message formatted for a terminal,
absolute path and all. Neither reaches a caller as something to act on.

The same report is available in a usable shape, because `cook server` bridges a
`cook lsp` subprocess onto `GET /api/ws/lsp`, and the language server publishes
exactly the parser's own errors and warnings as LSP diagnostics: spans turned
into ranges, nothing added and nothing dropped (cooklang-language-server,
`src/diagnostics.rs`). So this module is a one-document LSP client — open the
file, take the single `publishDiagnostics` that follows, close.

**This whole module is a workaround for a missing field.** Nothing but the
absence of the report on `GET`/`PUT /api/recipes/*path` justifies 100 lines of
LSP client and a `websockets` dependency to learn something the server already
knew. If upstream ever puts the parse report in those responses — the obvious
shapes being a `report` field beside `recipe`, or a JSON body on the 500 —
delete this module, ask `cookcli.request` for the report, and keep only the
mapping into `Diagnostic`. No upstream issue asks for it yet.

Three things about the bridge decide the shape of what is below
(cookcli, `src/server/lsp_bridge.rs`):

* it rewrites `initialize` to pin the workspace root at the collection it
  serves, and does so by reaching into `params`. A message whose `params` is
  absent, or is an array, is *dropped* — silently — so `initialize` has to
  carry an object even though nothing in it is needed;
* it speaks bare JSON-RPC over the socket and adds the `Content-Length`
  framing on the way to the subprocess, so nothing here has to;
* it spawns one `cook lsp` per socket, capped by `--max-lsp-sessions` (eight)
  and refused with `503` past that. Hence one short-lived socket per write,
  closed as soon as the diagnostics are in, rather than a session held open
  between calls. That spawn is ~48 ms of a ~58 ms write, and the rest of the
  write is four loopback requests of 2-4 ms each: if this ever needs to be
  faster, the subprocess is the only thing worth attacking.

The language server parses with every extension enabled, while `cook server`
parses the collection with its own narrower set, so a diagnostic can in
principle name something the collection itself accepts — upstream's to
reconcile (cookcli#643 is one instance), and reporting the parser's own words
is still better than dropping them.
"""

from __future__ import annotations

import asyncio
import json
from typing import Any, Callable, Literal
from urllib.parse import quote

import websockets
from pydantic import BaseModel, Field

from . import cookcli as cook

LSP_PATH = "/api/ws/lsp"

# What the language server calls the language, and the only id it answers to.
LANGUAGE_ID = "cooklang"

# Five messages against a process on the same host. The budget is for a
# subprocess that fails to start or never answers: a write must not hang on its
# own check.
TIMEOUT = 15.0


class DiagnosticsUnavailable(RuntimeError):
    """The language server could not be reached, or did not answer in time."""


class Diagnostic(BaseModel):
    """One thing the Cooklang parser said about a file it was given."""

    severity: Literal["error", "warning"] = Field(
        description=(
            "`error` means the file does not parse: its page shows the error "
            "in place of the recipe, and nothing in it reaches the shopping "
            "list until it is fixed. `warning` means the file parsed with "
            "something the parser flagged — usually a metadata value it could "
            "not use, which it then ignores."
        )
    )
    line: int = Field(description="Line in the file, counting from 1.")
    message: str = Field(description="What the parser reported, in its words.")


async def diagnose(path: str, source: str) -> list[Diagnostic]:
    """The parser's errors and warnings for `source`.

    `path` only names the document to the language server: the text goes with
    it, so nothing has to be on disk and the file need not exist yet. The order
    is the one the language server published them in — errors, then warnings.

    Raises `DiagnosticsUnavailable` if the language server cannot be reached,
    which a caller has to tell apart from a clean file.
    """
    document = {
        "uri": f"file:///{quote(path, safe='/')}",
        "languageId": LANGUAGE_ID,
        "version": 1,
        "text": source,
    }
    try:
        async with asyncio.timeout(TIMEOUT):
            # Five small frames over loopback: deflate would allocate two zlib
            # contexts per write to compress nothing, and a keepalive ping has
            # nothing to keep alive in a socket that lives under a second.
            async with websockets.connect(
                cook.ws_url(LSP_PATH), compression=None, ping_interval=None
            ) as socket:
                # `params` has to be an object or the bridge drops this. The
                # result is awaited and discarded: the spec forbids sending
                # anything before it arrives, and nothing in it is needed.
                await _send(socket, "initialize", {"capabilities": {}}, request_id=1)
                response = await _receive(
                    socket, lambda m: m.get("id") == 1 and "method" not in m
                )
                if "error" in response:
                    raise DiagnosticsUnavailable(
                        f"the language server refused: {response['error']}"
                    )
                await _send(socket, "initialized", {})
                await _send(socket, "textDocument/didOpen", {"textDocument": document})
                # `did_open` always publishes, even with nothing to report, so
                # this waits for one notification and never for a timeout. Its
                # `uri` is not checked against the one opened above: this
                # socket opened one document, so there is no other document it
                # could be about, and the server re-serialises the uri it
                # echoes — which a comparison here would have to reimplement.
                published = await _receive(
                    socket,
                    lambda m: m.get("method") == "textDocument/publishDiagnostics",
                )
    except (OSError, TimeoutError, websockets.WebSocketException) as err:
        raise DiagnosticsUnavailable(f"{type(err).__name__}: {err}") from err
    return [
        Diagnostic(
            # Only `Error` and `Warning` are ever published
            # (`src/diagnostics.rs`); an `Information` or `Hint` added later is
            # reported as a warning rather than dropped.
            severity="error" if item.get("severity") == 1 else "warning",
            # LSP counts lines from zero. An editor, and anyone reading this,
            # counts from one.
            line=item["range"]["start"]["line"] + 1,
            message=item["message"],
        )
        for item in published["params"]["diagnostics"]
    ]


async def _send(
    socket: Any, method: str, params: dict[str, Any], request_id: int | None = None
) -> None:
    """One JSON-RPC message: a request when it carries an id, else a
    notification."""
    message: dict[str, Any] = {"jsonrpc": "2.0", "method": method, "params": params}
    if request_id is not None:
        message["id"] = request_id
    await socket.send(json.dumps(message))


async def _receive(
    socket: Any, matches: Callable[[dict[str, Any]], bool]
) -> dict[str, Any]:
    """The next message `matches` accepts, past everything else on the socket.

    The language server interleaves messages of its own — notifications like
    `window/logMessage`, and requests, which carry an id just as a response
    does. So a response is identified by its id *and* the absence of a
    `method`, and anything unrecognised is skipped rather than mistaken for the
    thing being waited for.
    """
    while True:
        message = json.loads(await socket.recv())
        if matches(message):
            return message
