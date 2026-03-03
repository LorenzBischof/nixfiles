{ roVarNixDb, rwVarNixDb }:

{
  # Overlay /nix/var/nix/db in microVMs to share the host DB while keeping guest writes.
  # Source: https://gist.github.com/Ramblurr/ea69233ad7c76dcd234ed7373bf6ff6e
  boot.initrd.systemd.enable = true;
  boot.initrd.systemd.mounts = [
    {
      where = "/sysroot/nix/var/nix/db";
      what = "overlay";
      type = "overlay";
      options = builtins.concatStringsSep "," [
        "lowerdir=/sysroot${roVarNixDb}"
        "upperdir=/sysroot${rwVarNixDb}/var/nix/db"
        "workdir=/sysroot${rwVarNixDb}/work"
      ];
      wantedBy = [ "initrd-fs.target" ];
      before = [ "initrd-fs.target" ];
      requires = [ "rw-var-nix-db.service" ];
      after = [ "rw-var-nix-db.service" ];
      unitConfig.RequiresMountsFor = "/sysroot${roVarNixDb}";
    }
  ];
  boot.initrd.systemd.services.rw-var-nix-db = {
    unitConfig = {
      DefaultDependencies = false;
      RequiresMountsFor = "/sysroot${rwVarNixDb}";
    };
    script = ''
      /bin/mkdir -p -m 0755 /sysroot${rwVarNixDb}/var/nix/db /sysroot${rwVarNixDb}/work /sysroot/nix/var/nix/db
      # Shadow host-only 0600 files so the unprivileged microvm user can read the DB.
      /bin/touch /sysroot${rwVarNixDb}/var/nix/db/big-lock
      /bin/chmod 600 /sysroot${rwVarNixDb}/var/nix/db/big-lock
      /bin/touch /sysroot${rwVarNixDb}/var/nix/db/reserved
      /bin/chmod 600 /sysroot${rwVarNixDb}/var/nix/db/reserved
    '';
    serviceConfig.Type = "oneshot";
  };
}
