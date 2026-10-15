# Internal option addresses shared by policy facts and cross-runtime checks.
# Read record metadata only: policy callers need neither a package set nor a
# module evaluation. Supplying pkgs also makes the records usable by checks.
{
  lib,
  pkgs ? null,
}: let
  recordLib = lib // {ai = import ./. {inherit lib;};};
  records = lib.mapAttrs (_: file:
    import file {
      lib = recordLib;
      inherit pkgs;
    }) {
    claude = ../../packages/claude-code/lib/mkClaude.nix;
    codex = ../../packages/chatgpt-codex/lib/mkCodex.nix;
    copilot = ../../packages/copilot-cli/lib/mkCopilot.nix;
    kimchi = ../../packages/kimchi/lib/mkKimchi.nix;
    kiro = ../../packages/kiro-cli/lib/mkKiro.nix;
  };
  namespaces = import ./app/optionNamespaces.nix {inherit lib;};
  runtimePath = runtime: ["ai" runtime];
  launcherPath = runtime: runtimePath runtime ++ namespaces.launcher records.${runtime};
  # Both backends declare the same option tree, so the record's shared
  # options with either backend's additions show where it is.
  declaredOptions = runtime: let
    record = records.${runtime};
  in
    lib.recursiveUpdate record.options (record.hm.options or {});
  nativeSettingsPath = runtime:
    lib.findFirst (path: lib.hasAttrByPath (lib.drop 2 path) (declaredOptions runtime)) null
    (map (base: base ++ ["native" "settings"]) [(runtimePath runtime) (launcherPath runtime)]);
in {
  inherit records;
  # Whether the runtime ships a launcher (its package).
  hasLauncher = runtime: namespaces.hasLauncher records.${runtime};
  # The settable runtime switch.
  enable = runtime: runtimePath runtime ++ namespaces.enable records.${runtime};
  launcher = runtime: option: launcherPath runtime ++ [option];
  # A shared surface's per-runtime pool option.
  pool = runtime: surface: runtimePath runtime ++ namespaces.pool records.${runtime} surface ++ [surface];
  # Native settings are runtime-owned, not part of the generic launcher seam.
  # Read their declaration: a runtime may keep them at its root even when its
  # launcher is nested. Kiro declares them inside its launcher subtree, and
  # github.com Copilot reads no settings file, so it declares none.
  hasNativeSettings = runtime: nativeSettingsPath runtime != null;
  nativeSettings = runtime: let
    path = nativeSettingsPath runtime;
  in
    if path == null
    then throw "option-paths: ${runtime} declares no native settings"
    else path;
}
