{
  lib,
  python3Packages,
}:
python3Packages.buildPythonApplication {
  pname = "cooklang-mcp";
  version = "0.2.0";
  pyproject = true;

  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./cooklang_mcp
      ./tests
      ./pyproject.toml
      ./README.md
    ];
  };

  build-system = [ python3Packages.hatchling ];

  dependencies = with python3Packages; [
    mcp
    httpx
    recipe-scrapers
    beautifulsoup4
    pyyaml
  ];

  nativeCheckInputs = [ python3Packages.pytestCheckHook ];

  pythonImportsCheck = [ "cooklang_mcp.server" ];

  meta = {
    description = "MCP server over a Cooklang recipe collection, via the CookCLI HTTP API";
    mainProgram = "cooklang-mcp";
    platforms = lib.platforms.all;
  };
}
