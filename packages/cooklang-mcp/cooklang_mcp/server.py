"""The MCP tools, and the transports they are served over.

Every tool is a call to `cook server` (see `cookcli.py`), except `fetch_recipe`,
which reads a web page. The server keeps no state of its own: the recipes, the
shopping list and the pantry all live in the collection `cook server` was
pointed at, so what is done here shows up in its web UI and the other way
round.
"""

from __future__ import annotations

import logging
import os
import secrets
from typing import Annotated, Any
from urllib.parse import quote

from mcp.server.auth.provider import AccessToken, TokenVerifier
from mcp.server.auth.settings import AuthSettings
from mcp.server.fastmcp import FastMCP
from mcp.server.transport_security import TransportSecuritySettings
from pydantic import AnyHttpUrl, BaseModel, Field

from . import cookcli as cook
from .importer import fetch_recipe as fetch_recipe_from_url

WEB_URL = (
    os.environ.get("COOKLANG_WEB_URL")
    or os.environ.get("COOKLANG_SERVER_URL")
    or "http://127.0.0.1:9080"
).rstrip("/")

INSTRUCTIONS = f"""\
Browse and manage the user's personal recipe collection, meal plans, and \
shopping list. This includes finding something to cook, working with recipes, \
planning meals, and importing recipes from the web.

Whenever a user-facing answer mentions a recipe or meal plan that currently \
exists in the collection, make its title or path a clickable Markdown link to \
its Cook web page. This includes the confirmation after creating or updating \
one. Use the `web_url` returned by the tools. If only a path is available, its \
web page is `{WEB_URL}/recipe/<percent-encoded path>`. Do not substitute a \
recipe's external `source.url`; that is where the recipe came from, not its \
page in the user's collection. \

`Meal Plan.menu` at the collection root is the ordered queue of upcoming \
recipes, under `Meals`. `Meal History.menu` is the record of cooked recipes. \
Read a file before changing it, write its complete updated contents, and only \
create it when it does not exist. Do not create weekly or date-named plans. \

Only copy the shopping-list recipes into `Meal Plan.menu` when the user \
explicitly asks. Read the shopping list and current plan, then append missing \
recipe paths in shopping-list order without disturbing the existing queue. \
Preserve a non-default shopping-list scale; use empty braces for scale 1. Skip \
an already-planned path and tell the user it was skipped; for this comparison, \
`Risotto.cook` and `./Risotto` are the same path. Show the complete resulting \
plan. Recipes that were in the plan before the copy but are absent from the \
shopping list may be stale: ask whether each is still upcoming or was cooked. \
After the plan was written successfully, clear the shopping list when it \
contains ingredients and all of them are checked, and tell the user that it \
was cleared. If any ingredient is unchecked, ask before clearing and otherwise \
leave the shopping list unchanged. \

When the user says a recipe was cooked, record it in `Meal History.menu` and \
remove it from `Meal Plan.menu` if present. Ask when it was cooked and, \
ask for brief, optional feedback about how it turned out or what to change next \
time. Use the exact date when known. For a vague or unknown answer, choose a \
plausible past date using the existing history; normally avoid placing two \
recipes on one inferred day, but treat that as a soft rule. Mark only the \
inferred recipe with `— date estimated`. Store feedback on a `Feedback:` line \
directly below that recipe, but record the meal even without feedback. Reuse a \
matching date section and keep dated history sections newest-first. Write the \
history successfully before removing the recipe from the current plan.\
"""

Path = Annotated[
    str,
    Field(
        description=(
            "Path relative to the collection root, e.g. `Risotto.cook` or "
            "`Meal Plan.menu`."
        )
    ),
]
Scale = Annotated[
    float, Field(description="Multiply the recipe's quantities by this.", gt=0)
]


class RecipeSummary(BaseModel):
    """Metadata returned for a recipe or meal plan search result."""

    path: str = Field(description="Path used with the other recipe tools.")
    title: str = Field(description="The user-facing recipe or meal-plan name.")
    web_url: str = Field(description="Clickable Cook web page for this entry.")
    tags: list[str] = Field(description="Tags stored in the file's metadata.")
    is_menu: bool = Field(
        description="Whether this is a meal plan instead of a recipe."
    )


class RecipeDocument(BaseModel):
    """A stored recipe or meal plan and its Cook web page."""

    path: str = Field(description="Path used with the other recipe tools.")
    web_url: str = Field(description="Clickable Cook web page for this entry.")
    source: str = Field(
        description="Complete raw Cooklang source, frontmatter included."
    )


def recipe_web_url(path: str) -> str:
    """Return the public Cook page for a collection-relative path."""
    while path.startswith("./"):
        path = path[2:]
    return f"{WEB_URL}/recipe/{quote(path, safe='/')}"


class SharedSecret(TokenVerifier):
    """Accept one static bearer token.

    The MCP authorization spec is OAuth 2.1 throughout: it has no notion of a
    shared secret, and conformance is only a SHOULD, so this opts out of that
    chapter rather than implementing it badly. Everything else — the 401, the
    `WWW-Authenticate` challenge — the SDK does from here.
    """

    def __init__(self, token: str) -> None:
        self._token = token

    async def verify_token(self, token: str) -> AccessToken | None:
        if not secrets.compare_digest(token, self._token):
            return None
        return AccessToken(token=token, client_id="cooklang-mcp", scopes=[])


def _token() -> str | None:
    """The shared secret, from a file where systemd put one, else the
    environment."""
    path = os.environ.get("COOKLANG_MCP_TOKEN_FILE")
    if not path:
        return os.environ.get("COOKLANG_MCP_TOKEN") or None
    with open(path, encoding="utf-8") as handle:
        token = handle.read().strip()
    if not token:
        raise SystemExit(f"{path} is empty")
    return token


_secret = _token()
mcp = FastMCP(
    "Cook Recipes & Plan Meals",
    instructions=INSTRUCTIONS,
    host=os.environ.get("COOKLANG_MCP_HOST", "127.0.0.1"),
    port=int(os.environ.get("COOKLANG_MCP_PORT", "3001")),
    token_verifier=SharedSecret(_secret) if _secret else None,
    auth=(
        AuthSettings(
            # Unused: both are read only by the OAuth discovery routes, which
            # are mounted only for an authorization server, and there is none.
            issuer_url=AnyHttpUrl("https://localhost"),
            resource_server_url=None,
        )
        if _secret
        else None
    ),
    # Off, because the guard is aimed at a browser reaching a loopback server
    # and the only thing that reaches this one is the reverse proxy in front of
    # it. On, it rejects every proxied request: the `Host` header is the public
    # name, not `localhost`.
    transport_security=TransportSecuritySettings(enable_dns_rebinding_protection=False),
)


# -- recipes and menus ----------------------------------------------------


@mcp.tool()
async def search_recipes(
    query: Annotated[
        str,
        Field(
            description=(
                "Search text, such as a recipe name, ingredient, instruction, or tag."
            )
        ),
    ] = "",
) -> list[RecipeSummary]:
    """Search the user's recipes and meal plans for a recipe to cook, matching
    recipe names, ingredients, instructions, tags, or other metadata.

    An empty query matches everything. Results contain metadata only; use
    `read_recipe` for the complete recipe or meal plan.
    """
    return [
        RecipeSummary.model_validate(
            {**entry, "web_url": recipe_web_url(entry["path"])}
        )
        for entry in await cook.search_entries(query)
    ]


@mcp.tool()
async def read_recipe(path: Path) -> RecipeDocument:
    """Read the raw Cooklang source of one recipe or meal plan, frontmatter
    included, and return its clickable Cook web page."""
    source = (await cook.request("GET", f"/api/recipes/raw/{path}")).text
    return RecipeDocument(path=path, web_url=recipe_web_url(path), source=source)


@mcp.tool()
async def write_recipe(
    path: Path,
    source: Annotated[
        str,
        Field(
            description=(
                "The complete new file contents in Cooklang syntax. This "
                "replaces the file wholesale, so send the whole document, "
                "not a fragment."
            )
        ),
    ],
) -> dict[str, Any]:
    """Create or replace a recipe or meal plan. When changing an existing
    recipe or meal plan, read it first and write back the complete updated
    document.

    Cooklang is forgiving — text it cannot interpret becomes a plain step
    rather than an error — so the result lists the ingredients the parser
    actually found. Read them back: an ingredient missing from that list was
    dropped, and will be missing from the shopping list too.

    A folder in the path must already exist — writing into one that does not
    fails rather than creating it.

    An ingredient's name ends at the first space unless it is followed by
    braces, so `@soy sauce{2%tbsp}` defines "soy sauce" while `@soy sauce`
    defines "soy" and leaves "sauce" as prose. Preparation belongs in a note
    rather than the name: `@onion{1}(finely diced)` keeps the shopping list
    saying "onion" while the step still reads "finely diced". The note is
    parentheses directly after the component with no space between, and
    cookware takes one too: `#pan{}(heavy-bottomed)`. Always write the braces
    first — without them the name ends before the note. A timer cannot carry a
    note; the parentheses stay prose.

    A recipe that came from a web page must record where it came from: its
    frontmatter carries `source.url` with the full original URL, not the site
    name and not a shortened link. The key is `source.url` and not `source`,
    because that is the one the web UI renders as a clickable link.
    `fetch_recipe` hands back a frontmatter block with that line already in it.

    A meal plan is an ordinary Cooklang file whose ingredients may be
    references to other recipes. Keep upcoming recipes in the root file
    `Meal Plan.menu`, in order under `Meals`. Separate consecutive recipe
    references with a blank line (two newline characters); a single line break
    leaves them in one Cooklang step, so the web UI displays both paths on one
    line:

        ---
        title: Meal Plan
        ---
        = Meals
        @./Risotto{2%servings}

        @./Caprese{2%servings}

        @paper towels{1}

    `@./Name{N}` pulls in that recipe scaled by N, `{N%servings}` scales it to
    N servings instead, and a bare `@item{N}` is a loose ingredient belonging
    to no recipe.

    Keep cooked recipes in the separate root file `Meal History.menu`, under
    `Weekday (YYYY-MM-DD)` sections ordered newest-first, reusing a matching
    date section. Put feedback directly below the recipe it describes. If the
    cooking date was inferred rather than known, suffix that recipe reference
    with `— date estimated`:

        ---
        title: Meal History
        ---
        = Friday (2026-09-18)
        @./Risotto{} — date estimated

        Feedback: Turned out well; use less salt next time.

        @./Caprese{}
    """
    await cook.request(
        "PUT",
        f"/api/recipes/{path}",
        content=source.encode(),
        headers={"Content-Type": "text/plain; charset=utf-8"},
    )
    try:
        parsed = (await cook.request("GET", f"/api/recipes/{path}")).json()
    except Exception as err:  # noqa: BLE001 - the write itself succeeded
        return {
            "path": path,
            "web_url": recipe_web_url(path),
            "written": True,
            "parse_error": str(err),
        }
    ingredients = parsed.get("recipe", {}).get("ingredients", [])
    return {
        "path": path,
        "web_url": recipe_web_url(path),
        "written": True,
        "ingredients": [ingredient["name"] for ingredient in ingredients],
    }


@mcp.tool()
async def delete_recipe(path: Path) -> dict[str, Any]:
    """Permanently delete a recipe or meal plan. There is no undo and no
    trash."""
    await cook.request("DELETE", f"/api/recipes/{path}")
    return {"path": path, "deleted": True}


@mcp.tool()
async def fetch_recipe(
    url: Annotated[
        str, Field(description="The recipe web page, exactly as the user gave it.")
    ],
) -> dict[str, Any]:
    """Fetch a recipe from a web page for import into the user's collection.
    This does not save it; convert the returned material to Cooklang and pass
    it to `write_recipe`.

    Everything you write must come from this result. A recipe reconstructed
    from memory is not the one at that URL, however familiar the dish looks:
    use the ingredients, quantities and steps in `text` and nothing else, and
    where the page is silent — an oven temperature, a resting time — leave it
    out rather than supply a plausible value.

    - `frontmatter` is a finished YAML block, `---` delimiters included,
      carrying `source.url` with the exact URL. Put it at the top of the
      `.cook` file, and never retype or shorten that URL. It carries no `tags`:
      a page's keywords are its SEO surface, so pick tags that match the ones
      already in the collection.
    - `text` is the recipe as the page stated it: ingredients, then the method.
    - `extraction` is `structured` when the page published machine-readable
      recipe data. It is `page_text` when it did not — then `text` is the
      readable text of the whole page, navigation and comments included, and
      finding the recipe in it is your job. If there is no recipe in it, say so
      instead of inventing one.
    - `notes` carries anything else worth knowing about this result.

    An error means the page could not be read at all. Report that; do not
    answer it with a recipe of your own.
    """
    return await fetch_recipe_from_url(url)


# -- shopping list --------------------------------------------------------


@mcp.tool()
async def shopping_list() -> dict[str, Any]:
    """Read the user's shopping list, including the recipes or meal plans that
    were added and the resulting ingredients.

    Quantities are summed with unit conversion, reduced by whatever the pantry
    holds, and grouped into store aisles by the Cooklang library, so the result
    is authoritative — do not total ingredients yourself. `pantry_items` names
    the ingredients that were already at home and have been subtracted.

    This is the same list the collection's web UI shows, including which items
    have been ticked off. `recipes` carries each source path and scale;
    ingredient entries carry `checked` individually.
    """
    result = await cook.shopping_list()
    for recipe in result["recipes"]:
        recipe["web_url"] = recipe_web_url(recipe["path"])
    return result


@mcp.tool()
async def add_to_shopping_list(path: Path, scale: Scale = 1.0) -> dict[str, Any]:
    """Put a recipe, or every recipe in a meal plan, on the shopping list."""
    # A menu is added as one entry with its recipes resolved and nested inside;
    # `add` would store it as a single opaque file instead.
    endpoint = "add_menu" if path.endswith(".menu") else "add"
    await cook.request(
        "POST", f"/api/shopping_list/{endpoint}", json={"path": path, "scale": scale}
    )
    return {
        "path": path,
        "web_url": recipe_web_url(path),
        "scale": scale,
        "added": True,
    }


@mcp.tool()
async def remove_from_shopping_list(path: Path) -> dict[str, Any]:
    """Take one recipe or meal plan back off the shopping list."""
    await cook.request("POST", "/api/shopping_list/remove", json={"path": path})
    return {"path": path, "web_url": recipe_web_url(path), "removed": True}


@mcp.tool()
async def clear_shopping_list() -> dict[str, Any]:
    """Empty the shopping list completely."""
    await cook.request("POST", "/api/shopping_list/clear")
    return {"cleared": True}


@mcp.tool()
async def check_shopping_item(
    name: Annotated[
        str,
        Field(
            description="The ingredient name exactly as `shopping_list` returned it."
        ),
    ],
    checked: Annotated[
        bool, Field(description="True to tick the item off, false to untick it.")
    ] = True,
) -> dict[str, Any]:
    """Tick an ingredient off the shopping list, or put it back."""
    endpoint = "check" if checked else "uncheck"
    await cook.request("POST", f"/api/shopping_list/{endpoint}", json={"name": name})
    return {"name": name, "checked": checked}


def main() -> None:
    if os.environ.get("COOKLANG_MCP_TRANSPORT", "stdio") == "stdio":
        mcp.run()
        return
    if not _secret:
        logging.getLogger(__name__).warning(
            "no token configured - serving HTTP without auth"
        )
    mcp.run("streamable-http")


if __name__ == "__main__":
    main()
