"""The language-server client, against a socket that speaks like the bridge.

The fixture is the protocol as `cook server` presents it — bare JSON-RPC over a
WebSocket, the framing already stripped — so these tests pin the exchange and
the shape it produces, not the transport underneath. What they cannot pin is
which diagnostics the real parser emits; that is upstream's, and is checked by
hand against a live `cook server`.
"""

import asyncio
import json

import pytest
import websockets

from cooklang_mcp import diagnostics


def diagnose_against(
    monkeypatch, handler, path="Risotto.cook", source="Mix @rice{200%g}"
):
    """`diagnose`, with `handler` standing in for the language server."""

    async def run():
        async with websockets.serve(handler, "127.0.0.1", 0) as server:
            port = server.sockets[0].getsockname()[1]
            monkeypatch.setattr(
                diagnostics.cook,
                "ws_url",
                lambda path: f"ws://127.0.0.1:{port}{path}",
            )
            return await diagnostics.diagnose(path, source)

    return asyncio.run(run())


def language_server(published, *, chatter=(), seen=None):
    """A socket that answers `initialize` and publishes once on `didOpen`.

    `seen` collects what the client sent, for the tests that are about the
    messages rather than the diagnostics.
    """

    async def handler(socket):
        async for message in socket:
            message = json.loads(message)
            method = message.get("method")
            if seen is not None:
                seen[method] = message.get("params")
            if method == "initialize":
                for extra in chatter:
                    await socket.send(json.dumps(extra))
                await socket.send(
                    json.dumps(
                        {
                            "jsonrpc": "2.0",
                            "id": message["id"],
                            "result": {"capabilities": {}},
                        }
                    )
                )
            elif method == "textDocument/didOpen":
                await socket.send(
                    json.dumps(
                        {
                            "jsonrpc": "2.0",
                            "method": "textDocument/publishDiagnostics",
                            "params": {
                                "uri": message["params"]["textDocument"]["uri"],
                                "diagnostics": published,
                            },
                        }
                    )
                )

    return handler


def at(line, message, severity=1):
    """One LSP diagnostic, with the zero-based line the protocol uses."""
    return {
        "range": {
            "start": {"line": line, "character": 12},
            "end": {"line": line, "character": 15},
        },
        "severity": severity,
        "source": "cooklang",
        "message": message,
    }


@pytest.mark.parametrize(
    ("published_severity", "reported"),
    [
        (1, "error"),
        (2, "warning"),
        # `Information`, which the language server does not emit today: a
        # severity added later is reported rather than dropped.
        (3, "warning"),
    ],
)
def test_a_severity_is_mapped_and_the_line_gains_one(
    monkeypatch, published_severity, reported
):
    (found,) = diagnose_against(
        monkeypatch,
        language_server([at(8, "Division by zero", severity=published_severity)]),
    )
    assert found.model_dump() == {
        "severity": reported,
        "line": 9,
        "message": "Division by zero",
    }


def test_a_clean_file_reports_nothing(monkeypatch):
    assert diagnose_against(monkeypatch, language_server([])) == []


def test_diagnostics_keep_the_order_they_were_published_in(monkeypatch):
    found = diagnose_against(
        monkeypatch, language_server([at(4, "second"), at(1, "first", severity=2)])
    )
    assert [item.message for item in found] == ["second", "first"]


def test_the_false_timer_unit_error_is_dropped(monkeypatch):
    """cookcli#643: published for every timer, true of none of them.

    Pinned by the message the parser formats, so it keeps holding once the
    filter is a prefix match against real text (`Unknown timer unit: minutes`,
    cooklang-rs `analysis/event_consumer.rs`). The timer errors that do not need
    the converter stay.
    """
    found = diagnose_against(
        monkeypatch,
        language_server(
            [
                at(0, "Unknown timer unit: minutes"),
                at(1, "Unknown timer unit: heures"),
                at(2, "Timer value is text: some"),
            ]
        ),
    )
    assert [item.message for item in found] == ["Timer value is text: some"]


def test_log_messages_and_server_requests_do_not_derail_the_handshake(monkeypatch):
    """Neither a notification nor a request of the server's own is a response."""
    chatter = (
        {"jsonrpc": "2.0", "method": "window/logMessage", "params": {"message": "hi"}},
        {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "client/registerCapability",
            "params": {},
        },
    )
    found = diagnose_against(
        monkeypatch, language_server([at(0, "Division by zero")], chatter=chatter)
    )
    assert [item.message for item in found] == ["Division by zero"]


def test_the_document_is_opened_as_cooklang_with_its_source(monkeypatch):
    seen = {}
    diagnose_against(
        monkeypatch,
        language_server([], seen=seen),
        path="Meal Plan.menu",
        source="= Meals\n@./Risotto{}",
    )

    # An `initialize` whose `params` is not an object is dropped by the bridge,
    # unsent, and the handshake then hangs until the timeout.
    assert isinstance(seen["initialize"], dict)
    document = seen["textDocument/didOpen"]["textDocument"]
    assert document["languageId"] == "cooklang"
    assert document["text"] == "= Meals\n@./Risotto{}"
    # A space in the path has to survive as a URI, and a separator has to stay
    # a separator rather than becoming %2F.
    assert document["uri"] == "file:///Meal%20Plan.menu"


def test_a_server_that_is_not_there_is_unavailable_rather_than_an_error(monkeypatch):
    # Port 1 is not in use and is refused rather than timed out.
    monkeypatch.setattr(
        diagnostics.cook, "ws_url", lambda path: f"ws://127.0.0.1:1{path}"
    )
    with pytest.raises(diagnostics.DiagnosticsUnavailable):
        asyncio.run(diagnostics.diagnose("Risotto.cook", "Mix @rice{}"))


def test_a_server_that_never_answers_gives_up(monkeypatch):
    async def silence(socket):
        await asyncio.sleep(30)

    monkeypatch.setattr(diagnostics, "TIMEOUT", 0.5)
    with pytest.raises(diagnostics.DiagnosticsUnavailable):
        diagnose_against(monkeypatch, silence)


def test_a_refused_initialize_is_unavailable(monkeypatch):
    async def refuse(socket):
        async for message in socket:
            await socket.send(
                json.dumps(
                    {
                        "jsonrpc": "2.0",
                        "id": json.loads(message)["id"],
                        "error": {"code": -32603, "message": "nope"},
                    }
                )
            )

    with pytest.raises(diagnostics.DiagnosticsUnavailable):
        diagnose_against(monkeypatch, refuse)
