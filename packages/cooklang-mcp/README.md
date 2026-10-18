# cooklang-mcp

An MCP server over a [Cooklang](https://cooklang.org) recipe collection.

It holds no state. Everything — the recipe files, the aisle and pantry
configuration, the shopping list — lives in the collection that
[CookCLI](https://github.com/cooklang/cookcli)'s `cook server` was pointed at,
and this server is an HTTP client for it. A recipe written here appears in the
web UI; an item ticked off there comes back ticked off here.

## Tools

Eleven tools in three groups, named for the thing they act on. A group pairs one
read with one write rather than giving every endpoint underneath a tool of its
own: a client faced with twelve flat names mixed `read_recipe` up with
`fetch_recipe`, and never had a reason to prefer one shopping-list verb over
another.

| Tool | | CookCLI endpoint |
| --- | --- | --- |
| `recipe_search` | read | `GET /api/search` + `GET /api/recipes` |
| `recipe_read` | read | `GET /api/recipes/raw/*path` |
| `recipe_write` | write | `PUT /api/recipes/*path`, then `GET /api/ws/lsp` + `GET /api/recipes/*path` + `GET /api/aisles` |
| `recipe_delete` | destructive | `DELETE /api/recipes/*path` |
| `recipe_import` | read, web | — reads a web page with [recipe-scrapers](https://github.com/hhursev/recipe-scrapers) |
| `mark_cooked` | write | `GET`/`PUT /api/recipes/*path` on the two `.menu` files |
| `shopping_list_read` | read | `GET /api/shopping_list/items` + `POST /api/shopping_list` |
| `shopping_list_edit` | write | `POST /api/shopping_list/{add,add_menu,remove,check,uncheck,clear}`, and `GET`/`PUT /api/recipes/*path` for a loose item |
| `aisles_read` | read | `GET /api/aisles`, optionally `GET /api/aisles/uncategorized` |
| `aisles_edit` | write | `GET /api/aisles`, `POST /api/aisles/changes`; initializes a missing file |
| `ingredients_edit` | write | `GET /api/aisles`, `POST /api/aisles/changes` |

The second column is the tool's [annotations](https://modelcontextprotocol.io/):
a read carries `readOnlyHint`, so a client can let it through without asking,
and only `recipe_delete` carries `destructiveHint` — it is the one tool whose
effect no other tool can undo, which is the distinction worth gating on.
`recipe_import` is the only one with `openWorldHint`: everything else stays
inside the collection.

Most are a bare proxy and live in `server.py`. Some results are reshaped, for
reasons the endpoint shapes force:

- **`recipe_search`** combines the search results with the recipe tree so
  every result has a title, relative path, clickable Cook web URL, tags, and a
  recipe-or-meal-plan distinction. With no query it returns that complete
  collection directly.
- **Recipe links** come back from recipe search/read/write, `mark_cooked`, and
  the shopping list's recipe entries. Rendering one is the model's job: MCP has
  no clickable-link primitive, and the `resource_link` content block it does
  have promises a resource *this* server can read, which a page served by
  `cook server` is not. So `web_url` asks for the Markdown link in its own
  field description — carried in every output schema, marked `format: "uri"` —
  and the server instructions repeat the rule for a client that drops those.
  Neither says how a URL is built: a guessed link to a recipe that moved or
  never existed is worse than the plain name, so a name that arrived without a
  `web_url` stays unlinked. Which is why reading or writing a `.menu` resolves
  its recipe references into `entries`, each a `recipe_search` result with its
  own page. Instructions alone did not survive the case that prompted this: a
  recipe added to the meal plan was confirmed by name and unlinked, because the
  only URL in the write's result was the plan's. A name needs its URL in the
  result of the call just made, not three calls back. The instructions also
  spell out that the rule holds for every name in an answer, because a summary
  closing a run of writes to several recipes named them all and linked none:
  phrased around a single write, the rule read as being about the one-line
  confirmation that follows one.
- **`recipe_write`** reads the file back after writing it and returns the
  ingredients the parser found. Cooklang turns text it cannot interpret into a
  plain step rather than an error, so a mistyped ingredient is silently
  dropped; this is what makes it visible. It also returns `diagnostics`, the
  parser's own errors and warnings — see below.
- **`shopping_list_read`** asks for the stored list and then for the
  ingredients it adds up to, because the store holds recipes and only the
  aggregator turns them into ingredients. This is exactly what the web UI does,
  so the two always agree.
- **`shopping_list_edit`** takes an ordered batch of `add`, `remove`,
  `add_item`, `remove_item`, `check`, `uncheck` and `clear` changes and returns
  the whole list afterwards, so a client never has to read it back. It is not a
  transaction: a failure part-way leaves the earlier changes applied, same as
  the web UI. Each action accepts only its own fields, so a `clear` carrying a
  path is refused rather than read as emptying the list — that mistake costs a
  whole shopping trip.

## A single ingredient on the list

CookCLI's shopping list stores recipes, and nothing else: there is no endpoint
for "also buy kitchen roll". So `add_item` keeps those in a file of their own,
`Extra Items.menu` at the collection root, and holds that file on the list like
any other menu — a `.menu` rather than a `.cook` so the collection lists it
beside the plan instead of offering it as something to cook. It shows under the
list's selected recipes as **Extra Items**, and its ingredients group into
aisles, tick off and sum with the recipes' own.

`menus.py` writes it, one ingredient per block. A quantity is written as a cook
would say it and turned into Cooklang on the way in: `500 g` becomes
`@Butter{500%g}`, so it adds to the 200 g a recipe asks for, while `a pinch`
stays the words it is and Cooklang reads it as a text quantity. Adding a name
already in the file rewrites its block instead of appending a second one, since
two blocks would be summed into two bottles of milk.

The file and the list are kept in step by the tool: the menu goes on the list
as soon as the file holds something and comes off when it holds nothing, so
there is never an entry with no ingredients under it. The interesting case is
the other direction. A shopping trip ends with `clear` — often in the web UI,
which tells this server nothing — and the file is then last trip's. Rather than
watch for that, an addition starts from an empty file whenever the menu is not
currently on the list, which covers a clear from anywhere, and a file deleted
by hand with it. The items cannot carry over into the next trip, and nothing
has to remember to empty them.

`remove_item` matches by name and only within that file, so an ingredient a
recipe calls for is refused rather than silently not removed: it leaves when
its recipe does. `check` and `uncheck` need no such distinction — the list is
flat by the time it is ticked off.

Which is also why `shopping_list_read` returns `extra_items`, the names that
file holds. The aggregated list carries no attribution at all: 30 g of butter
from a recipe and 250 g added by hand come back as one `butter: 280 g` line,
and CookCLI's own response has nothing more to offer — the sum is the whole of
it. So the list alone cannot say which names `remove_item` is allowed to take
off, and reading the file is the only way to know. It is read only when the
menu is actually on the list, and a failure there costs the field rather than
the read.

## Recording a cooked meal

`mark_cooked` adds a recipe to `Meal History.menu` and takes it off
`Meal Plan.menu`. Both are ordinary Cooklang files that `recipe_write` can
reach, and leaving it at that went badly: the right date section, newest-first
order, the blank line between references, feedback below the recipe it
describes, and the history written before the plan is touched were five
paragraphs of instructions, each of which a client could drop. `menus.py` does
that as code, and the instructions keep only the judgement that is genuinely
the model's — which day the meal was eaten.

A menu file parses as optional frontmatter, then `= Heading` sections holding
blocks of lines separated by blank lines. The block is the unit that moves,
which is what lets a reference be removed without taking the `Feedback:` note
under it, and a loose `@paper towels{1}` stay where it is. Rendering is
normalised to one blank line between blocks, so a round trip tidies spacing
rather than preserving it byte for byte. A reference and a path compare equal
once `./` and the extension are off, because `Risotto.cook` and `./Risotto`
name one recipe.

The date is the client's to supply, as `YYYY-MM-DD`; when it was inferred
rather than told, `date_estimated` marks that entry `— date estimated` and
nothing else.

The result also carries `remaining_plan`: what is still queued afterwards, in
order, each recipe resolved to a page the same way a `.menu` read is. Saying
what is left over is the natural other half of the confirmation, and the plan's
own source would only give the model `@./Caprese`.

## Ingredient names and the aisles

`aisle.conf` groups the shopping list by store aisle, so it doubles as the
collection's vocabulary of ingredient names. `recipe_write` reads it back after
every write and returns a `warnings` list naming the ingredients it does not
hold — the one moment where `onion` quietly becoming `onions` is still cheap to
fix, before the shopping list shows both. A clean write returns `warnings: []`.

A warning is a hint, not a correction: nothing is renamed and nothing is written
to the catalogue, because ingredients that really are different have to stay
different. A name the catalogue knows passes whatever its case, a repeated name
warns once, and the names with nothing similar to them share one warning line.
Similar ones are found by two cheap rules — one name's words sitting inside the
other's (`butter` for `unsalted butter`), or a near spelling (`onion` for
`onions`) — because one extra qualifier or one wrong letter is what the mistake
actually looks like. A write whose catalogue read fails still reports
`written: true` and says so in `warnings`; only the write itself failing raises.

`aisles_read` returns `aisles` as `{aisle: [[preferred name, alias, ...], ...]}`.
Each inner list is one ingredient, with its preferred shopping-list name first.
The case-insensitive `query` substring
filter returns the whole group when any name matches, or the whole aisle when
its name matches. An empty query returns every aisle, including empty ones.
For example, searching `milk` returns:

```json
{"aisles": {"dairy": [["milk", "milch"], ["whole milk"]]}}
```

This keeps aliases together and similar but distinct ingredients separate.
`query` also accepts a list, for example `["milk", "Milch", "milks"]`.
It matches any term and returns each ingredient group once, in catalogue order.
Blank terms are ignored; an empty list or only blank terms returns everything.
The same filter applies to uncategorized names.
`uncategorized` adds the names the collection uses that no aisle lists yet;
`recipe_search` finds the recipes they come from.

Both edit tools accept only `changes`, a nonempty list applied in order, all or
none. They fetch the current catalogue and handle CookCLI's revision checks
internally. A concurrent edit fails the batch; read again before retrying.
An alias already owned by another ingredient also fails the whole batch. The
API error reaches the agent with the conflicting name, aisle, and (for batches)
change number. Use an explicit merge only when the ingredients are equivalent.

`ingredients_edit` handles everyday ingredient work:

- `create(name, aisle, aliases?)`: preferred name plus optional alternative
  spellings. The aisle must already exist.
- `update(ingredient, preferred_name?, aisle?, add_aliases?, remove_aliases?)`:
  change only supplied fields; identify the ingredient by any existing name.
  Moving preserves aliases. Renaming keeps the old name as an alias unless
  explicitly removed. Removing the preferred name requires choosing another.
- `merge(ingredients, preferred_name)`: combine at least two existing groups,
  supplying one name per ingredient. The preferred name must already belong to
  one of them; its group supplies the aisle and position. All aliases are kept.
- `delete(ingredient)`: remove the entire group. Use `update` to remove just an alias.

For example, add a translation, remove an unwanted plural, and move an ingredient:

```json
{"changes": [{"action": "update", "ingredient": "milk", "add_aliases": ["Milch"], "remove_aliases": ["milks"], "aisle": "dairy"}]}
```

`aisles_edit` organizes the aisles themselves: `create(name, position?)`,
`rename(name, new_name)`, `move(name, position)`, and
`delete(name, delete_ingredients?)`. Positions start at zero; creation defaults
to last. Deleting a nonempty aisle fails unless `delete_ingredients=true`.
Create missing aisles before editing their ingredients. Creating the first aisle
initializes a missing catalogue automatically. Neither tool changes recipes.

## What the parser says about a write

A write also returns `diagnostics`: the Cooklang parser's own errors and
warnings about the file just saved, each with a severity, a 1-based line and
the parser's message. An `error` means the file does not parse, so its page
shows the error in place of the recipe and nothing in it reaches the shopping
list; a `warning` means it parsed with something flagged, in practice a
metadata value the parser could not use and so ignored.

`cook server` keeps that report to itself — a warning goes to its own stderr
and an error comes back as a `500` carrying a message formatted for a terminal
— so the diagnostics are fetched from the language server it bridges onto
`GET /api/ws/lsp`, which publishes exactly the parser's errors and warnings as
LSP diagnostics. `diagnostics.py` is a one-document LSP client: open a
WebSocket, `initialize`, `didOpen` with the source, take the single
`publishDiagnostics` that follows, close. The bridge spawns one `cook lsp` per
socket, so the socket is opened per write and closed as soon as the answer is
in; it also adds the JSON-RPC framing, and rewrites `initialize` to pin the
workspace at the collection — reaching into `params`, which is why a message
without an object there is dropped unsent. All of that is a workaround for a
missing field: if `GET`/`PUT /api/recipes/*path` ever carries the parse report
itself, `diagnostics.py` and the `websockets` dependency go away and only the
mapping into `Diagnostic` stays. No upstream issue asks for it yet.

This does not replace reading `ingredients` back. The parser is lenient about
exactly the mistake that matters: an unclosed brace makes `@sugar{2%g and` a
plain step and is reported by nothing. And because the language server parses
with every extension enabled while `cook server` parses the collection with
none, a diagnostic can in principle name something the collection itself
accepts — upstream's to reconcile, and still better than dropping the report.
A write whose diagnostics cannot be fetched says so in `warnings` rather than
returning an empty `diagnostics`, which would read as a clean file.

Requires CookCLI 0.38.1 or newer, whose parser runs with no extensions enabled:
`|`, `&` and `-` in an ingredient are part of its name rather than an alias or a
modifier, so a name is the only thing either side has to compare. It has to be
built with both the `server` and `lsp` cargo features: without `lsp` there is
no `cook lsp` subcommand for the bridge to spawn, the socket closes without
answering, and every write reports its diagnostics as unavailable.

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
| `COOKLANG_MCP_TRANSPORT` | `stdio` | or `http` for streamable HTTP |
| `COOKLANG_MCP_HOST` | `127.0.0.1` | |
| `COOKLANG_MCP_PORT` | `3001` | the endpoint is `/mcp` |
| `COOKLANG_MCP_TOKEN_FILE` | — | file holding the shared bearer token |
| `COOKLANG_MCP_TOKEN` | — | the token itself, if there is no file |

Without a token the HTTP transport starts unauthenticated and says so. With
one, the SDK's own bearer-auth middleware runs against a `TokenVerifier` that
accepts that single token: every request must carry `Authorization: Bearer
<token>`, anything else gets a 401. It is a shared secret, not OAuth — the MCP
authorization spec has no notion of one, and conformance is a SHOULD.

The SDK's DNS-rebinding guard is off, because it is aimed at a browser reaching
a loopback server and the only thing that reaches this one is the proxy in
front of it.
