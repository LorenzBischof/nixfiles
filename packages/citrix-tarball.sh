# The build command of a fixed-output derivation, so it has network access.
# Reads $name, $latestPage and $legacyIndex from the derivation; see
# packages/citrix-tarball.nix and docs/citrix-workspace.md.
# shellcheck shell=bash
set -euo pipefail

# --disable: ignore any ~/.curlrc the sandbox happens to expose. --cacert: the
# sandbox has no system trust store, only the bundle the derivation passes in.
curlFlags=(
  --disable
  --fail
  --silent
  --show-error
  --location
  --max-redirs 10
  --retry 3
  --cacert "$SSL_CERT_FILE"
)

# The current release page first: the version nixpkgs pins is usually the
# current release, and then nothing else is fetched. The legacy index is
# best-effort for the same reason — if it is unreachable the page above may
# still carry the file.
pages=$latestPage
if legacy=$(
  curl "${curlFlags[@]}" --max-time 60 "$legacyIndex" \
    | grep -oE '/downloads/workspace-app/legacy-workspace-app-for-linux/[a-z0-9.-]+\.html' \
    | sort -u \
    | sed 's|^|https://www.citrix.com|'
); then
  pages+=$'\n'$legacy
else
  echo "could not list $legacyIndex, trying the current release page alone" >&2
fi

# Nothing says which page carries the pinned release, so they are tried in turn
# until one publishes the file name. ~19 pages of ~115 kB, and only on a build
# that is not substituted.
# The file name is a literal here; `.` is a metacharacter to grep -E.
pattern=${name//./\\.}
url=
while read -r page; do
  html=$(curl "${curlFlags[@]}" --max-time 120 "$page") || continue
  # Every variant (arm64, the gcc-8 builds) sits on the same page, so the name
  # is matched whole, between the component id and the signed token.
  hits=$(grep -oE "//downloads\.citrix\.com/[0-9]+/$pattern\?__gda__=[^\"]+" <<<"$html") || continue
  # One match is enough. Not echoed: the URL carries a signed token.
  url="https:${hits%%$'\n'*}"
  echo "$name is published on $page"
  break
done <<<"$pages"

if [ -z "$url" ]; then
  echo "error: Citrix publishes $name on none of its Linux download pages." >&2
  echo "Citrix keeps its GA releases for years, so this is almost certainly a" >&2
  echo "tech preview it has withdrawn, and no amount of downloading fixes it:" >&2
  echo "the pin has to move to a version Citrix still offers." >&2
  echo "See docs/citrix-workspace.md." >&2
  exit 1
fi

curl "${curlFlags[@]}" --max-time 1800 --output "$out" "$url"

# A rejected or expired token answers with an HTML error page rather than a
# 4xx, and a bare hash mismatch is a confusing way to hear about that.
if [ "$(od -An -N2 -tx1 "$out" | tr -d ' \n')" != "1f8b" ]; then
  echo "error: $page served $name as something other than a gzip file;" >&2
  echo "Citrix most likely rejected the signed download token." >&2
  exit 1
fi
