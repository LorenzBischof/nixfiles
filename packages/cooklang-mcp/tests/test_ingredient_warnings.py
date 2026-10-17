"""The ingredient names a write warns about, and the ones it accepts."""

import asyncio

import httpx

from cooklang_mcp import server

CATALOGUE = {
    "configured": True,
    "warnings": [],
    "aisles": [
        {
            "name": "produce",
            "ingredients": [{"names": ["garlic clove"]}, {"names": ["onion"]}],
        },
        {
            "name": "dairy",
            "ingredients": [{"names": ["butter"]}, {"names": ["milk", "Milch"]}],
        },
    ],
}


def warnings_for(monkeypatch, *names, catalogue=CATALOGUE):
    async def request(method, path, **kwargs):
        assert (method, path) == ("GET", "/api/aisles")
        return httpx.Response(200, json=catalogue)

    monkeypatch.setattr(server.cook, "request", request)
    ingredients = [{"name": name} for name in names]
    return asyncio.run(server._ingredient_warnings(ingredients))


def test_catalogued_names_pass_in_any_case(monkeypatch):
    assert warnings_for(monkeypatch, "butter", "MILK", "Milch") == []


def test_a_name_inside_another_is_suggested(monkeypatch):
    warnings = warnings_for(monkeypatch, "unsalted butter", "garlic cloves")
    assert len(warnings) == 2
    assert "'garlic cloves' is new, but the catalogue has 'garlic clove'" in warnings[0]
    assert "'unsalted butter' is new, but the catalogue has 'butter'" in warnings[1]
    assert "Reuse one only if it is the same ingredient." in warnings[0]


def test_a_suggestion_names_what_the_shopping_list_shows(monkeypatch):
    (warning,) = warnings_for(monkeypatch, "whole milk")
    assert "'whole milk' is new, but the catalogue has 'milk'" in warning


def test_a_plural_is_the_same_word(monkeypatch):
    (warning,) = warnings_for(monkeypatch, "onions")
    assert "'onions' is new, but the catalogue has 'onion'" in warning


def test_a_misspelling_is_caught_by_spelling(monkeypatch):
    (warning,) = warnings_for(monkeypatch, "buter")
    assert "'buter' is new, but the catalogue has 'butter'" in warning


def test_names_with_nothing_similar_share_one_warning(monkeypatch):
    (warning,) = warnings_for(monkeypatch, "saffron", "tahini", "saffron")
    assert warning == (
        "Not in the aisle catalogue, which is fine for a new ingredient: "
        "'saffron', 'tahini'"
    )


def test_no_ingredient_to_check_needs_no_catalogue(monkeypatch):
    async def request(*args, **kwargs):
        raise AssertionError("the catalogue was read without need")

    monkeypatch.setattr(server.cook, "request", request)
    assert asyncio.run(server._ingredient_warnings([])) == []
    references = [{"name": "Dough", "reference": {"name": "Dough"}}]
    assert asyncio.run(server._ingredient_warnings(references)) == []


def test_without_an_aisle_file_nothing_is_checked(monkeypatch):
    catalogue = {"configured": False, "warnings": [], "aisles": []}
    assert warnings_for(monkeypatch, "rice", "milk", catalogue=catalogue) == [
        "The collection has no aisle file, so the names were not checked."
    ]
