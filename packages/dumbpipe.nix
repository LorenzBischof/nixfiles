# TODO: nixpkgs still has dumbpipe 0.39.0 as of 2026-11; nixpkgs-update's
# attempts to bump it, 0.40.0 and 0.40.1 included, all hit its 6h timeout. 0.39
# breaks gha-vm's connections in two ways, both fixed in 0.40.0 (we take 0.40.2
# for its security updates):
# - its listener exits when it fails to accept one connection, so a stray packet
#   at the runner's UDP port ends every open one
#   (https://github.com/n0-computer/dumbpipe/pull/112);
# - it logs to stdout, which on the `connect` side is the ssh stream
#   (https://github.com/n0-computer/dumbpipe/pull/116).
# Used by the vps overlay (hosts/vps/agents.nix) and by .github/workflows/vm.yml.
# Drop it, and both uses, once nixpkgs ships 0.40.0 or later.
{
  dumbpipe,
  fetchFromGitHub,
  rustPlatform,
}:

dumbpipe.overrideAttrs (
  finalAttrs: _: {
    version = "0.40.2";
    src = fetchFromGitHub {
      owner = "n0-computer";
      repo = "dumbpipe";
      tag = "v${finalAttrs.version}";
      hash = "sha256-/TEc0l2PpGgF17FQwpcSKhyLm3lsLY/9X8Ar7Jy3S9s=";
    };
    cargoDeps = rustPlatform.fetchCargoVendor {
      inherit (finalAttrs) src;
      hash = "sha256-RXiYFMfH9SaTXf6MbwPJCl4JkGphfMUdUtOLyoZ1hNI=";
    };
  }
)
