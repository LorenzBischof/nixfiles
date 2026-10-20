"""The MCP surface exposed to clients."""

import asyncio
import json

import httpx
import pytest
from mcp.server.fastmcp.exceptions import ToolError

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
    # Only the importer reaches outside the collection.
    assert listed["recipe_import"].annotations.openWorldHint is True
    assert listed["recipe_read"].annotations.openWorldHint is False


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
        return httpx.Response(200, json={"recipe": {"ingredients": []}})

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
        assert (method, path) == ("GET", "/api/recipes/raw/Extra Items.menu")
        return httpx.Response(
            200, text="---\ntitle: Extra Items\n---\n@butter{250%g}\n\n@Milch{1%l}\n"
        )

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

    async def request(*_args, **_kwargs):
        pytest.fail("the loose-items file was read when nothing pointed at it")

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
