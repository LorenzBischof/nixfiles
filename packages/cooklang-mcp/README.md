# cooklang-mcp

An MCP server over a [Cooklang](https://cooklang.org) recipe collection.

It holds no state. Everything — the recipe files, the aisle and pantry
configuration, the shopping list — lives in the collection that
[CookCLI](https://github.com/cooklang/cookcli)'s `cook server` was pointed at,
and this server is an HTTP client for it. A recipe written here appears in the
web UI; an item ticked off there comes back ticked off here.

## Tools

Ten tools in three groups, named for the thing they act on. A group pairs one
read with one write rather than giving every endpoint underneath a tool of its
own: a client faced with twelve flat names mixed `read_recipe` up with
`fetch_recipe`, and never had a reason to prefer one shopping-list verb over
another.

| Tool | | CookCLI endpoint |
| --- | --- | --- |
| `recipe_search` | read | `GET /api/search` + `GET /api/recipes` |
| `recipe_read` | read | `GET /api/recipes/raw/*path` |
| `recipe_write` | write | `PUT /api/recipes/*path`, then `GET /api/recipes/*path` + `GET /api/aisles` |
| `recipe_delete` | destructive | `DELETE /api/recipes/*path` |
| `recipe_import` | read, web | — reads a web page with [recipe-scrapers](https://github.com/hhursev/recipe-scrapers) |
| `mark_cooked` | write | `GET`/`PUT /api/recipes/*path` on the two `.menu` files |
| `shopping_list_read` | read | `GET /api/shopping_list/items` + `POST /api/shopping_list` |
| `shopping_list_edit` | write | `POST /api/shopping_list/{add,add_menu,remove,check,uncheck,clear}` |
| `aisles_read` | read | `GET /api/aisles`, optionally `GET /api/aisles/uncategorized` |
| `aisles_edit` | write | `POST /api/aisles` or `POST /api/aisles/changes` |

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
  result of the call just made, not three calls back.
- **`recipe_write`** reads the file back after writing it and returns the
  ingredients the parser found. Cooklang turns text it cannot interpret into a
  plain step rather than an error, so a mistyped ingredient is silently
  dropped; this is what makes it visible.
- **`shopping_list_read`** asks for the stored list and then for the
  ingredients it adds up to, because the store holds recipes and only the
  aggregator turns them into ingredients. This is exactly what the web UI does,
  so the two always agree.
- **`shopping_list_edit`** takes an ordered batch of `add`, `remove`, `check`,
  `uncheck` and `clear` changes and returns the whole list afterwards, so a
  client never has to read it back. It is not a transaction: a failure part-way
  leaves the earlier changes applied, same as the web UI. Each action accepts
  only its own fields, so a `clear` carrying a path is refused rather than read
  as emptying the list — that mistake costs a whole shopping trip.

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

`aisles_read` returns `{aisle: [ingredient names]}` and the `revision` to edit
against. A whole catalogue is small — the CookCLI seed's 160 ingredients are
about 3 kB of JSON — so the `query` substring filter is an economy rather than a
necessity: it keeps an aisle whose own name matches entire, and otherwise only
the names that match. `uncategorized` adds the names the collection uses that no
aisle lists yet; `recipe_search` finds the recipes they come from.

`aisles_edit` applies a batch of changes in order, all or none, against that
revision — a concurrent edit fails the batch instead of overwriting it, so read
again and reconsider. It creates, renames, moves and removes aisles, and adds or
removes one ingredient at a time; moving an ingredient is a removal and an
addition in the same batch. Where a collection has no `aisle.conf` at all
(`configured: false`), `revision=null` with `changes=[]` creates the file and
hands back the revision that opens it for editing.

The API can also store several spellings for one ingredient and merge them on
the shopping list. These tools deliberately write only one: a second spelling is
another way to write the same ingredient, which is what the write warnings exist
to prevent. Spellings an existing file already holds are listed as ordinary
names, and removing any of them drops the whole line they share.

Requires CookCLI 0.38.1 or newer, whose parser runs with no extensions enabled:
`|`, `&` and `-` in an ingredient are part of its name rather than an alias or a
modifier, so a name is the only thing either side has to compare.

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
