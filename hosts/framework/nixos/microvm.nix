{
  lib,
  inputs,
  config,
  pkgs,
  ...
}:

let
  inherit (inputs) microvm;
  microvmBase = import ./microvm-base.nix;
  microvmDefinitions = import ./microvms/profiles.nix { };
  relativeMountCases = lib.concatMapStrings (
    name:
    let
      mounts = config.my.microvms.${name}.relativeMounts or [ ];
      mountsEntries = lib.concatMapStrings (path: "        ${lib.escapeShellArg path}\n") mounts;
    in
    ''
      ${lib.escapeShellArg name})
        relative_mounts=(
    ${mountsEntries}    )
        ;;
    ''
  ) (lib.attrNames config.my.microvms);
  hostNameCases = lib.concatMapStrings (
    name:
    let
      hostName = config.my.microvms.${name}.hostName or name;
    in
    ''
      ${lib.escapeShellArg name})
        vm_host_name=${lib.escapeShellArg hostName}
        ;;
    ''
  ) (lib.attrNames config.my.microvms);
  knownVmsArrayEntries = lib.concatMapStrings (name: "        ${lib.escapeShellArg name}\n") (
    lib.attrNames config.my.microvms
  );
  vmHostNamesArrayEntries = lib.concatMapStrings (
    hostName: "        ${lib.escapeShellArg hostName}\n"
  ) (
    lib.unique (
      map (name: config.my.microvms.${name}.hostName or name) (lib.attrNames config.my.microvms)
    )
  );
  microvmHereScript = pkgs.writeShellApplication {
    name = "microvm-here";
    runtimeInputs = with pkgs; [
      coreutils
      git
      gnused
      openssh
      systemd
    ];
    text = ''
      set -euo pipefail

      remote_cmd=""
      if [ "''${1-}" = "--" ]; then
        shift
        if [ "$#" -gt 0 ]; then
          remote_cmd="$*"
        fi
      fi

      repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
      vm_name="$(basename "$repo_root" | sed -E 's/[^A-Za-z0-9._-]+/-/g; s/^-+//; s/-+$//')"

      if [ -z "$vm_name" ]; then
        echo "Failed to derive VM name from path: $repo_root" >&2
        exit 1
      fi

      if [ ! -d "$repo_root/.git" ] && [ ! -f "$repo_root/.git" ]; then
        echo "Warning: '$repo_root' does not look like a git repository root." >&2
      fi

      known_vms=(
${knownVmsArrayEntries}      )
      known_vm_host_names=(
${vmHostNamesArrayEntries}      )

      is_known_vm() {
        local candidate="$1"
        local known_vm
        for known_vm in "''${known_vms[@]}"; do
          if [ "$known_vm" = "$candidate" ]; then
            return 0
          fi
        done
        return 1
      }

      if ! is_known_vm "$vm_name"; then
        echo "No microVM profile named '$vm_name'." >&2
        echo "Available profiles:" >&2
        if [ "''${#known_vms[@]}" -eq 0 ]; then
          echo "  (none configured)" >&2
        else
          name=""
          for name in "''${known_vms[@]}"; do
            echo "  $name" >&2
          done
        fi
        exit 1
      fi

      replace_with_symlink() {
        local source_path="$1"
        local target_path="$2"
        if [ -e "$target_path" ] && [ ! -L "$target_path" ]; then
          sudo rm -rf "$target_path"
        fi
        sudo ln -sfn "$source_path" "$target_path"
      }

      ensure_readonly_placeholder() {
        local path="$1"
        if [ ! -e "$path" ]; then
          sudo install -d -m 0555 -o root -g root "$path"
        fi
      }

      set_readonly_placeholder() {
        local path="$1"
        if [ -L "$path" ]; then
          sudo rm -f "$path"
        fi
        if [ ! -e "$path" ]; then
          sudo install -d -m 0555 -o root -g root "$path"
        fi
      }

      ensure_nixfiles_vm_home_dir() {
        local host_name="$1"
        if [ -L "$nixfiles_link" ]; then
          install -d "$nixfiles_link/hosts/microvms/$host_name"
        else
          sudo install -d -m 0555 -o root -g root "$nixfiles_link/hosts/microvms/$host_name"
        fi
      }

      vm_host_name="$vm_name"
      case "$vm_name" in
      ${hostNameCases}  esac

      ssh_wait_timeout=60

      workspace_base="/var/lib/microvm-workspaces"
      workspace_link="$workspace_base/$vm_name"
      sudo install -d -m 0755 "$workspace_base"

      nixfiles_link="$workspace_base/nixfiles"
      nix_secrets_link="$workspace_base/nix-secrets"
      ensure_readonly_placeholder "$nix_secrets_link"

      if [ "$vm_name" = "nixfiles" ]; then
        sibling_nix_secrets="$(realpath -m "$repo_root/../nix-secrets")"
        replace_with_symlink "$repo_root" "$nixfiles_link"

        if [ -d "$sibling_nix_secrets" ]; then
          replace_with_symlink "$sibling_nix_secrets" "$nix_secrets_link"
        else
          set_readonly_placeholder "$nix_secrets_link"
        fi
      else
        ensure_readonly_placeholder "$nixfiles_link"
      fi

      ensure_nixfiles_vm_home_dir "$vm_host_name"
      for host_name in "''${known_vm_host_names[@]}"; do
        ensure_nixfiles_vm_home_dir "$host_name"
      done

      replace_with_symlink "$repo_root" "$workspace_link"

      relative_mounts=()
      case "$vm_name" in
      ${relativeMountCases}  esac

      for rel in "''${relative_mounts[@]}"; do
        source_path="$(realpath -m "$repo_root/$rel")"
        mount_path="$(realpath -ms "$workspace_link/$rel")"

        sudo install -d -m 0755 "$(dirname "$mount_path")"
        if [ -e "$source_path" ]; then
          if [ -e "$mount_path" ] && [ ! -L "$mount_path" ]; then
            echo "Replacing managed mount path: $mount_path" >&2
            sudo rm -rf "$mount_path"
          fi
          sudo ln -sfn "$source_path" "$mount_path"
        else
          echo "Relative mount source missing: $source_path (from '$rel')" >&2
          if [ -L "$mount_path" ]; then
            sudo rm -f "$mount_path"
          fi
          if [ ! -e "$mount_path" ]; then
            sudo install -d -m 0755 "$mount_path"
          fi
        fi
      done

      echo "Starting microvm@$vm_name with workspace: $repo_root"
      sudo systemctl start "microvm@''${vm_name}.service"

      echo "Waiting for microvm@$vm_name to report active..."
      until systemctl is-active --quiet "microvm@''${vm_name}.service"; do
        sleep 1
      done

      ssh_target="microvm-$vm_name"
      workspace_path="/home/microvm/$vm_name"
      ssh_host="$(ssh -G "$ssh_target" 2>/dev/null | sed -n 's/^hostname //p' | head -n1)"
      ssh_port="$(ssh -G "$ssh_target" 2>/dev/null | sed -n 's/^port //p' | head -n1)"
      if [ -z "$ssh_host" ]; then
        ssh_host="$ssh_target"
      fi
      if [ -z "$ssh_port" ]; then
        ssh_port=22
      fi
      echo "Waiting for SSH on $ssh_target ($ssh_host:$ssh_port)..."
      ssh_deadline="$((SECONDS + ssh_wait_timeout))"
      until ${pkgs.netcat-openbsd}/bin/nc -z -w 2 "$ssh_host" "$ssh_port" >/dev/null 2>&1; do
        if [ "$SECONDS" -ge "$ssh_deadline" ]; then
          echo "Timed out waiting for SSH on $ssh_target (''${ssh_wait_timeout}s)." >&2
          exit 1
        fi
        sleep 1
      done

      echo "Connecting to $ssh_target (workspace: $workspace_path)"
      ssh "$ssh_target" 'if [ -e /run/host-credentials/codex/auth.json ]; then mkdir -p ~/.codex && ln -sfn /run/host-credentials/codex/auth.json ~/.codex/auth.json; fi'

      if [ -n "$remote_cmd" ]; then
        exec ssh -t "$ssh_target" "$remote_cmd"
      fi
      exec ssh -t "$ssh_target"
    '';
  };
  codexYoloScript = pkgs.writeShellApplication {
    name = "codex-yolo";
    runtimeInputs = with pkgs; [
      coreutils
      git
      gnused
      openssh
    ];
    text = ''
      set -euo pipefail

      repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
      vm_name="$(basename "$repo_root" | sed -E 's/[^A-Za-z0-9._-]+/-/g; s/^-+//; s/-+$//')"

      if [ -z "$vm_name" ]; then
        echo "Failed to derive VM name from path: $repo_root" >&2
        exit 1
      fi

      remote_cmd="cd ~/$vm_name && exec codex"
      if [ "$#" -gt 0 ]; then
        quoted_args=""
        for arg in "$@"; do
          quoted_args="$quoted_args $(printf '%q' "$arg")"
        done
        remote_cmd="$remote_cmd$quoted_args"
      fi

      exec microvm-here -- "$remote_cmd"
    '';
  };
  prepareHostSshScript = pkgs.writeShellScript "microvm-prepare-ssh" ''
    set -eu
    vm_name="$1"
    alias_name="microvm-$vm_name"
    base_dir="/var/lib/microvm-hostkeys"
    known_hosts="$base_dir/ssh_known_hosts"
    host_user="lbischof"
    host_group="$(${pkgs.coreutils}/bin/id -gn "$host_user")"

    install -d -m 0755 -o root -g root "$base_dir"

    key_dir="/var/lib/microvm-hostkeys/$vm_name"
    key_path="$key_dir/ssh_host_ed25519_key"
    key_pub="$key_path.pub"
    # Allow sshd (privsep path) to traverse the directory and read public
    # authorized-keys material, while private keys remain 0600 root-only.
    install -d -m 0711 -o root -g root "$key_dir"

    if [ ! -f "$key_path" ]; then
      ${pkgs.openssh}/bin/ssh-keygen -q -t ed25519 -N "" -f "$key_path"
    fi

    if [ ! -f "$key_pub" ]; then
      echo "missing host key: $key_pub" >&2
      exit 1
    fi

    chown root:root "$key_path" "$key_pub"
    chmod 0711 "$key_dir"
    chmod 0600 "$key_path"
    chmod 0644 "$key_pub"

    user_key_dir="/home/$host_user/.ssh/microvm/$vm_name"
    user_key_path="$user_key_dir/id_ed25519"
    user_key_pub="$user_key_path.pub"

    install -d -m 0700 -o "$host_user" -g "$host_group" "$user_key_dir"

    if [ ! -f "$user_key_path" ]; then
      ${pkgs.openssh}/bin/ssh-keygen -q -t ed25519 -N "" -f "$user_key_path"
    fi

    if [ ! -f "$user_key_pub" ]; then
      echo "missing user key: $user_key_pub" >&2
      exit 1
    fi

    chown "$host_user:$host_group" "$user_key_path" "$user_key_pub"
    chmod 0600 "$user_key_path"
    chmod 0644 "$user_key_pub"
    install -m 0644 -o root -g root "$user_key_pub" "$key_dir/ssh_user_microvm_ed25519.pub"
    touch "$known_hosts"
    chmod 0644 "$known_hosts"

    ${pkgs.openssh}/bin/ssh-keygen -f "$known_hosts" -R "$alias_name" >/dev/null 2>&1 || true
    echo "$alias_name $(cat "$key_pub")" >> "$known_hosts"
  '';
  microvmSshMatchBlocks = lib.mapAttrs' (
    name: vm:
    lib.nameValuePair "microvm-${name}" {
      hostname = vm.ipAddress;
      user = "microvm";
      identityFile = "/home/lbischof/.ssh/microvm/${name}/id_ed25519";
      extraOptions.HostKeyAlias = "microvm-${name}";
      extraOptions.GlobalKnownHostsFile = "/var/lib/microvm-hostkeys/ssh_known_hosts";
    }
  ) config.my.microvms;
in
{
  options.my.microvms = lib.mkOption {
    type = lib.types.attrsOf (
      lib.types.submodule (
        { name, ... }:
        {
          options = {
            hostName = lib.mkOption {
              type = lib.types.str;
              default = name;
            };
            ipAddress = lib.mkOption {
              type = lib.types.str;
            };
            tapId = lib.mkOption {
              type = lib.types.str;
            };
            mac = lib.mkOption {
              type = lib.types.str;
            };
            workspace = lib.mkOption {
              type = lib.types.str;
              default = "/var/lib/microvm-workspaces/${name}";
            };
            relativeMounts = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ ];
              description = ''
                Additional paths relative to the workspace that should be mounted read-write
                into the same relative location inside the VM.
              '';
            };
            overlaySizeMiB = lib.mkOption {
              type = lib.types.int;
              default = 20480;
              description = "Writable /nix/store overlay volume size cap (MiB).";
            };
            hostSshKeyDir = lib.mkOption {
              type = lib.types.str;
              default = "/var/lib/microvm-hostkeys/${name}";
            };
            vsockCid = lib.mkOption {
              type = lib.types.nullOr lib.types.int;
              default = null;
            };
            autostart = lib.mkOption {
              type = lib.types.bool;
              default = false;
            };
            extraModules = lib.mkOption {
              type = lib.types.listOf lib.types.anything;
              default = [ ];
            };
            extraZshInit = lib.mkOption {
              type = lib.types.lines;
              default = "";
            };
          };
        }
      )
    );
    default = { };
    description = "Host-side microVM inventory and settings.";
  };

  config = {
    my.microvms = lib.mkDefault microvmDefinitions;

    environment.systemPackages = [
      microvmHereScript
      codexYoloScript
    ];

    home-manager.users.lbischof.programs.ssh.matchBlocks = microvmSshMatchBlocks;
    systemd.services =
      lib.mapAttrs' (name: _: {
        name = "microvm-virtiofsd@${name}";
        value = {
          requires = [ "microvm-prepare-ssh@${name}.service" ];
          after = [ "microvm-prepare-ssh@${name}.service" ];
        };
      }) config.my.microvms
      // {
        "microvm-prepare-ssh@" = {
          description = "Prepare and trust SSH host key for MicroVM '%i' on host";
          serviceConfig = {
            Type = "oneshot";
            # Re-run on each activation path so regenerated user keys are copied
            # into the shared authorized keys file before SSH login.
            ExecStart = "${prepareHostSshScript} %i";
          };
        };
      };

    microvm.vms = lib.mapAttrs (_: vm: {
      inherit (vm) autostart;
      config = {
        imports = [
          microvm.nixosModules.microvm
          (microvmBase {
            inherit inputs vm;
          })
        ]
        ++ vm.extraModules;
      };
    }) config.my.microvms;
  };
}
