# Build command of packages/citrix-tarball.nix, which sets $name and $out.
# shellcheck shell=bash
# shellcheck disable=SC2154
set -euo pipefail

# The download links carry a signed token that expires within the hour, so they
# have to be read off the pages at fetch time. Try the current release first,
# then every version page the legacy index links.
curlFlags=(--fail --silent --show-error --location --retry 3)
pages="https://www.citrix.com/downloads/workspace-app/linux/workspace-app-for-linux-latest.html"
pages+=$'\n'$(
  curl "${curlFlags[@]}" https://www.citrix.com/downloads/workspace-app/legacy-workspace-app-for-linux/ \
    | grep -oE '/downloads/workspace-app/legacy-workspace-app-for-linux/[a-z0-9.-]+\.html' \
    | sort -u \
    | sed 's|^|https://www.citrix.com|' || true
)

url=
while read -r page; do
  url=$(curl "${curlFlags[@]}" "$page" \
    | grep -oE "//downloads\.citrix\.com/[0-9]+/${name//./\\.}\?__gda__=[^\"]+" \
    | head -n1) || true
  [ -n "$url" ] && break
done <<<"$pages"

if [ -z "$url" ]; then
  echo "error: no Citrix download page publishes $name." >&2
  echo "nixpkgs is likely on a withdrawn tech preview; pin a published release in the citrix-workspace overlay." >&2
  exit 1
fi

echo "downloading $name from $page"
curl "${curlFlags[@]}" --output "$out" "https:$url"
