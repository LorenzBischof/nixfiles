{
  nodes = {
    client =
      { config, pkgs, ... }:
      {
        imports = [
          ../hosts/vps/attic.nix
          ../modules/nixos/nginx.nix
        ];
        age.secrets.atticd-env.file = pkgs.writeText "env" ''
          ATTIC_SERVER_TOKEN_RS256_SECRET_BASE64=dGVzdGluZwo=
        '';
      };
  };

  testScript = # python
    ''
      start_all()

      client.systemctl("start network-online.target")
      client.wait_for_unit("network-online.target")

      client.wait_for_unit("atticd.service")
    '';
}
