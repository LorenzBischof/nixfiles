"""What a write hands back about ingredient names no aisle holds yet.

The sorting itself is the model's call — which aisle fits, and whether two
names are one ingredient — so what is tested here is that it arrives with
everything one `ingredients_edit` batch needs: the candidates a name resembles,
the aisle each sits in, and the aisles there are to choose from.
"""

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


def check_for(monkeypatch, *names, catalogue=CATALOGUE):
    async def request(method, path, **kwargs):
        assert (method, path) == ("GET", "/api/aisles")
        return httpx.Response(200, json=catalogue)

    monkeypatch.setattr(server.cook, "request", request)
    ingredients = [{"name": name} for name in names]
    return asyncio.run(server._catalogue_check(ingredients))


def candidates(new):
    return [(found.name, found.aisle) for found in new.similar]


def test_catalogued_names_pass_in_any_case(monkeypatch):
    check = check_for(monkeypatch, "butter", "MILK", "Milch")
    assert check.new_ingredients == []
    assert check.warnings == []
    # Nothing to sort, so the aisles are not worth carrying.
    assert check.aisles == []


def test_a_name_inside_another_is_offered_as_a_candidate(monkeypatch):
    check = check_for(monkeypatch, "unsalted butter", "garlic cloves")
    cloves, butter = check.new_ingredients
    assert (cloves.name, candidates(cloves)) == (
        "garlic cloves",
        [("garlic clove", "produce")],
    )
    assert (butter.name, candidates(butter)) == (
        "unsalted butter",
        [("butter", "dairy")],
    )


def test_a_candidate_is_named_as_the_shopping_list_shows_it(monkeypatch):
    """Its preferred name, which is also what identifies it to an edit — an
    alias would not."""
    (milk,) = check_for(monkeypatch, "whole milk").new_ingredients
    assert candidates(milk) == [("milk", "dairy")]


def test_a_plural_is_the_same_word(monkeypatch):
    (onions,) = check_for(monkeypatch, "onions").new_ingredients
    assert candidates(onions) == [("onion", "produce")]


def test_a_misspelling_is_caught_by_spelling(monkeypatch):
    (buter,) = check_for(monkeypatch, "buter").new_ingredients
    assert candidates(buter) == [("butter", "dairy")]


def test_a_name_with_nothing_similar_still_comes_with_the_aisles(monkeypatch):
    """There is no alias to add, so the whole of the decision is the aisle."""
    check = check_for(monkeypatch, "saffron", "tahini", "saffron")
    assert [new.name for new in check.new_ingredients] == ["saffron", "tahini"]
    assert all(new.similar == [] for new in check.new_ingredients)
    assert check.aisles == ["produce", "dairy"]


def test_no_ingredient_to_check_needs_no_catalogue(monkeypatch):
    async def request(*args, **kwargs):
        raise AssertionError("the catalogue was read without need")

    monkeypatch.setattr(server.cook, "request", request)
    assert asyncio.run(server._catalogue_check([])).new_ingredients == []
    references = [{"name": "Dough", "reference": {"name": "Dough"}}]
    assert asyncio.run(server._catalogue_check(references)).new_ingredients == []


def test_without_an_aisle_file_nothing_can_be_sorted(monkeypatch):
    catalogue = {"configured": False, "warnings": [], "aisles": []}
    check = check_for(monkeypatch, "rice", "milk", catalogue=catalogue)
    assert check.new_ingredients == []
    assert check.aisles == []
    (warning,) = check.warnings
    assert "no aisle file" in warning
    assert "Ask the user" in warning
