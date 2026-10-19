# Not in nixpkgs, and not packaged upstream at all: an unofficial MCP server for
# Galaxus/Digitec product search, pinned as the `galaxus-mcp` flake input.
#
# `src` is a required argument so the revision lives in flake.lock and nowhere
# else. Upstream ships a stdio server only; `http-entry.mjs` beside this file is
# ours, and is what vps actually runs.
#
# `operations.json` is ours too, and overrides the one in the source tree. Those
# are the persisted GraphQL query hashes the server replays, and Galaxus rotates
# them whenever it deploys a new frontend, which breaks all seven tools at once.
# Owning that one file here means a rotation is an edit in this repo, rather than
# waiting for the upstream fork to notice and then bumping the pin.
{
  lib,
  buildNpmPackage,
  makeWrapper,
  nodejs,
  src,
}:
buildNpmPackage {
  pname = "galaxus-mcp";
  # Upstream's package.json has said 0.1.0 since the first commit, so the pin is
  # the only real version. Taken from the input, so a bump needs no edit here.
  version = "0.1.0-unstable-${lib.substring 0 8 (src.lastModifiedDate or "00000000")}";
  inherit src;

  npmDepsHash = "sha256-zdEWSvp5Ef5oZlzrb3ttxmR2VFgZLrOJoDXdeyOPHYY=";

  nativeBuildInputs = [ makeWrapper ];

  # Before tsc runs: src/operations.json is imported by src/client.ts and so is
  # baked into dist/ at build time, which is what makes refreshing the hashes a
  # rebuild rather than a restart.
  postPatch = ''
    cp ${./operations.json} src/operations.json
  '';

  # `playwright` is a devDependency, used only by the hash refresher, which is
  # not something this package can run (see http-entry.mjs). Its postinstall
  # would download a browser; npmConfigHook passes --ignore-scripts, so it does
  # not, and the dependency is otherwise inert.

  # Two entry points of ours, installed inside the package directory so their
  # imports of @modelcontextprotocol/sdk and ./dist/*.js resolve by plain node
  # resolution, with no NODE_PATH. `galaxus-mcp` itself (upstream's stdio server)
  # is installed by the npm install hook from package.json's `bin`.
  postInstall = ''
    pkgdir=$out/lib/node_modules/galaxus-mcp
    cp ${./http-entry.mjs} $pkgdir/http-entry.mjs
    cp ${./check-hashes.mjs} $pkgdir/check-hashes.mjs

    makeWrapper ${lib.getExe nodejs} $out/bin/galaxus-mcp-http \
      --add-flags $pkgdir/http-entry.mjs
    makeWrapper ${lib.getExe nodejs} $out/bin/galaxus-mcp-check-hashes \
      --add-flags $pkgdir/check-hashes.mjs
  '';

  meta = {
    description = "MCP server for Galaxus/Digitec product search and discovery";
    homepage = "https://github.com/zurchpet/galaxus-mcp";
    license = lib.licenses.mit;
    mainProgram = "galaxus-mcp-http";
    platforms = lib.platforms.linux;
  };
}
