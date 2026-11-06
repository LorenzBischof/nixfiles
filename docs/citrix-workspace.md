# Citrix Workspace: getting the tarball to CI

## Context

`framework` installs a `wfica` wrapper around nixpkgs' `citrix-workspace`
(`hosts/framework/home/default.nix`). nixpkgs takes the client's tarball through
`requireFile`, so no Nix fetcher reaches it and the build stops at requireFile's
message until the file is in the store. That used to mean building on the laptop
and `nix copy`ing the result to the binary cache by hand.

The `Citrix Workspace tarball` step in `.github/workflows/build.yaml` now does
the whole thing, download included, so no human is in the loop and the laptop
only ever substitutes the built package.

## How the download works

Citrix's Linux download pages are plain server-rendered HTML and need no login,
no cookie and no JavaScript — an anonymous `curl` gets them at 200. Each download
entry carries its own Akamai-signed URL in a `rel` attribute, along with the
file's published SHA-256:

```html
<a class="ctx-dl-link …" data-authoreula="true"
   rel="//downloads.citrix.com/27152/linuxx64-26.08.0.225.tar.gz?__gda__=exp=1793968417~acl=/*~hmac=d6b3bf25…">
<span class="ctx-checksum-title">Checksums</span>
  <ul class="ctx-checksum-list"><li>SHA-256 - 4231d4c25506…</li></ul>
```

The token's `acl=/*` makes it valid for any path on `downloads.citrix.com`, and
`exp` is about an hour out. Fetching the page and following that URL is all there
is to it.

Note what this means: the EULA on those pages is a click-through, not an
authorization check on the wire, and CI downloading the file accepts it on our
behalf — the one thing the manual download did that this does not ask a human to
do.

## What the step does

1. Evaluates `citrix-workspace` for three things: the package path, the
   fixed-output path its `src` has to land on, and the file name `requireFile`
   asks for.
2. Stops right there if either path is already in the cache bucket. On the usual
   run this is where it ends, with nothing downloaded.
3. Otherwise looks for the file in the bucket under `citrix/`, and failing that
   walks Citrix's pages — the current release first, then every per-version page
   the [legacy index][legacy] links (19 pages, ~115 kB each) — until one
   publishes the exact file name, then downloads it.
4. `nix-store --add-fixed sha256`es it, which lands on precisely the path
   `requireFile` computes. A path mismatch fails the step: what arrived is not
   the version nixpkgs pins.
5. Uploads anything it got from Citrix to the bucket under `citrix/`.

[legacy]: https://www.citrix.com/downloads/workspace-app/legacy-workspace-app-for-linux/

Step 5 is what makes this hold up over time. **Citrix withdraws a version from
its site as soon as the next one ships**, typically months before nixpkgs moves
off it, so by the time a pin needs fetching the file is often already gone from
citrix.com. The bucket is then the only place it still exists. Keeping a copy on
the one run that could still download it is what stops a later rebuild — a
dependency bump that invalidates the package, say — from being unfixable.

## When it fails, and what to do

```
::error::Citrix publishes linuxx64-<version>.tar.gz on none of its Linux
download pages, and the bucket has no copy under citrix/.
```

This means the pinned version was withdrawn before any run archived it. No
amount of downloading fixes it; the pin has to move to a version Citrix still
offers. nixpkgs is usually already on its way there — check for an open
`citrix-workspace: <old> -> <new>` pull request — and until it merges,
`hosts/framework/nixos/default.nix` carries an overlay that overrides `version`
and `src`. The hash goes in as the nix32 form of the SHA-256 the download page
publishes, so it needs no download to write down:

```sh
nix hash convert --hash-algo sha256 --to nix32 <hex-from-the-page>
```

The other failure is a hash mismatch, which means Citrix replaced the tarball in
place under the same name. Same remedy: the pin moves.

## Why not something else

- **Uploading the tarball by hand**, once per Citrix release, is what this
  replaces. The bucket upload remains as the archive the step reads and writes,
  so a file put there by hand is still picked up.
- **A headless browser.** Not needed: the signed URL is in the HTML of a page a
  bare `curl` can fetch, and nothing on the download path runs JavaScript or
  checks a session.
- **Fetching it in the Nix expression.** The URL is signed and expires within the
  hour, so it cannot be written into a `fetchurl`. Pointing one at the private
  bucket instead would drop the workflow step, but puts bucket credentials into
  evaluation on every host rather than only in CI.
- **A GitHub release asset in a private repo** would need a token with access to
  that repo in the build job; the bucket credentials are already there.
