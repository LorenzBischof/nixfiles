{
  inputs,
  vm,
}:

{
  config,
  lib,
  pkgs,
  ...
}:

let
  guestWorkspace = "/home/microvm/${vm.hostName}";
  nixfilesWorkspace = "/var/lib/microvm-workspaces/nixfiles";
  nixfilesMountPoint = "/home/microvm/nixfiles";
  nixSecretsWorkspace = "/var/lib/microvm-workspaces/nix-secrets";
  nixSecretsMountPoint = "/home/microvm/nix-secrets";
  roVarNixDb = "/nix/.ro-var-nix-db";
  rwVarNixDb = "/nix/.rw-var-nix-db";
  hasNixfilesAsWorkspace = vm.workspace == nixfilesWorkspace;
  perVmHomeModulePath = ../../../hosts/microvms + "/${vm.hostName}/default.nix";
  perVmHomeModules = lib.optional (builtins.pathExists perVmHomeModulePath) perVmHomeModulePath;
  normalizePath =
    path:
    let
      parts = lib.splitString "/" path;
      fold =
        acc: part:
        if part == "" || part == "." then
          acc
        else if part == ".." then
          if acc == [ ] then [ ] else lib.init acc
        else
          acc ++ [ part ];
      normalized = lib.foldl fold [ ] parts;
    in
    "/" + lib.concatStringsSep "/" normalized;
  relativeWorkspaceShares = lib.imap0 (
    idx: rel:
    let
      mountPath = normalizePath "${guestWorkspace}/${rel}";
    in
    {
      proto = "virtiofs";
      tag = "workspace-rel-${toString idx}";
      source = normalizePath "${vm.workspace}/${rel}";
      mountPoint = mountPath;
      readOnly = false;
    }
  ) vm.relativeMounts;
  sharedNixfilesShares = lib.optionals (!hasNixfilesAsWorkspace) [
    {
      proto = "virtiofs";
      tag = "nixfiles-ro";
      source = nixfilesWorkspace;
      mountPoint = nixfilesMountPoint;
      readOnly = true;
    }
    {
      proto = "virtiofs";
      tag = "nixfiles-vm-home";
      source = normalizePath "${nixfilesWorkspace}/hosts/microvms/${vm.hostName}";
      mountPoint = normalizePath "${nixfilesMountPoint}/hosts/microvms/${vm.hostName}";
    }
  ];
  sharedNixSecretsShares = [
    {
      proto = "virtiofs";
      tag = "nix-secrets";
      source = nixSecretsWorkspace;
      mountPoint = nixSecretsMountPoint;
      readOnly = !hasNixfilesAsWorkspace;
    }
  ];
in
{
  imports = [
    inputs.home-manager.nixosModules.home-manager
    (import ./microvm-nix-db-overlay.nix { inherit roVarNixDb rwVarNixDb; })
  ];

  home-manager.useGlobalPkgs = true;
  home-manager.useUserPackages = true;
  home-manager.extraSpecialArgs = {
    inherit inputs;
    vmName = vm.hostName;
  };
  home-manager.users.microvm = {
    imports = [ ./microvm-home.nix ] ++ perVmHomeModules;
  };

  environment.systemPackages = with pkgs; [
    home-manager
    jq
    ripgrep
  ];

  networking.hostName = vm.hostName;

  system.stateVersion = "25.11";

  services.openssh.enable = true;
  services.openssh.authorizedKeysFiles = [ "/etc/ssh/host-keys/ssh_user_%u_ed25519.pub" ];

  nix = {
    # Make legacy nix-shell resolve <nixpkgs> from the VM's system nixpkgs.
    nixPath = [ "nixpkgs=${pkgs.path}" ];
    settings.experimental-features = [
      "nix-command"
      "flakes"
    ];
  };

  users.groups.microvm = {
    gid = 1000;
  };
  users.users.microvm = {
    isNormalUser = true;
    group = "microvm";
    uid = 1000;
  };

  services.resolved.enable = true;
  networking.useDHCP = false;
  networking.useNetworkd = true;
  networking.tempAddresses = "disabled";
  systemd.network.enable = true;
  systemd.network.networks."10-e" = {
    matchConfig.Name = "e*";
    addresses = [ { Address = "${vm.ipAddress}/24"; } ];
    routes = [ { Gateway = "192.168.83.1"; } ];
  };
  networking.nameservers = [
    "8.8.8.8"
    "1.1.1.1"
  ];

  networking.firewall.enable = false;

  systemd.settings.Manager = {
    DefaultTimeoutStopSec = "5s";
  };

  systemd.mounts = [
    {
      what = "store";
      where = "/nix/store";
      overrideStrategy = "asDropin";
      unitConfig.DefaultDependencies = false;
    }
  ];

  fileSystems = {
    ${roVarNixDb} = {
      device = "ro-var-nix-db";
      fsType = "virtiofs";
      options = [ "x-systemd.requires=systemd-modules-load.service" ];
      neededForBoot = true;
      noCheck = true;
    };
    "/nix/var/nix/db" = {
      device = "overlay";
      fsType = "overlay";
      neededForBoot = true;
      options = [
        "lowerdir=${roVarNixDb}"
        "upperdir=${rwVarNixDb}/var/nix/db"
        "workdir=${rwVarNixDb}/work"
      ];
      depends = [
        "/nix/.ro-store"
        "/nix/.rw-store"
        roVarNixDb
        rwVarNixDb
      ];
    };
  };

  services.openssh.hostKeys = [
    {
      path = "/etc/ssh/host-keys/ssh_host_ed25519_key";
      type = "ed25519";
    }
  ];

  microvm = lib.mkMerge [
    {
      writableStoreOverlay = "/nix/.rw-store";

      volumes = [
        {
          image = "nix-store-overlay.img";
          mountPoint = config.microvm.writableStoreOverlay;
          size = vm.overlaySizeMiB;
          # XFS uses dynamic inode allocation; ext4 ran out of inodes in the RW overlay.
          fsType = "xfs";
        }
        {
          image = "nix-var-overlay.img";
          mountPoint = rwVarNixDb;
          size = 200;
        }
        {
          mountPoint = "/var";
          image = "var.img";
          size = 8192;
        }
      ];

      shares = [
        {
          proto = "virtiofs";
          tag = "ro-store";
          source = "/nix/store";
          mountPoint = "/nix/.ro-store";
          readOnly = true;
        }
        {
          proto = "virtiofs";
          tag = "ro-var-nix-db";
          source = "/nix/var/nix/db";
          mountPoint = roVarNixDb;
          readOnly = true;
        }
        {
          proto = "virtiofs";
          tag = "ssh-host-keys";
          source = vm.hostSshKeyDir;
          mountPoint = "/etc/ssh/host-keys";
          readOnly = true;
        }
        {
          proto = "virtiofs";
          tag = "workspace";
          source = vm.workspace;
          mountPoint = guestWorkspace;
        }
        {
          proto = "virtiofs";
          tag = "host-codex";
          source = "/home/lbischof/.codex";
          mountPoint = "/run/host-credentials/codex";
          readOnly = true;
        }
      ]
      ++ sharedNixfilesShares
      ++ sharedNixSecretsShares
      ++ relativeWorkspaceShares;

      interfaces = [
        {
          type = "tap";
          id = vm.tapId;
          mac = vm.mac;
        }
      ];

      hypervisor = lib.mkDefault "cloud-hypervisor";
      vcpu = lib.mkDefault 8;
      mem = lib.mkDefault 16384;
      socket = "control.socket";
    }
    (lib.optionalAttrs (vm ? vsockCid && vm.vsockCid != null) { vsock.cid = vm.vsockCid; })
  ];
}
