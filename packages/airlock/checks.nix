{pkgs, ...}: let
  package = pkgs.ai.generic.airlock;
in {
  imports = [./checks/airlock-instances.nix ./checks/claude-launch.nix];

  # nixpkgs' buildRustPackage has no clippy hook, so reuse the package's
  # offline vendored-dependency setup and run clippy instead of the build.
  checks.airlock-clippy = package.overrideAttrs {
    name = "airlock-clippy";
    # A subshell keeps nounset out of the stdenv phases that follow.
    buildPhase = ''
      (
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      runHook preBuild
      cargo clippy --offline --all-targets -- -D warnings
      runHook postBuild
      )
    '';
    doCheck = false;
    installPhase = ''touch "$out"'';
    dontFixup = true;
  };

  checks.airlock-sqlx-metadata = package.overrideAttrs (old: {
    name = "airlock-sqlx-metadata";
    # Preparation must inspect its fresh database; package builds stay offline.
    SQLX_OFFLINE = "false";
    nativeBuildInputs =
      old.nativeBuildInputs or [] ++ [pkgs.diffutils pkgs.jq pkgs.sqlx-cli];
    # A clean regeneration catches changed SQL/types and orphan metadata files.
    buildPhase = ''
      (
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      runHook preBuild
      workspace="$NIX_BUILD_TOP/metadata-workspace"
      expected="$NIX_BUILD_TOP/expected-metadata"
      expectedCanonical="$NIX_BUILD_TOP/expected-metadata-canonical"
      actualCanonical="$NIX_BUILD_TOP/actual-metadata-canonical"
      databaseUrl="sqlite://$NIX_BUILD_TOP/metadata.sqlite3"
      mkdir -p "$workspace"
      cp -a . "$workspace"/.
      mv "$workspace/.sqlx" "$expected"
      mkdir "$workspace/.sqlx"
      DATABASE_URL="$databaseUrl" sqlx database create
      DATABASE_URL="$databaseUrl" sqlx migrate run \
        --source "$workspace/crates/airlock-core/migrations"
      (
        cd "$workspace"
        CARGO="$(command -v cargo)" DATABASE_URL="$databaseUrl" \
          sqlx prepare --workspace
      )
      mkdir -p "$expectedCanonical" "$actualCanonical"
      for metadata in "$expected"/*.json; do
        jq -S . "$metadata" > "$expectedCanonical/$(basename "$metadata")"
      done
      for metadata in "$workspace/.sqlx"/*.json; do
        jq -S . "$metadata" > "$actualCanonical/$(basename "$metadata")"
      done
      diff -ru "$expectedCanonical" "$actualCanonical"
      runHook postBuild
      )
    '';
    doCheck = false;
    installPhase = ''touch "$out"'';
    dontFixup = true;
  });
}
