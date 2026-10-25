"""The MCP surface exposed to clients."""

import asyncio
import json
import time

import httpx
import pytest
from mcp.server.fastmcp.exceptions import ToolError
from starlette.testclient import TestClient

from cooklang_mcp import menus, server
from cooklang_mcp.server import INSTRUCTIONS, mcp


def tools():
    return {tool.name: tool for tool in asyncio.run(mcp.list_tools())}


def test_the_tool_surface_is_grouped_and_annotated():
    """Names group by the thing they act on, and a read says it is one.

    The old flat names are asserted absent because a client that cached them
    would otherwise keep calling tools this server no longer answers.
    """
    listed = tools()

    assert set(listed) == {
        "recipe_search",
        "recipe_read",
        "recipe_write",
        "recipe_delete",
        "recipe_image_upload",
        "recipe_import",
        "mark_cooked",
        "shopping_list_read",
        "shopping_list_edit",
        "aisles_read",
        "aisles_edit",
        "ingredients_edit",
    }
    for retired in (
        "list_recipes",
        "search_recipes",
        "read_recipe",
        "write_recipe",
        "fetch_recipe",
        "shopping_list",
        "add_to_shopping_list",
        "remove_from_shopping_list",
        "clear_shopping_list",
        "check_shopping_item",
        "read_aisles",
        "edit_aisles",
    ):
        assert retired not in listed

    reads = {
        "recipe_search",
        "recipe_read",
        "recipe_import",
        "shopping_list_read",
        "aisles_read",
    }
    for name, tool in listed.items():
        assert tool.annotations is not None, name
        assert tool.annotations.readOnlyHint is (name in reads), name
    # Only deletion is destructive; every other write can be undone by writing
    # again, which is the distinction a client should gate on.
    assert listed["recipe_delete"].annotations.destructiveHint is True
    assert listed["recipe_write"].annotations.destructiveHint is False
    # Only the importer reaches outside the collection. Not the picture tool:
    # it hands out a link, and the upload that follows is not this server's
    # request to make.
    assert listed["recipe_import"].annotations.openWorldHint is True
    for name, tool in listed.items():
        if name != "recipe_import":
            assert tool.annotations.openWorldHint is False, name


def test_recipe_search_advertises_its_result_fields():
    schema = tools()["recipe_search"].model_dump(by_alias=True)["outputSchema"]
    summary = schema["$defs"]["RecipeSummary"]

    assert set(summary["properties"]) == {
        "path",
        "title",
        "web_url",
        "tags",
        "is_menu",
    }
    assert summary["required"] == ["path", "title", "web_url", "tags", "is_menu"]
    assert schema["properties"]["result"]["items"] == {"$ref": "#/$defs/RecipeSummary"}


def test_every_tool_that_returns_a_url_asks_for_the_link_itself():
    """`web_url`'s own description asks for the link, not just the server
    instructions: those are advisory, an output schema always arrives.

    `format` is the standard marker for a URL-valued string, and all MCP has to
    offer — `resource_link` would promise a resource this server can read.
    """
    listed = tools()
    for name, model in (
        ("recipe_search", "RecipeSummary"),
        ("recipe_read", "RecipeDocument"),
        ("recipe_write", "RecipeWritten"),
        ("recipe_image_upload", "PictureUpload"),
        ("mark_cooked", "MealCooked"),
    ):
        # A list result is wrapped and its model moved into `$defs`; a single
        # one is the schema itself.
        schema = listed[name].model_dump(by_alias=True)["outputSchema"]
        web_url = schema.get("$defs", {}).get(model, schema)["properties"]["web_url"]
        assert "Markdown link" in web_url["description"], name
        assert web_url["format"] == "uri", name


def test_recipe_tools_return_clickable_web_urls(monkeypatch):
    monkeypatch.setattr(server, "WEB_URL", "https://cook.example.test")

    async def search_entries(_query):
        return [
            {
                "path": "Weeknight meals/Chili & Rice.cook",
                "title": "Chili & Rice",
                "tags": ["dinner"],
                "is_menu": False,
            }
        ]

    async def shopping_list():
        return {
            "recipes": [{"path": "Weeknight meals/Chili & Rice.cook", "scale": 1.0}],
            "categories": [],
            "pantry_items": [],
        }

    class Response:
        text = "---\ntitle: Chili & Rice\n---\n"

        @staticmethod
        def json():
            return {"recipe": {"ingredients": [{"name": "rice"}]}}

    async def request(_method, _path, **_kwargs):
        if _path == "/api/aisles":
            return httpx.Response(
                200,
                json={
                    "configured": True,
                    "aisles": [
                        {"name": "pantry", "ingredients": [{"names": ["rice"]}]}
                    ],
                },
            )
        return Response()

    monkeypatch.setattr(server.cook, "search_entries", search_entries)
    monkeypatch.setattr(server.cook, "shopping_list", shopping_list)
    monkeypatch.setattr(server.cook, "request", request)

    summary = asyncio.run(server.recipe_search("chili"))[0]
    document = asyncio.run(server.recipe_read("./Weeknight meals/Chili & Rice.cook"))
    shopping = asyncio.run(server.shopping_list_read())
    written = asyncio.run(
        server.recipe_write(
            "Weeknight meals/Chili & Rice.cook",
            Response.text,
        )
    )
    expected = (
        "https://cook.example.test/recipe/Weeknight%20meals/Chili%20%26%20Rice.cook"
    )

    assert summary.web_url == expected
    assert document.web_url == expected
    assert document.source == Response.text
    assert shopping["recipes"][0]["web_url"] == expected
    assert written.model_dump() == {
        "path": "Weeknight meals/Chili & Rice.cook",
        "web_url": expected,
        "written": True,
        "diagnostics": [],
        "ingredients": ["rice"],
        # The catalogue already holds "rice", so there is nothing to sort.
        "new_ingredients": [],
        "aisles": [],
        "warnings": [],
        # A recipe, not a plan, so there are no referenced recipes to resolve.
        "entries": [],
    }


def _collection_with_picture(monkeypatch, answer, raw="---\ntitle: Kürbiswähe\n---\n"):
    """A collection that says what picture its one recipe has.

    `answer` is the picture endpoint's own JSON, or an exception to raise.
    """

    async def request(_method, path, **_kwargs):
        if path.startswith("/api/recipes/raw/"):
            return httpx.Response(200, text=raw)
        if path.startswith("/api/recipe_image/"):
            if isinstance(answer, Exception):
                raise answer
            return httpx.Response(200, json=answer)
        raise AssertionError(f"unexpected request: {path}")

    monkeypatch.setattr(server.cook, "request", request)


def test_a_picture_file_is_reported_because_the_source_cannot_be(monkeypatch):
    """The point of the field: a stored picture is a file beside the recipe,
    and the source a read returns never mentions it."""
    _collection_with_picture(
        monkeypatch, {"image": "/api/static/K%C3%BCrbisw%C3%A4he.png", "source": "file"}
    )

    assert asyncio.run(server.recipe_read("Kürbiswähe.cook")).picture == "file"


def test_a_picture_the_frontmatter_links_is_reported_as_metadata(monkeypatch):
    """The API's own word for it, and the word `pictures.py` already uses."""
    _collection_with_picture(
        monkeypatch, {"image": "https://example.test/dish.jpg", "source": "metadata"}
    )

    assert asyncio.run(server.recipe_read("Kürbiswähe.cook")).picture == "metadata"


def test_a_recipe_with_no_picture_says_none(monkeypatch):
    """`none` is what makes offering to add one right, so only a collection
    reporting nothing may produce it."""
    _collection_with_picture(monkeypatch, {"image": None, "source": None})

    assert asyncio.run(server.recipe_read("Kürbiswähe.cook")).picture == "none"


def test_a_kind_of_picture_this_server_does_not_know_is_still_a_picture(monkeypatch):
    """Whether there is one comes off `image`, so a kind of picture added
    upstream reads as a stored file rather than failing the read."""
    _collection_with_picture(
        monkeypatch, {"image": "/api/static/dish.png", "source": "sync"}
    )

    assert asyncio.run(server.recipe_read("Kürbiswähe.cook")).picture == "file"


PLAN = """\
---
title: Meal Plan
---
= Meals
@./Kürbiswähe{2%servings}

@paper towels{1}
"""


def _plan_collection(monkeypatch):
    """A collection holding the one recipe the plan refers to."""
    monkeypatch.setattr(server, "WEB_URL", "https://cook.example.test")

    async def list_entries():
        return [
            {
                "path": "Kürbiswähe.cook",
                "title": "Kürbiswähe",
                "tags": ["dinner"],
                "is_menu": False,
            }
        ]

    async def request(_method, path, **_kwargs):
        if path == "/api/aisles":
            return httpx.Response(200, json={"configured": False, "aisles": []})
        if path.startswith("/api/recipes/raw/"):
            return httpx.Response(200, text=PLAN)
        return httpx.Response(
            200,
            json={
                "recipe": {
                    "ingredients": [],
                    "sections": [
                        {
                            "name": None,
                            "content": [
                                {"type": "text", "value": "Soak the beans overnight."}
                            ],
                        }
                    ],
                }
            },
        )

    monkeypatch.setattr(server.cook, "list_entries", list_entries)
    monkeypatch.setattr(server.cook, "request", request)


@pytest.mark.parametrize("tool", ["read", "write"])
def test_menu_results_carry_each_recipe_s_own_page(monkeypatch, tool):
    """A plan names its recipes, so an answer about the plan names them too.

    The file holds `@./Kürbiswähe` and the result's own `web_url` is the plan's
    page, so neither leaves the model a link for the recipe it is about to
    mention. These entries do, in the result of the call just made.
    """
    _plan_collection(monkeypatch)

    if tool == "read":
        entries = asyncio.run(server.recipe_read("Meal Plan.menu")).entries
    else:
        entries = asyncio.run(server.recipe_write("Meal Plan.menu", PLAN)).entries

    assert [entry.model_dump() for entry in entries] == [
        {
            "path": "Kürbiswähe.cook",
            "title": "Kürbiswähe",
            # The recipe's own page, not the plan's.
            "web_url": "https://cook.example.test/recipe/K%C3%BCrbisw%C3%A4he.cook",
            "tags": ["dinner"],
            "is_menu": False,
            # Read for the caller, so an answer about the plan needs no
            # further call to say what has to be started the night before.
            "notes": ["Soak the beans overnight."],
        }
    ]


def test_menu_entries_leave_out_what_is_not_a_recipe(monkeypatch):
    """`@paper towels{1}` is a loose ingredient, and a mistyped reference is
    not a page. Both are in the source either way; neither gets a URL."""
    _plan_collection(monkeypatch)
    plan = PLAN.replace("@paper towels{1}", "@./Kürbiswaehe{1}\n\n@paper towels{1}")

    entries = asyncio.run(server.recipe_write("Meal Plan.menu", plan)).entries

    assert [entry.title for entry in entries] == ["Kürbiswähe"]


def test_only_menus_resolve_entries(monkeypatch):
    """An ordinary recipe's ingredients are not recipes, so listing the
    collection to discover that would be a request per read."""
    _plan_collection(monkeypatch)

    async def unexpected():
        raise AssertionError("the collection was listed for a plain recipe")

    monkeypatch.setattr(server.cook, "list_entries", unexpected)

    assert asyncio.run(server.recipe_read("Risotto.cook")).entries == []
    assert asyncio.run(server.recipe_write("Risotto.cook", PLAN)).entries == []


def test_unresolvable_entries_cost_the_links_not_the_write(monkeypatch):
    """A failure listing the collection leaves the names plain. It must not
    turn a saved file into an error."""
    _plan_collection(monkeypatch)

    async def fails():
        raise httpx.ConnectError("boom")

    monkeypatch.setattr(server.cook, "list_entries", fails)

    written = asyncio.run(server.recipe_write("Meal Plan.menu", PLAN))
    assert written.written is True
    assert written.entries == []


@pytest.mark.parametrize("failure", ["parse", "catalogue", "write"])
def test_write_failures_preserve_saved_status(monkeypatch, failure):
    def fails(method, path):
        if failure == "write":
            return method == "PUT"
        if failure == "catalogue":
            return path == "/api/aisles"
        return method == "GET" and path != "/api/aisles"

    async def request(method, path, **kwargs):
        if fails(method, path):
            raise server.cook.CookCliError("unavailable")
        return httpx.Response(200, json={"recipe": {"ingredients": [{"name": "rice"}]}})

    monkeypatch.setattr(server.cook, "request", request)
    if failure == "write":
        with pytest.raises(server.cook.CookCliError):
            asyncio.run(server.recipe_write("Rice.cook", "Add @rice."))
    else:
        result = asyncio.run(server.recipe_write("Rice.cook", "Add @rice."))
        assert result.written is True
        assert len(result.warnings) == 1
        assert isinstance(result.warnings[0], str)
        assert "Recipe saved" in result.warnings[0]


def _collection(monkeypatch, ingredient, *, read_back=True):
    """One recipe holding `ingredient`, whose catalogue knows that name — so
    the only warnings a write produces are the ones under test. With
    `read_back=False` the read after the write fails, which is what a file that
    does not parse looks like from here."""

    async def request(method, path, **_kwargs):
        if path == "/api/aisles":
            return httpx.Response(
                200,
                json={
                    "configured": True,
                    "aisles": [
                        {"name": "pantry", "ingredients": [{"names": [ingredient]}]}
                    ],
                },
            )
        if method == "GET" and not read_back:
            raise server.cook.CookCliError("GET failed (500): Division by zero")
        return httpx.Response(
            200, json={"recipe": {"ingredients": [{"name": ingredient}]}}
        )

    monkeypatch.setattr(server.cook, "request", request)


def _reports(monkeypatch, **diagnostic):
    """A language server that reports one diagnostic about every file."""

    async def diagnose(_path, _source):
        return [server.Diagnostic(**diagnostic)]

    monkeypatch.setattr(server, "diagnose", diagnose)


def test_what_the_parser_says_comes_back_with_the_write(monkeypatch):
    _collection(monkeypatch, "rice")
    _reports(
        monkeypatch, severity="warning", line=3, message="Unsupported value for key"
    )

    written = asyncio.run(server.recipe_write("Rice.cook", "Add @rice{1%cup}"))
    assert written.written is True
    assert written.ingredients == ["rice"]
    assert [d.model_dump() for d in written.diagnostics] == [
        {"severity": "warning", "line": 3, "message": "Unsupported value for key"}
    ]
    assert written.warnings == []


def test_a_new_name_comes_back_ready_to_be_sorted(monkeypatch):
    """The write is where a new ingredient is cheapest to catalogue, so its
    result carries the whole decision: the name, what it resembles, and the
    aisles to put it in."""

    async def request(method, path, **_kwargs):
        if path == "/api/aisles":
            return httpx.Response(
                200,
                json={
                    "configured": True,
                    "warnings": [],
                    "aisles": [
                        {"name": "produce", "ingredients": [{"names": ["onion"]}]},
                        {"name": "pantry", "ingredients": []},
                    ],
                },
            )
        return httpx.Response(
            200,
            json={"recipe": {"ingredients": [{"name": "onions"}, {"name": "saffron"}]}},
        )

    monkeypatch.setattr(server.cook, "request", request)

    written = asyncio.run(server.recipe_write("Pilaf.cook", "Add @onions{2}"))
    assert written.warnings == []
    assert written.aisles == ["produce", "pantry"]
    assert [
        (new.name, [(found.name, found.aisle) for found in new.similar])
        for new in written.new_ingredients
    ] == [("onions", [("onion", "produce")]), ("saffron", [])]


def test_a_file_that_does_not_parse_is_said_to_be_broken_not_unread(monkeypatch):
    """A read back failing *is* what a parse error looks like, so the two must
    not be reported the same way."""
    _collection(monkeypatch, "rice", read_back=False)
    _reports(monkeypatch, severity="error", line=9, message="Division by zero")

    written = asyncio.run(server.recipe_write("Rice.cook", "Add @rice{1/0%g}"))
    assert written.written is True
    assert written.diagnostics[0].severity == "error"
    (warning,) = written.warnings
    assert "does not parse" in warning
    assert "reading it back failed" not in warning


def test_a_parser_that_cannot_be_asked_does_not_pass_as_a_clean_file(monkeypatch):
    _collection(monkeypatch, "rice")

    async def unavailable(_path, _source):
        raise server.DiagnosticsUnavailable("refused")

    monkeypatch.setattr(server, "diagnose", unavailable)

    written = asyncio.run(server.recipe_write("Rice.cook", "Add @rice{1%cup}"))
    assert written.written is True
    assert written.diagnostics == []
    (warning,) = written.warnings
    assert "could not be asked" in warning


# -- a recipe's picture ---------------------------------------------------


def test_an_upload_link_is_minted_for_the_recipe_that_was_asked_for(monkeypatch):
    monkeypatch.setattr(server, "WEB_URL", "https://cook.example.test")
    monkeypatch.setattr(server, "PUBLIC_URL", "https://mcp.example.test/cooklang")

    upload = asyncio.run(server.recipe_image_upload("Risotto.cook"))

    assert upload.web_url == "https://cook.example.test/recipe/Risotto.cook"
    assert upload.upload_url.startswith("https://mcp.example.test/cooklang/picture/")
    token = upload.upload_url.rsplit("/", 1)[1]
    assert server.pictures.verify(token) == "Risotto.cook"


def test_the_link_says_how_long_it_is_good_for(monkeypatch):
    """Read off the signer rather than stated again here: a second copy of the
    number would go on being reported after the real one changed."""
    monkeypatch.setattr(server, "PUBLIC_URL", "https://mcp.example.test")

    upload = asyncio.run(server.recipe_image_upload("Risotto.cook"))

    assert upload.expires_in_seconds == server.pictures.TTL_SECONDS
    token = upload.upload_url.rsplit("/", 1)[1]
    with pytest.raises(server.pictures.BadToken, match="expired"):
        server.pictures.verify(token, now=time.time() + upload.expires_in_seconds + 2)


def test_a_server_with_no_public_name_says_so_instead_of_linking_to_itself(
    monkeypatch,
):
    """It binds loopback, so a minted link would name a host nothing can reach."""
    monkeypatch.setattr(server, "PUBLIC_URL", "")

    with pytest.raises(ValueError, match="no public URL"):
        asyncio.run(server.recipe_image_upload("Risotto.cook"))


def test_the_picture_must_not_travel_as_a_tool_argument():
    """Which is the one thing a model holding a photo will try. The rule is in
    the description because that is what a client cannot drop."""
    # Rewrapped, so a sentence worth asserting on is split at a column that has
    # nothing to do with what it says.
    description = " ".join(tools()["recipe_image_upload"].description.split())

    assert "curl -sS -X PUT --data-binary" in description
    assert "Never read it, encode it, or pass its bytes through a tool call" in (
        description
    )
    assert "Pictures of individual steps are not reachable" in description
    # And the ordinary way a recipe carries one, so this reads as the exception.
    assert "`image` key in its frontmatter" in description


def upload_client():
    """A client for the ASGI app, with no lifespan run.

    Deliberately not `with TestClient(...)`: the lifespan starts the MCP
    session manager, which refuses to start twice per server instance. The
    upload route needs none of it, which is rather the point of it being a
    plain HTTP route.
    """
    return TestClient(server.mcp.streamable_http_app())


def test_the_upload_route_stores_what_was_sent_to_it(monkeypatch):
    """Through the ASGI app, so the signed path and the status both count."""
    sent = []

    async def put_recipe_image(path, picture):
        sent.append((path, picture))
        return 200, {"source": "file"}

    monkeypatch.setattr(server.pictures.cook, "put_recipe_image", put_recipe_image)

    token = server.pictures.mint("Risotto.cook")
    response = upload_client().put(f"/picture/{token}", content=b"\xff\xd8jpeg")

    assert sent == [("Risotto.cook", b"\xff\xd8jpeg")]
    assert response.status_code == 200
    assert response.json() == {
        "path": "Risotto.cook",
        "stored": True,
        "source": "file",
        "warnings": [],
    }


def test_the_upload_route_refuses_an_unsigned_path_without_asking_anything(
    monkeypatch,
):
    """The signature is its only credential: nginx cannot check one, and the
    bearer token the protocol endpoint wants is not available to whatever holds
    the photo."""

    async def never(_path, _picture):  # pragma: no cover - must not be reached
        raise AssertionError("an unsigned upload reached the collection")

    monkeypatch.setattr(server.pictures.cook, "put_recipe_image", never)

    response = upload_client().put("/picture/forged.0.token", content=b"\xff\xd8x")

    assert response.status_code == 403
    assert "error" in response.json()


# -- shopping list --------------------------------------------------------


def shopping_calls(monkeypatch, changes):
    """Run one `shopping_list_edit` through the tool, and report what it sent.

    Through `call_tool` rather than the function, so the schema that rejects a
    malformed change is part of what is being tested.
    """
    sent = []

    async def request(method, path, **kwargs):
        sent.append((method, path, kwargs.get("json")))
        return httpx.Response(200, json={})

    async def shopping_list():
        return {"recipes": [], "categories": [], "pantry_items": []}

    monkeypatch.setattr(server.cook, "request", request)
    monkeypatch.setattr(server.cook, "shopping_list", shopping_list)
    result = asyncio.run(mcp.call_tool("shopping_list_edit", {"changes": changes}))[1]
    return sent, result


def test_one_batch_covers_every_shopping_list_verb(monkeypatch):
    """The four tools this replaced, as one ordered batch."""
    sent, result = shopping_calls(
        monkeypatch,
        [
            {"action": "add", "path": "Risotto.cook", "scale": 2},
            {"action": "add", "path": "Meal Plan.menu"},
            {"action": "remove", "path": "Caprese.cook"},
            {"action": "check", "name": "rice"},
            {"action": "uncheck", "name": "rice"},
            {"action": "clear"},
        ],
    )

    assert [(path, body) for _method, path, body in sent] == [
        ("/api/shopping_list/add", {"path": "Risotto.cook", "scale": 2.0}),
        ("/api/shopping_list/add_menu", {"path": "Meal Plan.menu", "scale": 1.0}),
        ("/api/shopping_list/remove", {"path": "Caprese.cook"}),
        ("/api/shopping_list/check", {"name": "rice"}),
        ("/api/shopping_list/uncheck", {"name": "rice"}),
        ("/api/shopping_list/clear", None),
    ]
    # The whole list comes back, so the client never has to read it again.
    assert result["applied"] == 6
    assert result["recipes"] == []
    assert "categories" in result


def test_the_shopping_list_carries_its_own_page(monkeypatch):
    """The list is a page as much as a recipe is, so the words for it link.

    Both tools return it, and an empty list returns it too: "nothing on the
    list yet" is an answer about the list, and links the same way.
    """
    monkeypatch.setattr(server, "WEB_URL", "https://cook.example.test")
    expected = "https://cook.example.test/shopping-list"

    async def shopping_list():
        return {"recipes": [], "categories": [], "pantry_items": []}

    monkeypatch.setattr(server.cook, "shopping_list", shopping_list)
    assert asyncio.run(server.shopping_list_read())["web_url"] == expected

    _sent, result = shopping_calls(monkeypatch, [{"action": "clear"}])
    assert result["web_url"] == expected

    # Said in both descriptions, because a client that drops the server
    # instructions has nothing else: the result is a plain object, so no
    # output schema carries the rule the way `web_url`'s own field does.
    listed = tools()
    for name in ("shopping_list_read", "shopping_list_edit"):
        assert "shopping list" in listed[name].description
        assert "Markdown link" in listed[name].description, name


def _parsed(*blocks):
    """A parsed-recipe response whose one section holds `blocks`."""
    return httpx.Response(
        200, json={"recipe": {"ingredients": [], "sections": [{"content": blocks}]}}
    )


def test_a_recipes_notes_come_back_with_the_shopping_list(monkeypatch):
    """The list says what to buy; the notes say what to buy differently.

    Both in one call: the aggregated list carries paths and ingredients and no
    recipe text at all, so the alternative is a `recipe_read` per recipe and
    the whole source back to find one `>` line.
    """
    monkeypatch.setattr(server, "WEB_URL", "https://cook.example.test")

    async def shopping_list():
        return {
            "recipes": [
                {"path": "Risotto.cook", "scale": 2.0},
                {"path": "Caprese.cook", "scale": 1.0},
            ],
            "categories": [],
            "pantry_items": [],
        }

    read = []

    async def request(_method, path, **_kwargs):
        read.append(path)
        if path == "/api/recipes/Risotto.cook":
            return _parsed(
                {"type": "text", "value": "The saffron is optional."},
                {"type": "step", "value": {"items": [], "number": 1}},
                {"type": "text", "value": "Usually eaten with the Caprese."},
            )
        return _parsed({"type": "step", "value": {"items": [], "number": 1}})

    monkeypatch.setattr(server.cook, "shopping_list", shopping_list)
    monkeypatch.setattr(server.cook, "request", request)

    recipes = asyncio.run(server.shopping_list_read())["recipes"]

    assert [recipe["notes"] for recipe in recipes] == [
        ["The saffron is optional.", "Usually eaten with the Caprese."],
        # Read and found to have none, which is not the same as unread.
        [],
    ]
    # One read each, and nothing beyond the recipes actually on the list.
    assert read == ["/api/recipes/Risotto.cook", "/api/recipes/Caprese.cook"]


def test_notes_that_cannot_be_read_are_not_a_recipe_without_notes(monkeypatch):
    """A recipe with a syntax error in it answers that read with a 500.

    `null` says the notes were not readable; `[]` would tell the model the
    recipe says nothing about itself, and it would pass that on.
    """

    async def shopping_list():
        return {
            "recipes": [{"path": "Broken.cook", "scale": 1.0}],
            "categories": [],
            "pantry_items": [],
        }

    async def request(_method, _path, **_kwargs):
        raise httpx.HTTPError("boom")

    monkeypatch.setattr(server.cook, "shopping_list", shopping_list)
    monkeypatch.setattr(server.cook, "request", request)

    result = asyncio.run(server.shopping_list_read())

    # The list itself survives: the notes are an extra, not the answer.
    assert result["recipes"][0]["notes"] is None
    assert "categories" in result


def test_search_hits_carry_no_notes_field_at_all(monkeypatch):
    """An empty query lists the whole collection.

    Filling notes there would be a request per file to answer a question
    about none of them, and an empty list would then mean both "no notes" and
    "not looked at". The field is absent from a summary instead.
    """

    async def search_entries(_query):
        return [
            {
                "path": "Risotto.cook",
                "title": "Risotto",
                "tags": [],
                "is_menu": False,
            }
        ]

    async def unexpected(*_args, **_kwargs):
        raise AssertionError("a search read the recipes behind its hits")

    monkeypatch.setattr(server.cook, "search_entries", search_entries)
    monkeypatch.setattr(server.cook, "request", unexpected)

    assert "notes" not in asyncio.run(server.recipe_search(""))[0].model_dump()


@pytest.mark.parametrize(
    "change",
    [
        {"action": "add"},
        {"action": "remove"},
        {"action": "check"},
        {"action": "uncheck"},
        {"action": "add", "path": "Risotto.cook", "scale": 0},
        {"action": "unknown", "path": "Risotto.cook"},
        # A field the action does not read is refused, not ignored: read as a
        # bare `clear`, the first of these would empty the whole list.
        {"action": "clear", "path": "Risotto.cook"},
        {"action": "check", "name": "rice", "path": "Risotto.cook"},
        {"action": "remove", "path": "Risotto.cook", "scale": 2},
        {"action": "add", "path": "Risotto.cook", "name": "rice"},
    ],
)
def test_a_shopping_change_that_cannot_be_expressed_never_reaches_the_server(
    monkeypatch, change
):
    async def unexpected(*args, **kwargs):
        pytest.fail("an invalid change reached the server")

    monkeypatch.setattr(server.cook, "request", unexpected)
    with pytest.raises(ToolError):
        asyncio.run(mcp.call_tool("shopping_list_edit", {"changes": [change]}))


# -- mark_cooked ----------------------------------------------------------


def cook_run(monkeypatch, files, **kwargs):
    """Run `mark_cooked` against a fake collection, and report the writes."""
    monkeypatch.setattr(server, "WEB_URL", "https://cook.example.test")
    written = {}

    async def list_entries():
        return [
            {
                "path": path,
                "title": menus.normalise(path),
                "tags": [],
                "is_menu": path.endswith(".menu"),
            }
            for path in files
        ]

    async def request(method, path, **options):
        if method == "GET" and path.startswith("/api/recipes/raw/"):
            return httpx.Response(200, text=files[path[len("/api/recipes/raw/") :]])
        if method == "PUT":
            written[path[len("/api/recipes/") :]] = options["content"].decode()
            return httpx.Response(200, json={})
        raise AssertionError(f"unexpected {method} {path}")

    monkeypatch.setattr(server.cook, "list_entries", list_entries)
    monkeypatch.setattr(server.cook, "request", request)
    result = asyncio.run(server.mark_cooked(**kwargs))
    return written, result


def test_marking_cooked_records_history_then_clears_the_plan(monkeypatch):
    plan = (
        "---\ntitle: Meal Plan\n---\n= Meals\n@./Risotto{2%servings}\n\n@./Caprese{}\n"
    )
    history = (
        "---\ntitle: Meal History\n---\n"
        "= Friday (2026-10-16)\n@./Chili{}\n\n"
        "= Monday (2026-10-12)\n@./Soup{}\n"
    )
    written, result = cook_run(
        monkeypatch,
        {"Meal Plan.menu": plan, "Meal History.menu": history},
        path="Risotto.cook",
        cooked_on="2026-10-14",
        feedback="Use less salt.",
    )

    # A new section, in newest-first order between the two that exist.
    assert written["Meal History.menu"] == (
        "---\ntitle: Meal History\n---\n"
        "= Friday (2026-10-16)\n@./Chili{}\n\n"
        "= Wednesday (2026-10-14)\n@./Risotto{}\n\n"
        "Feedback: Use less salt.\n\n"
        "= Monday (2026-10-12)\n@./Soup{}\n"
    )
    # Only the cooked recipe leaves the plan.
    assert written["Meal Plan.menu"] == (
        "---\ntitle: Meal Plan\n---\n= Meals\n@./Caprese{}\n"
    )
    assert result.removed_from_plan is True
    assert result.history_created is False
    assert result.cooked_on == "2026-10-14"


def test_marking_cooked_reports_the_rest_of_the_plan_with_its_pages(monkeypatch):
    """Saying what is left means naming those recipes, so the result carries
    their pages — the plan's own source holds only `@./Caprese`."""
    _, result = cook_run(
        monkeypatch,
        {
            "Meal Plan.menu": "= Meals\n@./Risotto{}\n\n@./Caprese{}\n",
            "Risotto.cook": "",
            "Caprese.cook": "",
        },
        path="Risotto.cook",
        cooked_on="2026-10-14",
    )

    assert result.removed_from_plan is True
    # The cooked one is gone; what is left is linkable.
    assert [(entry.title, entry.web_url) for entry in result.remaining_plan] == [
        ("Caprese", "https://cook.example.test/recipe/Caprese.cook")
    ]


def test_an_emptied_or_absent_plan_leaves_nothing_to_link(monkeypatch):
    _, emptied = cook_run(
        monkeypatch,
        {"Meal Plan.menu": "= Meals\n@./Risotto{}\n", "Risotto.cook": ""},
        path="Risotto.cook",
        cooked_on="2026-10-14",
    )
    _, no_plan = cook_run(monkeypatch, {}, path="Risotto.cook", cooked_on="2026-10-14")

    assert emptied.remaining_plan == []
    assert no_plan.remaining_plan == []


def test_an_estimated_date_is_marked_and_reuses_a_matching_section(monkeypatch):
    written, result = cook_run(
        monkeypatch,
        {
            "Meal Plan.menu": "= Meals\n@./Risotto{}\n",
            "Meal History.menu": "= Wednesday (2026-10-14)\n@./Soup{}\n",
        },
        path="./Risotto",
        cooked_on="2026-10-14",
        date_estimated=True,
    )

    assert written["Meal History.menu"] == (
        "= Wednesday (2026-10-14)\n@./Risotto{} — date estimated\n\n@./Soup{}\n"
    )
    assert result.date_estimated is True
    assert result.removed_from_plan is True


def test_a_missing_history_is_created_and_a_missing_plan_is_not_required(monkeypatch):
    written, result = cook_run(
        monkeypatch,
        {},
        path="Risotto.cook",
        cooked_on="2026-10-14",
    )

    assert written == {
        "Meal History.menu": (
            "---\ntitle: Meal History\n---\n= Wednesday (2026-10-14)\n@./Risotto{}\n"
        )
    }
    assert result.history_created is True
    assert result.removed_from_plan is False
    assert "no Meal Plan.menu" in result.note


def test_a_recipe_absent_from_the_plan_leaves_it_untouched(monkeypatch):
    written, result = cook_run(
        monkeypatch,
        {"Meal Plan.menu": "= Meals\n@./Caprese{}\n", "Meal History.menu": ""},
        path="Risotto.cook",
        cooked_on="2026-10-14",
    )

    assert "Meal Plan.menu" not in written
    assert result.removed_from_plan is False
    assert "only the history changed" in result.note


def test_a_date_that_is_not_a_date_is_refused_before_anything_is_written(monkeypatch):
    async def unexpected(*args, **kwargs):
        pytest.fail("a bad date reached the server")

    monkeypatch.setattr(server.cook, "list_entries", unexpected)
    monkeypatch.setattr(server.cook, "request", unexpected)
    for bad in ("yesterday", "2026-13-01", "14.10.2026", ""):
        with pytest.raises(Exception):  # noqa: B017 - pydantic pattern or ValueError
            asyncio.run(server.mark_cooked(path="Risotto.cook", cooked_on=bad))


# -- instructions ---------------------------------------------------------


def test_the_instructions_keep_only_what_is_cross_cutting():
    """Policy that belongs to one tool lives in that tool's description.

    The server instructions sit in context for the whole session, so they
    carry what spans tools — the link rule, sorting a new ingredient, the two
    file names — and nothing else; the procedures moved to the tool that
    performs them, where they are read at the moment of use.
    """
    listed = tools()

    assert "clickable Markdown link" in INSTRUCTIONS
    assert "`web_url`" in INSTRUCTIONS
    # A URL does not expire when the next call returns a different one: the
    # miss this is aimed at was a plan write whose own URL was the plan's.
    assert "not only the one from the last call" in INSTRUCTIONS
    # Nor does the rule weaken as the names pile up: the other miss was a
    # summary closing several writes that named every recipe and linked none.
    assert "run of several writes" in INSTRUCTIONS
    # And the instructions never explain how a URL is built, so a name without
    # one cannot be linked to a guess.
    assert "Never construct or guess a URL" in INSTRUCTIONS
    assert "/recipe/" not in INSTRUCTIONS
    # The shopping list is linked by the words for it rather than by a name,
    # which no one tool's description can establish on its own either.
    assert 'the words "shopping list" are that link' in INSTRUCTIONS
    assert "/shopping-list" not in INSTRUCTIONS
    assert "`Meal Plan.menu`" in INSTRUCTIONS
    assert "`Meal History.menu`" in INSTRUCTIONS
    assert "mark_cooked" in INSTRUCTIONS

    # Sorting a new ingredient starts in one tool's result and finishes in
    # another's call, so the instructions carry it the way they carry the link
    # rule: no one tool's description is read at both moments.
    assert "`new_ingredients`" in INSTRUCTIONS
    assert "`ingredients_edit`" in INSTRUCTIONS
    assert "ask the user" in INSTRUCTIONS

    # Relocated, and gone from the block that used to carry them.
    for moved, home in (
        ("date_estimated", "mark_cooked"),
        ("optional", "mark_cooked"),
        ("plausible past date", "mark_cooked"),
        ("explicitly asks", "shopping_list_read"),
        ("still upcoming or was already cooked", "shopping_list_read"),
        ("ticked off", "shopping_list_edit"),
    ):
        assert moved not in INSTRUCTIONS, moved
        assert moved in listed[home].description, (moved, home)

    # The marker's exact wording went further than a description: it is written
    # by code now, so no instruction has to spell it out at all.
    assert "date estimated" not in INSTRUCTIONS
    assert menus.ESTIMATED == "— date estimated"

    # Shorter than the file-format guidance it used to compete with.
    assert len(INSTRUCTIONS) < len(listed["recipe_write"].description)


def test_the_entry_points_say_when_to_reach_for_the_collection():
    """A client that drops the instructions sees names and descriptions only.

    The instructions are where "these are the user's own recipes" is said,
    and a client without them answers a question about dinner out of its own
    cooking knowledge and calls nothing. So every tool a cold conversation
    lands on first says when it is the one to reach for, in the words a user
    actually uses: a request about dinner or the groceries contains neither
    "recipe" nor "shopping list".
    """
    listed = tools()

    for name, words in (
        # Searching has to win against answering from general knowledge,
        # which is the only one of these a client would otherwise do anyway.
        ("recipe_search", ("dinner", "lunch", "general cooking knowledge")),
        ("recipe_read", ("how long", "eating")),
        ("recipe_write", ("kept",)),
        # A pasted link arrives with nothing said about it more often than not.
        ("recipe_import", ("bare URL",)),
        ("mark_cooked", ("last night", "eaten")),
        ("shopping_list_read", ("supermarket", "groceries")),
        ("shopping_list_edit", ("out of", "going to buy")),
    ):
        for word in words:
            assert word in listed[name].description, (name, word)

    # Said once more where a client that does deliver them reads it first.
    assert "whether or not" in INSTRUCTIONS
    assert '"recipe" or "cooking"' in INSTRUCTIONS

    # The server name is the other thing every client shows the model, so it
    # carries the everyday word for the shopping half of the collection.
    assert "Groceries" in mcp.name


def test_recipe_read_and_recipe_import_say_which_one_reaches_the_web():
    listed = tools()

    assert "recipe_import" in listed["recipe_read"].description
    assert "collection" in listed["recipe_read"].description
    assert "web page" in listed["recipe_import"].description
    assert "recipe_write" in listed["recipe_import"].description


def test_the_meal_plan_file_format_stays_with_the_tool_that_writes_it():
    write_description = tools()["recipe_write"].description

    assert "`Meal Plan.menu`" in write_description
    assert "blank line (two newline characters)" in write_description
    assert "source.url" in write_description
    # History is mark_cooked's to write, so this only points at it.
    assert "mark_cooked" in write_description


def test_a_recipes_own_notes_are_carried_where_they_change_a_decision():
    """A note in a recipe is read at the moment it matters, not in general.

    The two moments are shopping and planning, and they want different
    halves of the same note: what to buy is changed by an optional
    ingredient, a dish usually eaten alongside or a variation, while what is
    queued is changed by preparation that has to happen the day before. Both
    are capped at one short sentence and both are the recipe's words — an
    invented substitution or an inferred resting time is worse than silence.
    """
    # A description keeps the docstring's line breaks, so a phrase that spans
    # one is only findable in the text as one line.
    listed = {
        name: " ".join(tool.description.split()) for name, tool in tools().items()
    }

    for name in ("shopping_list_read", "shopping_list_edit"):
        description = listed[name]
        assert "marks optional" in description, name
        assert "usually eaten with" in description, name
        assert "variation" in description, name
    assert "substitution of your own" in listed["shopping_list_read"]

    plan = listed["recipe_read"]
    assert "before the day it is cooked" in plan
    assert "overnight" in plan
    assert "never preparation you" in plan

    # One sentence per recipe, not a second recipe pasted into the answer.
    for name in ("shopping_list_read", "shopping_list_edit", "recipe_read"):
        assert "one short sentence" in listed[name], name

    # The write side says where a note goes, so the read side has one to find,
    # and warns about the one way of writing one that silently produces none.
    write = listed["recipe_write"]
    assert "`>` note lines" in write
    assert "notes at the top of the file" in write
    assert "blank line above a note" in write
    assert "taken into that step" in write
    # A note is read before the cooking or not at all, which is what decides
    # whether something belongs in one or in a step.
    assert "cook mode does not show notes" in write

    # Read at the moment of use, so it stays out of the standing instructions.
    for phrase in ("marks optional", "one short sentence", "overnight"):
        assert phrase not in INSTRUCTIONS, phrase


def test_every_tool_description_is_json_serialisable_and_non_empty():
    for name, tool in tools().items():
        assert tool.description and tool.description.strip(), name
        json.dumps(tool.model_dump(by_alias=True))


def extras_run(monkeypatch, changes, files=None, listed=()):
    """Run `shopping_list_edit` against a fake collection and list.

    `listed` is what the shopping list already stores — the store drops the
    extension, so `Extra Items` is how its own entry comes back.
    """
    files = dict(files or {})
    sent = []

    async def list_entries():
        return [
            {
                "path": path,
                "title": menus.normalise(path),
                "tags": [],
                "is_menu": path.endswith(".menu"),
            }
            for path in files
        ]

    async def request(method, path, **options):
        if method == "GET" and path == "/api/shopping_list/items":
            return httpx.Response(200, json=[{"path": p, "scale": 1.0} for p in listed])
        if method == "GET" and path.startswith("/api/recipes/raw/"):
            return httpx.Response(200, text=files[path[len("/api/recipes/raw/") :]])
        if method == "PUT":
            files[path[len("/api/recipes/") :]] = options["content"].decode()
            return httpx.Response(200, json={})
        sent.append((path, options.get("json")))
        return httpx.Response(200, json={})

    async def shopping_list():
        return {"recipes": [], "categories": [], "pantry_items": []}

    monkeypatch.setattr(server.cook, "list_entries", list_entries)
    monkeypatch.setattr(server.cook, "request", request)
    monkeypatch.setattr(server.cook, "shopping_list", shopping_list)
    asyncio.run(mcp.call_tool("shopping_list_edit", {"changes": changes}))
    return files, sent


def test_a_first_item_creates_the_file_and_puts_it_on_the_list(monkeypatch):
    files, sent = extras_run(
        monkeypatch, [{"action": "add_item", "name": "Milch", "quantity": "1 l"}]
    )

    assert files["Extra Items.menu"] == "---\ntitle: Extra Items\n---\n@Milch{1%l}\n"
    assert sent == [
        ("/api/shopping_list/add_menu", {"path": "Extra Items.menu", "scale": 1.0})
    ]


def test_a_second_item_joins_the_file_without_adding_the_menu_twice(monkeypatch):
    files, sent = extras_run(
        monkeypatch,
        [{"action": "add_item", "name": "Taschentücher", "quantity": "2"}],
        files={"Extra Items.menu": "---\ntitle: Extra Items\n---\n@Milch{1%l}\n"},
        listed=["Extra Items"],
    )

    assert files["Extra Items.menu"] == (
        "---\ntitle: Extra Items\n---\n@Milch{1%l}\n\n@Taschentücher{2}\n"
    )
    assert sent == []


def test_items_from_the_last_trip_do_not_come_back(monkeypatch):
    """Off the list means it was cleared — here or in the web UI, which says
    nothing to this server — so the file is last trip's and is dropped."""
    files, sent = extras_run(
        monkeypatch,
        [{"action": "add_item", "name": "Butter", "quantity": "250 g"}],
        files={"Extra Items.menu": "---\ntitle: Extra Items\n---\n@Milch{1%l}\n"},
        listed=[],
    )

    assert files["Extra Items.menu"] == "---\ntitle: Extra Items\n---\n@Butter{250%g}\n"
    assert sent == [
        ("/api/shopping_list/add_menu", {"path": "Extra Items.menu", "scale": 1.0})
    ]


def test_removing_the_last_item_takes_the_menu_off_the_list(monkeypatch):
    """An entry with no ingredients under it would otherwise sit there
    claiming the user still has something to buy."""
    files, sent = extras_run(
        monkeypatch,
        [{"action": "remove_item", "name": "Milch"}],
        files={"Extra Items.menu": "---\ntitle: Extra Items\n---\n@Milch{1%l}\n"},
        listed=["Extra Items"],
    )

    assert menus.items(files["Extra Items.menu"]) == []
    # By the path the store gave back, which carries no extension.
    assert sent == [("/api/shopping_list/remove", {"path": "Extra Items"})]


def test_removing_one_of_several_items_leaves_the_menu_on_the_list(monkeypatch):
    files, sent = extras_run(
        monkeypatch,
        [{"action": "remove_item", "name": "Milch"}],
        files={
            "Extra Items.menu": (
                "---\ntitle: Extra Items\n---\n@Milch{1%l}\n\n@Taschentücher{2}\n"
            )
        },
        listed=["Extra Items"],
    )

    assert files["Extra Items.menu"] == (
        "---\ntitle: Extra Items\n---\n@Taschentücher{2}\n"
    )
    assert sent == []


def test_removing_an_ingredient_a_recipe_calls_for_says_so(monkeypatch):
    """`remove_item` reaches only the loose items. Silently doing nothing
    would be reported to the user as a removal that never happened."""
    with pytest.raises(ToolError) as error:
        extras_run(
            monkeypatch,
            [{"action": "remove_item", "name": "Mehl"}],
            files={"Extra Items.menu": "---\ntitle: Extra Items\n---\n@Milch{1%l}\n"},
            listed=["Extra Items"],
        )

    assert "not on the list as a single item" in str(error.value)


def test_a_cleared_list_in_the_same_batch_is_seen_by_the_next_item(monkeypatch):
    """`clear` is one request and the file is another, so the two stay in step
    only because each item reads the list back."""
    files, sent = extras_run(
        monkeypatch,
        [
            {"action": "clear"},
            {"action": "add_item", "name": "Butter"},
        ],
        files={"Extra Items.menu": "---\ntitle: Extra Items\n---\n@Milch{1%l}\n"},
        listed=[],
    )

    assert files["Extra Items.menu"] == "---\ntitle: Extra Items\n---\n@Butter{}\n"
    assert sent == [
        ("/api/shopping_list/clear", None),
        ("/api/shopping_list/add_menu", {"path": "Extra Items.menu", "scale": 1.0}),
    ]


def test_a_file_deleted_from_under_the_list_is_written_again(monkeypatch):
    """Deleted by hand while the list still names it. Asking the collection
    for it would 404, and every addition from then on would fail with no way
    back short of editing the list by hand."""
    files, sent = extras_run(
        monkeypatch,
        [{"action": "add_item", "name": "Butter", "quantity": "250 g"}],
        files={},
        listed=["Extra Items"],
    )

    assert files["Extra Items.menu"] == "---\ntitle: Extra Items\n---\n@Butter{250%g}\n"
    # Already on the list, so it is not added a second time.
    assert sent == []


def test_the_list_says_which_names_were_added_by_hand(monkeypatch):
    """Nothing else in the result does: the aggregator sums a recipe's butter
    and a loose one into a single line under a single name."""

    async def shopping_list():
        return {
            "recipes": [
                {"path": "Risotto.cook", "scale": 1.0},
                {"path": "Extra Items.menu", "scale": 1.0},
            ],
            "categories": [
                {
                    "category": "other",
                    "items": [{"name": "butter", "quantity": "280 g"}],
                }
            ],
            "pantry_items": [],
        }

    async def request(method, path, **_options):
        if path.startswith("/api/recipes/raw/"):
            assert (method, path) == ("GET", "/api/recipes/raw/Extra Items.menu")
            return httpx.Response(
                200,
                text="---\ntitle: Extra Items\n---\n@butter{250%g}\n\n@Milch{1%l}\n",
            )
        # Every recipe on the list is also read for its notes.
        return _parsed()

    monkeypatch.setattr(server.cook, "shopping_list", shopping_list)
    monkeypatch.setattr(server.cook, "request", request)

    assert asyncio.run(server.shopping_list_read())["extra_items"] == [
        "butter",
        "Milch",
    ]


def test_a_list_without_loose_items_does_not_go_looking_for_them(monkeypatch):
    async def shopping_list():
        return {
            "recipes": [{"path": "Risotto.cook", "scale": 1.0}],
            "categories": [],
            "pantry_items": [],
        }

    async def request(_method, path, **_kwargs):
        if path.startswith("/api/recipes/raw/"):
            pytest.fail("the loose-items file was read when nothing pointed at it")
        return _parsed()

    monkeypatch.setattr(server.cook, "shopping_list", shopping_list)
    monkeypatch.setattr(server.cook, "request", request)

    assert asyncio.run(server.shopping_list_read())["extra_items"] == []


def test_a_loose_items_file_that_cannot_be_read_costs_the_field_only(monkeypatch):
    """The list was read fine; only the note about which names are loose is
    missing, and an empty field is honest about that."""

    async def shopping_list():
        return {
            "recipes": [{"path": "Extra Items.menu", "scale": 1.0}],
            "categories": [],
            "pantry_items": [],
        }

    async def request(*_args, **_kwargs):
        raise server.cook.CookCliError("cook server unreachable")

    monkeypatch.setattr(server.cook, "shopping_list", shopping_list)
    monkeypatch.setattr(server.cook, "request", request)

    assert asyncio.run(server.shopping_list_read())["extra_items"] == []
