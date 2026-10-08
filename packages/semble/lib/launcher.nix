# Bin-only launchers avoid propagating the application's Python dependencies
# into project shells. The module and customizePackage share this constructor.
{
  lib,
  pkgs,
}: {
  package,
  spec,
  cacheDir ? null,
}: let
  configFile = import ./configFile.nix {inherit pkgs;};
  customization = import ./customization.nix {inherit lib;};
  normalized = customization.normalize spec;
  errors = customization.errors normalized;
  config = customization.config normalized;
  sembleConfig = configFile package config;
  launcherArgs =
    ["--set" "SEMBLE_NIX_CONFIG" "${sembleConfig}"]
    ++ lib.optionals (cacheDir != null) ["--set" "SEMBLE_CACHE_LOCATION" cacheDir];
in
  assert lib.assertMsg (errors == [])
  "semble.customizePackage:\n${lib.concatStringsSep "\n" errors}";
  # An unpatched consumer package silently ignores nondefault runtime config.
  assert lib.assertMsg (config == customization.config {} || (package.passthru.sembleConfigSchema or null) == 1)
  "Semble nondefault configuration requires a package exposing passthru.sembleConfigSchema = 1.";
    pkgs.runCommand "${lib.getName package}-wrapped" {
      nativeBuildInputs = [pkgs.makeWrapper];
      passthru = {
        inherit sembleConfig;
        unwrapped = package;
      };
      meta = lib.optionalAttrs (package.meta ? mainProgram) {inherit (package.meta) mainProgram;};
    } ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      mkdir -p "$out/bin" # bare-commands: ok
      for bin in ${package}/bin/*; do
        makeWrapper "$bin" "$out/bin/''${bin##*/}" ${lib.escapeShellArgs launcherArgs}
      done
    ''
