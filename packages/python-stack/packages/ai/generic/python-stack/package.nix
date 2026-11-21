# Delegate-routing and other Python consumers call withPackages on this
# interpreter. Its package set builds Pydantic and core from one release.
# cspell:ignore maturin
{
  lib,
  packageLib,
  pkgs,
  python3,
  repoPath,
}: let
  pinFile = name: let
    file =
      if name == "pydantic"
      then "sources.json"
      else "${name}-sources.json";
  in
    ../../../../. + "/${file}";
  pinFor = name: builtins.fromJSON (builtins.readFile (pinFile name));

  pinnedRelease = old: let
    pin = pinFor old.pname;
  in {
    inherit (pin) version;
    # Some nixpkgs recipes close over their old version in the changelog URL.
    meta = old.meta // {changelog = lib.replaceStrings [old.version] [pin.version] old.meta.changelog;};
    src = pkgs.fetchzip {
      name = "source";
      inherit (pin.src) url hash;
      # nixpkgs uses the release tag in changelog links.
      passthru.tag = lib.removeSuffix ".tar.gz" (baseNameOf pin.src.url);
    };
  };

  maturin =
    pkgs.buildPackages.maturin.overrideAttrs (old:
      pinnedRelease old // {cargoHash = (pinFor "maturin").cargoHash or lib.fakeHash;});

  # The hook brings its own maturin onto PATH alongside cargo and rustc.
  rustPlatform =
    pkgs.rustPlatform
    // {
      maturinBuildHook = pkgs.rustPlatform.maturinBuildHook.overrideAttrs (old: {
        propagatedBuildInputs = builtins.map (dep:
          if dep == pkgs.buildPackages.maturin
          then maturin
          else dep)
        old.propagatedBuildInputs;
      });
    };

  python = python3.override {
    self = python;
    packageOverrides = final: prev:
      lib.genAttrs ["annotated-types" "typing-extensions" "typing-inspection"]
      (name: prev.${name}.overridePythonAttrs pinnedRelease)
      // {
        pydantic = prev.pydantic.overridePythonAttrs (old:
          pinnedRelease old
          // {
            # This release includes the pytest compatibility change.
            patches = builtins.filter (patch: (patch.name or "") != "pytest-9.1-compat.patch") (old.patches or []);
          });
        pydantic-core = (prev.pydantic-core.override {inherit rustPlatform;}).overridePythonAttrs (finalAttrs: old: {
          inherit (pinFor "pydantic-core") version;
          inherit (final.pydantic) src;
          sourceRoot = "${finalAttrs.src.name}/pydantic-core";
          passthru =
            old.passthru
            // {
              tests =
                old.passthru.tests
                // {
                  pytest = final.pydantic-core.overridePythonAttrs {doCheck = true;};
                };
            };
          cargoDeps = rustPlatform.fetchCargoVendor {
            # A new Pydantic tag can change Cargo.lock at the same core version.
            pname = "pydantic-${final.pydantic.version}-core";
            inherit (finalAttrs) version src sourceRoot;
            hash = (pinFor "pydantic-core").cargoHash or lib.fakeHash;
          };
        });
      };
  };
in
  python.overrideAttrs (old: {
    passthru =
      old.passthru
      // (import ../../../../lib/update.nix {inherit packageLib pinFile pkgs repoPath;})
      // {maturinCargoDeps = maturin.cargoDeps;};
  })
