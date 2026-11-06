# Citrix Workspace: fetching the tarball

## Context

`framework` installs a `wfica` wrapper around nixpkgs' `citrix-workspace`
(`hosts/framework/home/default.nix`). nixpkgs takes the client's tarball through
`requireFile`, so no Nix fetcher reaches it and the build stops at requireFile's
message until the file is in the store. That used to mean building on the laptop
and `nix copy`ing the result to the binary cache by hand.

`packages/citrix-tarball.nix` replaces that source with a fixed-output
derivation that fetches the tarball itself, off Citrix's download pages. A
fixed-output derivation is the one kind with network access in the build
sandbox, so the fetch happens where every other source is fetched — no
workflow step, no credentials, and it works the same on the laptop as in CI.

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
authorization check on the wire, and fetching the file accepts it on our behalf
— the one thing the manual download did that this does not ask a human to do.
Since it is the build that fetches now, rather than a step with our credentials,
that also holds for a build of a fork's pull request.

## What the derivation does

`packages/citrix-tarball.sh` is its whole build command:

1. Fetches the current release page, then the per-version pages the
   [legacy index][legacy] links, and stops at the first one publishing the exact
   file name (~19 pages of ~115 kB — and only on a build that is not
   substituted). The legacy index is best-effort: if it cannot be listed, the
   current release page alone is tried, since that is where the pinned version
   usually is.
2. Downloads the signed URL from that page into `$out`, then checks it really is
   a gzip file — a rejected token answers with an HTML error page rather than a
   4xx, and a bare hash mismatch is a confusing way to hear about that.

Nix does the rest: the output hash is the SHA-256 the page publishes, so a
tarball Citrix replaced in place under the same name fails the build.

[legacy]: https://www.citrix.com/downloads/workspace-app/legacy-workspace-app-for-linux/

The derivation keeps no copy of its own anywhere, and needs none. **Citrix leaves
a GA release on the legacy index for years** — as of 2026-11 that index still
publishes sixteen versions, every one back to 23.2.0.10 (February 2023) — so the
file nixpkgs pins is normally still being served. And on the usual build nothing
is fetched at all: the built package substitutes from the binary cache, and the
source is never asked for.

It also lands on exactly the store path `requireFile` would compute, because it
uses the same name and the same flat SHA-256. So a tarball that is already in
the cache, or put there by hand with `nix-store --add-fixed sha256` and
`nix copy`, substitutes for this derivation untouched — the old manual route
still works, it is just no longer needed.

## When it fails, and what to do

```
error: Citrix publishes linuxx64-<version>.tar.gz on none of its Linux
download pages.
```

The one kind of build Citrix does withdraw is a **tech preview**, as soon as its
GA replacement ships; that is what happened to 26.08.0.153. Since the legacy
index keeps GA releases, this error almost certainly means a withdrawn tech
preview. No amount of downloading fixes it; the pin has to move to a version
Citrix still offers. nixpkgs is usually already on its way there — check for an
open `citrix-workspace: <old> -> <new>` pull request — and until it merges,
`hosts/framework/nixos/default.nix` carries an overlay that overrides `version`
and the hash. The hash goes in as the nix32 form of the SHA-256 the download
page publishes, so it needs no download to write down:

```sh
nix hash convert --hash-algo sha256 --to nix32 <hex-from-the-page>
```

A hash mismatch instead of that error means Citrix replaced the tarball in place
under the same name. Same remedy: the pin moves.

## Why not something else

- **Uploading the tarball by hand**, once per Citrix release, is what this
  replaces. It is still honoured if ever needed, as above.
- **A workflow step that downloads it** (what this replaces, and what the first
  version of this did) works, but only in CI: it needs the cache credentials to
  decide whether to download, and leaves `nix build` on the laptop stopping at
  requireFile's message. The derivation runs the same page walk without either —
  nix decides when to fetch, as it does for every other source.
- **A headless browser.** Not needed: the signed URL is in the HTML of a page a
  bare `curl` can fetch, and nothing on the download path runs JavaScript or
  checks a session.
- **A plain `fetchurl`.** The download URL is signed and expires within the hour,
  so it cannot be written down in an expression — which is why the page walk has
  to happen inside the derivation rather than before it.
- **Mirroring the tarball** into the private bucket or a private GitHub release
  would drop the page walk, but a mirror can only hold a version something
  already downloaded, and whatever downloaded it also pushed the built package to
  the cache — which is what a build looks for first. The mirror would never be
  what saved a build.
