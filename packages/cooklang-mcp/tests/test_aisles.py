"""The aisle tools: what they send, what they hand back, what they refuse."""

import asyncio
import json

import httpx
import pytest
from cooklang_mcp import cookcli
from cooklang_mcp.server import mcp
from mcp.server.mcpserver.exceptions import ToolError


def call(name, arguments):
    return asyncio.run(mcp.call_tool(name, arguments)).structured_content


def serve(monkeypatch, respond):
    monkeypatch.setattr(
        cookcli,
        "_http",
        httpx.AsyncClient(
            base_url="http://cook.test", transport=httpx.MockTransport(respond)
        ),
    )


def test_the_catalogue_preserves_groups_without_the_server_s_own_paths(monkeypatch):
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
        "aisles": {"produce": [["onion", "Zwiebel"]], "dairy": [["milk"]], "empty": []},
    }
    assert len(requests) == 1

    assert call("aisles_read", {"query": " ZWIEBEL "})["aisles"] == {
        "produce": [["onion", "Zwiebel"]]
    }
    assert call("aisles_read", {"query": "DAIRY"})["aisles"] == {"dairy": [["milk"]]}
    assert call("aisles_read", {"query": "absent"})["aisles"] == {}

    result = call("aisles_read", {"uncategorized": True})
    assert result["uncategorized"] == ["onions", "rice"]
    assert requests[-1].url.path == "/api/aisles/uncategorized"
    result = call("aisles_read", {"query": "onion", "uncategorized": True})
    assert result["uncategorized"] == ["onions"]

    catalogue["warnings"] = ["Line 3: Duplicate ingredient: 'milk'"]
    assert call("aisles_read", {})["warnings"] == catalogue["warnings"]


def test_search_returns_matching_ingredients_and_their_complete_aliases(monkeypatch):
    catalogue = {
        "configured": True,
        "revision": "v1",
        "warnings": [],
        "aisles": [
            {
                "name": "dairy",
                "ingredients": [
                    {"names": ["milk", "milch"]},
                    {"names": ["whole milk"]},
                    {"names": ["butter", "beurre"]},
                ],
            }
        ],
    }
    serve(monkeypatch, lambda request: httpx.Response(200, json=catalogue))

    result = call("aisles_read", {"query": "milk"})
    assert result["aisles"] == {"dairy": [["milk", "milch"], ["whole milk"]]}

    result = call("aisles_read", {"query": "dairy"})
    assert result["aisles"] == {
        "dairy": [["milk", "milch"], ["whole milk"], ["butter", "beurre"]]
    }

    result = call("aisles_read", {"query": "milch"})
    assert result["aisles"] == {"dairy": [["milk", "milch"]]}


@pytest.mark.parametrize(
    ("query", "expected", "unassigned"),
    [
        (
            [" MILK ", "milch", "milks", "milk", ""],
            {"dairy": [["milk", "milch"], ["whole milk"]]},
            ["milks"],
        ),
        (["milch", "beurre"], {"dairy": [["milk", "milch"], ["butter", "beurre"]]}, []),
        (
            ["dairy", "rice"],
            {"dairy": [["milk", "milch"], ["whole milk"], ["butter", "beurre"]]},
            ["rice"],
        ),
        (["missing", "absent"], {}, []),
        (
            [],
            {
                "dairy": [["milk", "milch"], ["whole milk"], ["butter", "beurre"]],
                "empty": [],
            },
            ["milks", "rice"],
        ),
        (
            ["", "  "],
            {
                "dairy": [["milk", "milch"], ["whole milk"], ["butter", "beurre"]],
                "empty": [],
            },
            ["milks", "rice"],
        ),
    ],
)
def test_multiple_search_terms_match_any_without_duplicate_groups(
    monkeypatch, query, expected, unassigned
):
    requests = []

    def respond(request):
        requests.append(request.url.path)
        if request.url.path.endswith("uncategorized"):
            return httpx.Response(
                200, json={"ingredients": [{"name": "milks"}, {"name": "rice"}]}
            )
        return httpx.Response(
            200,
            json={
                "configured": True,
                "revision": "v1",
                "warnings": [],
                "aisles": [
                    {
                        "name": "dairy",
                        "ingredients": [
                            {"names": ["milk", "milch"]},
                            {"names": ["whole milk"]},
                            {"names": ["butter", "beurre"]},
                        ],
                    },
                    {"name": "empty", "ingredients": []},
                ],
            },
        )

    serve(monkeypatch, respond)
    result = call("aisles_read", {"query": query, "uncategorized": True})
    assert result["aisles"] == expected
    assert result["uncategorized"] == unassigned
    assert requests == ["/api/aisles", "/api/aisles/uncategorized"]


def editing_server(monkeypatch, *, configured=True, conflict=False):
    requests = []
    catalogue = {
        "configured": configured,
        "revision": "v1" if configured else None,
        "warnings": [],
        "aisles": [
            {
                "name": "dairy",
                "ingredients": [
                    {"names": ["milk", "Milch", "milks"]},
                    {"names": ["whole milk", "Vollmilch"]},
                ],
            },
            {"name": "fridge", "ingredients": []},
        ]
        if configured
        else [],
    }

    def respond(request):
        requests.append(request)
        if request.method == "GET":
            return httpx.Response(200, json=catalogue)
        if request.url.path == "/api/aisles":
            return httpx.Response(
                201, json={**catalogue, "configured": True, "revision": "new"}
            )
        if conflict:
            return httpx.Response(409, json={"error": "the aisle file changed"})
        return httpx.Response(200, json={"revision": "v2", "warnings": []})

    serve(monkeypatch, respond)
    return requests


def posted_batch(requests):
    assert [r.method for r in requests] == ["GET", "POST"]
    assert requests[-1].url.path == "/api/aisles/changes"
    body = json.loads(requests[-1].content)
    assert body["revision"] == "v1"
    return body["changes"]


def test_ingredient_update_adds_removes_and_moves_without_resending_aliases(
    monkeypatch,
):
    requests = editing_server(monkeypatch)
    assert call(
        "ingredients_edit",
        {
            "changes": [
                {
                    "action": "update",
                    "ingredient": "MILCH",
                    "aisle": "fridge",
                    "add_aliases": ["lait", "MILCH"],
                    "remove_aliases": ["MILKS"],
                }
            ]
        },
    ) == {"applied": 1}
    assert posted_batch(requests) == [
        {
            "action": "update_ingredient",
            "name": "MILCH",
            "aisle": "fridge",
            "names": ["milk", "Milch", "lait"],
        }
    ]


@pytest.mark.parametrize(
    ("fields", "names"),
    [
        ({"aisle": "fridge"}, ["milk", "Milch", "milks"]),
        ({"preferred_name": "Milch"}, ["Milch", "milk", "milks"]),
        (
            {"preferred_name": "lait", "remove_aliases": ["milk"]},
            ["lait", "Milch", "milks"],
        ),
    ],
)
def test_move_and_rename_preserve_unspecified_aliases(monkeypatch, fields, names):
    requests = editing_server(monkeypatch)
    call(
        "ingredients_edit",
        {"changes": [{"action": "update", "ingredient": "milk", **fields}]},
    )
    assert posted_batch(requests)[0]["names"] == names


def test_batch_tracks_new_ingredients_and_aliases_in_order(monkeypatch):
    requests = editing_server(monkeypatch)
    call(
        "ingredients_edit",
        {
            "changes": [
                {
                    "action": "create",
                    "name": "butter",
                    "aisle": "dairy",
                    "aliases": ["beurre"],
                },
                {
                    "action": "update",
                    "ingredient": "beurre",
                    "add_aliases": ["Butterfett"],
                },
                {
                    "action": "update",
                    "ingredient": "Butterfett",
                    "remove_aliases": ["beurre"],
                },
                {"action": "delete", "ingredient": "Butterfett"},
            ]
        },
    )
    assert posted_batch(requests) == [
        {"action": "add_ingredient", "aisle": "dairy", "names": ["butter", "beurre"]},
        {
            "action": "update_ingredient",
            "name": "beurre",
            "names": ["butter", "beurre", "Butterfett"],
        },
        {
            "action": "update_ingredient",
            "name": "Butterfett",
            "names": ["butter", "Butterfett"],
        },
        {"action": "remove_ingredient", "name": "Butterfett"},
    ]


def test_merge_then_update_keeps_all_groups_aliases(monkeypatch):
    requests = editing_server(monkeypatch)
    call(
        "ingredients_edit",
        {
            "changes": [
                {
                    "action": "merge",
                    "ingredients": ["milk", "whole milk"],
                    "preferred_name": "Vollmilch",
                },
                {
                    "action": "update",
                    "ingredient": "Milch",
                    "remove_aliases": ["milks"],
                },
            ]
        },
    )
    assert posted_batch(requests) == [
        {
            "action": "merge_ingredients",
            "names": ["milk", "whole milk"],
            "main": "Vollmilch",
        },
        {
            "action": "update_ingredient",
            "name": "Milch",
            "names": ["Vollmilch", "whole milk", "milk", "Milch"],
        },
    ]


@pytest.mark.parametrize(
    "change",
    [
        {"action": "update", "ingredient": "milk", "remove_aliases": ["milk"]},
        {"action": "update", "ingredient": "milk", "remove_aliases": ["unknown"]},
        {"action": "update", "ingredient": "milk", "aisle": "missing"},
        {"action": "delete", "ingredient": "missing"},
        {"action": "merge", "ingredients": ["milk", "Milch"], "preferred_name": "milk"},
        {
            "action": "merge",
            "ingredients": ["milk", "whole milk"],
            "preferred_name": "new",
        },
    ],
)
def test_invalid_ingredient_plan_writes_nothing(monkeypatch, change):
    requests = editing_server(monkeypatch)
    with pytest.raises(ToolError):
        call(
            "ingredients_edit",
            {
                "changes": [
                    {"action": "create", "name": "butter", "aisle": "dairy"},
                    change,
                ]
            },
        )
    assert [r.method for r in requests] == ["GET"]


def test_aisle_batch_tracks_renames_and_checks_nonempty_deletion(monkeypatch):
    requests = editing_server(monkeypatch)
    with pytest.raises(ToolError, match="not empty"):
        call(
            "aisles_edit",
            {
                "changes": [
                    {"action": "rename", "name": "dairy", "new_name": "cold"},
                    {"action": "delete", "name": "COLD"},
                ]
            },
        )
    assert len(requests) == 1

    requests = editing_server(monkeypatch)
    call(
        "aisles_edit",
        {
            "changes": [
                {"action": "create", "name": "spices"},
                {"action": "rename", "name": "spices", "new_name": "herbs"},
                {"action": "move", "name": "herbs", "position": 0},
                {"action": "delete", "name": "herbs"},
                {"action": "delete", "name": "dairy", "delete_ingredients": True},
            ]
        },
    )
    assert posted_batch(requests) == [
        {"action": "add_aisle", "name": "spices"},
        {"action": "rename_aisle", "name": "spices", "new_name": "herbs"},
        {"action": "move_aisle", "name": "herbs", "position": 0},
        {"action": "remove_aisle", "name": "herbs"},
        {"action": "remove_aisle", "name": "dairy"},
    ]


def test_first_aisle_initializes_missing_catalogue(monkeypatch):
    requests = editing_server(monkeypatch, configured=False)
    assert call(
        "aisles_edit", {"changes": [{"action": "create", "name": "dairy"}]}
    ) == {"applied": 1}
    assert [(r.method, r.url.path) for r in requests] == [
        ("GET", "/api/aisles"),
        ("POST", "/api/aisles"),
        ("POST", "/api/aisles/changes"),
    ]
    assert json.loads(requests[-1].content)["revision"] == "new"


@pytest.mark.parametrize(
    "tool, change",
    [
        ("aisles_edit", {"action": "delete", "name": "fridge"}),
        (
            "ingredients_edit",
            {"action": "update", "ingredient": "milk", "add_aliases": ["lait"]},
        ),
    ],
)
def test_concurrent_edit_fails_without_retry(monkeypatch, tool, change):
    requests = editing_server(monkeypatch, conflict=True)
    with pytest.raises(ToolError, match="aisle file changed"):
        call(tool, {"changes": [change]})
    assert len(requests) == 2


@pytest.mark.parametrize(
    "tool, changes",
    [
        ("aisles_edit", []),
        ("ingredients_edit", []),
        ("aisles_edit", [{"action": "move", "name": "dairy", "position": -1}]),
        ("aisles_edit", [{"action": "rename", "name": "dairy"}]),
        ("aisles_edit", [{"action": "create", "name": "  "}]),
        ("ingredients_edit", [{"action": "update", "ingredient": "milk"}]),
        ("ingredients_edit", [{"action": "create", "name": "milk"}]),
        (
            "ingredients_edit",
            [{"action": "delete", "ingredient": "milk", "aliases": ["Milch"]}],
        ),
        (
            "ingredients_edit",
            [
                {
                    "action": "update",
                    "ingredient": "milk",
                    "add_aliases": ["lait"],
                    "remove_aliases": ["LAIT"],
                }
            ],
        ),
    ],
)
def test_invalid_action_fields_fail_before_reading(monkeypatch, tool, changes):
    async def unexpected(*args, **kwargs):
        pytest.fail("invalid input reached the server")

    monkeypatch.setattr(cookcli, "request", unexpected)
    with pytest.raises(ToolError):
        call(tool, {"changes": changes})


def test_edit_schemas_require_only_changes_and_explain_actions():
    listed = {tool.name: tool for tool in asyncio.run(mcp.list_tools())}
    for name in ("aisles_edit", "ingredients_edit"):
        schema = listed[name].input_schema
        assert set(schema["properties"]) == {"changes"}
        assert schema["required"] == ["changes"]
        assert len(schema["properties"]["changes"]["items"]["oneOf"]) == 4


def test_alias_conflict_reaches_agent_with_change_number_and_aisle(monkeypatch):
    requests = []

    def respond(request):
        requests.append(request)
        if request.method == "GET":
            return httpx.Response(
                200,
                json={
                    "configured": True,
                    "revision": "v1",
                    "warnings": [],
                    "aisles": [
                        {
                            "name": "dairy",
                            "ingredients": [
                                {"names": ["milk", "Milch"]},
                                {"names": ["whole milk"]},
                            ],
                        }
                    ],
                },
            )
        return httpx.Response(
            400, json={"error": 'Change 2: "Milch" is already in the "dairy" aisle'}
        )

    serve(monkeypatch, respond)
    with pytest.raises(
        ToolError, match='Change 2: "Milch" is already in the "dairy" aisle'
    ):
        call(
            "ingredients_edit",
            {
                "changes": [
                    {"action": "update", "ingredient": "milk", "add_aliases": ["lait"]},
                    {
                        "action": "update",
                        "ingredient": "whole milk",
                        "add_aliases": ["Milch"],
                    },
                ]
            },
        )
    assert len(requests) == 2


def test_aisle_lookup_uses_stored_spelling_in_api_requests(monkeypatch):
    requests = editing_server(monkeypatch)
    call(
        "aisles_edit",
        {
            "changes": [
                {"action": "rename", "name": "FRIDGE", "new_name": "Cold"},
                {"action": "move", "name": "COLD", "position": 0},
                {"action": "delete", "name": "cold"},
            ]
        },
    )
    assert posted_batch(requests) == [
        {"action": "rename_aisle", "name": "fridge", "new_name": "Cold"},
        {"action": "move_aisle", "name": "Cold", "position": 0},
        {"action": "remove_aisle", "name": "Cold"},
    ]
    requests = editing_server(monkeypatch)
    call(
        "ingredients_edit",
        {
            "changes": [
                {"action": "create", "name": "butter", "aisle": "DAIRY"},
                {"action": "update", "ingredient": "butter", "aisle": "FRIDGE"},
            ]
        },
    )
    assert posted_batch(requests) == [
        {"action": "add_ingredient", "aisle": "dairy", "names": ["butter"]},
        {
            "action": "update_ingredient",
            "name": "butter",
            "aisle": "fridge",
            "names": ["butter"],
        },
    ]
