#!/usr/bin/env bash
# Check whether this vendored skill copy matches the nixos-agent-test-vm
# revision pinned in the consumer's flake.lock.
#
#   check.sh             read-only: prints "ok" (exit 0) or "stale" (exit 1)
#   check.sh --refresh   overwrite the vendored copy to match the pin
#
# Default is read-only so an agent can probe freely; --refresh changes the
# working tree, so only run it when the user asks or grants permission.
set -euo pipefail

case "${1:-}" in
  "")        refresh=false ;;
  --refresh) refresh=true ;;
  *)         echo "usage: $0 [--refresh]" >&2; exit 2 ;;
esac

here="$(cd "$(dirname "$0")" && pwd)"

flake_dir="$here"
while [ "$flake_dir" != / ] && [ ! -f "$flake_dir/flake.lock" ]; do
  flake_dir="$(dirname "$flake_dir")"
done
if [ ! -f "$flake_dir/flake.lock" ]; then
  echo "error: no flake.lock found from $here upward" >&2
  exit 2
fi

pinned=$(nix eval --raw --impure --expr "
  let locked = (builtins.fromJSON (builtins.readFile \"$flake_dir/flake.lock\")).nodes.nixos-agent-test-vm.locked;
  in (builtins.fetchTree locked).outPath
")
src="$pinned/skills/nixos-agent-test-vm"

if ! $refresh; then
  if diff -rq "$src" "$here" >/dev/null 2>&1; then
    echo "ok: $here matches pinned nixos-agent-test-vm"
    exit 0
  fi
  echo "stale: $here is out of sync with the pinned nixos-agent-test-vm" >&2
  echo "to update, run: $0 --refresh" >&2
  exit 1
fi

# rm first so the result exactly mirrors the pin: cp alone would merge and
# leave behind files deleted upstream. Unlinking the running script is safe —
# our open fd keeps the old inode readable until bash finishes.
rm -rf "$here"
cp -rL --no-preserve=mode,ownership "$src" "$(dirname "$here")/"
chmod +x "$here/check.sh"

echo "refreshed $here from $pinned"
