# Temporary until https://github.com/NixOS/nixpkgs/pull/552347 reaches the
# pinned nixpkgs revision. Keep this as a minimal override so it can then be
# replaced directly with `pkgs.cook-cli` — that PR turns on both features
# below, among others.
{ cook-cli }:
cook-cli.overrideAttrs (_previous: {
  # nixpkgs builds with no default features, so both are named here. `lsp` is
  # not optional: the MCP server asks `GET /api/ws/lsp` what the parser makes
  # of every recipe it writes, and that bridge spawns `cook lsp` out of this
  # same binary. Without the feature the socket opens, finds no such
  # subcommand and closes unanswered, and every write reports its diagnostics
  # as unavailable.
  cargoBuildFeatures = [
    "server"
    "lsp"
  ];

  # The CLI test harness recompiles the large binary. Nothing here changes CLI
  # behaviour, and the MCP package carries its own tests.
  doCheck = false;
})
