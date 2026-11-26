# Orca's headless runtime, a second front end to the agents in agents.nix
# beside herdr.nix. Orca on framework pairs with it and opens terminals here
# as the agent user, in Orca's own terminal daemon rather than hc's.
#
# To pair: as the agent user, `orca pair --address <tailnet address>` prints
# an access link; add it in Orca under Settings > Remote Orca Servers.
# `--rotate` retires an unused one. The link is a credential: a paired device
# gets terminals as this user, with its GitHub tokens, and any agent here can
# mint one (the server's keys sit unencrypted in ~/.config/orca, as there is no
# keyring). Orca 1.4.272 has no command to revoke a paired device.
#
# On each start Orca also installs its hooks into ~/.claude/settings.json and
# ~/.codex (marking the Codex ones trusted).
# ORCA_AGENT_HOOKS_DISABLED and ORCA_DISABLE_CODEX_TRUST_RPC turn this off.
#
# Claude accounts for Orca are Orca's own: `orca account add` once per account
# (it runs `claude auth login` into ~/.config/orca/claude-profiles, whose
# settings carry Orca's hooks), then `orca account select` or Orca's account
# switcher. Orca's terminals run plain `claude`, which uses the selected one.
{
  config,
  lib,
  pkgs,
  agentUser,
  ...
}:
let
  orca = pkgs.llm-agents.orca;
  port = 6768;
  # The tailnet address nginx listens on (configuration.nix).
  address = lib.head config.services.nginx.defaultListenAddresses;
in
{
  users.users.${agentUser.name}.packages = [ orca ];

  systemd.user.services.orca = {
    description = "Orca runtime server";
    unitConfig.ConditionUser = agentUser.name;
    wantedBy = [ "default.target" ];
    inherit (agentUser) path;
    environment.ORCA_TELEMETRY_DISABLED = "1";
    serviceConfig = {
      # Tailnet only, straight to the tailnet address: pairing is end-to-end
      # encrypted with Orca's own keys, so no nginx or TLS in front. Before
      # pairing, every tailnet peer can still load the web client and open a
      # WebSocket.
      #
      # This runs Orca's Electron server, not its Node one (orcad): orcad
      # checks the bundled agent-browser by sha256, the package patchelfs that
      # binary, and serve falls back to Electron, which works headless.
      ExecStart = lib.escapeShellArgs [
        "${orca}/bin/orca"
        "serve"
        "--port"
        (toString port)
        "--bind"
        address
        "--pairing-address"
        address
      ];
      # Its terminals live in a daemon of their own (systemd scopes), so a
      # restart leaves them running. The Electron server moves itself into a
      # scope too; a clean stop reaches it through the CLI, a hard kill of
      # the CLI would leave it holding the port.
      Restart = "always";
      RestartSec = "5s";
    };
  };

  networking.firewall.interfaces."tailscale0".allowedTCPPorts = [ port ];
  my.homelab.ports = [ port ];
}
