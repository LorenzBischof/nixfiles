"""The MCP tools, and the transports they are served over.

Every tool is a call to `cook server` (see `cookcli.py`), except
`recipe_import`, which reads a web page. The server keeps no state of its own:
the recipes, the shopping list and the pantry all live in the collection
`cook server` was pointed at, so what is done here shows up in its web UI and
the other way round.

The tools are grouped by the thing they act on — `recipe_*`, `shopping_list_*`,
`aisles_*` — and each group pairs one read with one write rather than giving
every HTTP endpoint underneath a tool of its own. A read is marked
`readOnlyHint` so a client can let it through without asking.
"""

from __future__ import annotations

import logging
import os
import secrets
from datetime import date as Date
from difflib import get_close_matches
from typing import Annotated, Any, Literal
from urllib.parse import quote

from mcp.server.auth.provider import AccessToken, TokenVerifier
from mcp.server.auth.settings import AuthSettings
from mcp.server.fastmcp import FastMCP
from mcp.server.transport_security import TransportSecuritySettings
from mcp.types import ToolAnnotations
from pydantic import AnyHttpUrl, BaseModel, Field, model_validator

from . import cookcli as cook
from . import menus
from .importer import fetch_recipe as fetch_recipe_from_url

WEB_URL = (
    os.environ.get("COOKLANG_WEB_URL")
    or os.environ.get("COOKLANG_SERVER_URL")
    or "http://127.0.0.1:9080"
).rstrip("/")

PLAN_PATH = "Meal Plan.menu"
HISTORY_PATH = "Meal History.menu"

INSTRUCTIONS = f"""\
Browse and manage the user's personal recipe collection, meal plans, and \
shopping list. This includes finding something to cook, working with recipes, \
planning meals, and importing recipes from the web.

Whenever an answer names a recipe or meal plan you have a web URL for, make \
the name a clickable Markdown link to it — the confirmation after a write \
included, and the recipes inside a meal plan, which come with URLs of their \
own. Any `web_url` a tool returned in this conversation counts, not only the \
one from the last call. Never construct or guess a URL: a name you have none \
for stays plain, and a recipe's external `source.url` is where it came from, \
not its page here.

`{PLAN_PATH}` at the collection root is the ordered queue of upcoming recipes, \
under `Meals`. `{HISTORY_PATH}` is the record of cooked ones. Both are \
ordinary recipe files, so `recipe_read` and `recipe_write` work on them — but \
when the user says a recipe was cooked, use `mark_cooked`, which moves it from \
the one to the other. Do not create weekly or date-named plan files.\
"""

# All four hints are advisory, and a client is free to ignore them. Only
# `recipe_delete` is marked destructive: it is the one tool whose effect cannot
# be undone by calling another one, which is the distinction worth gating on.
# `openWorldHint` separates the collection, a closed and known set of files,
# from `recipe_import` reaching an arbitrary web page.
READ = ToolAnnotations(readOnlyHint=True, openWorldHint=False)
WEB_READ = ToolAnnotations(readOnlyHint=True, openWorldHint=True)
WRITE = ToolAnnotations(readOnlyHint=False, destructiveHint=False, openWorldHint=False)
DELETE = ToolAnnotations(
    readOnlyHint=False,
    destructiveHint=True,
    idempotentHint=True,
    openWorldHint=False,
)

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
# JSON Schema's own marker for a URL-valued string, and the only standard one
# within reach: MCP has no URL-typed field, and its `resource_link` content
# block means a resource this server can read — which a cookcli web page,
# served by another process, is not.
URI = {"format": "uri"}

# The server instructions carry the link rule as well, but a client is free to
# drop those and an output schema always arrives, so this says what to do with
# the URL rather than naming it. Nothing renders the link but the model: the
# protocol has no way to hand the user something clickable.
WebUrl = Annotated[
    str,
    Field(
        description=(
            "This entry's page in the user's collection. Whenever an answer "
            "names this recipe or meal plan, make the name a Markdown link to "
            "this URL, in this reply or a later one. Never build a URL this "
            "way for a name that came without one."
        ),
        json_schema_extra=URI,
    ),
]


class RecipeSummary(BaseModel):
    """Metadata for one recipe or meal plan: a search hit, or a recipe a meal
    plan refers to."""

    path: str = Field(description="Path used with the other recipe tools.")
    title: str = Field(description="The user-facing recipe or meal-plan name.")
    web_url: WebUrl
    tags: list[str] = Field(description="Tags stored in the file's metadata.")
    is_menu: bool = Field(
        description="Whether this is a meal plan instead of a recipe."
    )


MenuEntries = Annotated[
    list[RecipeSummary],
    Field(
        default_factory=list,
        description=(
            "For a meal plan or history, the recipes it refers to in file "
            "order, each with its own page — so a name taken from this file "
            "can be linked. Empty for an ordinary recipe."
        ),
    ),
]


class RecipeDocument(BaseModel):
    """A stored recipe or meal plan and its Cook web page."""

    path: str = Field(description="Path used with the other recipe tools.")
    web_url: WebUrl
    source: str = Field(
        description="Complete raw Cooklang source, frontmatter included."
    )
    entries: MenuEntries


class RecipeWritten(BaseModel):
    """What one write saved, and the two ways to check it came out right."""

    path: str = Field(description="Path the file was written to.")
    web_url: WebUrl
    # Never false: a write that did not happen raises instead. It is here so
    # that a `warnings` entry about a failed check cannot read as a failed save.
    written: bool = Field(default=True, description="True once the file is saved.")
    ingredients: list[str] = Field(
        default_factory=list,
        description=(
            "Ingredient names the parser found in the saved file. Empty when "
            "reading it back failed, which `warnings` then says."
        ),
    )
    warnings: list[str] = Field(
        default_factory=list,
        description="Ingredient names the aisle catalogue did not recognise.",
    )
    entries: MenuEntries


class MealCooked(BaseModel):
    """What one `mark_cooked` call recorded, and what it left in the plan."""

    path: str = Field(description="Path of the recipe that was cooked.")
    web_url: WebUrl
    cooked_on: str = Field(description="The date it was recorded under.")
    date_estimated: bool = Field(
        description="Whether that date was inferred rather than given."
    )
    recorded_in: str = Field(
        description="Page of the history file the entry was written to.",
        json_schema_extra=URI,
    )
    history_created: bool = Field(
        description="Whether the history file had to be created first."
    )
    removed_from_plan: bool = Field(
        description="Whether the recipe was taken off the meal plan."
    )
    note: str | None = Field(
        default=None,
        description="Why nothing left the plan, on the occasions nothing did.",
    )
    remaining_plan: list[RecipeSummary] = Field(
        default_factory=list,
        description=(
            "What is still queued on the meal plan afterwards, in order, each "
            "with its own page — so saying what is left links every name. "
            "Empty when the plan now holds no recipes, or the collection has "
            "no plan at all."
        ),
    )


def recipe_web_url(path: str) -> str:
    """Return the public Cook page for a collection-relative path."""
    while path.startswith("./"):
        path = path[2:]
    return f"{WEB_URL}/recipe/{quote(path, safe='/')}"


def _summary(entry: dict[str, Any]) -> RecipeSummary:
    """One entry from the recipe tree, with its page filled in."""
    return RecipeSummary.model_validate(
        {**entry, "web_url": recipe_web_url(entry["path"])}
    )


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


@mcp.tool(annotations=READ)
async def recipe_search(
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
    `recipe_read` for the complete recipe or meal plan.
    """
    return [_summary(entry) for entry in await cook.search_entries(query)]


@mcp.tool(annotations=READ)
async def recipe_read(path: Path) -> RecipeDocument:
    """Read one recipe or meal plan already in the user's collection: its raw
    Cooklang source, frontmatter included, and its clickable Cook web page.

    For a meal plan or history, `entries` resolves the recipes it refers to,
    each with its own page. Naming one of them in an answer means linking it
    from there: the file's own `web_url` is the plan's page, not theirs.

    This reads the collection. To read a recipe off a web page instead, so it
    can be imported, use `recipe_import`.
    """
    source = (await cook.request("GET", f"/api/recipes/raw/{path}")).text
    return RecipeDocument(
        path=path,
        web_url=recipe_web_url(path),
        source=source,
        entries=await _menu_entries(path, source),
    )


def _words(name: str) -> tuple[str, ...]:
    """A name as words, with singular and plural spelled the same.

    Both sides of every comparison come through here, so trimming a trailing
    `s` that is not a plural ("glass") costs nothing.
    """
    return tuple(word.casefold().removesuffix("s") for word in name.split())


def _runs_inside(outer: tuple[str, ...], inner: tuple[str, ...]) -> bool:
    """Whether `inner`'s words sit inside `outer`, in order and side by side."""
    return any(
        outer[index : index + len(inner)] == inner
        for index in range(len(outer) - len(inner) + 1)
    )


def _similar(name: str, known: dict[str, str]) -> list[str]:
    """Catalogue names worth a second look, by two cheap rules.

    One name's words run inside the other's ("butter" for "unsalted butter",
    "garlic clove" for "garlic cloves"), or the whole names are spelled nearly
    the same ("onion" for "onions"). Three at most: this is a hint, not a list.
    """
    words = _words(name)
    matches = [
        preferred
        for key, preferred in known.items()
        if _runs_inside(words, _words(key)) or _runs_inside(_words(key), words)
    ]
    matches += [known[key] for key in get_close_matches(name, known, n=3, cutoff=0.8)]
    return list(dict.fromkeys(matches))[:3]


async def _ingredient_warnings(ingredients: list[dict[str, Any]]) -> list[str]:
    """What the aisle catalogue does not recognise in a recipe's ingredients.

    A hint, never a correction: ingredients that really are different stay
    different, and nothing here renames one or writes to the catalogue. A
    recipe reference is not an ingredient, so it is left out.
    """
    names: dict[str, str] = {}
    for ingredient in ingredients:
        if not ingredient.get("reference"):
            names.setdefault(ingredient["name"].casefold(), ingredient["name"])
    if not names:
        return []
    catalogue = (await cook.request("GET", "/api/aisles")).json()
    if not catalogue["configured"]:
        return ["The collection has no aisle file, so the names were not checked."]
    known = {
        name.casefold(): entry["names"][0]
        for aisle in catalogue["aisles"]
        for entry in aisle["ingredients"]
        for name in entry["names"]
    }
    warnings = []
    unknown = []
    for key, name in sorted(names.items()):
        if key in known:
            continue
        similar = _similar(key, known)
        if similar:
            warnings.append(
                f"{name!r} is new, but the catalogue has "
                f"{', '.join(repr(match) for match in similar)}. "
                "Reuse one only if it is the same ingredient."
            )
        else:
            unknown.append(name)
    if unknown:
        warnings.append(
            "Not in the aisle catalogue, which is fine for a new ingredient: "
            + ", ".join(repr(name) for name in unknown)
        )
    return warnings


async def _menu_entries(path: str, source: str) -> list[RecipeSummary]:
    """The recipes a menu file refers to, each with its page.

    A menu's source names them and nothing more — the file holds
    `@./Kürbiswähe`, and a path is not a URL — so an answer about a plan has no
    link for the recipes it is about to mention. Resolving them here puts the
    URL beside the name in the result of the call just made; a URL two or three
    calls back does not get used.

    A component no file matches is left out rather than guessed at: `@paper
    towels{1}` is a loose ingredient and not a recipe, and the source is still
    there to say what the file really holds. Resolving costs a request, so a
    failure costs the links and not the read.
    """
    if not path.endswith(".menu"):
        return []
    referenced = dict.fromkeys(
        menus.normalise(name).casefold()
        for section in menus.parse(source).sections
        for block in section.blocks
        for line in block
        if (name := menus.component(line))
    )
    if not referenced:
        return []
    try:
        known = {
            menus.normalise(entry["path"]).casefold(): entry
            for entry in await cook.list_entries()
        }
    except Exception as err:  # noqa: BLE001 - the read or write itself succeeded
        logging.getLogger(__name__).warning("Resolving menu entries failed: %s", err)
        return []
    return [_summary(known[name]) for name in referenced if name in known]


async def _put_recipe(path: str, source: str) -> None:
    """Write a file into the collection, wholesale."""
    await cook.request(
        "PUT",
        f"/api/recipes/{path}",
        content=source.encode(),
        headers={"Content-Type": "text/plain; charset=utf-8"},
    )


@mcp.tool(annotations=WRITE)
async def recipe_write(
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
) -> RecipeWritten:
    """Create or replace a recipe or meal plan. When changing an existing
    recipe or meal plan, read it first and write back the complete updated
    document.

    Cooklang is forgiving — text it cannot interpret becomes a plain step
    rather than an error — so the result lists the ingredients the parser
    actually found. Read them back: an ingredient missing from that list was
    dropped, and will be missing from the shopping list too.

    The result's `warnings` name the ingredients the aisle catalogue does not
    know, so that one thing does not reach the shopping list under two names.
    They are hints: an ingredient that really is new stays as written.

    End the confirmation with the recipe's title linked to the result's
    `web_url`, so the user can open the saved page and see for themselves that
    it came out right.

    Writing a meal plan also returns `entries`: the recipes it now holds, each
    with its own page. A confirmation that names one of them — "X is on your
    meal plan" — links that name to its entry's `web_url`, never to the
    result's own, which is the plan's page.

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
    `recipe_import` hands back a frontmatter block with that line already in it.

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

    `Meal History.menu` follows the same shape under `Weekday (YYYY-MM-DD)`
    headings, but `mark_cooked` writes it — reach for this tool only to correct
    an entry already there.
    """
    await _put_recipe(path, source)
    entries = await _menu_entries(path, source)
    try:
        parsed = (await cook.request("GET", f"/api/recipes/{path}")).json()
    except Exception as err:  # noqa: BLE001 - the write itself succeeded
        return RecipeWritten(
            path=path,
            web_url=recipe_web_url(path),
            entries=entries,
            warnings=[
                (
                    "Recipe saved, but reading it back failed, so its "
                    f"ingredients were not checked: {err}"
                )
            ],
        )
    ingredients = parsed.get("recipe", {}).get("ingredients", [])
    try:
        warnings = await _ingredient_warnings(ingredients)
    except Exception as err:  # noqa: BLE001 - post-save checks must not hide success
        logging.getLogger(__name__).warning("Ingredient check failed: %s", err)
        warnings = [
            (
                "Recipe saved, but the aisle catalogue could not be read, so its "
                "ingredients were not checked."
            )
        ]
    return RecipeWritten(
        path=path,
        web_url=recipe_web_url(path),
        ingredients=[ingredient["name"] for ingredient in ingredients],
        warnings=warnings,
        entries=entries,
    )


@mcp.tool(annotations=DELETE)
async def recipe_delete(path: Path) -> dict[str, Any]:
    """Permanently delete a recipe or meal plan. There is no undo and no
    trash."""
    await cook.request("DELETE", f"/api/recipes/{path}")
    return {"path": path, "deleted": True}


@mcp.tool(annotations=WEB_READ)
async def recipe_import(
    url: Annotated[
        str, Field(description="The recipe web page, exactly as the user gave it.")
    ],
) -> dict[str, Any]:
    """Read a recipe off a web page so it can be imported. This saves nothing:
    convert the returned material to Cooklang and pass it to `recipe_write`.

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


async def _read_menu(path: str, existing: set[str]) -> str | None:
    """A menu file's source, or None when the collection has no such file."""
    if not any(menus.same_recipe(path, other) for other in existing):
        return None
    return (await cook.request("GET", f"/api/recipes/raw/{path}")).text


@mcp.tool(annotations=WRITE)
async def mark_cooked(
    path: Path,
    cooked_on: Annotated[
        str,
        Field(
            description="The day it was cooked, as `YYYY-MM-DD`.",
            pattern=r"^\d{4}-\d{2}-\d{2}$",
        ),
    ],
    date_estimated: Annotated[
        bool,
        Field(
            description=(
                "True when the date was inferred rather than told, which marks "
                "the entry accordingly."
            )
        ),
    ] = False,
    feedback: Annotated[
        str | None,
        Field(
            description=(
                "How it turned out, or what to change next time. Recorded "
                "below the recipe; omit when the user has nothing to say."
            )
        ),
    ] = None,
) -> MealCooked:
    """Record that a recipe was cooked: add it to `Meal History.menu` and take
    it off `Meal Plan.menu`.

    This replaces editing those two files by hand. It reuses an existing
    section for that date or opens a new one in the right place, keeps the
    history newest-first, puts feedback directly below its recipe, and only
    touches the plan once the history is safely written. Creates
    `Meal History.menu` if the collection has none.

    `remaining_plan` is what is still queued afterwards, each recipe with its
    own page: say what is left from there, linking every name to its entry.

    Ask the user when it was cooked, and ask for brief feedback, saying it is
    optional. Pass the exact date when they know it. When the answer is vague
    or they do not remember, pick a plausible past date from the dates already
    in the history — normally avoid putting two recipes on one inferred day,
    though treat that as a soft rule — and pass `date_estimated`.
    """
    cooked = Date.fromisoformat(cooked_on)
    existing = {entry["path"] for entry in await cook.list_entries()}
    history = await _read_menu(HISTORY_PATH, existing)
    await _put_recipe(
        HISTORY_PATH,
        menus.add_to_history(
            history or "",
            path,
            cooked,
            estimated=date_estimated,
            feedback=feedback,
        ),
    )
    plan = await _read_menu(PLAN_PATH, existing)
    if plan is None:
        removed = False
        remaining = ""
        note = f"The collection has no {PLAN_PATH}, so nothing was removed."
    else:
        # Rendered either way, so it is the plan as it now stands whether or
        # not this recipe was on it.
        remaining, removed = menus.remove_from_plan(plan, path)
        if removed:
            await _put_recipe(PLAN_PATH, remaining)
        note = (
            None
            if removed
            else f"It was not in {PLAN_PATH}, so only the history changed."
        )

    return MealCooked(
        path=path,
        web_url=recipe_web_url(path),
        cooked_on=cooked.isoformat(),
        date_estimated=date_estimated,
        recorded_in=recipe_web_url(HISTORY_PATH),
        history_created=history is None,
        removed_from_plan=removed,
        note=note,
        remaining_plan=await _menu_entries(PLAN_PATH, remaining),
    )


# -- shopping list --------------------------------------------------------


# Which fields each action reads, and which it cannot do without. A field the
# action does not read is refused rather than ignored: `{"action": "clear",
# "path": "Risotto.cook"}` reads as "take this recipe off", and emptying the
# whole list instead is the worst available reading of it.
_SHOPPING_FIELDS: dict[str, tuple[frozenset[str], frozenset[str]]] = {
    "add": (frozenset({"path", "scale"}), frozenset({"path"})),
    "remove": (frozenset({"path"}), frozenset({"path"})),
    "check": (frozenset({"name"}), frozenset({"name"})),
    "uncheck": (frozenset({"name"}), frozenset({"name"})),
    "clear": (frozenset(), frozenset()),
}


class ShoppingChange(BaseModel):
    """One edit to the shopping list; the fields each action needs vary."""

    model_config = {"extra": "forbid"}

    action: Literal["add", "remove", "check", "uncheck", "clear"]
    path: Path | None = None
    scale: Scale | None = None
    name: Annotated[
        str | None,
        Field(description="Ingredient name exactly as `shopping_list_read` gave it."),
    ] = None

    @model_validator(mode="after")
    def _fields_match_the_action(self) -> ShoppingChange:
        allowed, required = _SHOPPING_FIELDS[self.action]
        given = {
            field
            for field in ("path", "scale", "name")
            if getattr(self, field) is not None
        }
        if unused := given - allowed:
            raise ValueError(
                f"{self.action!r} does not take {', '.join(sorted(unused))}."
            )
        if missing := required - given:
            raise ValueError(f"{self.action!r} needs {', '.join(sorted(missing))}.")
        return self


@mcp.tool(annotations=READ)
async def shopping_list_read() -> dict[str, Any]:
    """Read the user's shopping list, including the recipes or meal plans that
    were added and the resulting ingredients.

    Quantities are summed with unit conversion, reduced by whatever the pantry
    holds, and grouped into store aisles by the Cooklang library, so the result
    is authoritative — do not total ingredients yourself. `pantry_items` names
    the ingredients that were already at home and have been subtracted.

    This is the same list the collection's web UI shows, including which items
    have been ticked off. `recipes` carries each source path and scale;
    ingredient entries carry `checked` individually.

    Copying these recipes into `Meal Plan.menu` is only ever done when the user
    explicitly asks for it. Then read the plan, append the missing recipe paths
    in shopping-list order without disturbing the queue, and preserve a
    non-default scale — empty braces mean scale 1. Say which already-planned
    paths you skipped; `Risotto.cook` and `./Risotto` are the same path. A
    recipe in the plan but absent from this list may be stale, so ask whether
    it is still upcoming or was already cooked.
    """
    result = await cook.shopping_list()
    for recipe in result["recipes"]:
        recipe["web_url"] = recipe_web_url(recipe["path"])
    return result


def _shopping_request(change: ShoppingChange) -> tuple[str, dict[str, Any] | None]:
    """One validated change as the endpoint and body that apply it."""
    if change.action == "add":
        # A menu is added as one entry with its recipes resolved and nested
        # inside; `add` would store it as a single opaque file instead.
        endpoint = "add_menu" if str(change.path).endswith(".menu") else "add"
        return endpoint, {"path": change.path, "scale": change.scale or 1.0}
    if change.action == "remove":
        return "remove", {"path": change.path}
    if change.action in ("check", "uncheck"):
        return change.action, {"name": change.name}
    return "clear", None


@mcp.tool(annotations=WRITE)
async def shopping_list_edit(
    changes: Annotated[
        list[ShoppingChange],
        Field(description="Applied in order; at least one.", min_length=1),
    ],
) -> dict[str, Any]:
    """Change the shopping list, and return it as it now stands.

    Actions, with the fields they take (? optional): `add`(path, scale?) puts a
    recipe, or every recipe in a meal plan, on the list; `remove`(path) takes
    one back off; `check`(name) ticks an ingredient off and `uncheck`(name)
    puts it back; `clear` empties the list completely. Each action takes only
    its own fields — a `clear` carrying a path is refused rather than read as
    emptying the list, so send `remove` when one recipe is what you mean.

    They are applied in the order given, and a failure part-way through leaves
    the earlier ones applied — this is the same list the web UI shows, not a
    transaction. The result is the whole list afterwards, so there is no need
    to read it back.

    `clear` after the user has shopped is the normal end of a trip. When a
    meal-plan copy has just been written, clear the list if every ingredient is
    ticked off, and say that you did; if any is still unticked, ask first and
    otherwise leave it alone.
    """
    requests = [_shopping_request(change) for change in changes]
    for endpoint, body in requests:
        await cook.request(
            "POST",
            f"/api/shopping_list/{endpoint}",
            **({"json": body} if body is not None else {}),
        )
    return {"applied": len(requests), **await shopping_list_read()}


# -- aisles ---------------------------------------------------------------


class AisleChange(BaseModel):
    """One edit to the aisle file; `cook server` checks each action's fields."""

    model_config = {"extra": "forbid"}

    action: Literal[
        "add_aisle",
        "rename_aisle",
        "remove_aisle",
        "move_aisle",
        "add_ingredient",
        "remove_ingredient",
    ]
    name: str | None = None
    aisle: str | None = None
    new_name: str | None = None
    position: Annotated[int, Field(ge=0)] | None = None


@mcp.tool(annotations=READ)
async def aisles_read(query: str = "", uncategorized: bool = False) -> dict[str, Any]:
    """Read the shopping list's aisles as {aisle: [ingredient names]}.

    An empty query lists every aisle; otherwise only the aisles whose own name
    contains it, with their whole contents, and the matching names of the
    others, ignoring case. `uncategorized` also lists the ingredient names the
    collection uses that no aisle has yet. Pass `revision` to `aisles_edit`;
    `configured` is false when the collection has no aisle file at all.
    """
    catalogue = (await cook.request("GET", "/api/aisles")).json()
    query = query.strip().casefold()
    aisles = {}
    for aisle in catalogue["aisles"]:
        names = [name for entry in aisle["ingredients"] for name in entry["names"]]
        if query not in aisle["name"].casefold():
            names = [name for name in names if query in name.casefold()]
            if not names:
                continue
        aisles[aisle["name"]] = names
    result = {
        "configured": catalogue["configured"],
        "revision": catalogue["revision"],
        "aisles": aisles,
    }
    if catalogue["warnings"]:
        result["warnings"] = catalogue["warnings"]
    if uncategorized:
        unassigned = (await cook.request("GET", "/api/aisles/uncategorized")).json()
        result["uncategorized"] = [
            item["name"]
            for item in unassigned["ingredients"]
            if query in item["name"].casefold()
        ]
    return result


@mcp.tool(annotations=WRITE)
async def aisles_edit(
    revision: Annotated[
        str | None,
        Field(
            description="From aisles_read; null only to create a missing aisle file."
        ),
    ],
    changes: Annotated[
        list[AisleChange],
        Field(
            description="Applied in order, all or none; empty only to create the file."
        ),
    ],
) -> dict[str, Any]:
    """Change the aisle file in one atomic batch, and return its new revision.

    Read first and send that revision: a stale one fails instead of overwriting
    an edit made meanwhile, and then you read again and reconsider the batch.
    For a collection with no aisle file, `revision=null` with `changes=[]`
    creates one; edit it afterwards with the revision that comes back.

    Actions, with their fields (? optional): add_aisle(name, position?),
    rename_aisle(name, new_name), remove_aisle(name), move_aisle(name, position),
    add_ingredient(aisle, name), remove_ingredient(name).

    `position` counts from 0; without it an aisle goes last. Removing an aisle
    removes its ingredients too. An ingredient is found by name ignoring case,
    and removing it drops its whole line, including any other spellings sharing
    it; to move one, remove it and add it back in the same batch. Recipes are
    never touched: an aisle only groups the ingredient on the shopping list.
    """
    if revision is None:
        if changes:
            raise ValueError("Create with changes=[], then edit with the new revision.")
        catalogue = (await cook.request("POST", "/api/aisles")).json()
        return {"revision": catalogue["revision"], "created": True}
    if not revision or not changes:
        raise ValueError("Editing needs a revision and at least one change.")
    catalogue = (
        await cook.request(
            "POST",
            "/api/aisles/changes",
            json={
                "revision": revision,
                "changes": [_aisle_change(change) for change in changes],
            },
        )
    ).json()
    result = {"revision": catalogue["revision"], "applied": len(changes)}
    if catalogue["warnings"]:
        result["warnings"] = catalogue["warnings"]
    return result


def _aisle_change(change: AisleChange) -> dict[str, Any]:
    """One change as the API takes it.

    The API stores an ingredient as a list of spellings, the first of which the
    shopping list shows. Only ever write one: a second spelling is a second way
    to write the same ingredient, which is the inconsistency the write warnings
    exist to prevent.
    """
    body = change.model_dump(exclude_none=True)
    if change.action == "add_ingredient" and "name" in body:
        body["names"] = [body.pop("name")]
    return body


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
