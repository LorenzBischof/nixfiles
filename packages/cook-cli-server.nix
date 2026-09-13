# Temporary until https://github.com/NixOS/nixpkgs/pull/552347 reaches the
# pinned nixpkgs revision. Keep this as a minimal override so it can then be
# replaced directly with `pkgs.cook-cli`.
{ cook-cli }:
cook-cli.overrideAttrs (previous: {
  cargoBuildFeatures = [ "server" ];

  # The CLI test harness recompiles the large binary. Nothing here changes CLI
  # behaviour, and the MCP package carries its own tests.
  doCheck = false;

  # Without this, `PUT /api/recipes/Week 39.menu` writes `Week 39.menu.cook` and
  # still answers `"status": "success"` - so cooklang-mcp cannot create a meal
  # plan at all. The patch file explains it; it is written to be sent upstream
  # as-is, which has not been done yet.
  patches = (previous.patches or [ ]) ++ [ ./cook-cli-save-extension.patch ];
})
