"""The reshaping `cookcli.py` does to the API's JSON."""

import asyncio

from cooklang_mcp import cookcli
from cooklang_mcp.cookcli import (
    _search_result,
    _walk,
    aggregate_requests,
    format_quantities,
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
