# The interpreter exposes these scripts to the update sweep. Refresh the
# release and its dependency pins before building the two Cargo vendor sets.
# cspell:ignore maturin
{
  packageLib,
  pinFile,
  pkgs,
  repoPath,
}: let
  attr = "python-stack";
  sourcesFile = name: repoPath (pinFile name);
  runtimeParent = project: {
    inherit project;
    sourcesFile = sourcesFile project;
  };
  updateArchive = pname: repo: options:
    packageLib.ghArchiveUpdateScript ({
        inherit pkgs pname repo;
        sourcesFile = sourcesFile pname;
      }
      // options);
  updateDependency = pname: repo: parents: options:
    updateArchive pname repo (options
      // {
        versionCheck.cmd = packageLib.pythonDependencyVersionCmd {
          inherit pkgs parents;
          dependency = pname;
        };
      });

  pydantic = runtimeParent "pydantic";
  pydanticRepo = "pydantic/pydantic";
  updatePydantic = updateArchive "pydantic" pydanticRepo {
    versionCheck.cmd = "${pkgs.curl}/bin/curl -fsSL https://pypi.org/pypi/pydantic/json | ${pkgs.jq}/bin/jq -er '.info.version'";
  };
  updateCore = packageLib.mkUpdateScript {
    inherit pkgs;
    pname = "pydantic-core";
    sourcesFile = sourcesFile "pydantic-core";
    platforms = {};
    # Read the new tag from the worktree even when the updater was built at the old one.
    versionCheck.cmd = ''
      src=$(${pkgs.nix}/bin/nix build --no-link --print-out-paths ".#${packageLib.ciAttr {inherit attr pkgs;}}.pkgs.pydantic.src")
      ${pkgs.python3.withPackages (ps: [ps.packaging])}/bin/python3 -I ${./core-version.py} "$src"
    '';
  };
  updateMaturin = updateDependency "maturin" "PyO3/maturin" [
    {
      inherit (pydantic) sourcesFile;
      pyprojectUrl = "https://raw.githubusercontent.com/${pydanticRepo}/v{version}/pydantic-core/pyproject.toml";
    }
  ] {};
  updateAnnotatedTypes = updateDependency "annotated-types" "annotated-types/annotated-types" [pydantic] {};
  updateTypingInspection = updateDependency "typing-inspection" "pydantic/typing-inspection" [pydantic] {};
  updateTypingExtensions = updateDependency "typing-extensions" "python/typing_extensions" [
    pydantic
    (runtimeParent "pydantic-core")
    (runtimeParent "typing-inspection")
  ] {tagPrefix = "";};

  fixCargoHash = pname: attrPath:
    packageLib.mkHashFix {
      inherit attr pkgs pname;
      name = "cargo-hash";
      sourcesFile = sourcesFile pname;
      targets = [(packageLib.hashFixTargets.cargoVendor // {inherit attrPath;})];
    };
  rustUpdateExtract = pkgs.writeShellScript "fix-python-stack-cargo-hashes" ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
    ${fixCargoHash "pydantic-core" "pkgs.pydantic-core.cargoDeps"}
    ${fixCargoHash "maturin" "maturinCargoDeps"}
  '';
in {
  inherit rustUpdateExtract;
  updateScript = pkgs.writeShellScript "update-python-stack" ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
    ${updatePydantic}
    ${updateCore}
    ${updateMaturin}
    ${updateAnnotatedTypes}
    ${updateTypingInspection}
    ${updateTypingExtensions}
    ${rustUpdateExtract}
  '';
}
