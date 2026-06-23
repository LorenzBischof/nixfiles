{
  config,
  pkgs,
  lib,
  ...
}:
let
  domain = config.my.homelab.domain;
  gpsDomain = "gps.${domain}";

  # GPSLogger writes one .gpx per day into this Syncthing-synced directory.
  syncDir = "${config.services.syncthing.dataDir}/home/googledrive/Ferien/gpslogger";

  # Merged outputs that uMap reads as single remote-data URLs:
  # - track.geojson: LineString tracks (for the default/line layer)
  # - points.geojson: the trackpoints as Point features (uMap heatmaps only
  #   work with points, not lines)
  outDir = "/var/lib/gps-track";
  trackFile = "${outDir}/track.geojson";
  pointsFile = "${outDir}/points.geojson";

  user = config.services.syncthing.user;
  group = config.services.syncthing.group;

  # Fade tracks by age: drop opacity fadePerYear each year the track's "%Y-%m-%d"
  # name is older than the current year, never below fadeFloor. Writes the
  # per-feature opacity uMap reads from _umap_options. Unparseable names default
  # to the current year (full opacity).
  fadeFloor = 0.2;
  fadePerYear = 0.25;
  fadeByAge = ''
    (now | gmtime | strftime("%Y") | tonumber) as $year
    | .features |= map(
        ((.properties.name // "")[0:4] | tonumber? // $year) as $y
        | .properties._umap_options.opacity =
            ([${toString fadeFloor}, 1 - ($year - $y) * ${toString fadePerYear}] | max))
  '';
in
{
  # uMap can only point at a single URL, so merge the per-day GPX files into
  # one GeoJSON on a timer.
  systemd.tmpfiles.rules = [
    "d ${outDir} 0755 ${user} ${group} -"
  ];

  systemd.services.gps-track-merge = {
    description = "Merge GPSLogger per-day GPX into a single GeoJSON for uMap";
    serviceConfig = {
      Type = "oneshot";
      User = user;
      Group = group;

      # Belt-and-suspenders: the whole filesystem is read-only to this service
      # (so the source GPX in syncDir can never be modified), except outDir
      # where it writes the merged GeoJSON.
      ProtectSystem = "strict";
      ReadWritePaths = [ outDir ];
      ProtectHome = true;
      PrivateTmp = true;
      NoNewPrivileges = true;
      ProtectKernelTunables = true;
      ProtectControlGroups = true;
      RestrictSUIDSGID = true;
    };
    path = [
      pkgs.gpsbabel
      pkgs.findutils
      pkgs.coreutils
      pkgs.jq
    ];
    script = ''
      set -euo pipefail

      # Collect all *.gpx (full history) into gpsbabel -f arguments.
      mapfile -d "" -t gpx < <(
        find ${lib.escapeShellArg syncDir} -type f -iname '*.gpx' -print0 | sort -z
      )
      if [ ''${#gpx[@]} -eq 0 ]; then
        echo "No GPX files found; nothing to merge."
        exit 0
      fi
      args=()
      for f in "''${gpx[@]}"; do
        args+=(-f "$f")
      done

      # Write stdin to $1 atomically and world-readably (nginx must read it;
      # mktemp would otherwise leave it 0600).
      save() {
        local tmp
        tmp=$(mktemp "${outDir}/tmp.XXXXXX.geojson")
        cat > "$tmp"
        chmod 0644 "$tmp"
        mv -f "$tmp" "$1"
      }

      # Tracks (LineStrings): rename each track to its start date (GPSLogger
      # names them inconsistently, e.g. id_date vs 20230328), simplify the
      # geometry (~20m cross-track error), then fade older tracks by opacity.
      gpsbabel -i gpx "''${args[@]}" \
        -x track,title=%Y-%m-%d \
        -x simplify,crosstrack,error=0.02k \
        -o geojson -F - \
        | jq '${fadeByAge}' \
        | save ${lib.escapeShellArg trackFile}

      # Points for the heatmap layer (uMap heatmaps need points, not lines):
      # keep every 10th trackpoint to shrink the file (per-track, so repeat
      # visits still stack into heat), then explode them into Point features.
      gpsbabel -i gpx "''${args[@]}" \
        -x resample,decimate=10 \
        -x transform,wpt=trk,del \
        -o geojson -F - \
        | save ${lib.escapeShellArg pointsFile}
    '';
  };

  systemd.timers.gps-track-merge = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "daily";
      Persistent = true;
    };
  };

  # Static, tailnet-only endpoint (nginx already listens only on the Tailscale
  # IP). No Authelia, so uMap's server-side proxy can fetch it.
  services.nginx.virtualHosts."${gpsDomain}" = {
    useACMEHost = domain;
    forceSSL = true;
    root = outDir;
    locations."/".extraConfig = ''
      add_header Access-Control-Allow-Origin "*" always;
    '';
  };
}
