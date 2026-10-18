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
import re
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

from . import catalogue, menus
from . import cookcli as cook
from .diagnostics import Diagnostic, DiagnosticsUnavailable, diagnose
from .importer import fetch_recipe as fetch_recipe_from_url

WEB_URL = (
    os.environ.get("COOKLANG_WEB_URL")
    or os.environ.get("COOKLANG_SERVER_URL")
    or "http://127.0.0.1:9080"
).rstrip("/")

PLAN_PATH = "Meal Plan.menu"
HISTORY_PATH = "Meal History.menu"
# Where `shopping_list_edit`'s `add_item` collects the things no recipe calls
# for. A `.menu` rather than a `.cook`, so the collection lists it beside the
# plan instead of offering it as something to cook.
EXTRAS_PATH = "Extra Items.menu"

# Served in the `initialize` result, which the spec says a client should put in
# front of the model. claude.ai and Claude Desktop drop the field instead, so
# there nothing below reaches the model and the tool descriptions are all it
# sees: https://github.com/anthropics/claude-ai-mcp/issues/93 (open, triaged,
# no ETA). Claude Code does deliver it, but as a user turn truncated at 2048
# characters. So every load-bearing rule here is repeated in the tool it
# applies to, and this text is the summary rather than the only copy — keep it
# that way, and keep it short.
INSTRUCTIONS = f"""\
Browse and manage the user's personal recipe collection, meal plans, and \
shopping list. This includes finding something to cook, working with recipes, \
planning meals, and importing recipes from the web.

Whenever an answer names a recipe or meal plan you have a web URL for, make \
the name a clickable Markdown link to it — every name, every time, however \
many an answer carries: the confirmation after a write, the summary that \
closes a run of several writes and names each recipe it touched, and the \
recipes inside a meal plan, which come with URLs of their own. Any `web_url` \
a tool returned in this conversation counts, not only the one from the last \
call. Never construct or guess a URL: a name you have none \
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

# The server instructions carry the link rule as well, but clients drop those
# (see above) and an output schema always arrives, so this says what to do with
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
    """What one write saved, and the three ways to check it came out right."""

    path: str = Field(description="Path the file was written to.")
    web_url: WebUrl
    # Never false: a write that did not happen raises instead. It is here so
    # that a `warnings` entry about a failed check cannot read as a failed save.
    written: bool = Field(default=True, description="True once the file is saved.")
    diagnostics: list[Diagnostic] = Field(
        default_factory=list,
        description=(
            "What the Cooklang parser reported about the saved file, empty "
            "when it reported nothing. Say so and offer a fix whenever this "
            "holds an `error`: the file is saved, but it is not a readable "
            "recipe until that line is corrected. Mention a `warning` only "
            "where it affects what the user asked for."
        ),
    )
    ingredients: list[str] = Field(
        default_factory=list,
        description=(
            "Ingredient names the parser found in the saved file. Empty when "
            "reading it back failed, which `warnings` then says."
        ),
    )
    warnings: list[str] = Field(
        default_factory=list,
        description=(
            "Prose about the write: ingredient names the aisle catalogue did "
            "not recognise, and a sentence for any check that could not be "
            "run — which is not the same as a check that came back clean."
        ),
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

    Every hit carries its own page. Naming one in an answer means linking that
    name to its `web_url` — every name, every time, however many the answer
    holds, and in a later reply just as much as this one.
    """
    return [_summary(entry) for entry in await cook.search_entries(query)]


@mcp.tool(annotations=READ)
async def recipe_read(path: Path) -> RecipeDocument:
    """Read one recipe or meal plan already in the user's collection: its raw
    Cooklang source, frontmatter included, and its clickable Cook web page.

    For a meal plan or history, `entries` resolves the recipes it refers to,
    each with its own page. Naming one of them in an answer means linking it
    from there: the file's own `web_url` is the plan's page, not theirs.

    `web_url` is the only page to link. A `source.url` in the frontmatter is
    the web page the recipe was copied from, not its page in the collection,
    and linking a name to it sends the user off to the original site.

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


# The docstring deliberately skips the syntax a model already knows and can
# look up — @ingredients, braces, % units, # cookware, ~ timers, frontmatter
# (https://cooklang.org/docs/spec/) and `.menu` references and scaling
# (https://cooklang.org/guides/meal-planning/). It keeps the traps those pages
# do not warn about, and the conventions this collection adds on top. The
# result carries both checks the parser can give: what it said about the file
# (`diagnostics`) and what it made of it (`ingredients`), so a syntax mistake
# surfaces either as a reported line or as a missing ingredient, never as
# silence.
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

    Nothing rejects a malformed file, so the result carries what became of it.
    `diagnostics` is the Cooklang parser's own errors and warnings, each with
    its line: an `error` means the file is saved but unreadable, and is worth
    raising with the user and offering to fix. The parser is lenient, though,
    and says nothing about the commonest mistake — an unclosed brace makes
    `@sugar{2%g and` a plain step, silently — which is why `ingredients` lists
    the names it actually found. Read them back: one missing from that list was
    dropped, and will be missing from the shopping list too. The result's
    `warnings` name ingredients the aisle catalogue does not know, so one thing
    does not reach the list under two names; they are hints, and a genuinely
    new ingredient stays as written.

    Preparation belongs in a note, not the name: `@onion{1}(finely diced)`
    keeps the shopping list and the aisle catalogue saying "onion" while the
    step still reads "finely diced". The braces go first even when empty —
    `@soy sauce{}(diced)` — because a name without them ends at the first
    space.

    A recipe taken from a web page records its origin as `source.url` in the
    frontmatter, holding the full URL: not the site name, not a shortened link,
    and not the key `source`, which the web UI does not render as a link.
    `recipe_import` hands back a frontmatter block with that line already in it.

    Upcoming recipes go in the root file `Meal Plan.menu`, in order under a
    single `= Meals` section — not a section per day. Separate references with a
    blank line (two newline characters) — a single line break leaves them in
    one step, and the web UI then prints both paths on one line.

        = Meals
        @./Risotto{2%servings}

        @./Caprese{2%servings}

    `Meal History.menu` is the record, under `Weekday (YYYY-MM-DD)` headings,
    but `mark_cooked` writes it — reach for this tool only to correct an entry
    already there. Those two root files are the whole of the plan and the
    record: do not create weekly or date-named plan files, which the web UI
    never shows as the plan and `mark_cooked` cannot drain. A single
    ingredient to buy is not part of the plan either — it goes through
    `shopping_list_edit`'s `add_item`, which writes `Extra Items.menu` itself.

    A folder in the path must already exist — writing into one that does not
    fails rather than creating it.

    End the confirmation with the recipe's title linked to the result's
    `web_url`, so the user can open the saved page and check it themselves. For
    a meal plan, `entries` carries the recipes it now holds, each with its own
    page: naming one of them links that name to its entry's `web_url`, never to
    the result's own, which is the plan's page.
    """
    await _put_recipe(path, source)
    entries = await _menu_entries(path, source)
    warnings: list[str] = []
    diagnostics: list[Diagnostic] = []
    try:
        diagnostics = await diagnose(path, source)
    except DiagnosticsUnavailable as err:
        # The language server is a second process behind a WebSocket, so it
        # can be unreachable in ways the save was not. Say so: an empty
        # `diagnostics` is otherwise a claim that nothing is wrong, and a
        # syntax error would pass as silence.
        logging.getLogger(__name__).warning("Diagnostics unavailable: %s", err)
        warnings.append(
            "Recipe saved, but the parser could not be asked about it, so a "
            "syntax error in it would not show up here."
        )
    try:
        parsed = (await cook.request("GET", f"/api/recipes/{path}")).json()
    except Exception as err:  # noqa: BLE001 - the write itself succeeded
        # A file with a parse error in it is exactly what a failed read back
        # looks like, and `diagnostics` has already named the line. Saying
        # "reading it back failed" there would describe a glitch, when what
        # happened is that the recipe does not parse.
        if any(found.severity == "error" for found in diagnostics):
            warnings.append(
                "Recipe saved, but it does not parse, so its page shows the "
                "error in place of the recipe and its ingredients are on no "
                "shopping list. `diagnostics` says where."
            )
        else:
            warnings.append(
                "Recipe saved, but reading it back failed, so its "
                f"ingredients were not checked: {err}"
            )
        return RecipeWritten(
            path=path,
            web_url=recipe_web_url(path),
            diagnostics=diagnostics,
            entries=entries,
            warnings=warnings,
        )
    ingredients = parsed.get("recipe", {}).get("ingredients", [])
    try:
        warnings += await _ingredient_warnings(ingredients)
    except Exception as err:  # noqa: BLE001 - post-save checks must not hide success
        logging.getLogger(__name__).warning("Ingredient check failed: %s", err)
        warnings.append(
            "Recipe saved, but the aisle catalogue could not be read, so its "
            "ingredients were not checked."
        )
    return RecipeWritten(
        path=path,
        web_url=recipe_web_url(path),
        diagnostics=diagnostics,
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
    "add_item": (frozenset({"name", "quantity"}), frozenset({"name"})),
    "remove_item": (frozenset({"name"}), frozenset({"name"})),
    "check": (frozenset({"name"}), frozenset({"name"})),
    "uncheck": (frozenset({"name"}), frozenset({"name"})),
    "clear": (frozenset(), frozenset()),
}

# An added item is written into a Cooklang file, where `@`, `%` and braces are
# the syntax an ingredient is made of. A name carrying one would be stored as
# something other than what was asked for, and there is nothing to escape it
# with, so it is refused — no ingredient is really spelled that way.
_ITEM_NAME = re.compile(r"^[^@{}%\r\n]+$")


class ShoppingChange(BaseModel):
    """One edit to the shopping list; the fields each action needs vary."""

    model_config = {"extra": "forbid"}

    action: Literal[
        "add", "remove", "add_item", "remove_item", "check", "uncheck", "clear"
    ]
    path: Path | None = None
    scale: Scale | None = None
    name: Annotated[
        str | None,
        Field(
            description=(
                "Ingredient name: for `add_item` as it should read on the "
                "list, otherwise exactly as `shopping_list_read` gave it."
            )
        ),
    ] = None
    quantity: Annotated[
        str | None,
        Field(
            description=(
                "`add_item` only: how much to buy, written as on a list — "
                "`2`, `500 g`, `1 TL`, `a pinch`. Omit when the user did not "
                "say, and the item is listed without one."
            )
        ),
    ] = None

    @model_validator(mode="after")
    def _fields_match_the_action(self) -> ShoppingChange:
        allowed, required = _SHOPPING_FIELDS[self.action]
        given = {
            field
            for field in ("path", "scale", "name", "quantity")
            if getattr(self, field) is not None
        }
        if unused := given - allowed:
            raise ValueError(
                f"{self.action!r} does not take {', '.join(sorted(unused))}."
            )
        if missing := required - given:
            raise ValueError(f"{self.action!r} needs {', '.join(sorted(missing))}.")
        if self.action == "add_item" and not _ITEM_NAME.match(self.name.strip()):
            raise ValueError(
                "An item name cannot be blank or hold any of @ % { }; write a "
                "quantity in `quantity` and a preparation in the name's own "
                "words."
            )
        return self


@mcp.tool(annotations=READ)
async def shopping_list_read() -> dict[str, Any]:
    """Read the user's shopping list, including the recipes or meal plans that
    were added and the resulting ingredients.

    Quantities are summed with unit conversion, reduced by whatever the pantry
    holds, and grouped into store aisles by the Cooklang library, so the result
    is authoritative — do not total ingredients yourself. `pantry_items` names
    the ingredients that were already at home and have been subtracted; no tool
    here changes what the pantry holds.

    This is the same list the collection's web UI shows, including which items
    have been ticked off. `recipes` carries each source path and scale;
    ingredient entries carry `checked` individually. `Extra Items.menu` among
    them is not a recipe: it is the single ingredients added with
    `shopping_list_edit`'s `add_item`, and it is not something to cook, to
    plan, or to copy anywhere.

    An ingredient does not say which recipe it came from, and cannot: the same
    name from two sources is summed into one entry, so 30 g of butter a recipe
    calls for and 250 g added by hand are one 280 g line. Do not tell the user
    what a quantity is made of. `extra_items` is the exception — the names
    added with `add_item`, and so the only names `remove_item` can take off.
    One of them may still be part of a recipe's quantity as well.

    Each entry in `recipes` also carries a `web_url`, its page in the user's
    collection. Naming one of those recipes in an answer means linking that
    name to its `web_url` — every name, every time, here or in a later reply.
    Ingredients have no page, so their names stay plain; never assemble a URL
    for one.

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
    result["extra_items"] = await _extra_items(result["recipes"])
    return result


async def _extra_items(recipes: list[dict[str, Any]]) -> list[str]:
    """The names on the list that were added as single items.

    The aggregated list says nothing about where an ingredient came from: 30 g
    of butter a recipe calls for and 250 g added by hand arrive as one 280 g
    line, under the one name. So the only way to know which names
    `remove_item` can reach is to read the file behind them.

    A failure costs the field and not the read, the same way resolving a
    menu's entries does.
    """
    if not any(menus.same_recipe(recipe["path"], EXTRAS_PATH) for recipe in recipes):
        return []
    try:
        source = (await cook.request("GET", f"/api/recipes/raw/{EXTRAS_PATH}")).text
    except Exception as err:  # noqa: BLE001 - the list itself was read fine
        logging.getLogger(__name__).warning("Reading the loose items failed: %s", err)
        return []
    return menus.items(source)


def _shopping_request(change: ShoppingChange) -> tuple[str, dict[str, Any] | None]:
    """One validated change as the endpoint and body that apply it.

    The item actions are not among them: they are file surgery first and a
    list call only sometimes, so `_edit_extras` has them.
    """
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


async def _stored_extras() -> dict[str, Any] | None:
    """The shopping list's entry for the loose items, if it holds one.

    Compared with `same_recipe` because the store drops the extension: the
    file is `Extra Items.menu` and the entry comes back as `Extra Items`.
    """
    stored = (await cook.request("GET", "/api/shopping_list/items")).json()
    return next(
        (item for item in stored if menus.same_recipe(item["path"], EXTRAS_PATH)),
        None,
    )


async def _edit_extras(change: ShoppingChange) -> None:
    """Apply one `add_item` or `remove_item`, and keep the list in step.

    `Extra Items.menu` goes on the list as soon as it holds something and
    comes off when it holds nothing, so the list never carries an entry with
    no ingredients under it.

    Off the list, whatever the file still holds is the last trip's: the user
    cleared the list after shopping, here or in the web UI, which tells this
    server nothing. So an addition then starts from an empty file rather than
    reviving items that are already in the cupboard.

    Deleted from the collection while still on the list, it starts from empty
    as well. Asking for the file and getting a 404 would otherwise fail every
    addition from then on, with no way back short of taking the entry off the
    list by hand.
    """
    name = change.name.strip()
    stored = await _stored_extras()
    source = ""
    if stored is not None:
        existing = {entry["path"] for entry in await cook.list_entries()}
        source = await _read_menu(EXTRAS_PATH, existing) or ""
    if change.action == "add_item":
        source = menus.add_item(source, name, change.quantity)
    else:
        source, removed = menus.remove_item(source, name)
        if not removed:
            raise ValueError(
                f"{name!r} is not on the list as a single item. An ingredient "
                "a recipe calls for leaves with that recipe — `remove` its "
                "path — or can be ticked off with `check`."
            )
    await _put_recipe(EXTRAS_PATH, source)
    remaining = menus.items(source)
    if remaining and stored is None:
        await cook.request(
            "POST",
            "/api/shopping_list/add_menu",
            json={"path": EXTRAS_PATH, "scale": 1.0},
        )
    elif not remaining and stored is not None:
        await cook.request(
            "POST", "/api/shopping_list/remove", json={"path": stored["path"]}
        )


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
    one back off; `add_item`(name, quantity?) puts a single ingredient on it
    and `remove_item`(name) takes that back off; `check`(name) ticks an
    ingredient off and `uncheck`(name) puts it back; `clear` empties the list
    completely. Each action takes only its own fields — a `clear` carrying a
    path is refused rather than read as emptying the list, so send `remove`
    when one recipe is what you mean.

    They are applied in the order given, and a failure part-way through leaves
    the earlier ones applied — this is the same list the web UI shows, not a
    transaction. The result is the whole list afterwards, so there is no need
    to read it back. It has the shape `shopping_list_read` returns, `recipes`
    and their `web_url`s included: a confirmation that names a recipe links it
    from there.

    `add_item` is for what no recipe calls for — kitchen roll, a carton of
    milk, more of something that ran out. Those are collected in
    `Extra Items.menu`, which this tool writes and keeps on the list; never
    create or edit that file with `recipe_write`, and never put a loose
    ingredient in `Meal Plan.menu` instead. Adding a name already there
    replaces its quantity rather than listing it twice, so pass the total the
    user now wants. The items clear themselves once the list has been cleared,
    so nothing carries over from the last trip. `check` and `uncheck` treat
    them like any other ingredient, while `remove_item` reaches only items
    added this way: an ingredient a recipe calls for leaves with the recipe.

    `clear` after the user has shopped is the normal end of a trip. When a
    meal-plan copy has just been written, clear the list if every ingredient is
    ticked off, and say that you did; if any is still unticked, ask first and
    otherwise leave it alone.
    """
    for change in changes:
        if change.action in ("add_item", "remove_item"):
            await _edit_extras(change)
            continue
        endpoint, body = _shopping_request(change)
        await cook.request(
            "POST",
            f"/api/shopping_list/{endpoint}",
            **({"json": body} if body is not None else {}),
        )
    return {"applied": len(changes), **await shopping_list_read()}


# -- aisles ---------------------------------------------------------------
#
# Both edit tools take a discriminated union, so the input schema already
# publishes every action's fields and which are required. The docstrings
# therefore carry only the behaviour behind each action, which no schema can
# state, and never a second copy of the field list.


@mcp.tool(annotations=READ)
async def aisles_read(
    query: str | list[str] = "", uncategorized: bool = False
) -> dict[str, Any]:
    """Read aisles as {aisle: [[preferred name, alias, ...], ...]}.

    Aisles are the store sections the shopping list is grouped into.

    Each inner list is one ingredient: its preferred shopping-list name first,
    followed by all its aliases. A case-insensitive substring query matches any
    name and returns the whole group. For example, searching "milk" returns
    [["milk", "milch"], ["whole milk"]]. Matching an aisle's name returns all
    its ingredients. Pass a list such as ["milk", "Milch", "milks"] to match
    ANY term, returning each ingredient once. Blank terms are ignored; no
    nonblank terms returns every aisle, including empty ones.
    `uncategorized` also lists the ingredient names the collection uses that no
    aisle has yet. `configured` is false when the collection has no aisle file
    at all. Use ingredients_edit to change ingredients and aliases, or
    aisles_edit to organize aisles.
    """
    catalogue = (await cook.request("GET", "/api/aisles")).json()
    terms = {
        term.strip().casefold()
        for term in ([query] if isinstance(query, str) else query)
    }
    terms.discard("")

    def matches(name: str) -> bool:
        return not terms or any(term in name.casefold() for term in terms)

    aisles = {}
    for aisle in catalogue["aisles"]:
        aisle_matches = matches(aisle["name"])
        groups = [
            entry["names"]
            for entry in aisle["ingredients"]
            if aisle_matches or any(matches(name) for name in entry["names"])
        ]
        if aisle_matches or groups:
            aisles[aisle["name"]] = groups
    result = {
        "configured": catalogue["configured"],
        "aisles": aisles,
    }
    if catalogue["warnings"]:
        result["warnings"] = catalogue["warnings"]
    if uncategorized:
        unassigned = (await cook.request("GET", "/api/aisles/uncategorized")).json()
        result["uncategorized"] = [
            item["name"] for item in unassigned["ingredients"] if matches(item["name"])
        ]
    return result


@mcp.tool(annotations=WRITE)
async def aisles_edit(
    changes: Annotated[list[catalogue.AisleChange], Field(min_length=1)],
) -> dict[str, Any]:
    """Organize aisles in one atomic batch: create, rename, move or delete one.
    Use ingredients_edit for the ingredients inside them.

    `create` appends to the end unless given a position, names are matched
    ignoring case, and deleting a nonempty aisle fails unless
    delete_ingredients is true — which deletes its ingredient groups with it.
    A missing catalogue is initialized on the first aisle created.

    Recipes are never changed. Changes run in order, all or none. Concurrent
    edits fail; read again before retrying.
    """
    return await _edit_catalogue(changes)


@mcp.tool(annotations=WRITE)
async def ingredients_edit(
    changes: Annotated[list[catalogue.IngredientChange], Field(min_length=1)],
) -> dict[str, Any]:
    """Categorize ingredients and manage aliases in one atomic batch: create,
    update, merge or delete an ingredient group.

    `create` needs an aisle that already exists — make one with aisles_edit
    first. `update` touches only the fields it is given and matches
    `ingredient` against any existing name, ignoring case; moving an ingredient
    keeps its aliases, and renaming keeps the old name as one, so pass it in
    remove_aliases to drop it. Removing the preferred name means naming another
    preferred_name in the same update. Aliases are alternative spellings of one
    ingredient, never a replacement for the complete group.

    `merge` folds groups into the one owning preferred_name, which supplies the
    aisle and position, and keeps every alias. An alias owned by a third
    ingredient fails the whole batch rather than being merged silently, so use
    merge only when the ingredients really are the same thing. `delete` removes
    a whole group; to drop a single alias, update with remove_aliases instead.

    Recipes never change. Changes run in order, all or none. Concurrent edits
    fail; read again before retrying.
    """
    return await _edit_catalogue(changes)


async def _edit_catalogue(changes) -> dict[str, Any]:
    current = (await cook.request("GET", "/api/aisles")).json()
    batch = catalogue.compile_changes(current, changes)
    if not current["configured"]:
        current = (await cook.request("POST", "/api/aisles")).json()
    updated = (
        await cook.request(
            "POST",
            "/api/aisles/changes",
            json={"revision": current["revision"], "changes": batch},
        )
    ).json()
    result = {"applied": len(changes)}
    if updated["warnings"]:
        result["warnings"] = updated["warnings"]
    return result


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
