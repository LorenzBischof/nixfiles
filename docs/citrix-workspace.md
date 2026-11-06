# Citrix Workspace: getting the tarball to CI

## Context

`framework` installs a `wfica` wrapper around nixpkgs' `citrix-workspace`
(`hosts/framework/home/default.nix`). Citrix only publishes the client behind a
login and an EULA, so the recipe takes its source through `requireFile`: nothing
— not nix, not CI — can download it. Without the file in the store the build
stops at requireFile's message, which is what used to force a local build on the
laptop followed by a hand-made `nix copy` of the result to the binary cache.

The tarball now lives in the cache bucket under the `citrix/` prefix, next to
(but not part of) the cache's own keys, and the `Citrix Workspace tarball` step
in `.github/workflows/build.yaml` puts it back into the store when a build needs
it. CI then builds `citrix-workspace` and pushes it to the cache like every
other path. The one thing left to a human is uploading the file — once per Citrix
release, with no nix involved.

## When it is needed

Only when nixpkgs moves `citrix-workspace` to a version whose tarball is not in
the bucket yet. Until then CI substitutes the built package and never looks at
the file. A bump that needs a new upload fails the `framework` leg with:

```
::error::linuxx64-<version>.tar.gz is not in the bucket under citrix/. ...
```

## Uploading a new version

The file name is the one nixpkgs pins, so ask the flake for it rather than
guessing:

```sh
nix eval --raw .#nixosConfigurations.framework.pkgs.citrix-workspace.src.name
# linuxx64-26.08.0.153.tar.gz
```

1. Download that version's 64-bit `.tar.gz` from
   <https://www.citrix.com/downloads/workspace-app/> (tech previews live under
   `betas-and-tech-previews/workspace-app-tp-for-linux.html`).
2. Check it is the file nixpkgs expects — the hash it prints has to match the
   `sha256` in nixpkgs' `citrix-workspace/package.nix`:

   ```sh
   nix-prefetch-url "file://$PWD/linuxx64-<version>.tar.gz"
   ```

3. Upload it under `citrix/`, keeping the name:

   ```sh
   aws s3 cp linuxx64-<version>.tar.gz \
     "s3://<bucket>/citrix/linuxx64-<version>.tar.gz" \
     --endpoint-url "https://<endpoint>"
   ```

   Bucket, endpoint and region are the ones in `secrets.s3-cache-store-url`
   (`nix-secrets`), the same values CI holds as the `S3_CACHE_*` GitHub secrets.

Re-run the failed workflow afterwards. The push step uploads the built package,
so later runs — and `nixos-rebuild` on the laptop — substitute it from the cache.

## Why not something else

- **Pushing the tarball's store path to the cache by hand** (the previous
  workflow, `nix-prefetch-url` then `nix copy`) also works, and CI would
  substitute it. It needs nix on the machine holding the download, which is the
  step this replaces.
- **Fetching it in the Nix expression** from the private bucket (overriding
  `src` with a credentialed `fetchurl`) would drop the workflow step, but puts
  bucket credentials into evaluation on every host instead of only in CI.
- **A GitHub release asset in a private repo** would need a token with access to
  that repo in the build job; the bucket credentials are already there.
