[private]
default: switch

[private]
add:
    @git add -N .

[private]
check-git-revision host="":
    #!/usr/bin/env bash
    if [ -n "{{host}}" ]; then
        deployed_revision=$(ssh {{host}} nixos-version --configuration-revision 2>/dev/null || echo "")
        source="{{host}}"
    else
        deployed_revision=$(nixos-version --configuration-revision 2>/dev/null || echo "")
        source="this host"
    fi
    # Guards against clobbering a background auto-upgrade with an older local build.
    # Auto-upgrade only ever deploys clean, pushed commits, so an empty or dirty
    # revision is a manual deploy with nothing to protect — only guard clean revs.
    case "$deployed_revision" in ""|*-dirty) exit 0 ;; esac
    if ! git cat-file -e "$deployed_revision" 2>/dev/null; then
        echo "Error: Git revision $deployed_revision from $source is not available locally"
        exit 1
    fi

# Activate configuration ("", nas, vps)
switch host="": add
    #!/usr/bin/env bash
    set -euo pipefail
    just check-git-revision "{{host}}"

    overrides=$(./override-input.sh)
    if [ "{{host}}" = "" ]; then
        sudo nixos-rebuild switch --flake . $overrides
    elif [ "{{host}}" = "nas" ]; then
        nixos-rebuild switch --flake .#nas --target-host nas --sudo $overrides
    elif [ "{{host}}" = "vps" ]; then
        nixos-rebuild switch --use-substitutes --flake .#vps --target-host vps --build-host vps --ask-sudo-password
    else
        echo "Unknown host: {{host}}"
        exit 1
    fi

# Test configuration ("", nas, vps)
test host="": add
    #!/usr/bin/env bash
    set -euo pipefail
    overrides=$(./override-input.sh)
    if [ "{{host}}" = "" ]; then
        sudo nixos-rebuild test --flake . $overrides
    elif [ "{{host}}" = "nas" ]; then
        nixos-rebuild test --flake .#nas --target-host nas --sudo $overrides
    elif [ "{{host}}" = "vps" ]; then
        nixos-rebuild test --flake .#vps --target-host vps --build-host vps --sudo $overrides
    else
        echo "Unknown host: {{host}}"
        exit 1
    fi

# Diagnose why a host's nixos-upgrade is stuck ("", nas, vps)
upgrade-doctor host="":
    @./scripts/nixos-upgrade-doctor.sh "{{host}}"

# Run flake checks
check: add
    #!/usr/bin/env bash
    set -euo pipefail
    overrides=$(./override-input.sh)
    nix flake check $overrides

code:
    sudo -v
    opencode
