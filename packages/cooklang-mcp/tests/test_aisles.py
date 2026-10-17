"""The aisle tools: what they send, what they hand back, what they refuse."""

import asyncio
import json

import httpx
import pytest
from mcp.server.fastmcp.exceptions import ToolError

from cooklang_mcp import cookcli
from cooklang_mcp.server import mcp


def call(name, arguments):
    return asyncio.run(mcp.call_tool(name, arguments))[1]


def serve(monkeypatch, respond):
    monkeypatch.setattr(
        cookcli,
        "_http",
        httpx.AsyncClient(
            base_url="http://cook.test", transport=httpx.MockTransport(respond)
        ),
    )


def test_the_catalogue_reads_flat_without_the_server_s_own_paths(monkeypatch):
    requests = []
    catalogue = {
        "configured": True,
        "revision": "v1",
        "warnings": [],
        "path": "/srv/recipes/config/aisle.conf",
        "aisles": [
            {"name": "produce", "ingredients": [{"names": ["onion", "Zwiebel"]}]},
            {"name": "dairy", "ingredients": [{"names": ["milk"]}]},
            {"name": "empty", "ingredients": []},
        ],
    }

    def respond(request):
        requests.append(request)
        if request.url.path.endswith("uncategorized"):
            return httpx.Response(
                200,
                json={
                    "ingredients": [
                        {"name": "onions", "recipes": [{"path": "Soup.cook"}]},
                        {"name": "rice", "recipes": []},
                    ]
                },
            )
        return httpx.Response(200, json=catalogue)

    serve(monkeypatch, respond)
    assert call("aisles_read", {}) == {
        "configured": True,
        "revision": "v1",
        "aisles": {"produce": ["onion", "Zwiebel"], "dairy": ["milk"], "empty": []},
    }
    assert len(requests) == 1

    assert call("aisles_read", {"query": " ZWIEBEL "})["aisles"] == {
        "produce": ["Zwiebel"]
    }
    assert call("aisles_read", {"query": "DAIRY"})["aisles"] == {"dairy": ["milk"]}
    assert call("aisles_read", {"query": "absent"})["aisles"] == {}

    result = call("aisles_read", {"uncategorized": True})
    assert result["uncategorized"] == ["onions", "rice"]
    assert requests[-1].url.path == "/api/aisles/uncategorized"
    result = call("aisles_read", {"query": "onion", "uncategorized": True})
    assert result["uncategorized"] == ["onions"]

    catalogue["warnings"] = ["Line 3: Duplicate ingredient: 'milk'"]
    assert call("aisles_read", {})["warnings"] == catalogue["warnings"]


def test_a_batch_goes_as_one_request_with_one_name_per_ingredient(monkeypatch):
    requests = []

    def respond(request):
        requests.append(request)
        return httpx.Response(200, json={"revision": "v2", "warnings": []})

    serve(monkeypatch, respond)
    assert call(
        "aisles_edit",
        {
            "revision": "v1",
            "changes": [
                {"action": "add_aisle", "name": "spices", "position": 0},
                {"action": "add_ingredient", "aisle": "spices", "name": "saffron"},
                {"action": "remove_ingredient", "name": "onion"},
            ],
        },
    ) == {"revision": "v2", "applied": 3}
    assert requests[-1].url.path == "/api/aisles/changes"
    assert json.loads(requests[-1].content) == {
        "revision": "v1",
        "changes": [
            {"action": "add_aisle", "name": "spices", "position": 0},
            {"action": "add_ingredient", "aisle": "spices", "names": ["saffron"]},
            {"action": "remove_ingredient", "name": "onion"},
        ],
    }


def test_creating_the_file_is_its_own_call_and_a_conflict_is_not_retried(monkeypatch):
    requests = []

    def respond(request):
        requests.append(request)
        if request.url.path == "/api/aisles":
            return httpx.Response(201, json={"revision": "new", "warnings": []})
        return httpx.Response(409, json={"error": "the aisle file changed"})

    serve(monkeypatch, respond)
    assert call("aisles_edit", {"revision": None, "changes": []}) == {
        "revision": "new",
        "created": True,
    }
    assert requests[0].method == "POST"
    with pytest.raises(ToolError, match="the aisle file changed"):
        call(
            "aisles_edit",
            {"revision": "stale", "changes": [{"action": "remove_aisle", "name": "x"}]},
        )
    assert len(requests) == 2


@pytest.mark.parametrize(
    "arguments",
    [
        {"revision": None, "changes": [{"action": "add_aisle", "name": "spices"}]},
        {"revision": "", "changes": [{"action": "add_aisle", "name": "spices"}]},
        {"revision": "v1", "changes": []},
        {"revision": "v1", "changes": [{"action": "unknown", "name": "spices"}]},
        {"revision": "v1", "changes": [{"action": "move_aisle", "position": -1}]},
        # The alias actions the API has but this tool deliberately leaves out.
        {"revision": "v1", "changes": [{"action": "add_names", "name": "milk"}]},
        {
            "revision": "v1",
            "changes": [{"action": "merge_ingredients", "main": "milk"}],
        },
        {
            "revision": "v1",
            "changes": [
                {"action": "add_ingredient", "aisle": "dairy", "names": ["milk"]}
            ],
        },
    ],
)
def test_an_edit_the_tool_cannot_express_never_reaches_the_server(
    monkeypatch, arguments
):
    async def unexpected(*args, **kwargs):
        pytest.fail("an invalid edit reached the server")

    monkeypatch.setattr(cookcli, "request", unexpected)
    with pytest.raises(ToolError):
        call("aisles_edit", arguments)
