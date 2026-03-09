{
  lib,
  inputs,
  config,
  pkgs,
  ...
}:

let
  inherit (inputs) microvm;
  microvmBase = import ./base.nix;
  microvmDefinitions = import ./profiles.nix { };
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
  microvmHereScript = pkgs.writeShellApplication {
    name = "microvm-here";
    runtimeInputs = with pkgs; [
      coreutils
      git
      gnused
      systemd
      util-linux
    ];
    text = ''
      set -euo pipefail

      profile_name="''${1-}"
      remote_cmd=""
      if [ -n "$profile_name" ] && [ "$profile_name" != "--" ]; then
        shift
      else
        profile_name=""
      fi
      if [ "''${1-}" = "--" ]; then
        shift
        if [ "$#" -gt 0 ]; then
          remote_cmd="$*"
        fi
      elif [ "$#" -gt 0 ]; then
        echo "Unexpected arguments. Use: microvm-here [profile] [-- <remote command>]" >&2
        exit 1
      fi

      repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
      cwd_name="$(basename "$repo_root" | sed -E 's/[^A-Za-z0-9._-]+/-/g; s/^-+//; s/-+$//')"
      vm_name="$cwd_name"
      if [ -n "$profile_name" ]; then
        vm_name="$profile_name"
      fi

      if [ -z "$vm_name" ]; then
        echo "Failed to derive VM name from path: $repo_root" >&2
        exit 1
      fi

      if [ ! -d "$repo_root/.git" ] && [ ! -f "$repo_root/.git" ]; then
        echo "Warning: '$repo_root' does not look like a git repository root." >&2
      fi

      known_vms=(
${knownVmsArrayEntries}      )

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

      ensure_mountpoint_dir() {
        local path="$1"
        if mountpoint -q "$path"; then
          return 0
        fi
        if [ -L "$path" ]; then
          sudo rm -f "$path"
        fi
        if [ -e "$path" ] && [ ! -d "$path" ]; then
          echo "Managed path exists but is not a directory: $path" >&2
          exit 1
        fi
        if [ ! -e "$path" ]; then
          sudo install -d -m 0755 -o root -g root "$path"
        fi
      }

      ensure_writable_mountpoint_dir() {
        local path="$1"
        if [ -L "$path" ]; then
          sudo rm -f "$path"
        fi
        if [ -e "$path" ] && [ ! -d "$path" ]; then
          echo "Managed path exists but is not a directory: $path" >&2
          exit 1
        fi
        sudo install -d -m 0755 -o root -g root "$path"
      }

      ensure_bind_mount() {
        local source_path="$1"
        local target_path="$2"
        local source_realpath
        local current_source
        local current_fsroot

        if [ -L "$target_path" ]; then
          sudo rm -f "$target_path"
        fi
        if [ -e "$target_path" ] && [ ! -d "$target_path" ]; then
          echo "Bind mount target exists but is not a directory: $target_path" >&2
          exit 1
        fi
        sudo install -d -m 0755 "$target_path"

        if mountpoint -q "$target_path"; then
          source_realpath="$(realpath -m "$source_path")"
          current_source="$(findmnt -n -o SOURCE -M "$target_path" | head -n1)"
          # FSROOT reports the bind root path directly even when SOURCE is
          # rendered as device[subpath] on filesystems like btrfs.
          current_fsroot="$(findmnt -n -o FSROOT -M "$target_path" | head -n1 || true)"
          if [ "$current_source" = "$source_path" ] || [ "$current_fsroot" = "$source_realpath" ]; then
            return 0
          fi
          echo "Rebinding workspace mount: $target_path (was: $current_source)" >&2
          sudo umount "$target_path"
        fi

        sudo mount --bind "$source_path" "$target_path"
      }

      vm_host_name="$vm_name"
      case "$vm_name" in
      ${hostNameCases}  esac

      ssh_wait_timeout=60

      workspace_base="/var/lib/microvm-workspaces"
      sudo install -d -m 0755 "$workspace_base"
      workspace_root="$workspace_base/$vm_name"
      if [ -L "$workspace_root" ]; then
        # Migrate from legacy per-VM symlink workspace layout.
        sudo rm -f "$workspace_root"
      fi
      if [ -e "$workspace_root" ] && [ ! -d "$workspace_root" ]; then
        echo "Workspace root exists but is not a directory: $workspace_root" >&2
        exit 1
      fi
      sudo install -d -m 0755 "$workspace_root"

      workspace_hash="$(printf '%s' "$repo_root" | sha256sum | cut -c1-12)"
      workspace_id="$cwd_name-$workspace_hash"
      workspace_mount="$workspace_root/$workspace_id"
      sudo install -d -m 0755 "$workspace_mount"
      ensure_bind_mount "$repo_root" "$workspace_mount"
      workspace_nix_secrets_mount="$workspace_root/nix-secrets"

      sibling_nix_secrets="$(realpath -m "$repo_root/../nix-secrets")"

      if [ "$vm_name" = "nixfiles" ]; then
        if [ -d "$sibling_nix_secrets" ]; then
          ensure_writable_mountpoint_dir "$workspace_nix_secrets_mount"
          ensure_bind_mount "$sibling_nix_secrets" "$workspace_nix_secrets_mount"
        else
          ensure_mountpoint_dir "$workspace_nix_secrets_mount"
        fi
      fi

      echo "Starting microvm@$vm_name with workspace: $repo_root"
      sudo systemctl start "microvm@''${vm_name}.service"

      echo "Waiting for microvm@$vm_name to report active..."
      until systemctl is-active --quiet "microvm@''${vm_name}.service"; do
        sleep 1
      done

      workspace_path="/home/microvm/.workspaces/$vm_host_name/$workspace_id"
      echo "Waiting for VSOCK SSH via microvm -s $vm_name..."
      ssh_deadline="$((SECONDS + ssh_wait_timeout))"
      until microvm -s "$vm_name" true >/dev/null 2>&1; do
        if [ "$SECONDS" -ge "$ssh_deadline" ]; then
          echo "Timed out waiting for VSOCK SSH on $vm_name (''${ssh_wait_timeout}s)." >&2
          exit 1
        fi
        sleep 1
      done

      echo "Connecting to $vm_name via microvm -s (workspace: ~/$cwd_name)"
      if [ -n "$remote_cmd" ]; then
        # shellcheck disable=SC2016
        session_cmd=$(cat <<EOF
set -euo pipefail
if [ -e /run/host-credentials/codex/auth.json ]; then
  mkdir -p /home/microvm/.codex
  ln -sfn /run/host-credentials/codex/auth.json /home/microvm/.codex/auth.json
fi
ln -sfn $(printf '%q' "$workspace_path") /home/microvm/$(printf '%q' "$cwd_name")
exec su - microvm -c $(printf '%q' "exec sh -lc $(printf '%q' "$remote_cmd")")
EOF
)
      else
        session_cmd=$(cat <<EOF
set -euo pipefail
if [ -e /run/host-credentials/codex/auth.json ]; then
  mkdir -p /home/microvm/.codex
  ln -sfn /run/host-credentials/codex/auth.json /home/microvm/.codex/auth.json
fi
ln -sfn $(printf '%q' "$workspace_path") /home/microvm/$(printf '%q' "$cwd_name")
exec su - microvm
EOF
)
      fi
      ssh_status=0
      microvm -s "$vm_name" -- -tt -o "RemoteCommand=$session_cmd" || ssh_status="$?"
      exit "$ssh_status"
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

      profile_name="''${1-}"
      if [ -n "$profile_name" ] && [ "$profile_name" != "--" ]; then
        shift
      else
        profile_name=""
      fi
      if [ "''${1-}" = "--" ]; then
        shift
      elif [ "$#" -gt 0 ]; then
        echo "Unexpected arguments. Use: codex-yolo [profile] [-- <codex args...>]" >&2
        exit 1
      fi

      repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
      cwd_name="$(basename "$repo_root" | sed -E 's/[^A-Za-z0-9._-]+/-/g; s/^-+//; s/-+$//')"
      vm_name="$cwd_name"
      if [ -n "$profile_name" ]; then
        vm_name="$profile_name"
      fi

      if [ -z "$vm_name" ]; then
        echo "Failed to derive VM name from path: $repo_root" >&2
        exit 1
      fi

      remote_cmd="cd $(printf '%q' "/home/microvm/$cwd_name") && exec codex"
      if [ "$#" -gt 0 ]; then
        quoted_args=""
        for arg in "$@"; do
          quoted_args="$quoted_args $(printf '%q' "$arg")"
        done
        remote_cmd="$remote_cmd$quoted_args"
      fi

      exec microvm-here "$vm_name" -- "$remote_cmd"
    '';
  };
  cleanupWorkspaceMountsScript = pkgs.writeShellApplication {
    name = "microvm-clean-workspace-mounts";
    runtimeInputs = with pkgs; [
      coreutils
      gawk
      util-linux
    ];
    text = ''
      set -euo pipefail

      vm_name="''${1:?usage: microvm-clean-workspace-mounts <vm-name>}"
      workspace_root="/var/lib/microvm-workspaces/$vm_name"

      if [ ! -d "$workspace_root" ]; then
        exit 0
      fi

      # Unmount deepest mount points first.
      while IFS= read -r target; do
        if ! umount "$target"; then
          echo "Warning: failed to unmount stale workspace mount: $target" >&2
        fi
      done < <(
        findmnt -rn -o TARGET \
          | awk -v prefix="$workspace_root/" 'index($0, prefix) == 1' \
          | sort -r
      )

      # Remove empty per-repo directories left behind by cleaned mounts.
      find "$workspace_root" -mindepth 1 -maxdepth 1 -type d -empty -delete || true
    '';
  };
  prepareHostSshScript = pkgs.writeShellScript "microvm-prepare-ssh" ''
    set -eu
    vm_name="$1"
    base_dir="/var/lib/microvm-hostkeys"
    host_user="lbischof"
    host_group="$(${pkgs.coreutils}/bin/id -gn "$host_user")"

    install -d -m 0755 -o root -g root "$base_dir"

    key_dir="/var/lib/microvm-hostkeys/$vm_name"
    install -d -m 0711 -o root -g root "$key_dir"

    user_key_pub="/home/$host_user/.ssh/id_ed25519.pub"
    if [ ! -f "$user_key_pub" ]; then
      echo "missing host user public key: $user_key_pub" >&2
      exit 1
    fi

    install -d -m 0700 -o "$host_user" -g "$host_group" "/home/$host_user/.ssh"
    install -m 0644 -o root -g root "$user_key_pub" "$key_dir/ssh_user_root_ed25519.pub"
  '';
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
            overlaySizeMiB = lib.mkOption {
              type = lib.types.int;
              default = 20480;
              description = "Writable /nix/store tmpfs overlay size cap (MiB).";
            };
            hostSshKeyDir = lib.mkOption {
              type = lib.types.str;
              default = "/var/lib/microvm-hostkeys/${name}";
            };
            vsockCid = lib.mkOption {
              type = lib.types.nullOr lib.types.int;
              default = null;
            };
            hypervisor = lib.mkOption {
              type = lib.types.str;
              default = "cloud-hypervisor";
              description = "MicroVM hypervisor backend (for example cloud-hypervisor, qemu, or crosvm).";
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

    systemd.services =
      lib.mapAttrs' (name: vm: {
        name = "microvm@${name}";
        value = {
          serviceConfig = {
            TimeoutStopSec = lib.mkDefault 30;
            ExecStartPost = lib.mkAfter (
              lib.optionals (vm.hypervisor == "cloud-hypervisor") [
                "${pkgs.coreutils}/bin/chmod 0770 /var/lib/microvms/${name}/notify.vsock"
              ]
            );
            ExecStopPost = lib.mkAfter [ "+${cleanupWorkspaceMountsScript}/bin/microvm-clean-workspace-mounts ${name}" ];
          };
        };
      }) config.my.microvms
      // lib.mapAttrs' (name: _: {
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

    microvm.vms = lib.mapAttrs (name: vm: {
      inherit (vm) autostart;
      config = {
        microvm.hypervisor = vm.hypervisor;
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
