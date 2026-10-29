# Hands-free voxtype dictation: say "dictate" to numen to start it, and hiss
# ("sssss") to stop it. numen is paused while voxtype records, because it
# hears the same microphone and would act on dictated words; it can't listen
# for a stop word itself either, since a grammar of one phrase makes Vosk
# force everything onto it. A hiss needs no model, and isn't transcribed.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  numen = config.services.numen.package;
  voxtype = lib.getExe config.programs.voxtype.package;

  dictatePhrases = pkgs.writeText "dictate.phrases" ''
    dictate: run ${voxtype} record start
  '';

  # numen's defaults spelled out, because services.numen.phrases replaces
  # them, and the module's numen-wake can't glob them back in.
  phrases =
    map (name: "${numen}/etc/numen/phrases/${name}.phrases") [
      "character"
      "control"
      "environment"
      "mouse"
      "voice"
    ]
    ++ [ dictatePhrases ];

  dictationStop =
    pkgs.writers.writePython3Bin "dictation-stop"
      {
        libraries = [ pkgs.python3Packages.numpy ];
        flakeIgnore = [
          "E501"
          "W503" # black-style line breaks before binary operators
        ];
      }
      (builtins.readFile ./dictation-stop.py);
in
{
  services.numen.phrases = phrases;

  systemd.user.services.dictation-stop = {
    Unit = {
      Description = "Stop voxtype dictation on a hiss";
      After = [
        "voxtype.service"
        "numen.service"
      ];
      PartOf = [ "graphical-session.target" ];
    };
    Install.WantedBy = [ "graphical-session.target" ];
    Service = {
      ExecStart = lib.escapeShellArgs (
        [
          (lib.getExe dictationStop)
          voxtype
          "${numen}/bin/numenc"
          # How long the hiss must hold, in seconds
          "0.5"
          # How far the hiss band must outweigh the voice band. The room
          # through the built-in mic sits ~0.2; synthetic hiss 5-7, and the
          # "s" in synthetic speech above 3 for at most 120 ms. Not yet
          # measured on a real voice.
          "3"
        ]
        ++ map toString phrases
      );
      Environment = [ "PATH=${lib.makeBinPath [ pkgs.pipewire ]}" ];
      Restart = "always";
      RestartSec = 5;
    };
  };
}
