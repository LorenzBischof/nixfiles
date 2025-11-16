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
    stylix.url = "github:danth/stylix";
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
    nix-ai-tools = {
      url = "github:numtide/nix-ai-tools";
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
      nix-ai-tools,
      mcp-nixos,
      lanzaboote,
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
                buildInputs = attrs.buildInputs ++ [ pkgs.sane-backends ];
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
    in
    {
      nixosConfigurations = {
        laptop = nixpkgs.lib.nixosSystem {
          inherit system pkgs;
          modules = [
            ./hosts/laptop/nixos
            ./modules/nixos
            stylix.nixosModules.stylix
            talon.nixosModules.talon
            home-manager.nixosModules.home-manager
            nix-secrets.nixosModules.laptop
            {
              home-manager = {
                useGlobalPkgs = true;
                useUserPackages = true;
                users.lbischof = import ./hosts/laptop/home;
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
            nixhome.nixosModules.nixhome
            alertmanager-ntfy.nixosModules.${system}.default
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
      homeConfigurations.bischoflo = home-manager.lib.homeManagerConfiguration {
        inherit pkgs;
        modules = [
          ./hosts/wsl/home.nix
          nix-index-database.hmModules.nix-index
          {
            programs.nix-index-database.comma.enable = true;
          }
        ];
      };
      images = {
        rpi2 = self.nixosConfigurations.rpi2.config.system.build.sdImage;
        rpi3 = self.nixosConfigurations.rpi3.config.system.build.sdImage;
      };
      formatter.${system} = treefmtEval.config.build.wrapper;
      checks.${system} =
        let
          testFiles = builtins.readDir ./tests;
          testNames = builtins.attrNames (
            lib.filterAttrs (name: type: type == "regular" && lib.hasSuffix ".nix" name) testFiles
          );
          removeExtension = name: lib.removeSuffix ".nix" name;
        in
        lib.listToAttrs (
          map (testFile: {
            name = removeExtension testFile;
            value = pkgs.testers.runNixOSTest {
              interactive.sshBackdoor.enable = true;
              globalTimeout = 300;

              name = removeExtension testFile;

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
              imports = [
                (./tests + "/${testFile}")
              ];
            };
          }) testNames
        );
    };
}
