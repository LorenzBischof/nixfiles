#!/usr/bin/env bash

# These must currently be manually updated!
hardwareconfig="hosts/laptop/nixos/hardware-configuration-framework.nix"
flakeref=".#framework"
target="nixos@192.168.0.116"

# The host key is currently copied from the current host. This should be improved for per-host keys.
TEMP_DIR=$(mktemp -d)
mkdir -p "$TEMP_DIR/etc/ssh"
if [ -f /etc/ssh/ssh_host_ed25519_key ]; then
    sudo cp /etc/ssh/ssh_host_ed25519_key* "$TEMP_DIR/etc/ssh/"
    sudo chown -R $(id -u) "$TEMP_DIR"
else
    echo "Warning: No SSH host keys found in /etc/ssh/"
    exit 1
fi

nix run github:nix-community/nixos-anywhere -- \
    --generate-hardware-config nixos-generate-config "$hardwareconfig" \
    --flake "$flakeref" \
    --target-host "$target" \
    --extra-files "$TEMP_DIR" \
    --no-use-machine-substituters # because the substitutor is only available with Tailscale
