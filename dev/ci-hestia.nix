# The CI-only Hestia binary uses the pinned action source plus the local
# manifest-scope and GC retention patches. dev/scripts/test-ci-cache.py checks
# the action pin against `rev`.
{
  inputs,
  pkgs,
}: let
  inherit (pkgs) lib;
  version = "3.1.0";
  rev = "dfed9ced335d28978ba74e513939a10db1f71025";
  src = pkgs.fetchFromGitHub {
    owner = "Mic92";
    repo = "hestia";
    inherit rev;
    hash = "sha256-R7SCvfTAtoRR6PuwUQlthLIypzmo6QHCKx/fFdPHKUU=";
  };
  rustPlatform = (import ../lib/toolchains.nix {inherit inputs;}).mkRustPlatform {inherit pkgs;};
  gitPackages =
    builtins.filter
    (package: lib.hasPrefix "git+" (package.source or ""))
    (builtins.fromTOML (builtins.readFile "${src}/Cargo.lock")).package;
in
  rustPlatform.buildRustPackage {
    pname = "ci-hestia";
    inherit version src;
    patches = [
      ../.github/actions/check-cache/patches/pr-manifest-scope.patch
      ../.github/actions/check-cache/patches/gc-pr-manifest-retention.patch
    ];
    postPatch = ''
      (
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      grep -m1 '^version = ' Cargo.toml | grep -Fx 'version = "${version}"'
      )
    '';
    cargoLock = {
      lockFile = "${src}/Cargo.lock";
      outputHashes =
        lib.genAttrs
        (map (package: "${package.name}-${package.version}") gitPackages)
        (_: "sha256-SKjUIxSvmEFYW+sMkFkyNVo4U5cOGwqZ48DTl0h8gDk=");
    };
    doCheck = true;
    # Nounset must not leak into stdenv's strip.sh during fixupPhase.
    checkPhase = ''
      (
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      export NIX_SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt
      export SSL_CERT_FILE="$NIX_SSL_CERT_FILE"
      runHook preCheck
      cargo test --offline --workspace --lib
      cargo test --offline --test gc
      cargo test --offline --test gc_pr_retention
      cargo test --offline --test pr_manifest_scope
      runHook postCheck
      )
    '';
    passthru.updateScript = pkgs.writeShellScript "update-ci-hestia" ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      exec ${pkgs.python3}/bin/python3 ${./scripts/update-ci-hestia.py} \
        ${pkgs.gh}/bin/gh ${pkgs.git}/bin/git \
        ${pkgs.nix}/bin/nix-prefetch-url ${pkgs.nix}/bin/nix
    '';
    meta = {
      description = "Patched Hestia binary for CI check caching";
      homepage = "https://github.com/Mic92/hestia";
      license = lib.licenses.mit;
      mainProgram = "hestia";
      platforms = lib.platforms.linux;
    };
  }
