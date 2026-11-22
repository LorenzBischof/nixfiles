# Dummy values with the shape of the private nix-secrets default.nix, for CI
# runs that can't fetch it (fork PRs). Only the names the configs read; add one
# here whenever a config starts reading a new `secrets.*` value.
{
  acme-email = "ci@example.invalid";
  s3-cache-store-url = "https://cache.example.invalid?priority=50";

  prod-domain = "prod.example.invalid";
  test-domain = "test.example.invalid";
  vps-domain = "vps.example.invalid";

  ntfy-alertmanager = "ci-stub-topic";
  healthchecks-watchdog = "00000000-0000-0000-0000-000000000000";

  cooklang-git-remote = "git@example.invalid:ci/cooklang.git";
  restic-repository = "s3:https://s3.example.invalid/ci-restic";
  paperless-ignore-dates = "";

  authelia-clients-audiobookshelf = "$plaintext$ci-stub";
  authelia-clients-dawarich = "$plaintext$ci-stub";
  authelia-clients-hedgedoc = "$plaintext$ci-stub";
  authelia-clients-outline = "$plaintext$ci-stub";
  authelia-clients-umap = "$plaintext$ci-stub";

  syncthing-devices =
    let
      id = "AAAAAAA-AAAAAAA-AAAAAAA-AAAAAAA-AAAAAAA-AAAAAAA-AAAAAAA-AAAAAAA";
    in
    {
      framework = id;
      pixel-7 = id;
      macbook = id;
      scanner = id;
      pixel-9a-l = id;
      pixel-9a-t = id;
    };
}
