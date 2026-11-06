# Build command of the fixed-output derivation in packages/citrix-tarball.nix,
# which is where $name, $latestPage, $legacyIndex and $out come from.
# shellcheck shell=bash
# shellcheck disable=SC2154
set -euo pipefail

# --disable: ignore any ~/.curlrc the sandbox exposes. --cacert: the sandbox has
# no system trust store, only the bundle the derivation passes in.
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

# The pinned version is usually the current release, so try that page first,
# then the per-version pages the legacy index links. Listing it is best-effort.
pages=$latestPage
if legacy=$(
  curl "${curlFlags[@]}" --max-time 60 "$legacyIndex" \
    | grep -oE '/downloads/workspace-app/legacy-workspace-app-for-linux/[a-z0-9.-]+\.html' \
    | sort -u \
    | sed 's|^|https://www.citrix.com|'
); then
  pages+=$'\n'$legacy
fi

# Nothing says which page publishes the pinned release, so try them in turn.
# The file name is a literal; `.` is a metacharacter to grep -E.
pattern=${name//./\\.}
url=
while read -r page; do
  html=$(curl "${curlFlags[@]}" --max-time 120 "$page") || continue
  # Other variants sit on the same page, so match the name whole, between the
  # component id and the signed token. One match is enough, and is not echoed.
  hits=$(grep -oE "//downloads\.citrix\.com/[0-9]+/$pattern\?__gda__=[^\"]+" <<<"$html") || continue
  url="https:${hits%%$'\n'*}"
  echo "$name is published on $page"
  break
done <<<"$pages"

if [ -z "$url" ]; then
  echo "error: Citrix publishes $name on none of its Linux download pages." >&2
  echo "Almost certainly a withdrawn tech preview; the pin has to move. See docs/citrix-workspace.md." >&2
  exit 1
fi

curl "${curlFlags[@]}" --max-time 1800 --output "$out" "$url"

# A rejected or expired token answers with an HTML error page rather than a 4xx,
# and a bare hash mismatch is a confusing way to hear about that.
if [ "$(od -An -N2 -tx1 "$out" | tr -d ' \n')" != "1f8b" ]; then
  echo "error: $page served $name as something other than a gzip file." >&2
  exit 1
fi
