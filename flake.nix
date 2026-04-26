{
  description = "Nix configuration";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    nixpkgs-citrix-workspace.url = "github:nixos/nixpkgs/87f93d54c572c70f5e4c69eb82f0a7ece26ac9f6";
    nixos-hardware.url = "github:NixOS/nixos-hardware/master";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    stylix = {
      url = "github:danth/stylix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nix-index-database = {
      url = "github:nix-community/nix-index-database";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nix-secrets = {
      # Access token expires after one year!
      # https://nix.dev/manual/nix/stable/command-ref/conf-file#conf-access-tokens
      # https://github.blog/2022-10-18-introducing-fine-grained-personal-access-tokens-for-github/
      url = "github:lorenzbischof/nix-secrets";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    pre-commit-hooks = {
      url = "github:cachix/pre-commit-hooks.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    talon = {
      # https://github.com/nix-community/talon-nix/pull/21
      url = "github:LorenzBischof/talon-nix/pango";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    numen = {
      url = "github:LorenzBischof/numen-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nixos-generators = {
      url = "github:nix-community/nixos-generators";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    neovim-config = {
      url = "github:LorenzBischof/neovim-config";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nixhome = {
      url = "github:eblechschmidt/nixhome";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    alertmanager-ntfy = {
      url = "github:alexbakker/alertmanager-ntfy";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    llm-agents = {
      url = "github:numtide/llm-agents.nix";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.treefmt-nix.follows = "treefmt-nix";
      #inputs.blueprint.inputs.nixpkgs.follows = "nixpkgs";
    };
    mcp-nixos = {
      url = "github:utensils/mcp-nixos";
      inputs.nixpkgs.follows = "nixpkgs";
      #inputs.devshell.inputs.nixpkgs.follows = "nixpkgs";
    };
    lanzaboote = {
      url = "github:nix-community/lanzaboote/v0.4.3";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nixpkgs-umap.url = "github:LorenzBischof/nixpkgs/push-toztvqvvsxnk";
    asustor-platform-driver = {
      url = "github:mafredri/asustor-platform-driver";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    alias-watch = {
      url = "github:lorenzbischof/alias-watch";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    voxtype = {
      url = "github:peteonrails/voxtype";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      nixpkgs-citrix-workspace,
      nixos-hardware,
      home-manager,
      stylix,
      nix-index-database,
      nix-secrets,
      pre-commit-hooks,
      talon,
      numen,
      nixos-generators,
      treefmt-nix,
      neovim-config,
      nixhome,
      alertmanager-ntfy,
      disko,
      mcp-nixos,
      lanzaboote,
      alias-watch,
      voxtype,
      ...
    }@inputs:
    let
      system = "x86_64-linux";
      lib = nixpkgs.lib;
      pkgs = import nixpkgs {
        inherit system;
        config = {
          allowUnfree = true;
          permittedInsecurePackages = [
            "electron-27.3.11"
            # Sonarr: https://github.com/NixOS/nixpkgs/issues/360592
            "aspnetcore-runtime-6.0.36"
            "aspnetcore-runtime-wrapped-6.0.36"
            "dotnet-sdk-6.0.428"
            "dotnet-sdk-wrapped-6.0.428"
          ];
        };
        overlays = [
          neovim-config.overlays.default
        ];
      };

      pkgs-citrix-workspace = import nixpkgs-citrix-workspace {
        inherit system;
        config = {
          allowUnfree = true;
          permittedInsecurePackages = [
            "libsoup-2.74.3"
            "libxml2-2.13.8"
          ];
        };
        overlays = [
          (final: prev: {
            citrix_workspace =
              (prev.citrix_workspace.overrideAttrs (attrs: {
                # Required by newer version
                buildInputs = attrs.buildInputs ++ [ prev.sane-backends ];
                src = attrs.src.overrideAttrs (srcAttrs: {
                  # So that I can push the tar.gz to the Nix cache
                  allowSubstitutes = true;
                });
              })).override
                {
                  version = "25.03.0.66";
                  hash = "052zibykhig9091xl76z2x9vn4f74w5q8i9frlpc473pvfplsczk";
                };
          })
        ];
      };
      treefmtEval = treefmt-nix.lib.evalModule pkgs ./treefmt.nix;
      mkTest =
        { name, module }:
        pkgs.testers.runNixOSTest {
          interactive.sshBackdoor.enable = true;
          globalTimeout = 500;

          inherit name;

          defaults = {
            # I could not get this to work another way. If I directly set the options, there is an eval error.
            # Including the full module means that we need a mocked private key etc.
            options.age = with lib; {
              secrets = mkOption {
                type = types.attrsOf (
                  types.submodule (
                    { config, ... }:
                    {
                      options = {
                        file = mkOption {
                          type = types.path;
                        };
                        path = mkOption {
                          type = types.str;
                          default = "${config.file}";
                        };
                      };
                    }
                  )
                );
                default = { };
              };
            };
          };
          imports = [ module ];
        };
    in
    {
      nixosConfigurations = {
        framework = nixpkgs.lib.nixosSystem {
          modules = [
            disko.nixosModules.disko
            nixos-hardware.nixosModules.framework-amd-ai-300-series
            ./modules/nixos
            ./hosts/framework/nixos
            stylix.nixosModules.stylix
            home-manager.nixosModules.home-manager
            nix-secrets.nixosModules.laptop
            lanzaboote.nixosModules.lanzaboote
            {
              home-manager = {
                useGlobalPkgs = true;
                useUserPackages = true;
                users.lbischof = import ./hosts/framework/home;
                extraSpecialArgs = {
                  inherit self inputs pkgs-citrix-workspace;
                };
              };
            }
            nix-index-database.nixosModules.nix-index
          ];
          specialArgs = {
            secrets = import nix-secrets;
            inherit inputs;
          };
        };
        nas = nixpkgs.lib.nixosSystem {
          modules = [
            ./hosts/nas/configuration.nix
            nix-secrets.nixosModules.nas
            alias-watch.nixosModules.default
            nixhome.nixosModules.nixhome
            alertmanager-ntfy.nixosModules.${system}.default
            inputs.asustor-platform-driver.nixosModules.default
          ];
          specialArgs = {
            secrets = import nix-secrets;
            inherit inputs;
          };
        };
        vps = nixpkgs.lib.nixosSystem {
          modules = [
            disko.nixosModules.disko
            nix-secrets.nixosModules.vps
            ./hosts/vps/configuration.nix
          ];
          specialArgs = {
            secrets = import nix-secrets;
            inherit inputs;
          };
        };
        iso-installer = nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          modules = [
            ./hosts/iso-installer/configuration.nix
          ];
          specialArgs = {
            inherit self nixpkgs;
          };
        };
        #  rpi2 = nixpkgs.lib.nixosSystem {
        #    modules = [
        #      "${nixpkgs}/nixos/modules/installer/sd-card/sd-image-raspberrypi.nix"
        #      {
        #        nixpkgs = {
        #          config.allowUnsupportedSystem = true;
        #          hostPlatform.system = "armv7l-linux";
        #          buildPlatform.system = "x86_64-linux"; # If you build on x86 other wise changes this.
        #          # ... extra configs as above
        #        };
        #      }
        #    ];
        #  };
        #  rpi3 = nixpkgs.lib.nixosSystem {
        #    system = "aarch64-linux";
        #    modules = [
        #      "${nixpkgs}/nixos/modules/installer/sd-card/sd-image-aarch64.nix"
        #      {
        #        environment.systemPackages = [ pkgs.git ];
        #        users.users.nixos = {
        #          isNormalUser = true;
        #          extraGroups = [
        #            "wheel"
        #            "networkmanager"
        #          ];
        #          openssh.authorizedKeys.keys = [
        #            "sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC1lZDI1NTE5QG9wZW5zc2guY29tAAAAIDSKZEtyhueGqUow/G2ewR5TuccLqhrgwWd5VUnd6ImqAAAAC3NzaDpob21lbGFi"
        #          ];
        #        };
        #        services.openssh.enable = true;
        #        security.sudo.wheelNeedsPassword = false;
        #        nix.settings.trusted-users = [
        #          "nixos"
        #          "root"
        #        ];

        #        # bzip2 compression takes loads of time with emulation, skip it.
        #        sdImage.compressImage = false;
        #      }
        #    ];
        #  };
      };
      homeConfigurations = {
        bischoflo = home-manager.lib.homeManagerConfiguration {
          inherit pkgs;
          modules = [
            ./hosts/wsl/home.nix
            nix-index-database.hmModules.nix-index
            {
              programs.nix-index-database.comma.enable = true;
            }
          ];
        };
      };
      images = {
        rpi2 = self.nixosConfigurations.rpi2.config.system.build.sdImage;
        rpi3 = self.nixosConfigurations.rpi3.config.system.build.sdImage;
      };
      formatter.${system} = treefmtEval.config.build.wrapper;
      apps.${system}.framework-vm =
        let
          vm = pkgs.testers.runNixOSTest {
            name = "framework-vm";
            node.pkgs = pkgs;
            node.pkgsReadOnly = false;
            node.specialArgs = self.nixosConfigurations.framework._module.specialArgs;
            imports = [
              {
                nodes.machine =
                  { lib, pkgs, ... }:
                  {
                    imports = self.nixosConfigurations.framework._module.args.modules ++ [
                      {
                        boot.consoleLogLevel = lib.mkForce 3;
                        boot.lanzaboote.enable = lib.mkForce false;
                        # Keep keyboard input predictable for send_chars() in the VM driver.
                        console.keyMap = lib.mkForce "us";
                        home-manager.users.lbischof.wayland.windowManager.sway.config.input."*".xkb_layout =
                          lib.mkForce "us";

                        virtualisation = {
                          memorySize = 4096;
                          cores = 4;
                          graphics = true;
                          qemu.package = lib.mkForce pkgs.qemu;
                          qemu.options = [
                            "-vga none"
                            "-device virtio-gpu-pci"
                            "-display gtk,gl=off"
                          ];
                        };

                        services.greetd = {
                          restart = lib.mkForce false;
                          settings.initial_session = {
                            command = "${pkgs.bash}/bin/bash -lc 'export WLR_RENDERER_ALLOW_SOFTWARE=1; exec ${pkgs.sway}/bin/sway'";
                            user = "lbischof";
                          };
                        };
                        services.tailscale.enable = lib.mkForce false;
                        services.syncthing.enable = lib.mkForce false;
                        virtualisation.docker.enable = lib.mkForce false;
                        virtualisation.libvirtd.enable = lib.mkForce false;
                        my.system.autoUpgrade.enable = lib.mkForce false;
                        home-manager.users.lbischof.programs.voxtype.service.enable = lib.mkForce false;
                      }
                    ];
                  };

                testScript = # python
                  ''
                    import json, traceback, socket, os
                    from pathlib import Path

                    start_all()

                    runtime_dir = os.environ.get("XDG_RUNTIME_DIR", "/tmp")
                    sock_path = Path(runtime_dir) / "framework-vm.sock"
                    sock_path.unlink(missing_ok=True)

                    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                    try:
                        srv.bind(str(sock_path))
                        srv.listen(1)

                        while True:
                            conn, _ = srv.accept()
                            with conn:
                                try:
                                    cmd = conn.makefile().read().strip()
                                    try:
                                        result = eval(cmd)
                                        resp = {"ok": True, "result": str(result) if result is not None else None}
                                    except Exception:
                                        resp = {"ok": False, "error": traceback.format_exc()}
                                    conn.sendall(json.dumps(resp).encode())
                                except SystemExit:
                                    raise
                                except Exception:
                                    pass  # client disconnected mid-command
                    finally:
                        srv.close()
                        sock_path.unlink(missing_ok=True)
                  '';
              }
            ];
          };
        in
        {
          type = "app";
          program = "${vm.driver}/bin/nixos-test-driver";
        };
      nixosTests.${system} = {
        attic = mkTest {
          name = "attic";
          module = import ./tests/attic.nix { inherit inputs self; };
        };
      };
      checks.${system} = {
        inherit (self.nixosTests.${system}) attic;
      };
    };
}
