# nixpkgs' pkgs/development/compilers/zig/fetcher.nix, with the fetch retried.
#
# TODO: Zig's HTTP client reuses pooled keep-alive connections even after the
# server has closed them, and fails with `HTTP request failed: WriteFailed`
# instead of reconnecting: https://codeberg.org/ziglang/zig/issues/37195 (open
# as of 2026-11), so many fetches from one host fail. A new `zig build --fetch`
# starts with an empty connection pool and skips what it already fetched, so a
# retry fetches only what failed. Any failure is retried, a permanent one
# (404, hash mismatch) too, which only costs time. Drop this once Zig
# reconnects, or once nixpkgs' fetcher retries (no nixpkgs PR yet).
{
  lib,
  zig,
  runCommand,
}:
{
  pname,
  version,
  name ? "${pname}-${version}",
  src,
  fetchAll ? false,
  hash ? lib.fakeHash,
}:
runCommand "${name}-zig-deps"
  {
    inherit src fetchAll;

    nativeBuildInputs = [ zig ];

    outputHashAlgo = if hash == "" then "sha256" else null;
    outputHashMode = "recursive";
    outputHash = hash;
  }
  (
    ''
      export ZIG_GLOBAL_CACHE_DIR=$(mktemp -d)
    ''
    # work around: https://codeberg.org/ziglang/zig/issues/31964 and https://codeberg.org/ziglang/zig/issues/35264
    # fixes builds for zig 0.16.0
    + lib.optionalString (
      lib.versions.majorMinor zig.version == "0.16"
    ) "mkdir -p $ZIG_GLOBAL_CACHE_DIR/tmp\n"
    + ''
      runHook unpackPhase

      cd $sourceRoot
      fetch() { zig build --fetch''${fetchAll:+=all}; }
      fetch || fetch || fetch

      mv $ZIG_GLOBAL_CACHE_DIR/p $out
    ''
  )
