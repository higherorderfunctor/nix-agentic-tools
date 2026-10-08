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
  runtimePath = runtime: ["ai" runtime];
  launcherPath = runtime: runtimePath runtime ++ records.${runtime}.launcherOptionsPath;
in {
  inherit records;
  launcher = runtime: option: launcherPath runtime ++ [option];
  # Native settings are runtime-owned, not part of the generic launcher seam.
  # Read their declaration: a runtime may keep them at its root even when its
  # launcher is nested. Kiro declares them inside its launcher subtree.
  nativeSettings = runtime:
    (
      if lib.hasAttrByPath ["native" "settings"] records.${runtime}.options
      then runtimePath runtime
      else launcherPath runtime
    )
    ++ ["native" "settings"];
}
