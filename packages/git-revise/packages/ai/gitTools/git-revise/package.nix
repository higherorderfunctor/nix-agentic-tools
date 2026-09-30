# git-revise — override nixpkgs to pin a newer version.
#
# nixpkgs uses buildPythonPackage with format = "setuptools" for
# an older unstable commit. v0.8.0+ switched to pyproject.toml with
# hatchling, so we override src/version AND the build system via
# overridePythonAttrs (which re-evaluates format handling).
#
# The facet composer supplies `pkgs` from this flake's pin for cache-hit parity
# (see dev/fragments/overlays/overlay-pattern.md).
#
# `passthru.extracted` is the config-key census of the source this recipe
# builds (packages/git-revise/extract/, lib/git-tool-settings). passthru is
# not a derivation input, so it does not move this package's store path.
{
  gitToolExtraction,
  packageLib,
  pkgs,
  repoPath,
  ...
}: let
  ourPkgs = pkgs;
  inherit (ourPkgs) fetchFromGitHub;
  vu = packageLib;

  rev = "a5bdbe420521a7784dd16c8f22b374b2f1d2d167";
  src = fetchFromGitHub {
    owner = "mystor";
    repo = "git-revise";
    inherit rev;
    hash = "sha256-D3MicmtruCNiW/WI37y18XDXAl7J9oJdJnDY4Ohj+rE=";
  };

  extraction = gitToolExtraction {pkgs = ourPkgs;};
  patchedSource = extraction.patchedSource {
    name = "git-revise";
    inherit package;
  };

  package = ourPkgs.git-revise.overridePythonAttrs (old: {
    version = vu.mkVersion {
      # pyproject.toml uses dynamic version (hatch); read from __init__.py
      # upstream: readPythonDunderVersion @ gitrevise/__init__.py
      upstream = "0.8.0";
      inherit rev;
    };
    inherit src;
    pyproject = true;
    format = null;
    build-system = [ourPkgs.python3Packages.hatchling];
    # v0.8.0 added test_sshsign which needs openssh (not in nixpkgs' v0.7.0 check deps)
    nativeCheckInputs =
      (old.nativeCheckInputs or [])
      ++ [ourPkgs.openssh];
    # nixpkgs builds meta.changelog from `finalAttrs.src.tag`. We pin `src`
    # to a bare rev (no tag), so src.tag is null and the base expression
    # throws `cannot coerce null to a string` the moment anything reads
    # meta.changelog (nix-update does). Repoint it at the pinned rev so the
    # changelog link stays valid instead of dropping the metadata.
    meta =
      (old.meta or {})
      // {
        changelog = "https://github.com/mystor/git-revise/blob/${rev}/CHANGELOG.md";
      };
    passthru =
      (old.passthru or {})
      // {
        inherit patchedSource;
        extracted = extraction.extracted {
          name = "git-revise";
          source = patchedSource;
          extractDir = ../../../../extract;
        };
        # A rev bump runs this through dev/scripts/update-pkg.sh, so the bump
        # PR carries the refreshed sidecar.
        regenerateExtracted = packageLib.mkRegenerateExtracted {
          name = "git-revise";
          pkgs = ourPkgs;
          targets = [
            {
              attr = "git-revise";
              dest = repoPath ../../../../extracted.json;
            }
          ];
        };
      };
  });
in
  package
