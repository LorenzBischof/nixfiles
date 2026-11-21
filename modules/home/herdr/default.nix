{
  config,
  pkgs,
  lib,
  inputs,
  ...
}:
let
  cfg = config.my.programs.herdr;
  herdr = inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system};

  # $mod+direction moves between Herdr panes and only leaves the window at the
  # pane edge; $mod+Ctrl+direction always moves between Sway windows. Run
  # test_sway_herdr_nav.py with python3 after changing the routing.
  swayHerdrNav = pkgs.writers.writePython3Bin "sway-herdr-nav" {
    flakeIgnore = [ "E501" ];
  } (builtins.readFile ./sway_herdr_nav.py);

  sway = config.wayland.windowManager.sway.config;
  # Vim keys and arrows, e.g. Mod4+h and Mod4+Left for left.
  bind =
    prefix: command:
    lib.mergeAttrsList (
      map
        (d: {
          "${prefix}+${sway.${d}}" = command d;
          "${prefix}+${lib.toSentenceCase d}" = command d;
        })
        [
          "left"
          "down"
          "up"
          "right"
        ]
    );

  c = lib.mapAttrs (_: hex: "#${hex}") config.my.theme.palette;
in
{
  options.my.programs.herdr.enable = lib.mkEnableOption "Herdr App with the Eighties layouts";

  config = lib.mkIf cfg.enable {
    home.packages = [
      herdr.herdr-app
      herdr.herdr-core
      swayHerdrNav
    ];

    wayland.windowManager.sway.config.keybindings = lib.mkOptionDefault (
      bind sway.modifier (d: "exec sway-herdr-nav ${d}") // bind "${sway.modifier}+Ctrl" (d: "focus ${d}")
    );

    # Linked file by file: Herdr writes its type declarations into each mod
    # directory, so the directories themselves must stay writable. Settings,
    # state and the stock mods remain Herdr's own.
    xdg.configFile = {
      "herdr-app" = {
        source = ./config;
        recursive = true;
      };
      # Colours live only here; the mods read them through theme() tokens.
      "herdr-app/themes/eighties.json".text = builtins.toJSON (
        with c;
        {
          ansi = [
            base00
            base08
            base0B
            base0A
            base0D
            base0E
            base0C
            base05
            base03
            base08
            base0B
            base0A
            base0D
            base0E
            base0C
            base07
          ];
          background = base00;
          foreground = base05;
          cursor = base05;
          selection = base02;
          colors = {
            accent = base0D;
            accent_foreground = base00;
            background = base00;
            blocked = base08;
            border = base01;
            canvas = base00;
            chrome = base00;
            dim = base04;
            done = base0B;
            foreground = base05;
            hover = base01;
            idle = base04;
            input = base02;
            muted = base05;
            popover = base01;
            raised = base01;
            selected = base02;
            selection = base02;
            solid = base0D;
            solid_foreground = base00;
            surface = base00;
            unknown = base04;
            working = base0A;
          };
        }
      );
    };
  };
}
