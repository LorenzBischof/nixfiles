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

One route here is not a tool: `/picture/{token}` takes a recipe's picture as an
ordinary HTTP body, because MCP cannot carry a file. See `pictures.py`.
"""

from __future__ import annotations

import asyncio
import functools
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
from mcp.server.mcpserver import MCPServer
from mcp.server.mcpserver.exceptions import ToolError
from mcp.server.transport_security import TransportSecuritySettings
from mcp.types import ToolAnnotations
from pydantic import AnyHttpUrl, BaseModel, Field, model_validator
from starlette.requests import Request
from starlette.responses import JSONResponse

from . import catalogue, menus, pictures
from . import cookcli as cook
from .diagnostics import Diagnostic, DiagnosticsUnavailable, diagnose
from .importer import fetch_recipe as fetch_recipe_from_url

WEB_URL = (
    os.environ.get("COOKLANG_WEB_URL")
    or os.environ.get("COOKLANG_SERVER_URL")
    or "http://127.0.0.1:9080"
).rstrip("/")

# The public name and path a reverse proxy serves this server under. Only the
# upload link is built from it, and nothing can derive it: the process binds
# loopback and never sees the name it is reached by.
PUBLIC_URL = (os.environ.get("COOKLANG_MCP_PUBLIC_URL") or "").rstrip("/")

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
#
# The first paragraph is the one the client needs most and is also repeated,
# because it is not a rule but the cue that a tool applies at all: a request
# about what to have for dinner, or about the groceries, carries neither the
# word "recipe" nor "shopping list", and without being told the user has a
# collection a client answers it out of its own cooking knowledge and calls
# nothing. So each tool a cold conversation lands on first opens by saying
# when it is the one to reach for, in the words the user would actually use —
# see `test_the_entry_points_say_when_to_reach_for_the_collection`.
INSTRUCTIONS = f"""\
The user's own recipes, meal plan, shopping list and record of what they have \
eaten. Food is always about this collection: what to cook or eat, what is \
planned, what to buy, what was eaten. Search it before answering from general \
cooking knowledge, whether or not the words "recipe" or "cooking" are used.

Whenever an answer names a recipe or meal plan you have a web URL for, make \
the name a clickable Markdown link to it — every name, every time, however \
many an answer carries: the confirmation after a write, the summary that \
closes a run of several writes and names each recipe it touched, and the \
recipes inside a meal plan, which come with URLs of their own. Any `web_url` \
a tool returned in this conversation counts, not only the one from the last \
call. The shopping list has a page of its own, returned by both shopping \
tools as the result's own `web_url`: when an answer mentions the shopping \
list, the words "shopping list" are that link. Never construct or guess a \
URL: a name you have none for stays plain, and a recipe's external \
`source.url` is where it came from, not its page here.

A write's `new_ingredients` are the ingredient names no aisle lists yet. \
Sort every one of them into an aisle before you answer, in a single \
`ingredients_edit` batch: an `update` adding the name as an alias of the \
`similar` ingredient it is another spelling of, or a `create` in whichever of \
the result's `aisles` it belongs in. Ingredients that are genuinely different \
stay different, and when no existing aisle fits, ask the user which to use \
rather than creating one.

`{PLAN_PATH}` at the collection root is the ordered queue of upcoming recipes, \
under `Meals`. `{HISTORY_PATH}` is the record of cooked ones. Both are \
ordinary recipe files, so `recipe_read` and `recipe_write` work on them — but \
when the user says a recipe was cooked, use `mark_cooked`, which moves it from \
the one to the other. Do not create weekly or date-named plan files. When adding \
a meal plan to the shopping list, read it and add its individual recipes with \
their scales, never the whole menu file. This is a temporary workaround until \
CookCLI handles menu updates and removing individual recipes correctly: editing \
the plan must not be assumed to update the shopping list.\
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


# Notes are the one part of a recipe that changes an answer about something
# else: what to buy, and what has to be started the day before. They are in
# the file and in none of the payloads these tools otherwise build, so the
# alternative to carrying them is a `recipe_read` per recipe and the whole
# source back for one line — see `_notes`.
Notes = Annotated[
    list[str] | None,
    Field(
        default=None,
        description=(
            "The recipe's own notes, in file order — its `>` lines, which is "
            "where it says what its ingredients and steps cannot: an "
            "ingredient that is optional, a dish it is usually eaten with, a "
            "variation, preparation to do the day before. Empty when the "
            "recipe has no notes; `null` when they could not be read, which "
            "is not the same thing and is not something to report as the "
            "recipe saying nothing."
        ),
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


class MenuEntry(RecipeSummary):
    """A recipe a meal plan or history refers to.

    A search hit carries no `notes`, and deliberately: an empty query lists
    the whole collection, so filling them there would be a request per file
    to answer a question about none of them. Here the entries are the few
    recipes one plan holds, and a note on one of them is what says the dough
    has to be made tonight.
    """

    notes: Notes


MenuEntries = Annotated[
    list[MenuEntry],
    Field(
        default_factory=list,
        description=(
            "For a meal plan or history, the recipes it refers to in file "
            "order, each with its own page and its own notes — so a name "
            "taken from this file can be linked, and what it needs done "
            "ahead of the day can be said. Empty for an ordinary recipe."
        ),
    ),
]


Picture = Annotated[
    Literal["metadata", "file", "none"],
    Field(
        description=(
            "Whether the recipe has a picture of the dish: `metadata` for one "
            "the frontmatter's `image` line links, `file` for one stored "
            "beside the recipe, and `none` for neither."
        )
    ),
]


class RecipeDocument(BaseModel):
    """A stored recipe or meal plan and its Cook web page."""

    path: str = Field(description="Path used with the other recipe tools.")
    web_url: WebUrl
    source: str = Field(
        description="Complete raw Cooklang source, frontmatter included."
    )
    picture: Picture
    entries: MenuEntries


class SimilarIngredient(BaseModel):
    """A catalogued ingredient that a new name may be another spelling of."""

    name: str = Field(
        description=(
            "Its preferred shopping-list name, which is also what identifies "
            "it to `ingredients_edit`."
        )
    )
    aisle: str = Field(description="The aisle it is sorted into.")


class NewIngredient(BaseModel):
    """An ingredient name the aisle catalogue does not hold yet."""

    name: str = Field(description="The name as the saved recipe spells it.")
    similar: list[SimilarIngredient] = Field(
        default_factory=list,
        description=(
            "Catalogued ingredients worth comparing it against, in no "
            "particular order, empty when the catalogue has nothing like it. "
            "One of these being the same ingredient under another spelling "
            "is what makes this an alias rather than a new entry; a related "
            "but distinct ingredient keeps its own entry, and its aisle is "
            "the first guess for where that entry goes."
        ),
    )


class CatalogueCheck(BaseModel):
    """What the aisle catalogue made of one recipe's ingredients."""

    new_ingredients: list[NewIngredient] = Field(default_factory=list)
    aisles: list[str] = Field(default_factory=list)
    warnings: list[str] = Field(default_factory=list)


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
    new_ingredients: list[NewIngredient] = Field(
        default_factory=list,
        description=(
            "Ingredient names in the saved file that no aisle lists yet. "
            "Sort all of them into aisles before answering, in one "
            "`ingredients_edit` batch, so the shopping list groups them and "
            "one thing never reaches it under two names: `update` the "
            "`similar` ingredient with this name in `add_aliases` when the "
            "two are the same ingredient — adding `preferred_name` if this "
            "spelling is the one the shopping list should show — and "
            "otherwise `create` it in the aisle from `aisles` it belongs in. "
            "Never fold together ingredients that are really different: "
            "'whole milk' is not 'milk'. If no aisle in `aisles` fits, ask "
            "the user which to use instead of creating one. Empty when the "
            "catalogue already knows every name, or could not be read, which "
            "`warnings` then says."
        ),
    )
    aisles: list[str] = Field(
        default_factory=list,
        description=(
            "The aisles the collection has, in catalogue order: the choices "
            "for a `new_ingredients` entry, and filled in only when there is "
            "one to sort."
        ),
    )
    warnings: list[str] = Field(
        default_factory=list,
        description=(
            "Prose about the write: a sentence for any check that could not "
            "be run — which is not the same as a check that came back clean."
        ),
    )
    entries: MenuEntries


class PictureUpload(BaseModel):
    """Where to send a recipe's picture."""

    path: str = Field(description="Path of the recipe the picture is for.")
    web_url: WebUrl
    upload_url: str = Field(
        description=(
            "PUT the picture file here, the file itself as the request body. "
            "Never read, encode or pass its bytes through a tool call. The "
            "reply is JSON and is the confirmation: read it rather than "
            "assuming the upload worked. Good for `expires_in_seconds`, and "
            "for this recipe only."
        ),
        json_schema_extra=URI,
    )
    expires_in_seconds: int = Field(
        description=(
            "How long `upload_url` stays valid, counted from this reply. "
            "After that it is refused and this tool has to be called again "
            "for a fresh link — so send the file now rather than asking the "
            "user something first and uploading afterwards."
        )
    )


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


def shopping_list_web_url() -> str:
    """Return the public Cook page for the shopping list itself.

    The one page here that is not a file: it is the list the two shopping
    tools read and write, and the words "shopping list" in an answer are what
    links to it.
    """
    return f"{WEB_URL}/shopping-list"


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
# mcp 2 renamed FastMCP to MCPServer and moved every transport-shaped argument
# off the constructor and onto run(), so host, port and transport_security now
# live in main() instead of here.
mcp = MCPServer(
    "Recipes, Meal Plans & Groceries",
    instructions=INSTRUCTIONS,
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
)


# The exception types this package raises on purpose, as opposed to the ones
# that mean it has a bug. ValueError covers the domain errors and the pydantic
# validators (which have to raise ValueError), plus pictures.BadToken; RuntimeError
# covers cookcli.CookCliError, diagnostics.DiagnosticsUnavailable and the
# importer's fetch failures. A TypeError or KeyError is deliberately absent.
AGENT_FACING = (ValueError, RuntimeError)


def tool(**kwargs):
    """`mcp.tool`, but a deliberate exception reaches the agent as its message.

    mcp 1 turned any exception a tool raised into a ToolError carrying its
    message. mcp 2 does that only for ToolError itself; everything else becomes
    `UnexpectedToolError("Error executing tool <name>")`, which keeps the
    original only on `__cause__` and so tells the agent nothing it can act on.

    The errors worth forwarding — "Aisle not found", "the aisle file changed",
    "not on the list as a single item" — are raised from modules that know
    nothing about MCP, so translate at the boundary instead of rewriting every
    raise. Anything outside `AGENT_FACING` is left alone, so a genuine bug
    still surfaces as UnexpectedToolError rather than being dressed up as
    advice; that part of mcp 2's change is an improvement worth keeping.

    Registers the wrapper but returns `fn`, so the module-level name stays the
    plain function: calling a tool directly (as the tests do) keeps raising the
    original exception, and only the MCP surface sees ToolError.
    """

    def decorate(fn):
        @functools.wraps(fn)
        async def wrapper(*args, **kw):
            try:
                return await fn(*args, **kw)
            except AGENT_FACING as err:
                raise ToolError(str(err)) from err

        mcp.tool(**kwargs)(wrapper)
        return fn

    return decorate


# -- recipes and menus ----------------------------------------------------


@tool(annotations=READ)
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
    """Search the user's own recipes and meal plans, matching recipe names,
    ingredients, instructions, tags, or other metadata.

    This is the collection they cook out of, so reach for it whenever food
    comes up at all, not only when they say "recipe" or "cooking": what to
    have for dinner tonight, lunch, breakfast, something quick, something
    with what is in the fridge, ideas for the week, what they are in the mood
    for. Search here before answering from general cooking knowledge, and
    never hand them an invented dish as though it were one of theirs — no
    hits is itself the answer that they have nothing for it.

    An empty query matches everything. Results contain metadata only; use
    `recipe_read` for the complete recipe or meal plan.

    Every hit carries its own page. Naming one in an answer means linking that
    name to its `web_url` — every name, every time, however many the answer
    holds, and in a later reply just as much as this one.
    """
    return [_summary(entry) for entry in await cook.search_entries(query)]


@tool(annotations=READ)
async def recipe_read(path: Path) -> RecipeDocument:
    """Read one recipe or meal plan already in the user's collection: its raw
    Cooklang source, frontmatter included, and its clickable Cook web page.

    This answers how one of their dishes is made — what goes in it, how long
    it takes, what it serves — and what is coming up to eat, since
    `Meal Plan.menu` is the queue of that: "what are we eating this week" is
    a read of that file.

    For a meal plan or history, `entries` resolves the recipes it refers to,
    each with its own page. Naming one of them in an answer means linking it
    from there: the file's own `web_url` is the plan's page, not theirs.

    Saying what is planned also means saying what has to happen before the
    day it is cooked, and each entry's `notes` are where its recipe says so.
    Give each at most one short sentence of what they put ahead of the
    cooking — a dough or a marinade resting overnight, beans soaked, a joint
    out of the freezer the day before, something bought fresh that morning.
    Only what a note says, nothing for an entry whose `notes` are empty, and
    never preparation you inferred from the dish.

    `picture` says whether the dish already has one: a `file` picture is
    stored beside the recipe and appears nowhere in the source text. Offer to
    add one only when it is `none`.

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
        picture=await _picture(path),
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


def _similar(name: str, known: dict[str, SimilarIngredient]) -> list[SimilarIngredient]:
    """Catalogued ingredients worth comparing a new name against.

    Two cheap rules: one name's words run inside the other's ("butter" for
    "unsalted butter", "garlic clove" for "garlic cloves"), or the whole names
    are spelled nearly the same ("onion" for "onions"). Three at most — these
    are candidates for the model to judge, not a ranking.
    """
    words = _words(name)
    matches = [
        found
        for key, found in known.items()
        if _runs_inside(words, _words(key)) or _runs_inside(_words(key), words)
    ]
    matches += [known[key] for key in get_close_matches(name, known, n=3, cutoff=0.8)]
    unique: dict[str, SimilarIngredient] = {}
    for found in matches:
        unique.setdefault(found.name.casefold(), found)
    return list(unique.values())[:3]


async def _catalogue_check(ingredients: list[dict[str, Any]]) -> CatalogueCheck:
    """The ingredient names no aisle holds yet, and what to compare them to.

    The judgement the sorting needs — whether two names are one ingredient,
    and which aisle a genuinely new one belongs in — is the model's, so this
    writes nothing to the catalogue and does not guess an aisle. It gathers
    what one `ingredients_edit` batch needs to settle every new name without
    reading the catalogue again: the candidates each name resembles, and the
    aisles there are to choose from. A recipe reference is not an ingredient,
    so it is left out.
    """
    names: dict[str, str] = {}
    for ingredient in ingredients:
        if not ingredient.get("reference"):
            names.setdefault(ingredient["name"].casefold(), ingredient["name"])
    if not names:
        return CatalogueCheck()
    catalogue = (await cook.request("GET", "/api/aisles")).json()
    if not catalogue["configured"]:
        return CatalogueCheck(
            warnings=[
                "The collection has no aisle file, so its ingredients could "
                "not be sorted into aisles. Ask the user which aisles they "
                "shop by before creating any."
            ]
        )
    known = {
        name.casefold(): SimilarIngredient(name=entry["names"][0], aisle=aisle["name"])
        for aisle in catalogue["aisles"]
        for entry in aisle["ingredients"]
        for name in entry["names"]
    }
    new = [
        NewIngredient(name=name, similar=_similar(key, known))
        for key, name in sorted(names.items())
        if key not in known
    ]
    if not new:
        return CatalogueCheck()
    return CatalogueCheck(
        new_ingredients=new,
        aisles=[aisle["name"] for aisle in catalogue["aisles"]],
    )


async def _picture(path: str) -> Picture:
    """Whether `path` has a picture of the dish, which its source cannot say.

    A stored picture is a file beside the recipe and leaves no trace in the
    Cooklang text, so one small request is the only way to tell that recipe
    from one with no picture at all. Only whether, not where: a linked
    picture's URL is in the frontmatter already, and a stored one's is a file
    nothing here reaches.

    Anything but `metadata` behind a picture that exists is reported as a
    stored file, so a kind of picture added upstream reads as a picture rather
    than failing the whole read on an unknown word. A failed request does fail
    the read, unlike the menu entries below: it is the same server answering
    the line above, so it has already failed by then.
    """
    body = await cook.get_recipe_image(path)
    if not body.get("image"):
        return "none"
    return "metadata" if body.get("source") == "metadata" else "file"


async def _notes(paths: list[str]) -> dict[str, list[str] | None]:
    """Each recipe's own notes, fetched together.

    One read per recipe is what a note costs: the recipe tree carries metadata
    and no body, and the shopping list carries paths and aggregated
    ingredients. Doing it here rather than leaving it to the caller is the
    whole point — the caller's only route to the same lines is a `recipe_read`
    per recipe, which is a round trip each and the complete source back to
    find one of them, where these run concurrently against the same server the
    call above just used.

    A read that fails leaves `None` for that path instead of an empty list:
    a file gone between the two calls 404s, and a recipe whose page shows a
    parse error in place of the recipe is what `recipe_write` already treats a
    failed read-back as. "We could not look" must not reach the model as "it
    says nothing".
    """

    async def one(path: str) -> list[str] | None:
        try:
            parsed = (await cook.request("GET", f"/api/recipes/{path}")).json()
        except Exception as err:  # noqa: BLE001 - the call being answered succeeded
            logging.getLogger(__name__).warning(
                "Reading the notes of %s failed: %s", path, err
            )
            return None
        return cook.recipe_notes(parsed.get("recipe") or {})

    found = await asyncio.gather(*(one(path) for path in paths))
    return dict(zip(paths, found))


async def _menu_entries(path: str, source: str) -> list[MenuEntry]:
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

    Each resolved entry also carries its own notes, because what a plan is
    read for includes what has to happen before the day: see `_notes`.
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
    entries = [known[name] for name in referenced if name in known]
    notes = await _notes([entry["path"] for entry in entries])
    return [
        MenuEntry(**_summary(entry).model_dump(), notes=notes[entry["path"]])
        for entry in entries
    ]


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
@tool(annotations=WRITE)
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

    Reach for it whenever the user wants something kept: a recipe they
    dictated, pasted or want saved, a change to one of theirs, or the week's
    meals queued up.

    Nothing rejects a malformed file, so the result carries what became of it.
    `diagnostics` is the Cooklang parser's own errors and warnings, each with
    its line: an `error` means the file is saved but unreadable, and is worth
    raising with the user and offering to fix. The parser is lenient, though,
    and says nothing about the commonest mistake — an unclosed brace makes
    `@sugar{2%g and` a plain step, silently — which is why `ingredients` lists
    the names it actually found. Read them back: one missing from that list was
    dropped, and will be missing from the shopping list too.

    `new_ingredients` holds the names no aisle lists yet, each with the
    catalogued ingredients it resembles. Sort all of them in one
    `ingredients_edit` batch before answering, so the shopping list groups
    them and one thing never reaches it under two names: when a `similar`
    entry is the same ingredient under another spelling, `update` that
    ingredient with the new name in `add_aliases` — passing `preferred_name`
    too if the new spelling is the one the list should show — and otherwise
    `create` the name in whichever aisle from `aisles` it belongs in, which
    for a related ingredient is usually its `similar` entry's. Ingredients
    that really are different stay apart: "whole milk" is not "milk". If no
    aisle in `aisles` fits, ask the user which to use instead of creating one.
    Say in one line what you sorted where.

    Preparation belongs in a note, not the name: `@onion{1}(finely diced)`
    keeps the shopping list and the aisle catalogue saying "onion" while the
    step still reads "finely diced". The braces go first even when empty —
    `@soy sauce{}(diced)` — because a name without them ends at the first
    space.

    What a recipe says about itself beyond its ingredients and steps belongs
    in `>` note lines, which is where the shopping and plan answers read it
    back from: an ingredient that is optional, a dish this one is usually
    eaten with, a variation worth knowing, preparation that has to happen the
    day before. Put the notes at the top of the file, above the first step and
    below the frontmatter: notes are reported in file order, so there they
    lead, and they are what the user reads before starting. Leave a blank line
    above a note — a `>` line directly under a step line is taken into that
    step, where it shows up as a note nowhere and nothing reports it. The web
    UI's cook mode does not show notes at all, so a note is for deciding —
    before the shop, before the day — and anything needed at the stove belongs
    in a step.

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

    Writing the plan does not synchronize the shopping list. When asked to
    shop for the plan, add each referenced recipe separately with its scale
    through `shopping_list_edit`, never `Meal Plan.menu` itself. This temporary
    CookCLI workaround keeps recipes individually removable from the list.

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
    check = CatalogueCheck()
    try:
        check = await _catalogue_check(ingredients)
    except Exception as err:  # noqa: BLE001 - post-save checks must not hide success
        logging.getLogger(__name__).warning("Ingredient check failed: %s", err)
        warnings.append(
            "Recipe saved, but the aisle catalogue could not be read, so its "
            "ingredients were neither checked nor sorted into aisles."
        )
    return RecipeWritten(
        path=path,
        web_url=recipe_web_url(path),
        diagnostics=diagnostics,
        ingredients=[ingredient["name"] for ingredient in ingredients],
        new_ingredients=check.new_ingredients,
        aisles=check.aisles,
        warnings=warnings + check.warnings,
        entries=entries,
    )


@tool(annotations=DELETE)
async def recipe_delete(path: Path) -> dict[str, Any]:
    """Permanently delete a recipe or meal plan. There is no undo and no
    trash."""
    await cook.request("DELETE", f"/api/recipes/{path}")
    return {"path": path, "deleted": True}


@tool(annotations=WRITE)
async def recipe_image_upload(path: Path) -> PictureUpload:
    """Get a URL for uploading a picture of a recipe — a photo of the dish, or
    any picture file to keep with the recipe rather than link to.

    Reach for it when the picture is not a URL to point at: one the user
    photographed themselves, or one on a site that blocks hotlinking. The
    ordinary way a recipe carries a picture is the `image` key in its
    frontmatter, which `recipe_import` fills in from the page already.

    Nothing is uploaded by calling this. Send the file to `upload_url` from
    wherever the file actually is:

        curl -sS -X PUT --data-binary @photo.jpg "<upload_url>"

    Send the file. Never read it, encode it, or pass its bytes through a tool
    call: a photo is megabytes, this protocol cannot carry one, and trying
    spends the context window on an upload that arrives corrupted. If there is
    no way to make that request from where the file is, say so and point at the
    recipe's own page in the web UI, which has a file picker — also the way to
    upload from a phone.

    The reply to the PUT is the confirmation; read it rather than assuming.
    JPEG, PNG and WebP, and an iPhone's HEIC is refused with a message saying
    how to convert it.

    This is the recipe's title picture, and the recipe has to exist already.
    Pictures of individual steps are not reachable from here. A recipe cannot
    both link and store one — an `image` line in the frontmatter wins — so the
    reply's `warnings` says when the frontmatter hid the upload, and dropping
    that line is `recipe_write`'s job. `recipe_read`'s `picture` says whether
    the recipe has one already.

    Confirm with the recipe's title linked to `web_url`.
    """
    if not PUBLIC_URL:
        raise ValueError(
            "This server has no public URL configured, so it cannot hand out "
            "an upload link. The picture can still be added through the "
            "collection's web UI, on the recipe's own page."
        )
    return PictureUpload(
        path=path,
        web_url=recipe_web_url(path),
        upload_url=f"{PUBLIC_URL}/picture/{pictures.mint(path)}",
        expires_in_seconds=pictures.TTL_SECONDS,
    )


# Not a tool: the whole point is that the picture never passes through the
# model. Served by the same ASGI app as `/mcp` and carrying no MCP
# authorization, which is what the signed token is for — see `pictures.py`.
# POST as well as PUT, because being refused for the verb after sending the
# file is a poor way to learn that.
@mcp.custom_route("/picture/{token}", methods=["PUT", "POST"], include_in_schema=False)
async def upload_picture(request: Request) -> JSONResponse:
    status, body = await pictures.receive(
        request.path_params["token"], await request.body()
    )
    return JSONResponse(body, status_code=status)


@tool(annotations=WEB_READ)
async def recipe_import(
    url: Annotated[
        str, Field(description="The recipe web page, exactly as the user gave it.")
    ],
) -> dict[str, Any]:
    """Read a recipe off a web page so it can be imported. This saves nothing:
    convert the returned material to Cooklang and pass it to `recipe_write`.

    Any link to a dish is one of these, including a bare URL the user pastes
    with nothing said about it: a food page they send is a recipe they are
    thinking of keeping, so read it and offer to save it.

    Everything you write must come from this result. A recipe reconstructed
    from memory is not the one at that URL, however familiar the dish looks:
    use the ingredients, quantities and steps in `text` and nothing else, and
    where the page is silent — an oven temperature, a resting time — leave it
    out rather than supply a plausible value.

    Read what came back before you write it, the way a cook would: recipe data
    can parse perfectly and still be wrong — nought minutes of preparation, a
    yield that contradicts the quantities, a step that breaks off mid-sentence,
    an ingredient no step ever uses, a quantity off by a factor of ten. Say
    what looks wrong and let the user decide; do not quietly correct it, and do
    not quietly write it down as though it were fine.

    - `frontmatter` is a finished YAML block, `---` delimiters included,
      carrying `source.url` with the exact URL. Put it at the top of the
      `.cook` file, and never retype or shorten that URL. It carries no `tags`:
      a page's keywords are its SEO surface, so pick tags that match the ones
      already in the collection.
    - `text` is the recipe as the page stated it: ingredients, then the method.
    - `extraction` is `structured` when the page's machine-readable recipe
      data could be read in full. It is `page_text` when it could not — either
      the page published none, or it published some that would not parse. Then
      `text` is the readable text of the whole page, navigation and comments
      included, and finding the recipe in it is your job. If there is no recipe
      in it, say so instead of inventing one.
    - `notes` carries anything else worth knowing about this result, including
      the parser's own message for any recipe field the page published and
      broke. A field that failed to parse is not a field the page left out: the
      page states it somewhere, so read it out of `text` instead of leaving it
      out of the recipe.

    An error means the page could not be read at all. Report that; do not
    answer it with a recipe of your own.
    """
    return await fetch_recipe_from_url(url)


async def _read_menu(path: str, existing: set[str]) -> str | None:
    """A menu file's source, or None when the collection has no such file."""
    if not any(menus.same_recipe(path, other) for other in existing):
        return None
    return (await cook.request("GET", f"/api/recipes/raw/{path}")).text


@tool(annotations=WRITE)
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
                "below the recipe; pass it only when they have already said, "
                "never to hold the entry back until they do."
            )
        ),
    ] = None,
) -> MealCooked:
    """Record that a recipe was cooked: add it to `Meal History.menu` and take
    it off `Meal Plan.menu`.

    Use it whenever they mention having eaten something of theirs — "we had
    the risotto last night", "I made the curry on Sunday", "that one was
    good" about a dish they cooked — and not only when they ask to mark one
    cooked. The same file answers what they have been eating lately.

    This replaces editing those two files by hand. It reuses an existing
    section for that date or opens a new one in the right place, keeps the
    history newest-first, puts feedback directly below its recipe, and only
    touches the plan once the history is safely written. Creates
    `Meal History.menu` if the collection has none.

    `remaining_plan` is what is still queued afterwards, each recipe with its
    own page: say what is left from there, linking every name to its entry.

    Ask the user when it was cooked, then record it straight away. Pass the
    exact date when they know it. When the answer is vague or they do not
    remember, pick a plausible past date from the dates already in the history
    — normally avoid putting two recipes on one inferred day, though treat
    that as a soft rule — and pass `date_estimated`.

    Ask for brief feedback afterwards, saying it is optional, and add what
    they say by editing `Meal History.menu` with `recipe_write`: a
    `Feedback: ...` block directly below the recipe's reference. Never wait on
    that answer before calling this — a question left open while nothing is
    recorded reads to the user as already done.
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


@tool(annotations=READ)
async def shopping_list_read() -> dict[str, Any]:
    """Read the user's shopping list, including the recipes or meal plans that
    were added and the resulting ingredients.

    This is the list they shop from, so it answers anything about buying
    food: what to get, whether something is on it already, what is still
    missing. Read it when they are heading to the shop or the supermarket or
    doing the groceries, however they put it.

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

    The result's own `web_url` is the list's page. Whenever an answer mentions
    the shopping list, make the words "shopping list" a Markdown link to it —
    every mention, every time, here or in a later reply.

    Each entry in `recipes` also carries a `web_url`, its page in the user's
    collection. Naming one of those recipes in an answer means linking that
    name to its `web_url` — every name, every time, here or in a later reply.
    Ingredients have no page, so their names stay plain; never assemble a URL
    for one.

    Each entry's `notes` are its recipe's own `>` lines, read for you so that
    walking the user through what to buy costs no further calls. Give each at
    most one short sentence of what they change about the shopping: an
    ingredient it marks optional, a side or second recipe it says this one is
    usually eaten with, a variation that swaps something out. Only what a note
    says, nothing for a recipe whose `notes` are empty, and never a
    substitution of your own. `null` there means the notes could not be read,
    not that the recipe has none.

    Copying these recipes into `Meal Plan.menu` is only ever done when the user
    explicitly asks for it. Then read the plan, append the missing recipe paths
    in shopping-list order without disturbing the queue, and preserve a
    non-default scale — empty braces mean scale 1. Say which already-planned
    paths you skipped; `Risotto.cook` and `./Risotto` are the same path. A
    recipe in the plan but absent from this list may be stale, so ask whether
    it is still upcoming or was already cooked.
    """
    result = await cook.shopping_list()
    notes = await _notes([recipe["path"] for recipe in result["recipes"]])
    for recipe in result["recipes"]:
        recipe["web_url"] = recipe_web_url(recipe["path"])
        recipe["notes"] = notes[recipe["path"]]
    result["extra_items"] = await _extra_items(result["recipes"])
    # The list's own page, alongside the pages of the recipes on it. Present
    # even for an empty list: "nothing on the shopping list yet" is as much an
    # answer about the list as any other, and links the same way.
    result["web_url"] = shopping_list_web_url()
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


@tool(annotations=WRITE)
async def shopping_list_edit(
    changes: Annotated[
        list[ShoppingChange],
        Field(description="Applied in order; at least one.", min_length=1),
    ],
) -> dict[str, Any]:
    """Change the shopping list, and return it as it now stands.

    This is the tool for "we are out of milk", "we need bread", "put that on
    the list", "pick up kitchen roll", and for "I have got everything" at the
    end of a trip: anything that changes what the user is going to buy.

    Actions, with the fields they take (? optional): `add`(path, scale?) puts a
    recipe on the list; `remove`(path) takes
    one back off; `add_item`(name, quantity?) puts a single ingredient on it
    and `remove_item`(name) takes that back off; `check`(name) ticks an
    ingredient off and `uncheck`(name) puts it back; `clear` empties the list
    completely. Each action takes only its own fields — a `clear` carrying a
    path is refused rather than read as emptying the list, so send `remove`
    when one recipe is what you mean.

    To shop for a meal plan, read the menu and send a separate `add` for each
    referenced recipe, preserving its scale. Never add `Meal Plan.menu` or
    another whole meal-plan menu as the source. This is a temporary workaround
    until CookCLI correctly handles menu changes and individual recipe removal:
    changing a menu does not reliably refresh its shopping-list ingredients,
    and recipes added through a menu cannot be removed individually. Read the
    shopping list first to avoid adding recipes already present. Changes to the
    plan must not be assumed to change the list; use explicit recipe-level
    shopping-list edits when the user asks to update it. `Extra Items.menu`,
    managed internally by `add_item` and `remove_item`, is separate from this
    meal-plan guidance.

    They are applied in the order given, and a failure part-way through leaves
    the earlier ones applied — this is the same list the web UI shows, not a
    transaction. The result is the whole list afterwards, so there is no need
    to read it back. It has the shape `shopping_list_read` returns, `recipes`
    and their `web_url`s included: a confirmation that names a recipe links it
    from there, and the result's own `web_url` is the list's page — a
    confirmation saying what is now on the shopping list makes those words a
    Markdown link to it.

    An `add` is also the moment for what the recipe's `notes` in the result
    change about the shopping — an ingredient it marks optional, a dish it
    says this one is usually eaten with, a variation that swaps something
    out — in one short sentence, in the note's own words and only when it has
    any.

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


@tool(annotations=READ)
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


@tool(annotations=WRITE)
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


@tool(annotations=WRITE)
async def ingredients_edit(
    changes: Annotated[list[catalogue.IngredientChange], Field(min_length=1)],
) -> dict[str, Any]:
    """Categorize ingredients and manage aliases in one atomic batch: create,
    update, merge or delete an ingredient group. This is where a write's
    `new_ingredients` get sorted: one batch, an `update` with `add_aliases`
    for a name that is another spelling of a catalogued ingredient and a
    `create` for one that is not.

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
    mcp.run(
        "streamable-http",
        host=os.environ.get("COOKLANG_MCP_HOST", "127.0.0.1"),
        port=int(os.environ.get("COOKLANG_MCP_PORT", "3001")),
        # Off, because the guard is aimed at a browser reaching a loopback
        # server and the only thing that reaches this one is the reverse proxy
        # in front of it. On, it rejects every proxied request: the `Host`
        # header is the public name, not `localhost`.
        transport_security=TransportSecuritySettings(
            enable_dns_rebinding_protection=False
        ),
    )


if __name__ == "__main__":
    main()
