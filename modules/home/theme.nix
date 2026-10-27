{ lib, ... }:
{
  # Apps read their colours from this palette rather than a theming framework.
  options.my.theme.palette = lib.mkOption {
    type = lib.types.attrsOf (lib.types.strMatching "[0-9a-fA-F]{6}");
    description = "Base16 colours base00 to base0F, as RRGGBB without a leading #.";
  };
}
