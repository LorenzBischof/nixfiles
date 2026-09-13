# cooklang-mcp

An MCP server over a [Cooklang](https://cooklang.org) recipe collection.

It holds no state. Everything — the recipe files, the aisle and pantry
configuration, the shopping list — lives in the collection that
[CookCLI](https://github.com/cooklang/cookcli)'s `cook server` was pointed at,
and this server is an HTTP client for it. A recipe written here appears in the
web UI; an item ticked off there comes back ticked off here.

## Tools

| Tool | CookCLI endpoint |
| --- | --- |
| `search_recipes` | `GET /api/search` + `GET /api/recipes` |
| `read_recipe` | `GET /api/recipes/raw/*path` |
| `write_recipe` | `PUT /api/recipes/*path`, then `GET /api/recipes/*path` |
| `delete_recipe` | `DELETE /api/recipes/*path` |
| `shopping_list` | `GET /api/shopping_list/items` + `POST /api/shopping_list` |
| `add_to_shopping_list` | `POST /api/shopping_list/add` or `/add_menu` |
| `remove_from_shopping_list` | `POST /api/shopping_list/remove` |
| `clear_shopping_list` | `POST /api/shopping_list/clear` |
| `check_shopping_item` | `POST /api/shopping_list/check` or `/uncheck` |
| `fetch_recipe` | — reads a web page with [recipe-scrapers](https://github.com/hhursev/recipe-scrapers) |

Most are a bare proxy and live in `server.py`. Some results are reshaped, for
reasons the endpoint shapes force:

- **`search_recipes`** combines the search results with the recipe tree so
  every result has a title, relative path, clickable Cook web URL, tags, and a
  recipe-or-meal-plan distinction. With no query it returns that complete
  collection directly.
- **Recipe links** are returned by recipe search/read/write and shopping-list
  recipe operations. The server instructions tell the client to make recipe
  names clickable in its answers, including after it creates a recipe.
- **`write_recipe`** reads the file back after writing it and returns the
  ingredients the parser found. Cooklang turns text it cannot interpret into a
  plain step rather than an error, so a mistyped ingredient is silently
  dropped; this is what makes it visible.
- **`shopping_list`** asks for the stored list and then for the ingredients it
  adds up to, because the store holds recipes and only the aggregator turns
  them into ingredients. This is exactly what the web UI does, so the two
  always agree.

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
