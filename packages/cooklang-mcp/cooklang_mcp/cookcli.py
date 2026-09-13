"""The CookCLI HTTP API, and the few places its JSON needs reshaping.

Everything stateful lives in `cook server`: the recipe files, the aisle and
pantry configuration, and the shopping list it shares with its own web UI.

Four things are reshaped rather than passed through, because the API's own
shape is unusable on the other end:

* the recipe tree is nested and its paths are absolute, while every other
  endpoint wants a flat path relative to the collection root;
* search results carry only a title and path, while callers need the same tags
  and recipe-or-menu distinction whether they search or list everything;
* a quantity is a four-level tagged union that reads as `200 g` and serialises
  as forty characters of JSON;
* the persistent shopping list stores *recipes*, so the ingredients behind it
  take a second call — see `shopping_list`.
"""

from __future__ import annotations

import os
from pathlib import PurePosixPath
from typing import Any

import httpx

_http = httpx.AsyncClient(
    base_url=os.environ.get("COOKLANG_SERVER_URL", "http://127.0.0.1:9080").rstrip("/"),
    timeout=30.0,
)


class CookCliError(RuntimeError):
    """A request to `cook server` failed."""


async def request(method: str, path: str, **kwargs: Any) -> httpx.Response:
    try:
        response = await _http.request(method, path, **kwargs)
    except httpx.HTTPError as err:
        raise CookCliError(f"cook server unreachable: {err}") from err
    if response.is_success:
        return response
    # The API reports failures as `{"error": "..."}`, but not universally:
    # axum's own query-string and body rejections come back as plain text.
    detail = response.text.strip()
    try:
        detail = response.json().get("error", detail)
    except ValueError:
        pass
    raise CookCliError(f"{method} {path} failed ({response.status_code}): {detail}")


async def list_entries() -> list[dict[str, Any]]:
    """Every `.cook` and `.menu` file, flattened out of the recipe tree."""
    tree = (await request("GET", "/api/recipes")).json()
    return sorted(_walk(tree, root=tree.get("path", "")), key=lambda e: e["path"])


async def search_entries(query: str = "") -> list[dict[str, Any]]:
    """Recipes matching `query`, with the collection metadata joined in.

    The search endpoint returns only a title and path. The recipe tree supplies
    tags and distinguishes recipes from meal plans. With no query the tree is
    already the complete result, so there is no reason to call both endpoints.
    """
    if not query:
        return await list_entries()

    hits = (await request("GET", "/api/search", params={"q": query})).json()
    entries = {entry["path"]: entry for entry in await list_entries()}
    return [_search_result(hit, entries.get(hit["path"])) for hit in hits]


def _search_result(hit: dict[str, Any], entry: dict[str, Any] | None) -> dict[str, Any]:
    """Give one search hit the same shape as an entry from the recipe tree."""
    if entry is not None:
        return entry

    # The file may disappear between the search and tree requests. Preserve the
    # hit with the metadata the search endpoint supplied instead of silently
    # dropping it.
    path = hit["path"]
    return {
        "path": path,
        "title": hit.get("name") or PurePosixPath(path).stem,
        "tags": [],
        "is_menu": path.endswith(".menu"),
    }


async def shopping_list() -> dict[str, Any]:
    """The stored list, with the ingredients it adds up to.

    Two calls, because the store holds recipes and only the aggregator turns
    them into ingredients. This is exactly what the web UI does, so the two
    always show the same list.
    """
    items = (await request("GET", "/api/shopping_list/items")).json()
    if not items:
        return {"recipes": [], "categories": [], "pantry_items": []}

    aggregated = (
        await request("POST", "/api/shopping_list", json=aggregate_requests(items))
    ).json()
    checked = {name.lower() for name in aggregated.get("checked", [])}

    return {
        "recipes": [
            {"path": item["path"], "scale": item.get("scale", 1.0)} for item in items
        ],
        "categories": [
            {
                "category": category["category"],
                "items": [
                    {
                        "name": item["name"],
                        "quantity": format_quantities(item.get("quantities", [])),
                        "checked": item["name"].lower() in checked,
                    }
                    for item in category["items"]
                ],
            }
            for category in aggregated.get("categories", [])
        ],
        # Already subtracted from the quantities above; listed so it is clear
        # why an ingredient a recipe calls for is missing or short.
        "pantry_items": aggregated.get("pantry_items", []),
    }


def _walk(node: dict[str, Any], root: str) -> Any:
    """Yield one entry per file in a `/api/recipes` tree."""
    recipe = node.get("recipe")
    if recipe is not None:
        path = (
            str(PurePosixPath(node["path"]).relative_to(root)) if root else node["path"]
        )
        metadata = recipe.get("metadata") or {}
        yield {
            "path": path,
            "is_menu": path.endswith(".menu"),
            "title": metadata.get("title") or node["name"],
            "tags": _tags(metadata.get("tags")),
        }
    for child in node.get("children", {}).values():
        yield from _walk(child, root)


def _tags(value: Any) -> list[str]:
    """Normalise the `tags` frontmatter, which is a list or a comma list."""
    if isinstance(value, str):
        value = value.split(",")
    if not isinstance(value, list):
        return []
    return [str(tag).strip() for tag in value if str(tag).strip()]


def aggregate_requests(items: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Turn stored entries into the aggregator's request body.

    A stored menu carries its resolved recipes in `recipes`. Those go in as
    individual requests, and the menu itself goes in once more with no
    references expanded, which is how its own loose ingredients — the
    `@paper towels{1}` written straight into the plan — reach the list.
    """
    requests: list[dict[str, Any]] = []
    for item in items:
        nested = item.get("recipes")
        if nested:
            requests.append(
                {
                    "recipe": item["path"],
                    "scale": item.get("scale", 1.0),
                    "included_references": [],
                }
            )
        requests.extend(_recipe_request(recipe) for recipe in nested or [item])
    return requests


def _recipe_request(item: dict[str, Any]) -> dict[str, Any]:
    request = {"recipe": item["path"], "scale": item.get("scale", 1.0)}
    if item.get("included_references") is not None:
        request["included_references"] = item["included_references"]
    return request


def format_quantities(quantities: list[dict[str, Any]]) -> str:
    """Render a shopping-list quantity as a cook would write it.

    An ingredient measured two ways — 200 g in one recipe, a pinch in another —
    keeps both, because they cannot be added up. An empty list means the recipe
    named the ingredient without a quantity: "some".
    """
    rendered = []
    for quantity in quantities:
        value = _format_value(quantity.get("value"))
        unit = quantity.get("unit")
        if value:
            rendered.append(f"{value} {unit}" if unit else value)
    return " + ".join(rendered) if rendered else "some"


def _format_value(value: Any) -> str:
    if not isinstance(value, dict):
        return ""
    kind = value.get("type")
    if kind == "number":
        return _format_number(value.get("value"))
    if kind == "range":
        span = value.get("value") or {}
        return f"{_format_number(span.get('start'))}-{_format_number(span.get('end'))}"
    if kind == "text":
        return str(value.get("value", ""))
    return ""


def _format_number(number: Any) -> str:
    if not isinstance(number, dict):
        return ""
    if number.get("type") == "fraction":
        fraction = number.get("value", {})
        whole, num, den = (
            fraction.get("whole", 0),
            fraction.get("num", 0),
            fraction.get("den", 1),
        )
        if not num:
            return str(whole)
        return f"{whole} {num}/{den}" if whole else f"{num}/{den}"
    amount = float(number.get("value", 0))
    # Quantities arrive as f64, so a count of eggs is `6.0`. Round-tripping
    # through int keeps whole numbers whole without touching 0.5 or 1.25.
    return str(int(amount)) if amount.is_integer() else f"{amount:g}"
