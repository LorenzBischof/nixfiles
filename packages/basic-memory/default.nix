# Built from upstream's uv.lock with uv2nix rather than from nixpkgs' python set.
# Upstream pins most of its dependencies exactly (fastapi, fastmcp, psycopg, and
# capped ranges for litellm) and tests only that set, while nixpkgs moves on its
# own schedule; packaging against nixpkgs meant re-auditing pythonRelaxDeps,
# vendoring a fastmcp nixpkgs did not have yet, and patching around APIs that
# newer releases removed, on every bump. The lock is the environment upstream's
# CI runs, so it is the one shipped here. The source comes from the
# `basic-memory` flake input, whose tag is the version.
{
  lib,
  python3,
  callPackage,
  callPackages,
  inputs,
}:
let
  src = inputs.basic-memory;

  # pyproject.toml takes its version from git tags, which the source has none
  # of, so it comes from the topmost CHANGELOG release heading: one string to
  # bump (the flake input's tag) instead of two that can disagree.
  version = lib.pipe "${src}/CHANGELOG.md" [
    builtins.readFile
    (lib.splitString "\n")
    (lib.findFirst (lib.hasPrefix "## v") (throw "basic-memory: no release heading in CHANGELOG.md"))
    (builtins.match "## v([^ ]+) .*")
    lib.head
  ];

  workspace = inputs.uv2nix.lib.workspace.loadWorkspace { workspaceRoot = src.outPath; };

  # Ship only an sdist, built with setuptools they never declare.
  setuptoolsSdists = [
    "pybars3"
    "pymeta3"
  ];

  pyprojectOverrides =
    final: prev:
    lib.genAttrs setuptoolsSdists (
      name:
      prev.${name}.overrideAttrs (old: {
        nativeBuildInputs = old.nativeBuildInputs ++ final.resolveBuildSystem { setuptools = [ ]; };
      })
    )
    // {
    basic-memory = prev.basic-memory.overrideAttrs (old: {
      # uv2nix reports a dynamic version as 0.0.0; mkApplication takes it from here.
      inherit version;
      # The source is already this release; only the reported version was wrong.
      __intentionallyOverridingVersion = true;
      # uv-dynamic-versioning reads this instead of asking git.
      env = (old.env or { }) // {
        UV_DYNAMIC_VERSIONING_BYPASS = version;
      };
    });
  };

  pythonSet = (callPackage inputs.pyproject-nix.build.packages { python = python3; }).overrideScope (
    lib.composeManyExtensions [
      inputs.pyproject-build-systems.overlays.wheel
      (workspace.mkPyprojectOverlay { sourcePreference = "wheel"; })
      pyprojectOverrides
    ]
  );

  # The default dependency group only: no dev tooling and none of the
  # pdf/documents/redis/milvus extras.
  venv = pythonSet.mkVirtualEnv "basic-memory-env" workspace.deps.default;

  inherit (callPackages inputs.pyproject-nix.build.util { }) mkApplication;
in
(mkApplication {
  inherit venv;
  package = pythonSet.basic-memory;
}).overrideAttrs
  (old: {
    # modules/home/ai builds the Claude Code and Codex plugins and the skills
    # directory out of the source tree.
    passthru = (old.passthru or { }) // {
      inherit src;
    };
    # Description and license come from upstream's pyproject; the binary
    # name does not, and the venv ships both `basic-memory` and `bm`.
    meta = (old.meta or { }) // {
      mainProgram = "basic-memory";
    };
  })
