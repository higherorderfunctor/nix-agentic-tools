# git-mcp — builds from modelcontextprotocol/servers mono-repo.
# Source: nv.src is the full mono-repo at HEAD. Version read from
# src/git/pyproject.toml at eval time.
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

  # Read version from pyproject.toml via regex
  tomlContent = builtins.readFile "${nv.src}/src/git/pyproject.toml";
  tomlLines = builtins.filter (l: builtins.isString l && l != "") (builtins.split "\n" tomlContent);
  versionLine = builtins.head (builtins.filter (l: builtins.match "^version = .*" l != null) tomlLines);
  version = builtins.head (builtins.match "^version = \"(.*)\"$" versionLine);
in
  python314Packages.buildPythonApplication {
    pname = "git-mcp";
    inherit version;
    src = "${nv.src}/src/git";
    pyproject = true;
    build-system = with python314Packages; [hatchling];
    dependencies = with python314Packages; [click gitpython mcp pydantic];
    meta.mainProgram = "mcp-server-git";
    doCheck = false;
  }
