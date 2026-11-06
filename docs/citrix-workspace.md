# Citrix Workspace: fetching the tarball

`framework` installs a `wfica` wrapper around nixpkgs' `citrix-workspace`
(`hosts/framework/home/default.nix`). nixpkgs takes the client's tarball through
`requireFile`, so no Nix fetcher reaches it and a build stops at requireFile's
message until the file is in the store — which used to mean building on the
laptop and `nix copy`ing the result to the binary cache by hand.

An overlay in `hosts/framework/nixos/default.nix` swaps that source for
`packages/citrix-tarball.nix`, a fixed-output derivation that fetches the
tarball off Citrix's download pages. A fixed-output derivation is the one kind
with network access in the build sandbox, so the fetch happens where every other
source is fetched: no workflow step, no credentials, same on the laptop as in
CI. It keeps upstream's file name and flat SHA-256, so it lands on exactly the
store path `requireFile` computes — a tarball already in the cache, or added by
hand with `nix-store --add-fixed sha256`, still substitutes for it.

The overlay normally only replaces the source, taking the file name and hash
from the `requireFile` source it replaces, so a nixpkgs bump needs no edit here.
The exception is the `pin` beside it, which overrides the version — and then
supplies the name and hash to match — while nixpkgs points at a release Citrix
has withdrawn. A `lib.versionOlder` guard retires the pin once nixpkgs catches
up.

## How the download works

Citrix's Linux download pages need no login, no cookie and no JavaScript — an
anonymous `curl` gets them at 200. Each entry carries its own Akamai-signed URL
in a `rel` attribute, next to the file's published SHA-256:

```html
<a class="ctx-dl-link …" data-authoreula="true"
   rel="//downloads.citrix.com/27152/linuxx64-26.08.0.225.tar.gz?__gda__=exp=1793968417~acl=/*~hmac=d6b3bf25…">
<span class="ctx-checksum-title">Checksums</span>
  <ul class="ctx-checksum-list"><li>SHA-256 - 4231d4c25506…</li></ul>
```

The token's `acl=/*` makes it good for any path on `downloads.citrix.com`, and
`exp` is about an hour out — which is why the page walk has to happen inside the
derivation rather than as a `fetchurl` URL written down in an expression.

`packages/citrix-tarball.sh` is the whole build command: fetch the current
release page, then the per-version pages the [legacy index][legacy] links, stop
at the first one publishing the pinned file name, download its signed URL into
`$out` and check the result really is a gzip file. On the usual build none of
that runs — the built package substitutes from the binary cache and the source
is never asked for.

Note what it does mean: the EULA on those pages is a click-through, not an
authorization check on the wire, and the build accepts it on our behalf. That
holds for a fork's pull request too, since it is the build that fetches now
rather than a step holding our credentials.

[legacy]: https://www.citrix.com/downloads/workspace-app/legacy-workspace-app-for-linux/

## When it fails

```
error: Citrix publishes linuxx64-<version>.tar.gz on none of its Linux
download pages.
```

Citrix leaves a GA release on the legacy index for years — as of 2026-11 it
still publishes sixteen versions, back to 23.2.0.10 (February 2023). What it
does withdraw is a **tech preview**, as soon as the GA replacement ships; that
is what happened to 26.08.0.153. So this error almost certainly means nixpkgs
pins a withdrawn tech preview, and no amount of downloading fixes it: the pin
has to move. Check for an open `citrix-workspace: <old> -> <new>` pull request
upstream, and in the meantime set `pin` in the overlay to that release: the
version off its download page, and the hash as the nix32 form of the SHA-256
the page publishes next to the file, so writing it down needs no download:

```sh
nix hash convert --hash-algo sha256 --to nix32 <hex-from-the-page>
```

A hash mismatch instead of that error means Citrix replaced the tarball in place
under the same name. Same remedy.
