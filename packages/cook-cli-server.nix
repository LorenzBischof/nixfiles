# Temporary until https://github.com/NixOS/nixpkgs/pull/552347 reaches the
# pinned nixpkgs revision. Keep this as a minimal override so it can then be
# replaced directly with `pkgs.cook-cli`.
{ cook-cli }:
cook-cli.overrideAttrs (_previous: {
  cargoBuildFeatures = [ "server" ];

  # The CLI test harness recompiles the large binary. Nothing here changes CLI
  # behaviour, and the MCP package carries its own tests.
  doCheck = false;
})
