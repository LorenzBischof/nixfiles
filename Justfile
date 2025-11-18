[private]
default: switch

[private]
add:
    @git add -N .

[private]
check-git-revision host:
    #!/usr/bin/env bash
    remote_revision=$(ssh {{host}} cat /etc/git-revision 2>/dev/null || echo "")
    if [ -n "$remote_revision" ] && ! git cat-file -e "$remote_revision" 2>/dev/null; then
        echo "Error: Git revision $remote_revision from {{host}} is not available locally"
        exit 1
    fi

# Activate configuration ("", nas, vps)
switch host="": add
    #!/usr/bin/env bash
    if [ -n "{{host}}" ]; then
        just check-git-revision {{host}}
    fi
    
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

code:
    sudo -v
    opencode
