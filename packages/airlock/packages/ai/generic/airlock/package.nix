# cspell:ignore bintools
# airlock is built from the in-repo Cargo workspace and its independently
# built web app. A UI-only edit does not change the Rust derivation.
{
  packageLib,
  pkgs,
  ...
}: let
  inherit (pkgs) lib;
  rustPlatform = packageLib.mkRustPlatform {inherit pkgs;};
  root = ../../../..;
  cargoRoot = root + "/src";
  webRoot = root + "/web";
  version = (lib.importTOML (cargoRoot + "/Cargo.toml")).workspace.package.version;
  biomeCpu =
    if pkgs.stdenv.hostPlatform.isx86_64
    then "x64"
    else "arm64";
  frontend = pkgs.buildNpmPackage {
    pname = "airlock-web";
    inherit version;
    src = lib.fileset.toSource {
      inherit root;
      fileset = lib.fileset.unions [
        (root + "/web-fixtures")
        (webRoot + "/.gitignore")
        (webRoot + "/biome.json")
        (webRoot + "/fixtures")
        (webRoot + "/index.html")
        (webRoot + "/package-lock.json")
        (webRoot + "/package.json")
        (webRoot + "/src")
        (webRoot + "/tests")
        (webRoot + "/tsconfig.json")
        (webRoot + "/vite.config.ts")
      ];
    };
    sourceRoot = "source/web";
    nodejs = pkgs.nodejs_24;
    npmDepsFetcherVersion = 2;
    npmDepsHash = "sha256-o9Tj8KKmmWvHbaFUyPi1CJnkw6+Wnkg9sVR0LRCVqR0=";
    nativeBuildInputs = lib.optionals pkgs.stdenv.hostPlatform.isLinux [pkgs.patchelf];
    doCheck = true;
    checkPhase = ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      runHook preCheck
      ${lib.optionalString pkgs.stdenv.hostPlatform.isLinux ''
        patchelf --set-interpreter ${pkgs.stdenv.cc.bintools.dynamicLinker} \
          --set-rpath ${lib.makeLibraryPath [pkgs.stdenv.cc.cc.lib pkgs.glibc]} \
          node_modules/@biomejs/cli-linux-${biomeCpu}/biome
      ''}
      npm run typecheck
      npm run lint
      npm test
      runHook postCheck
    '';
    installPhase = ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      runHook preInstall
      mkdir -p "$out"
      cp -r dist/. "$out/"
      runHook postInstall
    '';
  };
  raw = rustPlatform.buildRustPackage {
    pname = "airlock-raw";
    inherit version;
    # Only Cargo inputs enter this source. The frontend is a separate closure.
    src = lib.fileset.toSource {
      inherit root;
      fileset = lib.fileset.unions [cargoRoot (root + "/web-fixtures")];
    };
    sourceRoot = "source/src";
    cargoLock.lockFile = cargoRoot + "/Cargo.lock";
    SQLX_OFFLINE = "true";
    meta = {
      description = "Credential-injecting egress gateway for coding harnesses";
      mainProgram = "airlock";
    };
  };
  # The check substitutes an argv-recording executable while the Rust control
  # server is developed independently.
  mkLauncher = executable:
    (pkgs.writeShellScriptBin "airlock" ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      if [[ ''${1-} == serve ]]; then
        for argument in "$@"; do
          if [[ $argument == --web-root || $argument == --web-root=* ]]; then
            exec "${executable}/bin/airlock" "$@"
          fi
        done
        exec "${executable}/bin/airlock" "$@" --web-root "${frontend}"
      fi
      exec "${executable}/bin/airlock" "$@"
    '').overrideAttrs (old: {
      name = "airlock-${version}";
      passthru =
        (old.passthru or {})
        // {
          inherit frontend mkLauncher raw;
          updateTargetExempt = "built from the in-repo workspace; its Cargo.toml version has no upstream release";
        };
      meta =
        (old.meta or {})
        // {
          description = "Credential-injecting egress gateway for coding harnesses and web UI";
          mainProgram = "airlock";
        };
    });
in
  mkLauncher raw
