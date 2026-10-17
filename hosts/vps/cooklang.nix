{
  config,
  pkgs,
  secrets,
  ...
}:
let
  domain = config.my.homelab.domain;
  mcpDomain = "meals.${domain}";
  # `recipes.${domain}` is already Mealie on nas, so the browser UI gets its own
  # name rather than colliding with it.
  uiDomain = "cook.${domain}";

  stateDir = "/var/lib/cooklang";
  collection = "${stateDir}/collection";

  mcpPort = 3001;
  uiPort = 9080;

  cooklang-mcp = pkgs.callPackage ../../packages/cooklang-mcp { };
  cook-cli-server = pkgs.callPackage ../../packages/cook-cli-server.nix { };

  # A static user, deliberately not DynamicUser: `cook server` owns the
  # collection and the shopping list it keeps beside it, and a per-activation
  # UID would make that ownership unusable.
  user = "cooklang";
in
{
  users.users.${user} = {
    isSystemUser = true;
    group = user;
    home = stateDir;
  };
  users.groups.${user} = { };

  systemd.tmpfiles.rules = [
    "d ${stateDir} 0750 ${user} ${user} -"
    "d ${collection} 0750 ${user} ${user} -"
    "d ${collection}/config 0750 ${user} ${user} -"
  ];

  # The recipe collection, and the only thing that touches it. Both the browser
  # UI and the MCP server below are clients of this one process, so they always
  # see the same recipes, the same pantry and the same shopping list.
  #
  # It has no authentication of its own, which is why its vhost never gains a
  # public listen address.
  systemd.services.cook-server = {
    description = "Cooklang recipe server";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" ];
    serviceConfig = {
      # Since 0.38 the server 403s any Host that is not localhost or an IP, so
      # the proxied name has to be named here or the whole UI is refused.
      ExecStart = "${cook-cli-server}/bin/cook server --port ${toString uiPort} --cors-origin https://${uiDomain} ${collection}";
      User = user;
      Group = user;
      WorkingDirectory = collection;
      Restart = "on-failure";
      RestartSec = "5s";

      ReadWritePaths = [ collection ];
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      PrivateDevices = true;
      NoNewPrivileges = true;
      RestrictAddressFamilies = [
        "AF_INET"
        "AF_INET6"
      ];
      RestrictNamespaces = true;
      LockPersonality = true;
      SystemCallArchitectures = "native";
      SystemCallFilter = [ "@system-service" ];
    };
  };

  systemd.services.cooklang-mcp = {
    description = "Cooklang MCP server";
    wantedBy = [ "multi-user.target" ];
    after = [
      "network.target"
      "cook-server.service"
    ];
    # Every tool but `fetch_recipe` is a call to cook-server; without it the
    # server answers, but answers nothing but errors.
    wants = [ "cook-server.service" ];
    # LoadCredential snapshots the token once, at start, and the unit text does
    # not change when the secret is rekeyed - so nothing restarts this and the
    # server keeps checking against a stale token. Every request then fails the
    # bearer check and claude.ai sees the 404 below, with nothing in the log to
    # say why. Tie the unit to the encrypted file so a rekey restarts it.
    restartTriggers = [ config.age.secrets.cooklang-mcp-token.file ];
    environment = {
      COOKLANG_SERVER_URL = "http://127.0.0.1:${toString uiPort}";
      COOKLANG_WEB_URL = "https://${uiDomain}";
      COOKLANG_MCP_TRANSPORT = "http";
      COOKLANG_MCP_PORT = toString mcpPort;
      # The shared bearer token, placed here by LoadCredential below.
      COOKLANG_MCP_TOKEN_FILE = "%d/token";
    };
    serviceConfig = {
      ExecStart = "${cooklang-mcp}/bin/cooklang-mcp";
      LoadCredential = "token:${config.age.secrets.cooklang-mcp-token.path}";
      Restart = "on-failure";
      RestartSec = "5s";

      # It reads and writes nothing on disk: the recipes reach it over HTTP
      # from cook-server, so it needs no identity of its own.
      DynamicUser = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      PrivateDevices = true;
      NoNewPrivileges = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectControlGroups = true;
      RestrictAddressFamilies = [
        "AF_INET"
        "AF_INET6"
      ];
      RestrictNamespaces = true;
      LockPersonality = true;
      MemoryDenyWriteExecute = true;
      SystemCallArchitectures = "native";
      SystemCallFilter = [ "@system-service" ];
    };
  };

  # Publicly reachable, because claude.ai connects from the internet. Same
  # pattern as the n8n webhook vhost: nginx listens on the tailnet by default
  # and a vhost opts in to the public NIC.
  services.nginx.virtualHosts."${mcpDomain}" = {
    forceSSL = true;
    useACMEHost = domain;
    listenAddresses = [ "10.0.0.238" ] ++ config.services.nginx.defaultListenAddresses;
    # An exact match, so widening this later cannot publish anything else.
    locations."= /mcp" = {
      proxyPass = "http://127.0.0.1:${toString mcpPort}";
      extraConfig = ''
        # Anthropic's documented egress range. The bearer token guards against a
        # leaked URL; this guards against everyone else.
        allow 160.79.104.0/21;
        deny all;
        # Streamable HTTP responses are SSE and must not be buffered.
        proxy_buffering off;
      '';
    };
  };

  # Tailnet only: no extra listen address.
  services.nginx.virtualHosts."${uiDomain}" = {
    forceSSL = true;
    useACMEHost = domain;
    locations."/" = {
      proxyPass = "http://127.0.0.1:${toString uiPort}";
      proxyWebsockets = true;
    };
  };

  # gitwatch pushes over ssh from a sandbox with no writable HOME, so ssh can
  # never learn a host key at runtime: the remote's key has to be pinned here
  # or every push fails on an unverified host. Cross-checked against the key
  # GitLab publishes at https://docs.gitlab.com/user/gitlab_com/.
  programs.ssh.knownHosts.gitlab = {
    hostNames = [ "gitlab.com" ];
    publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAfuCHKVTjquxvt6CM6tdG4SLp1Btn/nOeHHE5UOzRdf";
  };

  # A git history for the collection, mirrored to a private remote. Both the
  # browser UI and the MCP server write recipes in place, with no undo of their
  # own, so a bad edit or a deletion is otherwise unrecoverable. Every change
  # becomes a commit and is pushed straight out.
  services.gitwatch.cook = {
    enable = true;
    inherit user;
    path = collection;
    remote = secrets.cooklang-git-remote;
    branch = "main";
    # Quoted deliberately. The module splices `message` into a shell script
    # unquoted, so a multi-word one would break into positional args and
    # gitwatch would exit printing its usage - the service never starts. Being
    # a script and not the unit also means `%d`, gitwatch's date placeholder,
    # needs no systemd escaping.
    # https://github.com/NixOS/nixpkgs/pull/561894
    message = ''"cook: auto-commit on %d"'';
  };

  # The upstream module generates little beyond the ExecStart. Ordering, a git
  # identity, the deploy key and the sandbox are ours.
  systemd.services.gitwatch-cook = {
    after = [ "cook-server.service" ];
    environment = {
      # git refuses to commit without an identity, and the service user has no
      # git config of its own.
      GIT_AUTHOR_NAME = "gitwatch";
      GIT_AUTHOR_EMAIL = "gitwatch@${config.networking.hostName}";
      GIT_COMMITTER_NAME = "gitwatch";
      GIT_COMMITTER_EMAIL = "gitwatch@${config.networking.hostName}";
      # The push-only deploy key, and nothing else: there is no agent and no
      # ~/.ssh to fall back on, and known_hosts is the system file pinned above.
      GIT_SSH_COMMAND = "ssh -i ${config.age.secrets.cooklang-deploy-key.path} -o IdentitiesOnly=yes -o UserKnownHostsFile=/etc/ssh/ssh_known_hosts";
    };
    # gitwatch never initialises the repo itself: it would just run `git add`
    # in a plain directory and log one failure per change. Seed it with the
    # collection as it stands, so the first real commit is a diff. The module's
    # own `git clone` never fires here, because tmpfiles has already created
    # the directory.
    preStart = ''
      if [ ! -e .git ]; then
        git init -b main
        git add --all .
        git commit --allow-empty -m "cook: initial collection state"
      fi
      # gitwatch pushes only after a change, so without this the history
      # already on disk would sit unmirrored until the next recipe edit.
      # Deliberately not fatal: unit scripts run under `set -e`, and a remote
      # that is unreachable or has diverged must not take down the local
      # history, which is the actual safety net. git logs the reason.
      git push ${secrets.cooklang-git-remote} main || :
    '';
    serviceConfig = {
      Group = user;
      WorkingDirectory = collection;
      Restart = "on-failure";
      RestartSec = "5s";

      ReadWritePaths = [ collection ];
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      PrivateDevices = true;
      NoNewPrivileges = true;
      RestrictAddressFamilies = [
        "AF_UNIX"
        "AF_INET"
        "AF_INET6"
        # glibc's resolver probes the available address families over netlink;
        # denying it makes name resolution degrade in ways that are hard to
        # read off a failed push.
        "AF_NETLINK"
      ];
      RestrictNamespaces = true;
      LockPersonality = true;
      SystemCallArchitectures = "native";
      SystemCallFilter = [ "@system-service" ];
    };
  };

  my.homelab.ports = [
    mcpPort
    uiPort
  ];
}
