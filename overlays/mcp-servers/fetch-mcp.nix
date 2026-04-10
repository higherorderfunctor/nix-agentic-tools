# fetch-mcp — builds from modelcontextprotocol/servers mono-repo.
# Source: nv.src is the full mono-repo at HEAD. Version read from
# src/fetch/pyproject.toml at eval time.
{
  inputs,
  final,
  nv,
  ...
}: let
  ourPkgs = import inputs.nixpkgs {
    inherit (final.stdenv.hostPlatform) system;
  };
  inherit (ourPkgs) python314Packages;

  # Read version from pyproject.toml via regex (no TOML parser in Nix)
  tomlContent = builtins.readFile "${nv.src}/src/fetch/pyproject.toml";
  tomlLines = builtins.filter (l: builtins.isString l && l != "") (builtins.split "\n" tomlContent);
  versionLine = builtins.head (builtins.filter (l: builtins.match "^version = .*" l != null) tomlLines);
  version = builtins.head (builtins.match "^version = \"(.*)\"$" versionLine);
in
  python314Packages.buildPythonApplication {
    pname = "fetch-mcp";
    inherit version;
    src = "${nv.src}/src/fetch";
    pyproject = true;
    build-system = with python314Packages; [hatchling];
    dependencies = with python314Packages; [
      httpx
      markdownify
      mcp
      protego
      pydantic
      readabilipy
      requests
    ];
    postPatch = ''
      substituteInPlace src/mcp_server_fetch/server.py \
        --replace-fail 'AsyncClient(proxies=' 'AsyncClient(proxy='
    '';
    pythonRelaxDeps = ["httpx"];
    meta.mainProgram = "mcp-server-fetch";
    doCheck = false;
  }
