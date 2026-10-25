# cooklang-mcp

An MCP server over a [Cooklang](https://cooklang.org) recipe collection.

It holds no state. The recipe files, the aisle and pantry configuration and the
shopping list all live in the collection
[CookCLI](https://github.com/cooklang/cookcli)'s `cook server` was pointed at,
and this server is an HTTP client for it. A recipe written here appears in the
web UI; an item ticked off there comes back ticked off here.

The tool descriptions are the authoritative documentation — they are what the
model reads, and they carry the reasoning. This is orientation.

## Tools

Twelve tools in three groups, named for the thing they act on. A group pairs one
read with one write rather than giving every endpoint underneath a tool of its
own: faced with twelve flat names, a client mixed `read_recipe` up with
`fetch_recipe` and never preferred one shopping-list verb over another.

| Tool | | CookCLI endpoint |
| --- | --- | --- |
| `recipe_search` | read | `GET /api/search` + `GET /api/recipes` |
| `recipe_read` | read | `GET /api/recipes/raw/*path` |
| `recipe_write` | write | `PUT /api/recipes/*path`, then `GET /api/ws/lsp` + `GET /api/recipes/*path` + `GET /api/aisles` |
| `recipe_delete` | destructive | `DELETE /api/recipes/*path` |
| `recipe_import` | read, web | — reads a web page with [recipe-scrapers](https://github.com/hhursev/recipe-scrapers) |
| `recipe_image_upload` | write | — mints a signed URL for `PUT /api/recipe_image/*path` |
| `mark_cooked` | write | `GET`/`PUT /api/recipes/*path` on the two `.menu` files |
| `shopping_list_read` | read | `GET /api/shopping_list/items` + `POST /api/shopping_list` |
| `shopping_list_edit` | write | `POST /api/shopping_list/{add,add_menu,remove,check,uncheck,clear}`, and `GET`/`PUT /api/recipes/*path` for a loose item |
| `aisles_read` | read | `GET /api/aisles`, optionally `GET /api/aisles/uncategorized` |
| `aisles_edit` | write | `GET /api/aisles`, `POST /api/aisles/changes` |
| `ingredients_edit` | write | `GET /api/aisles`, `POST /api/aisles/changes` |

The second column is the tool's
[annotations](https://modelcontextprotocol.io/). A read carries `readOnlyHint`
so a client can let it through without asking, and only `recipe_delete` carries
`destructiveHint` — it is the one tool no other tool can undo. `recipe_import`
is the only `openWorldHint`: everything else stays inside the collection.

## What is more than a proxy

- **`recipe_search`** joins the search results to the recipe tree, so every hit
  has a title, path, clickable web URL, tags and a recipe-or-plan distinction.
  With no query the tree is already the whole answer.
- **Recipe links.** MCP has no clickable-link primitive, so `web_url` asks for
  the Markdown link in its own field description — an output schema always
  arrives where server instructions get dropped. Nothing says how a URL is
  built: a guessed link to a recipe that moved is worse than a plain name. Which
  is why a `.menu` read resolves its references into `entries`, each with its
  own page — a name needs its URL in the result of the call just made, not three
  calls back.
- **`recipe_write`** reads the file back and returns the `ingredients` the
  parser found, the `diagnostics` it reported, and `new_ingredients`, the names
  the aisle catalogue does not hold yet. Cooklang turns text it cannot interpret
  into a plain step rather than an error, so a mistyped ingredient is otherwise
  dropped silently.
- **A recipe's notes** travel with the payloads that present recipes — each
  entry of the shopping list, and the recipes a `.menu` refers to. A `>` note is
  the only part of a recipe that changes an answer about something else (what to
  buy, what has to be started tonight), and it is in the file and in nothing
  else the API returns: the recipe tree carries metadata only. Carried here, the
  answer costs one call; left out, it costs a `recipe_read` per recipe and the
  whole source back for one line. They come from the parse, not from scanning
  the source for `>`, because a `>` line directly under a step line is taken
  into that step — the source then holds a marker the recipe has no note for,
  and the web UI shows none either. A search hit carries no notes at all: an
  empty query lists the collection, so filling them would be a request per file.
- **`shopping_list_read`** asks for the stored list and then for the ingredients
  it adds up to, because the store holds recipes and only the aggregator turns
  them into ingredients. Exactly what the web UI does, so the two always agree.
- **`shopping_list_edit`** takes an ordered batch and returns the whole list
  afterwards. Not a transaction: a failure part-way leaves the earlier changes
  applied, same as the web UI. Each action accepts only its own fields, so a
  `clear` carrying a path is refused rather than read as emptying the list.

## Being reached for at all

The cost of a thin description is not a wrong tool, it is no tool. "What should
I have for dinner?" contains neither *recipe* nor *shopping list*, and a client
with no reason to think the user has a collection answers it out of its own
cooking knowledge. The server instructions do say so, but claude.ai and Claude
Desktop drop them — so every tool a cold conversation lands on first opens by
saying when it is the one to reach for, in the words a user actually uses. The
server name carries the same words.

## Adding a meal plan to the shopping list

The descriptions tell clients to read the plan and add its recipes individually,
preserving their scales, rather than add the menu file. A temporary workaround
for reported CookCLI behaviour: editing a menu does not reliably update the
shopping list, and a recipe included through a menu cannot be removed
individually. Revisit when CookCLI handles both.

## A single ingredient on the list

CookCLI's shopping list stores recipes and nothing else, so `add_item` keeps the
rest in `Extra Items.menu` at the collection root and holds that file on the
list like any other menu. `menus.py` writes it one ingredient per block, turning
`500 g` into `@Butter{500%g}` so it sums with what a recipe asks for, while
`a pinch` stays the words it is.

The file and the list are kept in step by the tool. The interesting direction is
the other one: a trip ends with `clear`, often in the web UI, which tells this
server nothing — so an addition starts from an empty file whenever the menu is
not currently on the list. That covers a clear from anywhere and a file deleted
by hand, and nothing has to remember to empty them.

`shopping_list_read` returns `extra_items` because the aggregated list carries
no attribution at all: 30 g of butter from a recipe and 250 g added by hand come
back as one line, so only the file says which names `remove_item` may take off.

## Recording a cooked meal

`mark_cooked` adds a recipe to `Meal History.menu` and takes it off
`Meal Plan.menu`. Both are ordinary files `recipe_write` can reach, and leaving
it at that went badly: the right date section, newest-first order, the blank
line between references, feedback staying under the recipe it describes, and
history written before the plan is touched were five paragraphs of instructions,
each of which a client could drop. `menus.py` does it as code and leaves the
model only the judgement that is genuinely its — which day the meal was eaten.

A menu file parses as optional frontmatter, then `= Heading` sections holding
blocks separated by blank lines. The block is the unit that moves, which is what
lets a reference be removed without taking the `Feedback:` note under it.
Rendering normalises to one blank line between blocks, so a round trip tidies
spacing rather than preserving it byte for byte.

## Ingredient names and the aisles

`aisle.conf` groups the shopping list by store aisle, so it doubles as the
collection's vocabulary of ingredient names. `recipe_write` returns the names it
does not hold, each with the catalogued ingredients it resembles, and the tools
ask for them to be sorted in one `ingredients_edit` batch before the write is
confirmed — a write is the one moment when `onion` quietly becoming `onions` is
still cheap to fix.

The server proposes and never decides. Both halves of the judgement are semantic
and neither has a cheap rule: whether two names are one ingredient (`whole milk`
is not `milk`), and which aisle a new one belongs in. So it writes nothing to
the catalogue of its own accord and never guesses an aisle — when none fits, the
instructions say to ask.

`aisles_read` returns `{aisle: [[preferred name, alias, ...], ...]}`, which
keeps aliases together and similar-but-distinct ingredients apart:

```json
{"aisles": {"dairy": [["milk", "milch"], ["whole milk"]]}}
```

Both edit tools take only `changes`, applied in order, all or none, and handle
CookCLI's revision checks internally; a concurrent edit fails the batch.
`ingredients_edit` has `create`, `update`, `merge` and `delete`; `aisles_edit`
has `create`, `rename`, `move` and `delete`. Each action's fields are in its
description.

## What the parser says about a write

A write returns `diagnostics`: the parser's own errors and warnings, each with a
severity, a 1-based line and its message. An `error` means the file does not
parse, so its page shows the error instead of the recipe and nothing in it
reaches the shopping list.

`cook server` keeps that report to itself — a warning goes to its stderr, an
error comes back as a 500 formatted for a terminal — so `diagnostics.py` is a
one-document LSP client against the bridge on `GET /api/ws/lsp`: open a socket,
`initialize`, `didOpen`, take the single `publishDiagnostics`, close. All of it
is a workaround for a missing field, and goes away if `GET`/`PUT
/api/recipes/*path` ever carries the parse report itself. No upstream issue asks
for it yet.

This does not replace reading `ingredients` back: an unclosed brace makes
`@sugar{2%g and` a plain step and is reported by nothing. A write whose
diagnostics cannot be fetched says so in `warnings` rather than returning an
empty list, which would read as a clean file.

One diagnostic is dropped rather than reported: `Unknown timer unit`, which the
language server publishes for every timer that carries a unit, on files the
collection itself accepts — a unit database the language server does not have,
not anything about the file ([cookcli#643][]). It comes back once a cookcli
release carries the fix; `FALSE_TIMER_UNIT_ERROR` in `diagnostics.py` has the
detail.

[cookcli#643]: https://github.com/cooklang/cookcli/issues/643

## A recipe's picture

A recipe normally carries its picture as a URL in the `image` frontmatter key,
which `recipe_import` fills in from the page. `recipe_image_upload` is for when
there is no URL to point at, or pointing at one does not work.

The picture cannot travel through MCP: a tool call is JSON whose schema
vocabulary has no file type, so the only in-band route is the model reciting
base64. The bytes go out of band instead — the tool mints a URL and whatever
holds the file PUTs it there:

```console
$ curl -sS -X PUT --data-binary @photo.jpg "<upload_url>"
{"path":"Risotto.cook","stored":true,"source":"file","warnings":[]}
```

The link authenticates itself, because the uploader has no credential: the
bearer token lives in the client's connector configuration and the model never
sees it. So it carries what it authorises — one recipe path, one expiry — plus
an HMAC over both, and `pictures.py` verifies by recomputing the signature
rather than keeping a list of outstanding links — a 256-bit key made at
startup, so there is no secret to deploy and a restart invalidates what was
outstanding. A link covers one recipe for five minutes, which the reply
states as `expires_in_seconds` so a caller need not know the number.
`COOKLANG_MCP_PUBLIC_URL` is what the link is built from; the route is
`PUT /picture/{token}`, served by the same ASGI app as `/mcp` and deliberately
outside MCP's authorization, so a reverse proxy has to let it past whatever
guards the protocol endpoint.

The picture itself is `cook server`'s business: it writes `Risotto.jpg` beside
`Risotto.cook`, re-encodes as JPEG, scales to 2048 pixels on the long edge and
strips the Exif a phone records the kitchen's position in. JPEG, PNG and WebP;
an iPhone's HEIC is refused with a message saying how to convert it, and its
refusals pass through word for word. An `image` frontmatter key wins over the
stored file, so an upload can succeed and show on nothing — the result says
which of the two the page is showing.

## Running

`cook server` must be running against the collection:

```console
$ cook server --port 9080 ~/recipes
$ COOKLANG_SERVER_URL=http://127.0.0.1:9080 cooklang-mcp
```

That serves stdio, which is what a local agent expects. For a remote client,
serve streamable HTTP behind a TLS-terminating reverse proxy:

```console
$ COOKLANG_MCP_TRANSPORT=http \
  COOKLANG_MCP_TOKEN_FILE=/run/credentials/cooklang-mcp.service/token \
  cooklang-mcp
```

| Variable | Default | |
| --- | --- | --- |
| `COOKLANG_SERVER_URL` | `http://127.0.0.1:9080` | where `cook server` listens |
| `COOKLANG_WEB_URL` | `COOKLANG_SERVER_URL` | public browser URL for recipe links |
| `COOKLANG_MCP_PUBLIC_URL` | — | public URL this server is proxied under; needed for picture uploads |
| `COOKLANG_MCP_TRANSPORT` | `stdio` | or `http` for streamable HTTP |
| `COOKLANG_MCP_HOST` | `127.0.0.1` | |
| `COOKLANG_MCP_PORT` | `3001` | the endpoint is `/mcp` |
| `COOKLANG_MCP_TOKEN_FILE` | — | file holding the shared bearer token |
| `COOKLANG_MCP_TOKEN` | — | the token itself, if there is no file |

Without a token the HTTP transport starts unauthenticated and says so. With one,
the SDK's bearer-auth middleware runs against a `TokenVerifier` accepting that
single token. It is a shared secret, not OAuth — the MCP authorization spec has
no notion of one, and conformance is a SHOULD. The SDK's DNS-rebinding guard is
off: it is aimed at a browser reaching a loopback server, and the only thing
that reaches this one is the proxy in front of it.

Requires CookCLI 0.38.1 or newer, built with both the `server` and `lsp` cargo
features. Its parser then runs with no extensions enabled, so `|`, `&` and `-`
in an ingredient are part of its name; without `lsp` there is no `cook lsp`
subcommand for the bridge to spawn and every write reports its diagnostics as
unavailable.
