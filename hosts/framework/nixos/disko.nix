{
  disko.devices = {
    disk = {
      main = {
        type = "disk";
        device = "/dev/nvme0n1";
        content = {
          type = "gpt";
          partitions = {
            ESP = {
              size = "2G";
              type = "EF00";
              content = {
                type = "filesystem";
                format = "vfat";
                mountpoint = "/boot";
                mountOptions = [
                  "umask=0077"
                ];
              };
            };
            luks = {
              size = "100%";
              content = {
                type = "luks";
                name = "crypted";
                settings = {
                  allowDiscards = true;
                  crypttabExtraOpts = [
                    "no-read-workqueue"
                    "no-write-workqueue"
                    # TPM2 key is bound to PCRs 7+15 (15 = all zeros); this extends
                    # 15 after unlock so stage 2 can't unseal it again. PCR 12 is
                    # avoided: it changes with every generation's init= path.
                    # https://oddlama.org/blog/bypassing-disk-encryption-with-tpm2-unlock/
                    # https://discourse.nixos.org/t/a-modern-and-secure-desktop-setup/41154/17
                    "tpm2-measure-pcr=yes"
                    "tpm2-device=auto"
                    # No plain dm-crypt fallback for a header-less fake partition.
                    "luks"
                  ];
                };
                content = {
                  type = "btrfs";
                  extraArgs = [ "-f" ];
                  subvolumes = {
                    "/root" = {
                      mountpoint = "/";
                      mountOptions = [
                        "compress=zstd"
                        "noatime"
                      ];
                    };
                    "/home" = {
                      mountpoint = "/home";
                      mountOptions = [
                        "compress=zstd"
                        "noatime"
                      ];
                    };
                    "/nix" = {
                      mountpoint = "/nix";
                      mountOptions = [
                        "compress=zstd"
                        "noatime"
                      ];
                    };
                    "/persist" = {
                      mountpoint = "/persist";
                      mountOptions = [
                        "compress=zstd"
                        "noatime"
                      ];
                    };
                    "/swap" = {
                      mountpoint = "/.swapvol";
                      swap.swapfile.size = "100G";
                    };
                  };
                };
              };
            };
          };
        };
      };
    };
  };
}
