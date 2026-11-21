# Our skills and playwright-cli's, with the helpers they call in bin/.
{
  lib,
  stdenvNoCC,
  installAgentSkills,
  writers,
  writeShellApplication,
  gh,
  gnugrep,
  nodejs,
  playwright,
  chromium,
  browser ? chromium,
}:
let
  workLogExtract = writers.writePython3Bin "work-log-extract" {
    flakeIgnore = [
      "E501" # long lines read fine; wrapping them hurts more than it helps here
      "W503" # black-style line breaks before binary operators
    ];
  } (builtins.readFile ./work-log/extract.py);
  nixpkgsReviewGha = writeShellApplication {
    name = "nixpkgs-review-gha";
    runtimeInputs = [
      gh
      gnugrep
    ];
    text = builtins.readFile ./nixpkgs-review-gha/review.sh;
  };
  # nixpkgs' playwright-core ships the agent CLI and its matching skill.
  playwrightCli = writeShellApplication {
    name = "playwright-cli";
    runtimeInputs = [ nodejs ];
    text = ''
      export PLAYWRIGHT_MCP_EXECUTABLE_PATH=${lib.getExe browser}
      exec node ${playwright}/cli.js cli "$@"
    '';
  };
in
stdenvNoCC.mkDerivation {
  pname = "nixfiles";
  version = "0";
  src = ./.;
  # The hook installs our skills from src by itself.
  nativeBuildInputs = [ installAgentSkills ];
  dontBuild = true;
  installPhase = ''
    runHook preInstall
    installSkill ${playwright}/lib/tools/skills/playwright-cli
    mkdir -p $out/bin
    ln -s ${lib.getExe workLogExtract} ${lib.getExe nixpkgsReviewGha} ${lib.getExe playwrightCli} $out/bin/
    runHook postInstall
  '';
}
