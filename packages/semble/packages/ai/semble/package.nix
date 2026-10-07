# cspell:ignore manylinux
{
  fetchFromGitHub,
  lib,
  makeWrapper,
  packageLib,
  pkgs,
  python3,
  repoPath,
  versionCheckHook,
  writableTmpDirAsHomeHook,
}: let
  inherit (python3.pkgs) buildPythonPackage;
  buildSystem = with python3.pkgs; [setuptools setuptools-scm];
  sources = name: builtins.fromJSON (builtins.readFile (../../../sources + "/${name}.json"));
  sembleSources = sources "semble";
  grammarSources = sources "semble-grammars";
  sdistUrl = pname: version: "https://files.pythonhosted.org/packages/source/${builtins.substring 0 1 pname}/${pname}/${pname}-${version}.tar.gz";
  grammarPlatforms = {
    aarch64-darwin = "macosx_11_0_arm64";
    aarch64-linux = "manylinux2014_aarch64";
    x86_64-darwin = "macosx_10_13_x86_64";
    x86_64-linux = "manylinux2014_x86_64";
  };
  updateRows = {
    model2vec.platforms.src = sdistUrl "model2vec";
    semble = {
      platforms.src = version: "https://github.com/MinishLab/semble/archive/v${version}.tar.gz";
      unpack = true;
    };
    semble-grammars.platforms = lib.mapAttrs (_: platform: version: "https://files.pythonhosted.org/packages/py3/s/semble_grammars/semble_grammars-${version}-py3-none-${platform}.whl") grammarPlatforms;
    vicinity.platforms.src = sdistUrl "vicinity";
  };
  updateScript = pkgs.writeShellScript "update-semble-group" ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
    ${lib.concatStringsSep "\n" (lib.mapAttrsToList (pname: row: "${packageLib.mkUpdateScript (row
      // {
        inherit pkgs pname;
        sourcesFile = repoPath (../../../sources + "/${pname}.json");
        versionCheck.cmd = "${pkgs.curl}/bin/curl -fsSL https://pypi.org/pypi/${pname}/json | ${pkgs.jq}/bin/jq -r '.info.version'";
      })}")
    updateRows)}
    ${lib.concatMapStringsSep "\n" (target:
      packageLib.mkExtractRegen (target
        // {
          attr = "semble";
          inherit pkgs;
        })) [
      {dest = repoPath ../../../extracted.json;}
      {
        dest = repoPath ../../../upstream-templates.json;
        extract = "extractedTemplates";
      }
    ]}
  '';

  # Some of semble's direct runtime dependencies are not in nixpkgs.
  # Vendor them inline, since
  # they have no consumer in this flake other than semble itself.

  model2vec = python3.pkgs.buildPythonPackage rec {
    pname = "model2vec";
    inherit (sources "model2vec") version;
    pyproject = true;

    src = pkgs.fetchurl {inherit ((sources "model2vec").src) url hash;};

    build-system = buildSystem;

    env.SETUPTOOLS_SCM_PRETEND_VERSION = version;

    dependencies = with python3.pkgs; [
      jinja2
      joblib
      numpy
      rich
      safetensors
      setuptools
      tokenizers
      tqdm
    ];

    # Tests require torch + the [distill] / [train] extras, which we do not ship.
    doCheck = false;

    pythonImportsCheck = ["model2vec"];

    meta = with lib; {
      description = "Distill a small fast model from any sentence transformer";
      homepage = "https://github.com/MinishLab/model2vec";
      license = licenses.mit;
      platforms = platforms.all;
      sourceProvenance = with sourceTypes; [fromSource];
    };
  };

  vicinity = python3.pkgs.buildPythonPackage rec {
    pname = "vicinity";
    inherit (sources "vicinity") version;
    pyproject = true;

    src = pkgs.fetchurl {inherit ((sources "vicinity").src) url hash;};

    build-system = buildSystem;

    env.SETUPTOOLS_SCM_PRETEND_VERSION = version;

    dependencies = with python3.pkgs; [
      numpy
      orjson
      tqdm
    ];

    # Tests require optional backends that we don't ship.
    doCheck = false;

    pythonImportsCheck = ["vicinity"];

    meta = with lib; {
      description = "Lightweight nearest neighbors library with flexible backends";
      homepage = "https://github.com/MinishLab/vicinity";
      license = licenses.mit;
      platforms = platforms.all;
      sourceProvenance = with sourceTypes; [fromSource];
    };
  };

  # The grammar project publishes wheels only; building its 77 grammars
  # from source is a separate packaging change.
  semble-grammars = buildPythonPackage {
    pname = "semble-grammars";
    inherit (grammarSources) version;
    format = "wheel";

    src = pkgs.fetchurl {inherit (grammarSources.${pkgs.stdenv.hostPlatform.system}) url hash;};

    dependencies = with python3.pkgs; [
      tree-sitter
    ];

    pythonImportsCheck = ["semble_grammars"];

    meta = with lib; {
      description = "Prebuilt tree-sitter grammars for Semble";
      homepage = "https://github.com/MinishLab/semble-grammars";
      license = licenses.mit;
      platforms = builtins.attrNames grammarPlatforms;
      sourceProvenance = with sourceTypes; [binaryNativeCode];
    };
  };
in
  python3.pkgs.buildPythonApplication (finalAttrs: {
    pname = "semble";
    inherit (sembleSources) version;
    pyproject = true;

    src = fetchFromGitHub {
      owner = "MinishLab";
      repo = "semble";
      tag = "v${sembleSources.version}";
      inherit (sembleSources.src) hash;
    };

    build-system = buildSystem;

    # setuptools_scm normally derives the version from git metadata, but the
    # fetched source tarball has none. Inject the version explicitly so the
    # build doesn't fall back to 0.0.0+unknown (which would also break the
    # static `attr = semble.version.__version__` resolver in pyproject.toml).
    env.SETUPTOOLS_SCM_PRETEND_VERSION = finalAttrs.version;

    # Ship the [mcp] extra unconditionally — Nix users get one closure either
    # way, and exposing both binaries (`semble` and `semble-mcp`) is cleaner
    # than gating MCP behind a separate derivation.
    dependencies = with python3.pkgs; [
      mcp
      model2vec
      numpy
      orjson
      pathspec
      questionary
      semble-grammars
      tree-sitter
      vicinity
    ];

    nativeBuildInputs = [makeWrapper];

    # Upstream's `semble` entry point auto-dispatches to either the CLI or the
    # MCP server based on argv[1]. Expose a second binary that always launches
    # the MCP server so users can wire it into agent configs without relying on
    # the implicit "no-subcommand-means-MCP" behavior.
    # Scope nounset: nixpkgs' later Python wrapping hook reads unset array keys.
    postInstall = ''
      (
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        makeWrapper "$out/bin/semble" "$out/bin/semble-mcp"
      )
    '';

    pythonImportsCheck = [
      "semble"
      "semble.cli"
      "semble.mcp"
    ];

    doInstallCheck = true;
    nativeInstallCheckInputs = [versionCheckHook writableTmpDirAsHomeHook];
    # Bind the check to this package's version even when an overlay's shell
    # carries a different version variable into the hook.
    preVersionCheck = ''
      version="${finalAttrs.version}"
    '';

    passthru =
      {
        inherit model2vec semble-grammars updateScript vicinity;
      }
      // (import ../../../extract {inherit lib pkgs;}) finalAttrs.finalPackage;

    meta = with lib; {
      changelog = "https://github.com/MinishLab/semble/releases/tag/v${finalAttrs.version}";
      description = "Fast and accurate local code search for AI agents — CLI and MCP server";
      homepage = "https://github.com/MinishLab/semble";
      license = licenses.mit;
      mainProgram = "semble";
      platforms = builtins.attrNames grammarPlatforms;
      sourceProvenance = with sourceTypes; [fromSource];
    };
  })
