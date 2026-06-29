{
  lib,
  python3,
  fetchFromGitHub,
  restic,
}:

# nixpkgs still ships restic-exporter 1.7.0, which is incompatible with restic
# 0.19.0 (ngosang/restic-exporter#60). Upstream fixed it in 2.1.0, but 2.0.0 was
# a full rewrite into a real Python package, so we repackage 2.1.2 here instead
# of patching 1.7.0. Drop this once nixpkgs bumps the package past 2.1.0.
python3.pkgs.buildPythonApplication rec {
  pname = "prometheus-restic-exporter";
  version = "2.1.2";
  pyproject = true;

  src = fetchFromGitHub {
    owner = "ngosang";
    repo = "restic-exporter";
    tag = version;
    hash = "sha256-n56LjQWZuAYB+jQoJT8KDMxmCxWa3zICYjlPq3PXxgQ=";
  };

  build-system = [ python3.pkgs.setuptools ];

  dependencies = [ python3.pkgs.prometheus-client ];

  # The exporter shells out to `restic` and guards startup with
  # shutil.which("restic"), so the binary must be on PATH at runtime.
  makeWrapperArgs = [
    "--prefix PATH : ${lib.makeBinPath [ restic ]}"
  ];

  # The 2.x rewrite renamed the entry point to `restic-exporter`, but the NixOS
  # module (services.prometheus.exporters.restic) still execs `restic-exporter.py`.
  # Keep that name working so the upstream module needs no patching.
  postInstall = ''
    ln -s restic-exporter $out/bin/restic-exporter.py
  '';

  nativeCheckInputs = [
    restic
    python3.pkgs.pytestCheckHook
    python3.pkgs.pytest-mock
  ];

  pythonImportsCheck = [ "exporter.exporter" ];

  # Some upstream tests convert snapshot timestamps via naive local time and
  # assume the runner sits at UTC+1; pin TZ so they pass in the UTC build sandbox.
  preCheck = ''
    export TZ=UTC-1
  '';

  meta = {
    description = "Prometheus exporter for the Restic backup system";
    homepage = "https://github.com/ngosang/restic-exporter";
    changelog = "https://github.com/ngosang/restic-exporter/blob/${version}/CHANGELOG.md";
    license = lib.licenses.mit;
    mainProgram = "restic-exporter";
    platforms = lib.platforms.all;
  };
}
