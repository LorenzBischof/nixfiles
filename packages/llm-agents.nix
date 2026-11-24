# llm-agents.nix's packages, with the Zig dependency fetch of herdr-core and
# herdr-app retried.
#
# TODO: Zig 0.16's HTTP client reuses pooled keep-alive connections even after
# the server has closed them, and fails with `HTTP request failed: WriteFailed`
# instead of reconnecting: https://codeberg.org/ziglang/zig/issues/37195 (open
# as of 2026-11). On GitHub Actions many of ghostty's ~30 archives from
# deps.files.ghostty.org fail that way. A new `zig build --fetch` process starts
# with an empty pool and skips archives already in the global cache, so a
# retry fetches only what failed. The fetch is a fixed-output derivation, so
# this changes no store path. nixpkgs' zig.fetchDeps has no retry, and no PR
# adds one. Drop this once Zig reconnects stale connections, or once
# zig.fetchDeps retries.
{ inputs, pkgs }:
let
  inherit (pkgs) lib;
  packages = inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system};

  fetchOnce = "zig build --fetch\${fetchAll:+=all}";
  retryFetch =
    pkg:
    pkg.overrideAttrs (old: {
      zigDeps = old.zigDeps.overrideAttrs (deps: {
        buildCommand =
          assert lib.assertMsg (lib.hasInfix fetchOnce deps.buildCommand)
            "${pkg.name}: zig.fetchDeps no longer runs `${fetchOnce}`; update packages/llm-agents.nix";
          builtins.replaceStrings
            [ fetchOnce ]
            [
              ''
                for attempt in 1 2 3; do
                  ${fetchOnce} && break
                  [ "$attempt" = 3 ] && exit 1
                  echo "zig fetch failed (attempt $attempt of 3), retrying" >&2
                  # A run that stops partway can leave a temporary file in
                  # p/, and a package unpacked into zig-pkg/ whose p/ archive
                  # it never wrote, which the next run then skips. Clear both.
                  rm -rf zig-pkg
                  mkdir -p "$ZIG_GLOBAL_CACHE_DIR/p"
                  find "$ZIG_GLOBAL_CACHE_DIR/p" -mindepth 1 -maxdepth 1 ! -name '*.tar.gz' -exec rm -rf {} +
                done
              ''
            ]
            deps.buildCommand;
      });
    });

  # herdr-app and ovis take herdr-core as an argument: hand them the retried
  # one, or their build graph carries a second, unretried fetch of the same
  # output, which Nix may pick to build.
  herdr-core = retryFetch packages.herdr-core;
in
packages
// {
  inherit herdr-core;
  herdr-app = retryFetch (packages.herdr-app.override { inherit herdr-core; });
  ovis = packages.ovis.override { inherit herdr-core; };
}
