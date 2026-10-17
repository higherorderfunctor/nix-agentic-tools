# cspell:ignore logfire mcpserver mtkennerly ninoseki truststore
# The SDK and its private Python dependencies track releases as one update group.
{
  extractedLib,
  lib,
  packageLib,
  pkgs,
  repoPath,
  ...
}: let
  ps = pkgs.python3Packages;
  sourceSpecs = {
    dunamai = {
      parents = [{project = "uv-dynamic-versioning";}];
      repo = "mtkennerly/dunamai";
    };
    httpx2 = {
      parents = [{project = "mcp";}];
      repo = "pydantic/httpx2";
    };
    mcp.repo = "modelcontextprotocol/python-sdk";
    uv-dynamic-versioning = {
      parents = [
        {
          project = "httpx2";
          pyproject = "src/httpcore2/pyproject.toml";
        }
        {
          project = "httpx2";
          pyproject = "src/httpx2/pyproject.toml";
        }
        {
          project = "mcp";
          pyproject = "pyproject.toml";
        }
        {
          project = "mcp";
          pyproject = "src/mcp-types/pyproject.toml";
        }
      ];
      repo = "ninoseki/uv-dynamic-versioning";
    };
  };
  sourcesFiles = (lib.mapAttrs (name: _: ../../../../. + "/${name}-sources.json") sourceSpecs) // {mcp = ../../../../sources.json;};
  sources = lib.mapAttrs (_: file: builtins.fromJSON (builtins.readFile file)) sourcesFiles;
  githubSource = name: let
    spec = sourceSpecs.${name};
    pin = sources.${name};
    parts = lib.splitString "/" spec.repo;
  in
    pkgs.fetchFromGitHub {
      owner = builtins.head parts;
      repo = builtins.elemAt parts 1;
      tag = "v${pin.version}";
      inherit (pin.src) hash;
    };
  updateScript = pkgs.writeShellScript "update-mcp-group" ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
    ${lib.concatMapStringsSep "\n" (name: let
        spec = sourceSpecs.${name};
      in "${packageLib.ghArchiveUpdateScript ({
          inherit pkgs;
          inherit (spec) repo;
          pname = name;
          sourcesFile = repoPath sourcesFiles.${name};
        }
        // lib.optionalAttrs (spec ? parents) {
          versionCheck.cmd = packageLib.pythonDependencyVersionCmd {
            inherit pkgs;
            dependency = name;
            parents = map (parent:
              {sourcesFile = repoPath sourcesFiles.${parent.project};}
              // (
                if parent ? pyproject
                then {
                  pyprojectUrl = "https://raw.githubusercontent.com/${sourceSpecs.${parent.project}.repo}/v{version}/${parent.pyproject}";
                }
                else {inherit (parent) project;}
              ))
            spec.parents;
          };
        })}")
      # Parent pins must be current before their dependency bounds are read.
      ["mcp" "httpx2" "uv-dynamic-versioning" "dunamai"]}
    ${(extractedLib {inherit pkgs;}).regenCommand {name = "semble";}}
  '';

  dunamai = ps.dunamai.overridePythonAttrs (old: {
    inherit (sources.dunamai) version;
    src = githubSource "dunamai";
    meta = (old.meta or {}) // {changelog = "https://github.com/mtkennerly/dunamai/blob/v${sources.dunamai.version}/CHANGELOG.md";};
  });
  uv-dynamic-versioning = (ps.uv-dynamic-versioning.override {inherit dunamai;}).overridePythonAttrs (old: {
    inherit (sources.uv-dynamic-versioning) version;
    src = githubSource "uv-dynamic-versioning";
    # Repository-manipulation tests need .git.
    doCheck = false;
    meta = (old.meta or {}) // {changelog = "https://github.com/ninoseki/uv-dynamic-versioning/releases/tag/v${sources.uv-dynamic-versioning.version}";};
  });

  # Both transport distributions are released from the same source and version.
  transportSource = githubSource "httpx2";
  transportPin = {
    inherit (sources.httpx2) version;
    src = transportSource;
  };
  httpcore2 = (ps.httpcore2.override {inherit uv-dynamic-versioning;}).overridePythonAttrs transportPin;
  httpx2 = (ps.httpx2.override {inherit httpcore2 uv-dynamic-versioning;}).overridePythonAttrs (transportPin
    // {
      dependencies = with ps; [anyio httpcore2 idna truststore];
    });

  sdkSource = githubSource "mcp";
  mcp-types = ps.buildPythonPackage {
    pname = "mcp-types";
    inherit (sources.mcp) version;
    pyproject = true;
    src = sdkSource;
    sourceRoot = "${sdkSource.name}/src/mcp-types";
    build-system = [ps.hatchling uv-dynamic-versioning];
    dependencies = with ps; [pydantic typing-extensions];
    # Wire types are exercised by the SDK's server tests, which depend on this package.
    doCheck = false;
    pythonImportsCheck = ["mcp_types"];
    meta = {
      description = "Model Context Protocol wire types";
      homepage = "https://github.com/modelcontextprotocol/python-sdk";
      license = lib.licenses.mit;
    };
  };
in
  (ps.mcp.override {inherit uv-dynamic-versioning;}).overridePythonAttrs (old: let
    optionalDependencies = lib.getAttrs ["cli" "rich"] old.optional-dependencies;
  in {
    inherit (sources.mcp) version;
    src = sdkSource;
    dependencies = with ps; [
      anyio
      cryptography
      httpx2
      jsonschema
      mcp-types
      opentelemetry-api
      pydantic
      pyjwt
      python-multipart
      sse-starlette
      starlette
      typing-extensions
      typing-inspection
      uvicorn
    ];
    optional-dependencies = optionalDependencies;
    postPatch = "";
    pythonRelaxDeps = [];
    pythonImportsCheck = ["mcp" "mcp.server.mcpserver" "mcp_types"];

    # Exercise the public server API Semble uses, with the SDK 2 test fixtures.
    nativeCheckInputs = with ps;
      [
        blockbuster
        inline-snapshot
        logfire
        pytest-examples
        pytestCheckHook
      ]
      ++ lib.concatAttrValues optionalDependencies;
    pytestFlags = ["--override-ini=pythonpath=." "tests/server/mcpserver/test_server.py"];
    disabledTests = [];
    passthru =
      (old.passthru or {})
      // {
        inherit updateScript;
      };
  })
