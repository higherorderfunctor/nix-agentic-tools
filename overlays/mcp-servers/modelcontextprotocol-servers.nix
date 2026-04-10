# modelcontextprotocol/servers mono-repo — all packages from one source.
# Version read from each sub-package at eval time.
# Excludes `everything` (demo server).
{
  inputs,
  final,
  nv,
  ...
}: let
  ourPkgs = import inputs.nixpkgs {
    inherit (final.stdenv.hostPlatform) system;
  };
  inherit (ourPkgs) buildNpmPackage makeWrapper nodejs python314Packages;

  # Helper: read version from pyproject.toml via regex
  readPyVersion = subdir: let
    content = builtins.readFile "${nv.src}/src/${subdir}/pyproject.toml";
    lines = builtins.filter (l: builtins.isString l && l != "") (builtins.split "\n" content);
    vLine = builtins.head (builtins.filter (l: builtins.match "^version = .*" l != null) lines);
  in
    builtins.head (builtins.match "^version = \"(.*)\"$" vLine);

  # Helper: read version from package.json
  readJsVersion = subdir:
    (builtins.fromJSON (builtins.readFile "${nv.src}/src/${subdir}/package.json")).version;
in {
  # ── JS packages (buildNpmPackage) ──────────────────────────────

  sequential-thinking-mcp = buildNpmPackage {
    pname = "sequential-thinking-mcp";
    version = readJsVersion "sequentialthinking";
    inherit (nv) src;
    sourceRoot = "source/src/sequentialthinking";
    postPatch = "cp ${../locks/sequential-thinking-mcp-package-lock.json} package-lock.json";
    inherit (nv) npmDepsHash;
    dontNpmBuild = true;
    nativeBuildInputs = [makeWrapper];
    installPhase = ''
      runHook preInstall
      mkdir -p $out/lib/sequential-thinking-mcp $out/bin
      cp -r dist node_modules package.json $out/lib/sequential-thinking-mcp/
      makeWrapper ${nodejs}/bin/node $out/bin/sequential-thinking-mcp \
        --add-flags "$out/lib/sequential-thinking-mcp/dist/index.js"
      runHook postInstall
    '';
    meta.mainProgram = "sequential-thinking-mcp";
  };

  filesystem-mcp = buildNpmPackage {
    pname = "filesystem-mcp";
    version = readJsVersion "filesystem";
    inherit (nv) src;
    sourceRoot = "source/src/filesystem";
    postPatch = "cp ${../locks/filesystem-mcp-package-lock.json} package-lock.json";
    npmDepsHash = nv.filesystemMcpNpmDepsHash or nv.npmDepsHash or "";
    npmBuildScript = "build";
    nativeBuildInputs = [makeWrapper];
    installPhase = ''
      runHook preInstall
      mkdir -p $out/lib/filesystem-mcp $out/bin
      cp -r dist node_modules package.json $out/lib/filesystem-mcp/
      makeWrapper ${nodejs}/bin/node $out/bin/filesystem-mcp \
        --add-flags "$out/lib/filesystem-mcp/dist/index.js"
      runHook postInstall
    '';
    meta.mainProgram = "filesystem-mcp";
  };

  memory-mcp = buildNpmPackage {
    pname = "memory-mcp";
    version = readJsVersion "memory";
    inherit (nv) src;
    sourceRoot = "source/src/memory";
    postPatch = "cp ${../locks/memory-mcp-package-lock.json} package-lock.json";
    npmDepsHash = nv.memoryMcpNpmDepsHash or nv.npmDepsHash or "";
    npmBuildScript = "build";
    nativeBuildInputs = [makeWrapper];
    installPhase = ''
      runHook preInstall
      mkdir -p $out/lib/memory-mcp $out/bin
      cp -r dist node_modules package.json $out/lib/memory-mcp/
      makeWrapper ${nodejs}/bin/node $out/bin/memory-mcp \
        --add-flags "$out/lib/memory-mcp/dist/index.js"
      runHook postInstall
    '';
    meta.mainProgram = "memory-mcp";
  };

  # ── Python packages (buildPythonApplication) ───────────────────

  fetch-mcp = python314Packages.buildPythonApplication {
    pname = "fetch-mcp";
    version = readPyVersion "fetch";
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
    # Upstream main already fixed proxies= → proxy= (was needed for older releases).
    pythonRelaxDeps = ["httpx"];
    meta.mainProgram = "mcp-server-fetch";
    doCheck = false;
  };

  git-mcp = python314Packages.buildPythonApplication {
    pname = "git-mcp";
    version = readPyVersion "git";
    src = "${nv.src}/src/git";
    pyproject = true;
    build-system = with python314Packages; [hatchling];
    dependencies = with python314Packages; [click gitpython mcp pydantic];
    meta.mainProgram = "mcp-server-git";
    doCheck = false;
  };

  time-mcp = python314Packages.buildPythonApplication {
    pname = "time-mcp";
    version = readPyVersion "time";
    src = "${nv.src}/src/time";
    pyproject = true;
    build-system = with python314Packages; [hatchling];
    dependencies = with python314Packages; [mcp pydantic tzdata tzlocal];
    meta.mainProgram = "mcp-server-time";
    doCheck = false;
  };
}
