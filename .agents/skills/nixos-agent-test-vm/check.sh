#!/usr/bin/env bash
# Verify this vendored copy matches the revision pinned in the consumer's
# flake.lock for the `nixos-agent-test-vm` input.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"

flake_dir="$here"
while [ "$flake_dir" != / ] && [ ! -f "$flake_dir/flake.lock" ]; do
  flake_dir="$(dirname "$flake_dir")"
done
if [ ! -f "$flake_dir/flake.lock" ]; then
  echo "error: no flake.lock found from $here upward" >&2
  exit 2
fi

result=$(nix eval --raw --impure --expr "
  let locked = (builtins.fromJSON (builtins.readFile \"$flake_dir/flake.lock\")).nodes.nixos-agent-test-vm.locked;
  in (builtins.fetchTree locked).outPath + \" \" + (locked.rev or \"\")
")
pinned=${result% *}
rev=${result##* }

if diff -rq "$pinned/skills/nixos-agent-test-vm" "$here" >/dev/null 2>&1; then
  echo "ok: $here matches pinned nixos-agent-test-vm"
  exit 0
fi

cmd="nix run github:lorenzbischof/nixos-agent-test-vm"
[ -n "$rev" ] && cmd="$cmd/$rev"

echo "stale: $here" >&2
echo "skill is out of sync — run: $cmd" >&2
exit 1
