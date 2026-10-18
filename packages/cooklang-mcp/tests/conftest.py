"""Shared fixtures.

The language server is a second process behind a WebSocket (see
`diagnostics.py`), and every write asks it about the file it just saved. Left
alone, each test that writes would try to open a socket to whatever
`COOKLANG_SERVER_URL` names, and a test asserting on `warnings` would be
asserting on whether that connection was refused.

So the default here is a language server that reports nothing, which is what a
test about anything else means by a valid recipe. A test about the diagnostics
themselves replaces `server.diagnose` with its own.
"""

import pytest

from cooklang_mcp import server


@pytest.fixture(autouse=True)
def clean_diagnostics(monkeypatch):
    async def diagnose(_path, _source):
        return []

    monkeypatch.setattr(server, "diagnose", diagnose)
