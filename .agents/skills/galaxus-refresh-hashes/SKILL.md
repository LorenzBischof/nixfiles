---
name: galaxus-refresh-hashes
description: Refresh Galaxus/Digitec MCP operation hashes when they rotate or the Galaxus hash alert fires.
---

# Refresh Galaxus MCP hashes

Run on framework, outside the sandbox:

```bash
python3 .agents/skills/galaxus-refresh-hashes/scripts/refresh.py
```

The script captures storefront requests and JavaScript artifacts in a headed
browser, expands lazy-loaded ratings, and updates
`packages/galaxus-mcp/operations.json` only when every hash and the client version
were captured. It requires `playwright-cli`; artifacts stay in the printed `/tmp`
directory. No separate build or API check is needed.

If capture succeeds, the refresh is done.

## Manual fallback

If hashes are missing, use the `playwright-cli` skill and saved `capture.json`
to investigate those operations in a headed browser on framework. Keep artifacts
in `/tmp` and run outside the sandbox.

Read `scripts/capture.js` for the page URLs and extraction pattern. For upstream's
`scripts/refresh-hashes.mjs`, locate its pinned source with:

```bash
nix eval --impure --raw --expr '(builtins.getFlake (toString ./.)).inputs.galaxus-mcp.outPath'
```

- Attach request listeners before navigating. GraphQL URLs contain
  `/graphql/o/<hash>/<operation>`; request headers supply
  `x-dg-graphql-client-version`.
- Search loaded JavaScript bundles for Relay artifacts as well: some operations
  never fire as requests. Get bundle URLs from
  `performance.getEntriesByType("resource")`, fetch them with
  `page.context().request.get(url)`, and use the extraction pattern in the script.
- Expand **Product ratings** on the product page to load
  `productRatingsModuleInnerQuery`; scrolling alone missed it on 2026-11-15.

Combine the saved capture with the manually recovered hashes, confirming every
operation was captured, including unchanged ones. Update
`packages/galaxus-mcp/operations.json`, `_capturedAt`, and `_clientVersion`.
Do not silently retain uncaptured hashes. Fix the script if the storefront change
would break future captures.

Apply with `just switch vps` when deployment is authorized.
