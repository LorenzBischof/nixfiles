# A public stand-in for the private nix-secrets flake, so CI runs without access
# to it (fork PRs) still evaluate and build every host:
#
#   nix build --override-input nix-secrets path:./ci/secrets-stub ...
#
# Only derivations that use a secret value differ from main's (generated config
# files, the toplevel); everything else still comes from the binary caches.
{
  inputs = {
    # Overridden by flake.nix's `nix-secrets.inputs.nixpkgs.follows`.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    # The rev nix-secrets is locked to in flake.lock, so the agenix module (and
    # every derivation it touches) matches the real build. Bump with it.
    agenix.url = "github:ryantm/agenix/4835b1dc898959d8547a871ef484930675cb47f1";
    agenix.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    { nixpkgs, agenix, ... }:
    let
      # Each host's agenix secrets, by the names the configs read through
      # config.age.secrets.<name>. Never decrypted: CI only builds.
      ageSecrets = names: {
        imports = [ agenix.nixosModules.default ];
        age.secrets = nixpkgs.lib.genAttrs names (_: {
          file = ./dummy.age;
        });
      };
    in
    {
      nixosModules = {
        laptop = {
          imports = [ (ageSecrets [ "nix-daemon-env" ]) ];
          # The real module sets these; CI only builds.
          users.allowNoPasswordLogin = true;
          age.identityPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
        };
        nas = ageSecrets [
          "alias-watch-env"
          "authelia-jwt-secret"
          "authelia-oidc-hmac"
          "authelia-oidc-key"
          "authelia-session-secret"
          "authelia-storage-encryption-key"
          "authelia-users"
          "cloudflare-token"
          "dawarich-oidc-env"
          "hedgedoc-env"
          "nix-daemon-env"
          "offline-backup-password"
          "outline-oidc-secret"
          "paperless-password"
          "restic-env"
          "restic-password"
          "restic-repo"
          "tailscale-preauth"
          "umap-oidc-env"
        ];
        vps = ageSecrets [
          "agents-pr"
          "agents-push-org"
          "cloudflare-token"
          "cooklang-deploy-key"
          "mcp-nginx-auth"
          "nix-daemon-env"
          "ovis-token"
        ];
      };
      homeManagerModule = { };
    };
}
