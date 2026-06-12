#!/usr/bin/env bash
set -euo pipefail

# Check if flake.lock exists
if [[ ! -f "flake.lock" ]]; then
    echo "Error: flake.lock not found!" >&2
    exit 1
fi

check_input() {
    local input_name="$1"
    local local_path="$2"
    
    # Skip if the local directory doesn't exist
    if [[ ! -d "$local_path" ]]; then
        echo "Warning: Local directory $local_path doesn't exist, skipping check." >&2
        return
    fi
    
    # Get locked revision from flake.lock
    locked_rev=$(jq -r ".nodes.\"$input_name\".locked.rev" "flake.lock")
    
    # Check if input exists in flake.lock
    if [[ -z "$locked_rev" || "$locked_rev" == "null" ]]; then
        echo "Warning: Input '$input_name' not found in flake.lock" >&2
        return
    fi
    
    # Get the latest revision from the local repo
    pushd "$local_path" >/dev/null
    local_rev=$(git rev-parse HEAD)
    
    # Check if the working directory is dirty
    if [[ -n "$(git status --porcelain)" ]]; then
        git_dirty=true
    else
        git_dirty=false
    fi
    popd >/dev/null
    
    # Compare revisions
    if [[ "$locked_rev" != "$local_rev" || "$git_dirty" == true ]]; then
        echo "Input '$input_name' needs override!" >&2
        echo " --override-input $input_name $local_path"
    fi
}

check_input "nix-secrets" "../nix-secrets"
check_input "numen" "../numen-nix"
check_input "neovim-config" "../neovim-config"
