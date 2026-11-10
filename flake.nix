{
  description = "Nix configuration";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    nixos-hardware.url = "github:NixOS/nixos-hardware/master";
    home-manager = {
      url = "github:nix-community/home-manager";
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
    numen = {
      url = "github:LorenzBischof/numen-nix";
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
    lanzaboote = {
      url = "github:nix-community/lanzaboote";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    #nixpkgs-umap.url = "github:LorenzBischof/nixpkgs/push-toztvqvvsxnk";
    nixpkgs-umap.url = "github:LorenzBischof/nixpkgs/push-ptpxqyykswtl";
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
    # Ryzen AI NPU stack (XRT + xdna plugin + FastFlowLM). Deliberately not
    # following our nixpkgs, as upstream asks: its overlay also replaces
    # llama-cpp(-vulkan), pinning llama.cpp's source under nixpkgs' recipe, and
    # that pin is only tested against upstream's own nixpkgs. Following ours
    # broke the build when nixpkgs moved to llama.cpp 0.7.0 and dropped a test
    # patch the older pinned source still needed. The second nixpkgs only
    # costs closure/eval size; CI pushes it to our cache like everything else.
    nix-amd-ai.url = "github:noamsto/nix-amd-ai";
    nixos-agent-test-vm.url = "github:lorenzbischof/nixos-agent-test-vm";
    # Galaxus/Digitec product search, for the MCP server on vps. Upstream ships no
    # flake.nix, so this is a plain source pin - of the TypeScript only. The
    # persisted GraphQL query hashes it replays rotate whenever the shop deploys a
    # new frontend, and those live in packages/galaxus-mcp/operations.json, which
    # overrides the copy in this tree: a rotation is an edit there, not a bump
    # here. This pin moves only for actual code changes.
    galaxus-mcp = {
      url = "github:zurchpet/galaxus-mcp";
      flake = false;
    };
    # basic-memory pins its dependencies exactly and tests only that set, which
    # nixpkgs' python set never matches, so packages/basic-memory builds from
    # upstream's own uv.lock. A flake input rather than a fetchFromGitHub so the
    # lock is read at eval time without import-from-derivation; a bump is the
    # tag in this URL.
    basic-memory = {
      url = "github:basicmachines-co/basic-memory/v1.0.0";
      flake = false;
    };
    # Elephant-Goldfish Model: spec drafting and fresh-context design review. The
    # repo root is the plugin for both Claude Code and Codex, so it is handed to
    # both as-is; a bump is the tag in this URL.
    egm = {
      url = "github:google/elephant-goldfish-model/v0.1.1";
      flake = false;
    };
    pyproject-nix = {
      url = "github:pyproject-nix/pyproject.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    uv2nix = {
      url = "github:pyproject-nix/uv2nix";
      inputs.pyproject-nix.follows = "pyproject-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    pyproject-build-systems = {
      url = "github:pyproject-nix/build-system-pkgs";
      inputs.pyproject-nix.follows = "pyproject-nix";
      inputs.uv2nix.follows = "uv2nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      nixos-hardware,
      home-manager,
      nix-index-database,
      nix-secrets,
      numen,
      treefmt-nix,
      neovim-config,
      nixhome,
      alertmanager-ntfy,
      disko,
      lanzaboote,
      alias-watch,
      voxtype,
      nix-amd-ai,
      nixos-agent-test-vm,
      ...
    }@inputs:
    let
      system = "x86_64-linux";
      lib = nixpkgs.lib;
      pkgs = import nixpkgs {
        inherit system;
        config = {
          allowUnfree = true;
        };
        overlays = [
          neovim-config.overlays.default
        ];
      };

      treefmtEval = treefmt-nix.lib.evalModule pkgs ./treefmt.nix;
    in
    {
      nixosConfigurations = {
        framework = nixpkgs.lib.nixosSystem {
          modules = [
            disko.nixosModules.disko
            nixos-hardware.nixosModules.framework-amd-ai-300-series
            nix-amd-ai.nixosModules.default
            ./modules/nixos
            ./hosts/framework/nixos
            home-manager.nixosModules.home-manager
            nix-secrets.nixosModules.laptop
            lanzaboote.nixosModules.lanzaboote
            {
              home-manager = {
                useGlobalPkgs = true;
                useUserPackages = true;
                users.lbischof = import ./hosts/framework/home;
                extraSpecialArgs = {
                  inherit self inputs;
                  secrets = import nix-secrets;
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
            # Inline the upstream module instead of alertmanager-ntfy.nixosModules.${system}.default,
            # which uses the deprecated `pkgs.system` (renamed to stdenv.hostPlatform.system).
            ({ ... }: {
              imports = [ "${alertmanager-ntfy}/module.nix" ];
              nixpkgs.overlays = [
                (_self: _super: {
                  alertmanager-ntfy = alertmanager-ntfy.packages.${system}.alertmanager-ntfy;
                })
              ];
            })
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
      };
      homeConfigurations = {
        bischoflo = home-manager.lib.homeManagerConfiguration {
          inherit pkgs;
          modules = [
            ./hosts/wsl/home.nix
            nix-index-database.homeModules.nix-index
            {
              programs.nix-index-database.comma.enable = true;
            }
          ];
        };
      };
      formatter.${system} = treefmtEval.config.build.wrapper;
      packages.${system} = {
        basic-memory = pkgs.callPackage ./packages/basic-memory { inherit inputs; };
        # Exposed for CI: the auto-fix job hands this store path to
        # claude-code-action instead of letting it run its own install.
        claude-code = inputs.llm-agents.packages.${system}.claude-code;
        cooklang-mcp = pkgs.callPackage ./packages/cooklang-mcp { };
        cook-cli-server = pkgs.callPackage ./packages/cook-cli-server.nix { };
        galaxus-mcp = pkgs.callPackage ./packages/galaxus-mcp { src = inputs.galaxus-mcp; };
      };
      apps.${system}.framework-agent-vm =
        (nixos-agent-test-vm.mkAgentVm {
          inherit pkgs;
          host = "framework";
          nixosConfig = self.nixosConfigurations.framework;
          extraConfig =
            { lib, pkgs, ... }:
            {
              # framework sets consoleLogLevel=3; runNixOSTest sets it to 7 — pick one.
              boot.consoleLogLevel = lib.mkForce 3;
              boot.lanzaboote.enable = lib.mkForce false;
              home-manager.users.lbischof.wayland.windowManager.sway.config.input."*".xkb_layout =
                lib.mkForce "us";
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
            };
        })
        // {
          # Without it, flake-check logs carry a standing `lacks attribute 'meta'`
          # warning for this app.
          meta.description = "Boot the framework configuration in a throwaway VM for agent-driven testing";
        };
    };
}
