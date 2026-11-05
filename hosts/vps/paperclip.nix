{
  config,
  pkgs,
  inputs,
  ...
}:
let
  domain = config.my.homelab.domain;
  uiDomain = "paperclip.${domain}";

  stateDir = "/var/lib/paperclip";
  port = 3100;
  # The embedded PostgreSQL cluster, on loopback TCP.
  dbPort = 54329;

  llmAgents = inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system};
  paperclip = llmAgents.paperclip;
  npmArch = if pkgs.stdenv.hostPlatform.isAarch64 then "arm64" else "x64";

  # Static, not DynamicUser: the embedded PostgreSQL cluster, the secrets
  # master key and the agents' CLI logins all live in the state directory and
  # must keep one owner across restarts.
  user = "paperclip";

  # `run` refuses to start without a config when it has no tty, and only
  # `onboard` writes one. `onboard --yes` writes the quickstart defaults and
  # then starts the server itself, so the first boot ends up in the same
  # foreground process as every later one. The defaults it writes are
  # local_trusted/loopback; the environment below overrides both at runtime.
  start = pkgs.writeShellScript "paperclip-start" ''
    BETTER_AUTH_SECRET=$(cat ${stateDir}/auth-secret)
    export BETTER_AUTH_SECRET
    if [ ! -e "$PAPERCLIP_CONFIG" ]; then
      exec ${paperclip}/bin/paperclipai onboard --yes --no-install-service
    fi
    exec ${paperclip}/bin/paperclipai run
  '';
in
{
  users.users.${user} = {
    isSystemUser = true;
    group = user;
    home = stateDir;
  };
  users.groups.${user} = { };

  systemd.services.paperclip = {
    description = "Paperclip AI agent control plane";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];

    # What the agents' adapters shell out to. The adapters spawn these as
    # children of the server, so they inherit this PATH and this sandbox.
    path = [
      llmAgents.claude-code
      # llmAgents.codex
      pkgs.bash
      pkgs.coreutils
      pkgs.git
      pkgs.python3
      # The bundled paperclip skill talks to the API with curl and jq, and
      # runs its helper scripts and the CLI with node and `npx paperclipai`.
      paperclip
      pkgs.curl
      pkgs.jq
      pkgs.nodejs
      # Agents reach for `which` to probe their tools.
      pkgs.which
    ];

    environment = {
      HOME = stateDir;
      PAPERCLIP_HOME = stateDir;
      PAPERCLIP_CONFIG = "${stateDir}/instances/default/config.json";
      PORT = toString port;
      # Login required, on loopback behind the tailnet-only vhost below.
      PAPERCLIP_DEPLOYMENT_MODE = "authenticated";
      PAPERCLIP_DEPLOYMENT_EXPOSURE = "private";
      PAPERCLIP_BIND = "loopback";
      PAPERCLIP_PUBLIC_URL = "https://${uiDomain}";
      PAPERCLIP_ALLOWED_HOSTNAMES = uiDomain;
      # What agents call the API on. It defaults to the public URL, which
      # resolves to the tailnet address that IPAddressDeny below blocks.
      PAPERCLIP_API_URL = "http://127.0.0.1:${toString port}";
    };

    # Generated on the host rather than kept in agenix: nothing outside this
    # machine needs it, and losing it only signs everyone out. The secrets
    # master key next to it is created by Paperclip the same way.
    preStart = ''
      if [ ! -s auth-secret ]; then
        (umask 077; head -c 32 /dev/urandom | base64 > auth-secret)
      fi
    '';

    serviceConfig = {
      ExecStart = start;
      User = user;
      Group = user;
      StateDirectory = "paperclip";
      StateDirectoryMode = "0750";
      WorkingDirectory = stateDir;
      Restart = "on-failure";
      RestartSec = "5s";
      # Upstream allows 90s for adapter runs to settle before shutdown.
      TimeoutStopSec = "90s";
      # Signal only the server: it drains runs and stops its own PostgreSQL.
      # With the default control-group mode PostgreSQL got SIGTERM alongside
      # it and was gone before the drain's queries ran.
      KillMode = "mixed";

      # TODO: the bundled claude-agent-acp runs the prebuilt glibc `claude`
      # vendored in @anthropic-ai/claude-agent-sdk-linux-*, which NixOS can't
      # start, so every session fails with a bare "Internal error". Its
      # CLAUDE_CODE_EXECUTABLE override doesn't help: Paperclip launches agents
      # with an allowlisted environment that drops it. So the nixpkgs build is
      # mounted over the vendored one instead. (Codex will need the same for
      # the rg and zsh it vendors.) No upstream issue on numtide/llm-agents.nix
      # as of 2026-11. Drop once their paperclip package patches this itself.
      BindReadOnlyPaths = [
        "${llmAgents.claude-code}/bin/claude:${paperclip}/lib/node_modules/paperclipai/node_modules/@anthropic-ai/claude-agent-sdk-linux-${npmArch}/claude"
      ];

      # Deliberately looser than the other vps services: agents run arbitrary
      # shell commands, which rules out a @system-service allowlist, and node's
      # JIT rules out MemoryDenyWriteExecute. What remains keeps them out of
      # the rest of the system's state.
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      PrivateDevices = true;
      PrivateIPC = true;
      NoNewPrivileges = true;
      CapabilityBoundingSet = "";
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectKernelLogs = true;
      ProtectControlGroups = true;
      ProtectClock = true;
      ProtectHostname = true;
      ProtectProc = "invisible";
      RestrictNamespaces = true;
      RestrictSUIDSGID = true;
      RestrictRealtime = true;
      LockPersonality = true;
      UMask = "0077";
      SystemCallArchitectures = "native";
      # A denylist of what no shell, git, python or node workload calls.
      # EPERM rather than SIGSYS, so a stray call fails like any other error.
      SystemCallFilter = [
        "~@clock @cpu-emulation @module @mount @obsolete @raw-io @reboot @swap"
      ];
      SystemCallErrorNumber = "EPERM";

      # A runaway agent must not take the rest of the box (4 cores, 23G, no
      # swap) down with it.
      MemoryHigh = "6G";
      MemoryMax = "8G";
      TasksMax = 1024;
      CPUQuota = "300%";

      # The internet only: not the tailnet (and with it this host's own
      # tailnet-only vhosts), the VCN, or the instance metadata service.
      # DNS goes to public resolvers, so nothing here is needed for lookups.
      # Loopback stays open for nginx and PostgreSQL; the firewall rule below
      # narrows it.
      IPAddressDeny = [
        "10.0.0.0/8"
        "172.16.0.0/12"
        "192.168.0.0/16"
        "100.64.0.0/10"
        "169.254.0.0/16"
        "fc00::/7"
        "fe80::/10"
      ];

      RestrictAddressFamilies = [
        # The embedded PostgreSQL socket.
        "AF_UNIX"
        "AF_INET"
        "AF_INET6"
        "AF_NETLINK"
      ];
    };
  };

  # Loopback reaches every other service on this host (cook-server, n8n,
  # alloy, sshd, ...). New connections from the paperclip user over lo may go
  # only to Paperclip itself and its database; replies to nginx are not NEW.
  networking.firewall.extraCommands = ''
    ip46tables -N paperclip-lo 2>/dev/null || true
    ip46tables -F paperclip-lo
    ip46tables -A paperclip-lo -p tcp -m multiport --dports ${toString port},${toString dbPort} -j RETURN
    ip46tables -A paperclip-lo -j REJECT
    ip46tables -D OUTPUT -o lo -m owner --uid-owner ${user} -m conntrack --ctstate NEW -j paperclip-lo 2>/dev/null || true
    ip46tables -A OUTPUT -o lo -m owner --uid-owner ${user} -m conntrack --ctstate NEW -j paperclip-lo
  '';
  networking.firewall.extraStopCommands = ''
    ip46tables -D OUTPUT -o lo -m owner --uid-owner ${user} -m conntrack --ctstate NEW -j paperclip-lo 2>/dev/null || true
  '';

  # Tailnet only: no extra listen address.
  services.nginx.virtualHosts."${uiDomain}" = {
    forceSSL = true;
    useACMEHost = domain;
    locations."/" = {
      proxyPass = "http://127.0.0.1:${toString port}";
      proxyWebsockets = true;
    };
  };

  my.homelab.ports = [ port ];
}
