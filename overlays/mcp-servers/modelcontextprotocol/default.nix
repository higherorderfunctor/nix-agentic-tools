# modelcontextprotocol/servers — mono-repo with JS + Python servers.
# Source hash and npmDepsHash managed by nix-update.
# Uses npm workspaces with the upstream package-lock.json directly —
# no lockfiles shipped in this repo.
{
  inputs,
  final,
  ...
}: let
  ourPkgs = import inputs.nixpkgs {
    inherit (final.stdenv.hostPlatform) system;
  };
  inherit (ourPkgs) buildNpmPackage fetchFromGitHub makeWrapper nodejs python314Packages;
  vu = import ../../version-utils.nix;

  rev = "f4244583a6af9425633e433a3eec000d23f4e011";
  src = fetchFromGitHub {
    owner = "modelcontextprotocol";
    repo = "servers";
    inherit rev;
    hash = "sha256-bHknioQu8i5RcFlBBdXUQjsV4WN1IScnwohGRxXgGDk=";
  };

  # Helper: read version from a sub-package's pyproject.toml and append +shortrev
  readPyVersion = subdir:
    vu.mkVersion {
      upstream = vu.readPyprojectVersion "${src}/src/${subdir}/pyproject.toml";
      inherit rev;
    };

  # Helper: read version from a sub-package's package.json and append +shortrev
  readJsVersion = subdir:
    vu.mkVersion {
      upstream = vu.readPackageJsonVersion "${src}/src/${subdir}/package.json";
      inherit rev;
    };

  # Shared npm deps from the upstream mono-repo lockfile.
  # npmDepsFetcherVersion = 2 enables workspace support.
  # Hash managed by nix-update.
  npmDepsHash = "sha256-bj6q6TWOmZT+MGVugutU6vCpwaxedcraLB1Q/UfPIvc=";

  # Build a JS sub-package from the mono-repo using npm workspaces.
  mkJsPackage = {
    pname,
    subdir,
  }:
    buildNpmPackage {
      inherit pname src;
      version = readJsVersion subdir;
      sourceRoot = "source";
      postUnpack = "chmod -R u+w source";
      inherit npmDepsHash;
      npmDepsFetcherVersion = 2;
      npmWorkspace = "src/${subdir}";
      npmBuildScript = "build";
      nativeBuildInputs = [makeWrapper];
      installPhase = ''
        runHook preInstall
        mkdir -p $out/lib/${pname} $out/bin

        # Remove workspace symlinks that point to sibling packages
        # (they become dangling once we copy only this sub-package).
        find node_modules -maxdepth 2 -type l | while read -r link; do
          target=$(readlink "$link")
          if [[ "$target" == ../../src/* ]]; then
            rm "$link"
          fi
        done
        # Clean up dangling .bin stubs
        find node_modules/.bin -type l ! -exec test -e {} \; -delete 2>/dev/null || true

        cp -r src/${subdir}/dist $out/lib/${pname}/
        cp -r node_modules $out/lib/${pname}/
        cp src/${subdir}/package.json $out/lib/${pname}/
        makeWrapper ${nodejs}/bin/node $out/bin/${pname} \
          --add-flags "$out/lib/${pname}/dist/index.js"
        runHook postInstall
      '';
      meta.mainProgram = pname;
    };
in {
  # ── JS packages (npm workspaces) ──────────────────────────────

  filesystem-mcp = mkJsPackage {
    pname = "filesystem-mcp";
    subdir = "filesystem";
  };

  memory-mcp = mkJsPackage {
    pname = "memory-mcp";
    subdir = "memory";
  };

  sequential-thinking-mcp = mkJsPackage {
    pname = "sequential-thinking-mcp";
    subdir = "sequentialthinking";
  };

  # ── Python packages (buildPythonApplication) ───────────────────

  fetch-mcp = python314Packages.buildPythonApplication {
    pname = "fetch-mcp";
    version = readPyVersion "fetch";
    src = "${src}/src/fetch";
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
    # Upstream main already fixed proxies= -> proxy= (was needed for older releases).
    pythonRelaxDeps = ["httpx"];
    meta.mainProgram = "mcp-server-fetch";
    doCheck = false;
  };

  git-mcp = python314Packages.buildPythonApplication {
    pname = "git-mcp";
    version = readPyVersion "git";
    src = "${src}/src/git";
    pyproject = true;
    build-system = with python314Packages; [hatchling];
    dependencies = with python314Packages; [click gitpython mcp pydantic];
    meta.mainProgram = "mcp-server-git";
    doCheck = false;
  };

  time-mcp = python314Packages.buildPythonApplication {
    pname = "time-mcp";
    version = readPyVersion "time";
    src = "${src}/src/time";
    pyproject = true;
    build-system = with python314Packages; [hatchling];
    dependencies = with python314Packages; [mcp pydantic tzdata tzlocal];
    meta.mainProgram = "mcp-server-time";
    doCheck = false;
  };
}
