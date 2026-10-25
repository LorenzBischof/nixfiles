"""The reshaping `cookcli.py` does to the API's JSON."""

import asyncio

from cooklang_mcp import cookcli
from cooklang_mcp.cookcli import (
    _search_result,
    _walk,
    aggregate_requests,
    format_quantities,
    recipe_notes,
)


def regular(value):
    """A cooklang `Number`, which is what a range is made of."""
    return {"type": "regular", "value": value}


def number(value):
    """A cooklang `Value` wrapping one number, which is what a quantity holds."""
    return {"type": "number", "value": regular(value)}


def test_walk_tree_flattens_and_relativises_paths():
    tree = {
        "name": "collection",
        "path": "/var/lib/cooklang/collection",
        "recipe": None,
        "children": {
            "Backen": {
                "name": "Backen",
                "path": "/var/lib/cooklang/collection/Backen",
                "recipe": None,
                "children": {
                    "Kaesekuchen": {
                        "name": "Kaesekuchen",
                        "path": "/var/lib/cooklang/collection/Backen/Kaesekuchen.cook",
                        "recipe": {
                            "metadata": {
                                "title": "Käsekuchen",
                                "tags": "backen, süß",
                                "servings": 12,
                            }
                        },
                        "children": {},
                    }
                },
            },
            "2026-W38": {
                "name": "2026-W38",
                "path": "/var/lib/cooklang/collection/2026-W38.menu",
                "recipe": {"metadata": {}},
                "children": {},
            },
        },
    }

    entries = sorted(_walk(tree, root=tree["path"]), key=lambda e: e["path"])

    assert entries == [
        {
            "path": "2026-W38.menu",
            "is_menu": True,
            "title": "2026-W38",
            "tags": [],
        },
        {
            "path": "Backen/Kaesekuchen.cook",
            "is_menu": False,
            "title": "Käsekuchen",
            # A comma-separated `tags:` line is the common spelling; a YAML
            # list is the other, and both have to come back as a list.
            "tags": ["backen", "süß"],
        },
    ]


def test_search_result_uses_rich_collection_metadata():
    entry = {
        "path": "Backen/Kaesekuchen.cook",
        "title": "Käsekuchen",
        "tags": ["backen", "süß"],
        "is_menu": False,
    }

    assert (
        _search_result({"name": "Käsekuchen", "path": "Backen/Kaesekuchen.cook"}, entry)
        == entry
    )


def test_search_result_survives_a_recipe_disappearing_from_the_tree():
    assert _search_result({"name": "Week 38", "path": "Plans/Week 38.menu"}, None) == {
        "path": "Plans/Week 38.menu",
        "title": "Week 38",
        "tags": [],
        "is_menu": True,
    }


def test_search_entries_without_a_query_returns_the_collection(monkeypatch):
    entries = [
        {
            "path": "Risotto.cook",
            "title": "Risotto",
            "tags": ["dinner"],
            "is_menu": False,
        }
    ]

    async def list_entries():
        return entries

    async def unexpected_request(*args, **kwargs):
        raise AssertionError("an empty search should not call /api/search")

    monkeypatch.setattr(cookcli, "list_entries", list_entries)
    monkeypatch.setattr(cookcli, "request", unexpected_request)

    assert asyncio.run(cookcli.search_entries()) == entries


def test_search_entries_preserves_search_order_and_adds_metadata(monkeypatch):
    class Response:
        @staticmethod
        def json():
            return [
                {"name": "Risotto", "path": "Risotto.cook"},
                {"name": "Week 38", "path": "Plans/Week 38.menu"},
            ]

    async def request(method, path, **kwargs):
        assert (method, path, kwargs) == (
            "GET",
            "/api/search",
            {"params": {"q": "rice"}},
        )
        return Response()

    async def list_entries():
        return [
            {
                "path": "Plans/Week 38.menu",
                "title": "Week 38",
                "tags": ["weekly"],
                "is_menu": True,
            },
            {
                "path": "Risotto.cook",
                "title": "Mushroom Risotto",
                "tags": ["dinner", "italian"],
                "is_menu": False,
            },
        ]

    monkeypatch.setattr(cookcli, "request", request)
    monkeypatch.setattr(cookcli, "list_entries", list_entries)

    assert asyncio.run(cookcli.search_entries("rice")) == [
        {
            "path": "Risotto.cook",
            "title": "Mushroom Risotto",
            "tags": ["dinner", "italian"],
            "is_menu": False,
        },
        {
            "path": "Plans/Week 38.menu",
            "title": "Week 38",
            "tags": ["weekly"],
            "is_menu": True,
        },
    ]


def test_aggregate_requests_expands_a_stored_menu():
    """A menu goes in once per recipe, plus once for its own loose items."""
    stored = [
        {
            "path": "2026-W38.menu",
            "scale": 1.0,
            "recipes": [
                {"path": "Pfannkuchen.cook", "scale": 2.0},
                {"path": "Kaesekuchen.cook", "scale": 1.0, "included_references": []},
            ],
        },
        {"path": "Risotto.cook", "scale": 3.0},
    ]

    assert aggregate_requests(stored) == [
        {"recipe": "2026-W38.menu", "scale": 1.0, "included_references": []},
        {"recipe": "Pfannkuchen.cook", "scale": 2.0},
        {"recipe": "Kaesekuchen.cook", "scale": 1.0, "included_references": []},
        {"recipe": "Risotto.cook", "scale": 3.0},
    ]


def test_format_quantities_reads_as_a_cook_would_write_it():
    assert format_quantities([{"unit": "g", "value": number(200.0)}]) == "200 g"
    # A count, which arrives as an f64 and must not read "6.0 eggs".
    assert format_quantities([{"unit": None, "value": number(6.0)}]) == "6"
    assert format_quantities([{"unit": "kg", "value": number(1.25)}]) == "1.25 kg"
    assert (
        format_quantities(
            [
                {
                    "unit": "tsp",
                    "value": {
                        "type": "number",
                        "value": {
                            "type": "fraction",
                            "value": {"whole": 1, "num": 1, "den": 2, "err": 0.0},
                        },
                    },
                }
            ]
        )
        == "1 1/2 tsp"
    )
    assert (
        format_quantities(
            [
                {
                    "unit": None,
                    "value": {
                        "type": "range",
                        "value": {"start": regular(3.0), "end": regular(5.0)},
                    },
                }
            ]
        )
        == "3-5"
    )
    # Two units that cannot be added together keep both.
    assert (
        format_quantities(
            [
                {"unit": "g", "value": number(50.0)},
                {"unit": "tsp", "value": number(1.0)},
            ]
        )
        == "50 g + 1 tsp"
    )
    # An ingredient named without a quantity.
    assert format_quantities([]) == "some"


def test_a_websocket_endpoint_keeps_the_servers_address(monkeypatch):
    """`COOKLANG_SERVER_URL` becomes the HTTP client's base URL, and the
    WebSocket endpoint has to land on the same host and port."""
    monkeypatch.setattr(cookcli._http, "base_url", "http://127.0.0.1:9080")
    assert cookcli.ws_url("/api/ws/lsp") == "ws://127.0.0.1:9080/api/ws/lsp"


def test_a_tls_server_is_reached_over_tls(monkeypatch):
    monkeypatch.setattr(cookcli._http, "base_url", "https://cook.example.test")
    assert cookcli.ws_url("/api/ws/lsp") == "wss://cook.example.test/api/ws/lsp"


# -- notes ----------------------------------------------------------------
#
# The shapes below are what cookcli 0.38.1 actually returns for the sources in
# each docstring, checked against a running `cook server`.


def test_notes_are_the_text_blocks_a_recipe_holds():
    """`> …` parses to a `text` block, a step to a `step`, in file order.

        > Serve with the Caprese; the saffron is optional.

        Fry the @onion{1} in @butter{30%g}.

        > Make the stock the day before.
    """
    recipe = {
        "sections": [
            {
                "name": None,
                "content": [
                    {
                        "type": "text",
                        "value": "Serve with the Caprese; the saffron is optional.",
                    },
                    {"type": "step", "value": {"items": [], "number": 1}},
                    {"type": "text", "value": "Make the stock the day before."},
                ],
            }
        ]
    }

    assert recipe_notes(recipe) == [
        "Serve with the Caprese; the saffron is optional.",
        "Make the stock the day before.",
    ]


def test_consecutive_note_lines_arrive_as_one_note():
    """The parser joins them, so neither does this nor splits them again.

        > one line note
        > second consecutive note line
    """
    recipe = {
        "sections": [
            {
                "content": [
                    {
                        "type": "text",
                        "value": "one line note second consecutive note line",
                    }
                ]
            }
        ]
    }

    assert recipe_notes(recipe) == ["one line note second consecutive note line"]


def test_a_marker_swallowed_into_a_step_is_not_a_note():
    """A `>` line directly under a step line belongs to that step.

        Step with @salt{}.
        > note right after a step

    The parser returns one `step` and no `text`, and the recipe's page shows
    no note — which is the reason notes are read from the parse and not by
    scanning the source for `>`: a scan would report this one and the user
    would be told something their recipe does not say.
    """
    recipe = {
        "sections": [
            {
                "content": [
                    {
                        "type": "step",
                        "value": {
                            "items": [
                                {"type": "text", "value": "Step with "},
                                {"index": 0, "type": "ingredient"},
                                {"type": "text", "value": ". > note right after a step"},
                            ],
                            "number": 1,
                        },
                    }
                ]
            }
        ]
    }

    assert recipe_notes(recipe) == []


def test_notes_from_every_section_in_order():
    recipe = {
        "sections": [
            {"name": None, "content": [{"type": "text", "value": "first"}]},
            {"name": "Section", "content": [{"type": "text", "value": "second"}]},
        ]
    }

    assert recipe_notes(recipe) == ["first", "second"]


def test_a_recipe_with_no_notes_and_a_menu_file_hold_none():
    """A `.menu` parses as a recipe whose blocks are all references."""
    assert recipe_notes({"sections": [{"content": []}]}) == []
    assert recipe_notes({"sections": []}) == []
    # Absent and null both occur: `/api/recipes/*path` omits what it has none
    # of, and a caller passing `{}` through must not raise either.
    assert recipe_notes({}) == []
    assert recipe_notes({"sections": None}) == []
    # Whitespace is not a note.
    assert recipe_notes({"sections": [{"content": [{"type": "text", "value": " "}]}]}) == []
